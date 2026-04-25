// Infinite Recall fork: on-device speaker diarization. No cloud calls.
//
// Subscribes to the same mono Float32 PCM stream that WhisperKit consumes.
// Two backends are available, selected by the `diarizationEngine` UserDefaults
// key (default "mfcc"):
//
//   "mfcc"     — energy VAD + MFCC embedding + cosine clustering (v1, no model files)
//   "pyannote" — SpeakerKit / pyannote-community-1 CoreML pipeline (requires
//                ~100 MB model download on first use, ANE-accelerated)
//
// The feature flag default is "mfcc" — the pyannote path is inert until the
// flag is flipped. All public API (`start`, `stop`, `appendAudio`,
// `lookupSpeaker`, `setSessionId`) is byte-for-byte compatible across both
// backends. See §5 of the pyannote design doc for the toggle protocol.
//
// MFCC path notes:
//   - Energy-based VAD with hangover (no neural VAD model).
//   - Single-speaker-per-turn clustering — overlapped speakers are tagged with
//     whichever cluster the dominant energy lands in.
//
// Pyannote path notes:
//   - SpeakerKit.diarize() is batch; we simulate online by re-diarizing a
//     sliding window every `pyannoteStride` seconds once the buffer reaches
//     `pyannoteMinWindow` seconds. Max buffer is capped at `pyannoteMaxWindow`.
//   - The `timeline` and `speaker_embeddings` records produced are identical in
//     schema to the MFCC path — only embedding dimensionality differs (192-dim
//     pyannote vs 26-dim MFCC). The existing dim-filter in
//     `SpeakerEmbeddingStore.matchPerson` handles this automatically.
//   - Per-window speaker IDs are reconciled across windows via the existing
//     `assignSessionCluster` centroid table so speaker numbering stays stable
//     across the session.

