// Infinite Recall fork: on-device speaker diarization. No cloud calls.
//
// Subscribes to the same mono Float32 PCM stream that WhisperKit consumes, runs
// a lightweight VAD over it to extract speech turns, embeds each turn via
// MFCCExtractor, clusters within the live session, and matches against the
// global SpeakerEmbeddingStore so previously-named people are auto-tagged.
//
// Best-effort: any failure here is swallowed — capture and WhisperKit
// transcription stay live regardless of diarization state. See
// `enable()`/`disable()` and the early-return guards in `appendSamples`.
//
// v1 simplification (intentional, called out in commit message):
//   - Energy-based VAD with hangover (no neural VAD model).
//   - Single-speaker-per-turn clustering — overlapped speakers are tagged with
//     whichever cluster the dominant energy lands in. Real overlap detection
//     would require a pyannote-style segmentation model; we leave the seam in
//     `embed(samples:)` to swap a neural embedding in later.
//   - Per-session cluster ids start from 0; cross-session matching happens by
//     cosine on embeddings against named-person centroids.

import Foundation

/// One emitted diarization result — a single contiguous speech turn with its
/// session-local cluster id and (optionally) the auto-matched person.
struct DiarizationTurn {
    let speakerId: Int
    let personId: String?
    let similarity: Float?      // confidence of the personId match if any
    let start: Double           // seconds since session start
    let end: Double
    let embedding: [Float]      // L2-normalized
}

/// Audio sink the rest of the app calls into. Designed to mirror the
/// TranscriptionService.sendAudio shape so wiring is symmetrical.
@MainActor
protocol DiarizationSink: AnyObject {
    func sendDiarizationAudio(_ data: Data)
    func setDiarizationSession(id: Int64?, startedAt: Date?)
    func startDiarization(onTurn: @escaping (DiarizationTurn) -> Void)
    func stopDiarization()
}

/// Singleton owner of the diarization pipeline.
final class SpeakerDiarizationService: @unchecked Sendable {
    static let shared = SpeakerDiarizationService()

    // MARK: - Tuning constants (16 kHz mono assumed)

    /// Frame length for VAD energy decisions (20 ms).
    private let vadFrameSamples: Int = 320
    /// Energy threshold above which a frame is marked "voiced".
    /// Calibrated against [-1, 1]-normalized Float32 PCM.
    private let vadEnergyThreshold: Float = 0.0008
    /// How many consecutive non-voiced frames close out a turn (~600 ms).
    private let vadHangoverFrames: Int = 30
    /// Minimum turn duration we'll bother embedding (~0.6 s).
    private let minTurnSeconds: Double = 0.6
    /// Maximum turn duration before we force-emit and start a new turn (~12 s).
    private let maxTurnSeconds: Double = 12.0
    /// Cosine threshold between session-local clusters; below this means new cluster.
    private let intraSessionThreshold: Float = 0.78
    /// Max session-local clusters we'll create before falling back to "Speaker N".
    private let maxSessionClusters: Int = 8

    // MARK: - State

    private let mfcc = MFCCExtractor()
    private let stateLock = NSLock()
    private var isEnabled: Bool = false
    private var sessionId: Int64?
    private var sessionStartedAt: Date?

    /// Float32 ring of unvoiced+voiced samples for the current potential turn.
    private var turnBuffer: [Float] = []
    /// Sample index (since session start) of the first sample currently in `turnBuffer`.
    private var turnStartSampleIndex: Int = 0
    /// Total samples seen (since session start) — drives wall-clock turn boundaries.
    private var totalSamplesSeen: Int = 0
    /// Consecutive non-voiced frame counter for hangover.
    private var unvoicedFrameRun: Int = 0
    /// Are we currently inside a voiced segment?
    private var inVoiced: Bool = false

    /// Session-local clusters (centroid + count) — replaced on each new session.
    private struct LocalCluster {
        var centroid: [Float]
        var count: Int
    }
    private var sessionClusters: [LocalCluster] = []

    private var onTurn: ((DiarizationTurn) -> Void)?

    /// Compact timeline of recently-completed turns, used so the transcription
    /// segment handler can ask "who was talking at second X?" when WhisperKit
    /// emits a transcript line. Bounded to the last `maxTimelineEntries` turns
    /// — older entries are dropped because WhisperKit emits in ~real-time.
    private var timeline: [DiarizationTurn] = []
    private let maxTimelineEntries = 256

    private init() {}