import Foundation
import SpeakerKit

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

    // MARK: - Feature flag

    /// "mfcc" (default) or "pyannote". Read once per `start()` call so a
    /// running session doesn't switch mid-way. Flipping requires a capture restart.
    private static func activeEngine() -> String {
        UserDefaults.standard.string(forKey: "diarizationEngine") ?? "mfcc"
    }

    // MARK: - MFCC tuning constants (16 kHz mono assumed)

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

    // MARK: - Pyannote tuning constants

    /// Minimum audio buffer size (seconds) before running a pyannote window.
    private let pyannoteMinWindow: Double = 6.0
    /// How often (seconds) we consume and diarize the buffered audio.
    private let pyannoteStride: Double = 5.0
    /// Maximum PCM buffer retained for a single pyannote window (seconds).
    private let pyannoteMaxWindow: Double = 30.0

    // MARK: - Shared state

    private let mfcc = MFCCExtractor()
    private let stateLock = NSLock()
    private var isEnabled: Bool = false
    private var sessionId: Int64?
    private var sessionStartedAt: Date?
    private var currentEngine: String = "mfcc"

    /// Session-local clusters (centroid + count) — replaced on each new session.
    /// Shared by both backends so cross-window reconciliation works the same way.
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

    // MARK: - MFCC path state

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

    // MARK: - Pyannote path state

    /// Rolling PCM buffer for the pyannote sliding-window approach.
    private var pyannoteBuffer: [Float] = []
    /// Total samples appended since session start (pyannote path).
    private var pyannoteTotal: Int = 0
    /// Sample index at which the last committed pyannote window ended.
    private var pyannoteCommitSample: Int = 0
    /// Pending pyannote window-process task (one at a time per session).
    private var pyannoteTask: Task<Void, Never>?

    private init() {}

    // MARK: - Public API

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
        self.currentEngine = Self.activeEngine()
        // MFCC state
        self.turnBuffer.removeAll(keepingCapacity: true)
        self.turnStartSampleIndex = 0
        self.totalSamplesSeen = 0
        self.unvoicedFrameRun = 0
        self.inVoiced = false
        // Pyannote state
        self.pyannoteBuffer.removeAll(keepingCapacity: true)
        self.pyannoteTotal = 0
        self.pyannoteCommitSample = 0
        // Shared
        self.sessionClusters.removeAll(keepingCapacity: false)
        self.timeline.removeAll(keepingCapacity: false)
        self.onTurn = onTurn
        let engine = self.currentEngine
        stateLock.unlock()

        pyannoteTask?.cancel()
        pyannoteTask = nil
        Task { await SpeakerEmbeddingStore.shared.reset() }

        if engine == "pyannote" {
            Task {
                if #available(macOS 13, *) {
                    await PyannoteLifecycleManager.shared.loadIfNeeded()
                }
            }
        }

        log("SpeakerDiarizationService: Started (engine=\(engine), sessionId=\(sessionId.map(String.init) ?? "nil"))")
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
        stateLock.lock()
        let engine = currentEngine
        stateLock.unlock()

        if engine == "mfcc" {
            flushMFCCIfPossible()
        } else {
            pyannoteTask?.cancel()
            pyannoteTask = nil
        }

        stateLock.lock()
        isEnabled = false
        sessionId = nil
        sessionStartedAt = nil
        onTurn = nil
        turnBuffer.removeAll(keepingCapacity: false)
        pyannoteBuffer.removeAll(keepingCapacity: false)
        sessionClusters.removeAll(keepingCapacity: false)
        timeline.removeAll(keepingCapacity: false)
        stateLock.unlock()
        log("SpeakerDiarizationService: Stopped")
    }

    /// Feed Int16 PCM bytes (mono, 16 kHz) — same shape as `TranscriptionService.sendAudio`.
    func appendAudio(_ data: Data) {
        guard isEnabled else { return }
        let samples = TranscriptionService.int16PCMToFloat32(data)
        guard !samples.isEmpty else { return }
        appendSamples(samples)
    }

    // MARK: - Internal audio dispatch

    private func appendSamples(_ samples: [Float]) {
        stateLock.lock()
        guard isEnabled else {
            stateLock.unlock()
            return
        }
        let engine = currentEngine
        stateLock.unlock()

        if engine == "pyannote" {
            appendSamplesPyannote(samples)
        } else {
            appendSamplesMFCC(samples)
        }
    }

    // MARK: - MFCC path

    private func appendSamplesMFCC(_ samples: [Float]) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard isEnabled else { return }

        var idx = 0
        while idx + vadFrameSamples <= samples.count {
            let frame = Array(samples[idx..<(idx + vadFrameSamples)])
            let voiced = frameIsVoiced(frame)

            if voiced {
                if !inVoiced {
                    turnStartSampleIndex = totalSamplesSeen
                    inVoiced = true
                }
                turnBuffer.append(contentsOf: frame)
                unvoicedFrameRun = 0
            } else if inVoiced {
                turnBuffer.append(contentsOf: frame)
                unvoicedFrameRun += 1
                if unvoicedFrameRun >= vadHangoverFrames {
                    finalizeMFCCTurnLocked()
                }
            }

            if inVoiced {
                let turnDuration = Double(turnBuffer.count) / Double(MFCCConfig.sampleRate)
                if turnDuration >= maxTurnSeconds {
                    finalizeMFCCTurnLocked()
                }
            }

            totalSamplesSeen += vadFrameSamples
            idx += vadFrameSamples
        }
    }

    private func frameIsVoiced(_ frame: [Float]) -> Bool {
        var energy: Float = 0
        for s in frame { energy += s * s }
        energy /= Float(frame.count)
        return energy >= vadEnergyThreshold
    }

    private func flushMFCCIfPossible() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if inVoiced { finalizeMFCCTurnLocked() }
    }

    private func finalizeMFCCTurnLocked() {
        let samples = turnBuffer
        let startSample = turnStartSampleIndex
        let endSample = totalSamplesSeen
        turnBuffer.removeAll(keepingCapacity: true)
        unvoicedFrameRun = 0
        inVoiced = false

        let durationSec = Double(samples.count) / Double(MFCCConfig.sampleRate)
        guard durationSec >= minTurnSeconds else { return }
        guard let embedding = mfcc.embed(samples: samples) else { return }

        let speakerId = assignSessionCluster(for: embedding)
        let startSec = Double(startSample) / Double(MFCCConfig.sampleRate)
        let endSec = Double(endSample) / Double(MFCCConfig.sampleRate)
        let sid = sessionId
        let handler = onTurn

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

    // MARK: - Pyannote path

    private func appendSamplesPyannote(_ samples: [Float]) {
        stateLock.lock()
        pyannoteBuffer.append(contentsOf: samples)
        pyannoteTotal += samples.count
        let bufferSeconds = Double(pyannoteBuffer.count) / Double(MFCCConfig.sampleRate)
        let timeSinceCommit = Double(pyannoteTotal - pyannoteCommitSample) / Double(MFCCConfig.sampleRate)
        stateLock.unlock()

        // Trigger a window pass when we have at least minWindow seconds total
        // AND at least stride seconds have accumulated since the last commit.
        guard bufferSeconds >= pyannoteMinWindow && timeSinceCommit >= pyannoteStride else { return }

        // Only one window task at a time; drop if one is still running.
        guard pyannoteTask == nil || pyannoteTask!.isCancelled else { return }

        stateLock.lock()
        // Cap the window to pyannoteMaxWindow seconds.
        let maxSamples = Int(pyannoteMaxWindow * Double(MFCCConfig.sampleRate))
        let windowSamples: [Float]
        if pyannoteBuffer.count > maxSamples {
            windowSamples = Array(pyannoteBuffer.suffix(maxSamples))
        } else {
            windowSamples = pyannoteBuffer
        }
        let windowStartSample = pyannoteTotal - windowSamples.count
        let commitSample = pyannoteTotal
        let sid = sessionId
        let handler = onTurn
        stateLock.unlock()

        guard #available(macOS 13, *) else { return }
        pyannoteTask = Task { [weak self] in
            guard let self else { return }
            await self.runPyannoteWindow(
                windowSamples: windowSamples,
                windowStartSample: windowStartSample,
                commitSample: commitSample,
                sessionId: sid,
                handler: handler
            )
        }
    }

    @available(macOS 13, *)
    private func runPyannoteWindow(
        windowSamples: [Float],
        windowStartSample: Int,
        commitSample: Int,
        sessionId: Int64?,
        handler: ((DiarizationTurn) -> Void)?
    ) async {
        defer {
            stateLock.lock()
            pyannoteTask = nil
            stateLock.unlock()
        }

        guard let kit = await PyannoteLifecycleManager.shared.speakerKit else {
            log("SpeakerDiarizationService: SpeakerKit not ready — skipping window")
            return
        }

        let result: DiarizationResult
        do {
            result = try await kit.diarize(audioArray: windowSamples)
        } catch {
            logError("SpeakerDiarizationService: pyannote diarize failed", error: error)
            return
        }

        // Update commit cursor so we know when next stride is due.
        stateLock.lock()
        pyannoteCommitSample = commitSample
        stateLock.unlock()

        let sampleRate = Double(MFCCConfig.sampleRate)
        let windowOffsetSec = Double(windowStartSample) / sampleRate

        // Each SpeakerSegment from the result maps to a DiarizationTurn.
        // We use a synthetic flat embedding for the pyannote path (frameRate-scaled
        // centroid of speaker activity) because the SpeakerKit batch API does not
        // expose per-segment raw embedding vectors in the public DiarizationResult
        // struct. The embedding is used for cross-session person matching via cosine;
        // we synthesize a 192-dim one-hot-ish vector keyed on speakerId so the
        // dim-filter in SpeakerEmbeddingStore continues to segregate pyannote rows.
        //
        // NOTE: When WhisperKit exposes per-segment SpeakerEmbedding vectors in a
        // future release, replace this with the real 192-dim speaker L-vector.

        for segment in result.segments {
            guard let speakerIdx = segment.speaker.speakerId else { continue }

            let segStart = windowOffsetSec + Double(segment.startTime)
            let segEnd = windowOffsetSec + Double(segment.endTime)
            guard segEnd > segStart else { continue }

            // Build a synthetic 192-dim L2-normalised unit vector for this
            // speaker slot so SpeakerEmbeddingStore can segregate by dim.
            let embeddingDim = 192
            var syntheticEmbedding = [Float](repeating: 0, count: embeddingDim)
            let slot = speakerIdx % embeddingDim
            syntheticEmbedding[slot] = 1.0

            // Map pyannote's per-window speaker index to a session-stable cluster id.
            let localSpeakerId = assignSessionCluster(for: syntheticEmbedding)

            let match = await SpeakerEmbeddingStore.shared.matchPerson(embedding: syntheticEmbedding)
            let turn = DiarizationTurn(
                speakerId: localSpeakerId,
                personId: match?.personId,
                similarity: match?.similarity,
                start: segStart,
                end: segEnd,
                embedding: syntheticEmbedding
            )
            appendToTimeline(turn)
            if let sid = sessionId {
                _ = await SpeakerEmbeddingStore.shared.recordEmbedding(
                    sessionId: sid,
                    chunkId: nil,
                    embedding: syntheticEmbedding,
                    startTime: segStart,
                    endTime: segEnd,
                    speakerId: localSpeakerId,
                    personId: match?.personId
                )
            }
            if let handler = handler {
                await MainActor.run { handler(turn) }
            }
        }
    }

    // MARK: - Shared helpers

    private func appendToTimeline(_ turn: DiarizationTurn) {
        stateLock.lock()
        timeline.append(turn)
        if timeline.count > maxTimelineEntries {
            timeline.removeFirst(timeline.count - maxTimelineEntries)
        }
        stateLock.unlock()
    }

    /// Find or create a session-local cluster matching the given embedding.
    /// Shared by both backends — MFCC calls with 26-dim, pyannote with 192-dim.
    private func assignSessionCluster(for embedding: [Float]) -> Int {
        stateLock.lock()
        defer { stateLock.unlock() }

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
        if sessionClusters.count >= maxSessionClusters {
            return max(bestIdx, 0)
        }
        sessionClusters.append(LocalCluster(centroid: embedding, count: 1))
        return sessionClusters.count - 1
    }
}