    /// Best-effort lookup: which speaker was talking around `seconds` (since
    /// session start)? Returns the most recent turn that contains the time, or
    /// the closest preceding turn within 1.5s, or nil. Thread-safe.
    func lookupSpeaker(at seconds: Double) -> (speakerId: Int, personId: String?)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        // Walk back-to-front since the latest turn is most likely the match.
        var bestPrecedingDelta: Double = .infinity
        var bestPreceding: DiarizationTurn?
        for turn in timeline.reversed() {
            if seconds >= turn.start && seconds <= turn.end {
                return (turn.speakerId, turn.personId)
            }
            if seconds > turn.end {
                let delta = seconds - turn.end
                if delta < bestPrecedingDelta {
                    bestPrecedingDelta = delta
                    bestPreceding = turn
                }
            }
        }
        if let t = bestPreceding, bestPrecedingDelta <= 1.5 {
            return (t.speakerId, t.personId)
        }
        return nil
    }

    // MARK: - Lifecycle

    /// Begin a new diarization session. Safe to call repeatedly.
    func start(
        sessionId: Int64?,
        startedAt: Date?,
        onTurn: @escaping (DiarizationTurn) -> Void
    ) {
        stateLock.lock()
        self.isEnabled = true
        self.sessionId = sessionId
        self.sessionStartedAt = startedAt
        self.turnBuffer.removeAll(keepingCapacity: true)
        self.turnStartSampleIndex = 0
        self.totalSamplesSeen = 0
        self.unvoicedFrameRun = 0
        self.inVoiced = false
        self.sessionClusters.removeAll(keepingCapacity: false)
        self.timeline.removeAll(keepingCapacity: false)
        self.onTurn = onTurn
        stateLock.unlock()

        Task { await SpeakerEmbeddingStore.shared.reset() }
        log("SpeakerDiarizationService: Started (sessionId=\(sessionId.map(String.init) ?? "nil"))")
    }

    /// Update the session id mid-capture (mirrors AudioPersistenceService).
    func setSessionId(_ id: Int64?, startedAt: Date?) {
        stateLock.lock()
        self.sessionId = id
        if let startedAt = startedAt {
            self.sessionStartedAt = startedAt
        }
        stateLock.unlock()
    }

    /// Tear down — flushes any in-flight turn first.
    func stop() {
        flushIfPossible()
        stateLock.lock()
        isEnabled = false
        sessionId = nil
        sessionStartedAt = nil
        onTurn = nil
        turnBuffer.removeAll(keepingCapacity: false)
        sessionClusters.removeAll(keepingCapacity: false)
        timeline.removeAll(keepingCapacity: false)
        stateLock.unlock()
        log("SpeakerDiarizationService: Stopped")
    }

    // MARK: - Audio ingestion

    /// Feed Int16 PCM bytes (mono, 16 kHz) — same shape as `TranscriptionService.sendAudio`.
    func appendAudio(_ data: Data) {
        guard isEnabled else { return }
        let samples = TranscriptionService.int16PCMToFloat32(data)
        guard !samples.isEmpty else { return }
        appendSamples(samples)
    }

    /// Internal entry point that takes Float32 samples directly.
    private func appendSamples(_ samples: [Float]) {
        // Cheap fast path: if we're disabled, drop. We re-check inside the
        // lock to avoid racing with stop().
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabled else { return }

        // Process in vadFrameSamples-sized frames.
        var idx = 0
        while idx + vadFrameSamples <= samples.count {
            let frame = Array(samples[idx..<(idx + vadFrameSamples)])
            let voiced = frameIsVoiced(frame)

            if voiced {
                if !inVoiced {
                    // Start of a new turn — note the sample index.
                    turnStartSampleIndex = totalSamplesSeen
                    inVoiced = true
                }
                turnBuffer.append(contentsOf: frame)
                unvoicedFrameRun = 0
            } else if inVoiced {
                // Append silent frame to provide context for tail of word, then
                // count toward hangover.
                turnBuffer.append(contentsOf: frame)
                unvoicedFrameRun += 1
                if unvoicedFrameRun >= vadHangoverFrames {
                    finalizeTurnLocked()
                }
            } else {
                // Not in voiced segment — drop the frame.
            }

            // Force-emit on overlong turns.
            if inVoiced {
                let turnDuration = Double(turnBuffer.count) / Double(MFCCConfig.sampleRate)
                if turnDuration >= maxTurnSeconds {
                    finalizeTurnLocked()
                }
            }

            totalSamplesSeen += vadFrameSamples
            idx += vadFrameSamples
        }
        // Any straggler samples (< 1 frame) are dropped at boundary; they get
        // re-fed on the next chunk via TranscriptionService's caller cadence.
    }

    /// Quick energy-based voice activity detection: a frame is voiced if its
    /// mean-square energy exceeds `vadEnergyThreshold`.
    private func frameIsVoiced(_ frame: [Float]) -> Bool {
        var energy: Float = 0
        for s in frame {
            energy += s * s
        }
        energy /= Float(frame.count)
        return energy >= vadEnergyThreshold
    }

    /// Force-flush any in-flight turn (called from stop()).
    private func flushIfPossible() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if inVoiced {
            finalizeTurnLocked()
        }
    }

    /// Finalize the current turn, embed it, match it, and emit. Caller must
    /// hold `stateLock`.
    private func finalizeTurnLocked() {
        let samples = turnBuffer
        let startSample = turnStartSampleIndex
        let endSample = totalSamplesSeen
        // Reset turn state immediately so a new turn can start.
        turnBuffer.removeAll(keepingCapacity: true)
        unvoicedFrameRun = 0
        inVoiced = false

        let durationSec = Double(samples.count) / Double(MFCCConfig.sampleRate)
        guard durationSec >= minTurnSeconds else { return }
        guard let embedding = mfcc.embed(samples: samples) else { return }

        // Local cluster assignment.
        let speakerId = assignSessionCluster(for: embedding)

        let startSec = Double(startSample) / Double(MFCCConfig.sampleRate)
        let endSec = Double(endSample) / Double(MFCCConfig.sampleRate)
        let sid = sessionId
        let handler = onTurn

        // Async match + persist outside the lock.
        Task { [embedding, speakerId, startSec, endSec, sid, handler] in
            let match = await SpeakerEmbeddingStore.shared.matchPerson(embedding: embedding)
            let turn = DiarizationTurn(
                speakerId: speakerId,
                personId: match?.personId,
                similarity: match?.similarity,
                start: startSec,
                end: endSec,
                embedding: embedding
            )
            self.appendToTimeline(turn)
            if let sid = sid {
                _ = await SpeakerEmbeddingStore.shared.recordEmbedding(
                    sessionId: sid,
                    chunkId: nil,
                    embedding: embedding,
                    startTime: startSec,
                    endTime: endSec,
                    speakerId: speakerId,
                    personId: match?.personId
                )
            }
            if let handler = handler {
                await MainActor.run { handler(turn) }
            }
        }
    }

    private func appendToTimeline(_ turn: DiarizationTurn) {
        stateLock.lock()
        timeline.append(turn)
        if timeline.count > maxTimelineEntries {
            timeline.removeFirst(timeline.count - maxTimelineEntries)
        }
        stateLock.unlock()
    }

    /// Find or create a session-local cluster matching the given embedding.
    private func assignSessionCluster(for embedding: [Float]) -> Int {
        var bestIdx: Int = -1
        var bestSim: Float = -.infinity
        for (i, cluster) in sessionClusters.enumerated() {
            guard cluster.centroid.count == embedding.count else { continue }
            let sim = cosineSimilarity(cluster.centroid, embedding)
            if sim > bestSim {
                bestSim = sim
                bestIdx = i
            }
        }
        if bestIdx >= 0, bestSim >= intraSessionThreshold {
            // Update centroid (running mean, then renormalize).
            var cluster = sessionClusters[bestIdx]
            let n = Float(cluster.count)
            for i in 0..<cluster.centroid.count {
                cluster.centroid[i] = (cluster.centroid[i] * n + embedding[i]) / (n + 1)
            }
            var norm: Float = 0
            for x in cluster.centroid { norm += x * x }
            norm = sqrt(norm)
            if norm > 1e-6 {
                for i in 0..<cluster.centroid.count {
                    cluster.centroid[i] /= norm
                }
            }
            cluster.count += 1
            sessionClusters[bestIdx] = cluster
            return bestIdx
        }
        // Create a new cluster (capped).
        if sessionClusters.count >= maxSessionClusters {
            // Fall back to nearest existing — better to slightly mis-cluster than to spawn unbounded ids.
            return max(bestIdx, 0)
        }
        sessionClusters.append(LocalCluster(centroid: embedding, count: 1))
        return sessionClusters.count - 1
    }
}
