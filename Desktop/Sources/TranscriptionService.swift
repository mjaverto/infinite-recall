import Foundation
import WhisperKit

/// On-device speech-to-text via WhisperKit (Apache 2.0, Core ML Whisper).
///
/// HISTORY: This file used to stream audio over WebSocket to the Python backend
/// (`/v4/listen` for conversations, `/v2/voice-message/transcribe-stream` for PTT).
/// In the local-first fork that path is gone — see the `LegacyCloudPath` enum and
/// the commented-out `connectToBackend` / `parseBackendResponse` block below for
/// reference. We keep the old types (`BackendSegment`, `ListenEvent`, callback
/// shapes) so AppState and the live transcript UI compile unchanged.
///
/// Threading model: this class is `@unchecked Sendable`. Audio comes in on the
/// CoreAudio IO thread via `sendAudio(_:)`; transcription runs on a single async
/// task that consumes a sliding window from the buffer.
class TranscriptionService: @unchecked Sendable {

    // MARK: - Types

    /// Streaming mode determines which backend endpoint and parameters are used.
    /// In the local-first fork both modes resolve to the same on-device pipeline.
    enum StreamingMode {
        case conversation
        case ptt
    }

    /// Translation slot — kept for source compatibility with the old backend wire format.
    struct BackendTranslation: Decodable {
        let lang: String
        let text: String
    }

    /// Transcript segment — same shape AppState's `handleBackendSegments` expects.
    /// In WhisperKit mode `id` is a synthetic UUID per emitted segment, `speaker`
    /// is `"SPEAKER_00"`, and `is_user` is always true (no diarization in v1).
    struct BackendSegment: Decodable {
        let id: String?
        let text: String
        let speaker: String?
        let speaker_id: Int?
        let is_user: Bool
        let person_id: String?
        let start: Double
        let end: Double
        let translations: [BackendTranslation]?
    }

    /// Listen event — only used in cloud mode. Kept so callers compile.
    struct ListenEvent {
        let type: String
        let raw: [String: Any]
    }

    typealias BackendSegmentsHandler = ([BackendSegment]) -> Void
    typealias ListenEventHandler = (ListenEvent) -> Void
    typealias ErrorHandler = (Error) -> Void
    typealias ConnectionHandler = () -> Void

    enum TranscriptionError: LocalizedError {
        case missingBackendURL
        case connectionFailed(Error)
        case invalidResponse
        case payloadTooLarge
        case webSocketError(String)
        case modelLoadFailed(Error)

        var errorDescription: String? {
            switch self {
            case .missingBackendURL:
                return "Transcription backend not configured"
            case .connectionFailed(let error):
                return "Connection failed: \(error.localizedDescription)"
            case .invalidResponse:
                return "Invalid response from transcription engine"
            case .payloadTooLarge:
                return "Recording too long — keep it under 5 minutes"
            case .webSocketError(let message):
                return "Transcription error: \(message)"
            case .modelLoadFailed(let error):
                return "WhisperKit model load failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Properties

    private let language: String
    private let streamingMode: StreamingMode

    /// True once WhisperKit has loaded a model. Until then `sendAudio` still
    /// accepts samples (so audio capture can keep buffering on disk via
    /// AudioPersistenceService) but no segments are emitted.
    var isConnected = false
    var shouldReconnect = false  // unused locally; kept for API compatibility

    private var onBackendSegments: BackendSegmentsHandler?
    private var onListenEvent: ListenEventHandler?
    private var onError: ErrorHandler?
    private var onConnected: ConnectionHandler?
    private var onDisconnected: ConnectionHandler?

    // WhisperKit state
    private var whisperKit: WhisperKit?
    private var modelLoadTask: Task<Void, Never>?
    private var transcribeTask: Task<Void, Never>?

    /// PCM ring buffer (Float32 samples at 16 kHz mono) fed by `sendAudio`.
    private var pcmBuffer: [Float] = []
    private let pcmBufferLock = NSLock()

    /// Whisper's expected sample rate.
    private let sampleRate: Int = 16000

    /// Run a transcribe pass every `windowStrideSeconds` once we have at least
    /// `minWindowSeconds` of audio. Keep up to `maxWindowSeconds` in the window
    /// for context, then slide forward by `commitSeconds` after each pass.
    private let minWindowSeconds: Double = 4.0
    private let windowStrideSeconds: Double = 1.0
    private let maxWindowSeconds: Double = 30.0
    private let commitSeconds: Double = 6.0

    /// Wall-clock time at which the first sample in the current window started.
    private var windowStartTime: Date?
    /// Offset (seconds) from the *start of recording* of the first sample in the
    /// current window — used so emitted segments have monotonically increasing
    /// `start`/`end` even after the window slides.
    private var windowStartOffsetSeconds: Double = 0.0
    /// Offset (seconds) of the most recently committed end of transcription.
    private var lastCommittedEndSeconds: Double = 0.0

    /// Default model — small + English-only, ~140 MB on disk after Core ML
    /// quantization. Fits comfortably in memory and runs well on M1/M2/M3.
    /// (Multilingual users can swap to `openai_whisper-base` later.)
    private let modelName = "openai_whisper-base.en"

    // MARK: - Initialization

    init(language: String = "en", mode: StreamingMode = .conversation) throws {
        self.language = language
        self.streamingMode = mode
        log("TranscriptionService: WhisperKit init (mode=\(mode), language=\(language), model=\(modelName))")
    }

    /// Batch-only init — kept for `PushToTalkManager` API compat.
    init(apiKey: String? = nil, language: String = "en", forBatchOnly: Bool) throws {
        guard forBatchOnly else {
            throw TranscriptionError.webSocketError("Use init(language:) for streaming mode")
        }
        self.language = language
        self.streamingMode = .ptt
        log("TranscriptionService: WhisperKit batch init")
    }

    /// Legacy init taking explicit channel count — PTT path. Mono is the only
    /// supported configuration for the on-device pipeline.
    convenience init(language: String = "en", channels: Int) throws {
        try self.init(language: language, mode: .ptt)
    }

    // MARK: - Public API (preserved from cloud version)

    /// Start streaming transcription. Audio fed via `sendAudio` will be transcribed
    /// in overlapping windows and emitted as `BackendSegment`s.
    ///
    /// Best-effort: if the WhisperKit model fails to load (e.g. first launch with
    /// no network), `onError` is fired but `onConnected` is also called so callers
    /// know audio capture should still proceed. Internally we keep retrying load.
    func start(
        onSegments: @escaping BackendSegmentsHandler,
        onEvent: @escaping ListenEventHandler,
        onError: ErrorHandler? = nil,
        onConnected: ConnectionHandler? = nil,
        onDisconnected: ConnectionHandler? = nil
    ) {
        self.onBackendSegments = onSegments
        self.onListenEvent = onEvent
        self.onError = onError
        self.onConnected = onConnected
        self.onDisconnected = onDisconnected

        // Reset windowing state
        pcmBufferLock.lock()
        pcmBuffer.removeAll(keepingCapacity: true)
        windowStartTime = Date()
        windowStartOffsetSeconds = 0
        lastCommittedEndSeconds = 0
        pcmBufferLock.unlock()

        // Fire onConnected immediately so AppState can start mic capture even
        // before WhisperKit finishes loading. Audio still flows into pcmBuffer
        // via sendAudio() and gets transcribed once the model is ready.
        isConnected = true
        DispatchQueue.main.async { [weak self] in
            self?.onConnected?()
        }

        // Kick off model load in the background.
        modelLoadTask?.cancel()
        modelLoadTask = Task { [weak self] in
            await self?.loadModelAndStartTranscribing()
        }
    }

    /// Tear down — cancels in-flight transcription, releases the model.
    func stop() {
        isConnected = false
        modelLoadTask?.cancel()
        modelLoadTask = nil
        transcribeTask?.cancel()
        transcribeTask = nil

        pcmBufferLock.lock()
        pcmBuffer.removeAll(keepingCapacity: false)
        pcmBufferLock.unlock()

        whisperKit = nil

        DispatchQueue.main.async { [weak self] in
            self?.onDisconnected?()
        }
        log("TranscriptionService: Stopped")
    }

    /// Feed mixed mono Int16 PCM @ 16 kHz from AudioMixer.
    func sendAudio(_ data: Data) {
        guard isConnected else { return }
        let samples = Self.int16PCMToFloat32(data)
        guard !samples.isEmpty else { return }

        pcmBufferLock.lock()
        pcmBuffer.append(contentsOf: samples)
        pcmBufferLock.unlock()
    }

    /// Returns true when the window's RMS is below a silence threshold.
    /// Threshold tuned empirically on M-series Macs: -45 dBFS catches room
    /// silence + keyboard clicks but lets normal speech through. Float32
    /// samples in [-1, 1].
    private static func isWindowSilent(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return true }
        var sumSq: Float = 0
        for s in samples { sumSq += s * s }
        let rms = (sumSq / Float(samples.count)).squareRoot()
        // -45 dBFS = 10^(-45/20) ≈ 0.00562
        return rms < 0.00562
    }

    /// Flush remaining audio. Cloud path used to send a "finalize" message; in
    /// WhisperKit mode this just triggers one last transcribe pass.
    func finishStream() {
        // Best-effort final pass — let the existing transcribe loop drain naturally.
        // (Forcing a synchronous pass here would race with the running task.)
    }

    var connected: Bool { isConnected }

    // MARK: - WhisperKit pipeline

    private func loadModelAndStartTranscribing() async {
        do {
            log("TranscriptionService: Loading WhisperKit model '\(modelName)' (downloads ~140 MB on first run)…")
            let kit = try await WhisperKit(
                model: modelName,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: true
            )
            self.whisperKit = kit
            log("TranscriptionService: WhisperKit model loaded")
        } catch {
            logError("TranscriptionService: WhisperKit model load failed", error: error)
            // Don't tear down — audio capture stays live via AudioPersistenceService.
            // We log and bail; AppState already considers "isTranscribing" = recording.
            DispatchQueue.main.async { [weak self] in
                self?.onError?(TranscriptionError.modelLoadFailed(error))
            }
            return
        }

        // Spin the transcribe loop.
        transcribeTask?.cancel()
        transcribeTask = Task { [weak self] in
            await self?.runTranscribeLoop()
        }
    }

    /// Periodic-window streaming: every `windowStrideSeconds`, if we have at
    /// least `minWindowSeconds` of audio, run `transcribe(audioArray:)` over the
    /// entire current window. After a pass we slide the window forward by
    /// `commitSeconds` and emit any segments whose end falls within the
    /// committed prefix.
    ///
    /// Battery gating: before each `kit.transcribe(...)` call we consult
    /// `BatteryAwareScheduler.shared.allowHeavyWork`. If the machine is on
    /// battery (or in low-power-mode / thermal throttling), we skip the live
    /// Whisper pass and enqueue a `PendingWork(kind: .transcribe, payload:)`
    /// describing the wall-clock window. The handler registered on the
    /// scheduler then drains by fetching the matching `audio_chunks` rows and
    /// transcribing them on AC. Audio capture itself (AudioPersistenceService
    /// → audio_chunks) is unchanged on battery.
    private func runTranscribeLoop() async {
        let strideNanos = UInt64(windowStrideSeconds * 1_000_000_000)

        while !Task.isCancelled, isConnected {
            try? await Task.sleep(nanoseconds: strideNanos)
            guard !Task.isCancelled, isConnected, let kit = whisperKit else { continue }

            // Snapshot the buffer
            pcmBufferLock.lock()
            let samples = pcmBuffer
            pcmBufferLock.unlock()

            let durationSec = Double(samples.count) / Double(sampleRate)
            guard durationSec >= minWindowSeconds else { continue }

            // Silence gate (fork-local): skip the Whisper pass when the window's
            // RMS is below a small threshold. Whisper hallucinates noise (e.g.
            // "Thank you." / ".") on near-silence and burns ~600ms of inference
            // each pass. This is a cheap inline replacement for the original
            // VADGateService (stereo, cloud-streaming-shaped) that's intentionally
            // disabled in this fork — we still slide the window so we don't
            // re-evaluate the same silence next pass.
            if Self.isWindowSilent(samples) {
                await slideWindowForward()
                continue
            }

            // Battery gate: if heavy work is not allowed, skip the live Whisper
            // pass and enqueue a marker referencing the current window's
            // wall-clock range. The handler will fetch matching audio_chunks
            // rows from GRDB and transcribe them when we're back on AC.
            let allow = await MainActor.run { BatteryAwareScheduler.shared.allowHeavyWork }
            if !allow {
                await enqueueDeferredTranscribeForCurrentWindow(durationSec: durationSec)
                await slideWindowForward()
                continue
            }

            do {
                // WhisperKit's transcribe(audioArray:) is the streaming-friendly
                // entry point — it accepts arbitrary-length [Float] at 16 kHz.
                let results = try await kit.transcribe(
                    audioArray: samples,
                    decodeOptions: nil
                )
                guard !Task.isCancelled, isConnected else { return }
                await emitSegments(from: results)
            } catch {
                logError("TranscriptionService: transcribe pass failed", error: error)
            }

            // Slide the window forward — drop the first commitSeconds of audio
            // so the buffer doesn't grow unbounded. The remaining tail provides
            // context for the next pass.
            await slideWindowForward()
        }
    }

    /// Encode and enqueue a deferred-transcription marker covering the current
    /// window's wall-clock range. The audio itself is in `audio_chunks` already
    /// (written by AudioPersistenceService independently of Whisper state), so
    /// we only persist *which* chunks need transcribing.
    private func enqueueDeferredTranscribeForCurrentWindow(durationSec: Double) async {
        guard let started = windowStartTime else { return }
        let ended = Date()
        let language = self.language
        let mode = self.streamingMode == .ptt ? "ptt" : "conversation"
        let payloadDict: [String: Any] = [
            "started_at": ISO8601DateFormatter().string(from: started),
            "ended_at": ISO8601DateFormatter().string(from: ended),
            "duration_sec": durationSec,
            "language": language,
            "mode": mode,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payloadDict, options: []) else {
            return
        }
        await MainActor.run {
            BatteryAwareScheduler.shared.enqueue(
                PendingWork(kind: .transcribe, payload: data)
            )
        }
    }

    private func emitSegments(from results: [TranscriptionResult]) async {
        var emitted: [BackendSegment] = []
        for result in results {
            for seg in result.segments {
                let absStart = windowStartOffsetSeconds + Double(seg.start)
                let absEnd = windowStartOffsetSeconds + Double(seg.end)
                // Only emit segments whose end is within the committed prefix —
                // anything past commitSeconds is provisional and may shift on
                // the next pass.
                guard absEnd <= windowStartOffsetSeconds + commitSeconds else { continue }
                guard absEnd > lastCommittedEndSeconds else { continue }
                // Infinite Recall fork: WhisperKit's raw output contains special
                // tokens like <|startoftranscript|>, <|0.00|>, <|endoftext|>,
                // <|en|>, <|transcribe|>. Strip them before persisting so the
                // UI shows clean speech.
                let stripped = seg.text.replacingOccurrences(
                    of: #"<\|[^|>]+\|>"#,
                    with: "",
                    options: .regularExpression
                )
                let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }

                // Infinite Recall fork: consult the on-device diarization
                // timeline to attach a real speakerId. If diarization isn't
                // running (or hasn't seen this region yet), fall back to
                // SPEAKER_00 / is_user=true so behavior is unchanged from the
                // pre-diarization baseline.
                let midpoint = (absStart + absEnd) * 0.5
                let lookup = SpeakerDiarizationService.shared.lookupSpeaker(at: midpoint)
                let speakerId = lookup?.speakerId ?? 0
                let personId = lookup?.personId
                let speakerLabel = String(format: "SPEAKER_%02d", speakerId)
                emitted.append(
                    BackendSegment(
                        id: UUID().uuidString,
                        text: trimmed,
                        speaker: speakerLabel,
                        speaker_id: speakerId,
                        is_user: speakerId == 0 && personId == nil,
                        person_id: personId,
                        start: absStart,
                        end: absEnd,
                        translations: nil
                    )
                )
                lastCommittedEndSeconds = absEnd
            }
        }
        if !emitted.isEmpty {
            let segs = emitted
            DispatchQueue.main.async { [weak self] in
                self?.onBackendSegments?(segs)
            }
        }
    }

    private func slideWindowForward() async {
        let dropSamples = Int(commitSeconds * Double(sampleRate))
        pcmBufferLock.lock()
        if pcmBuffer.count > dropSamples {
            pcmBuffer.removeFirst(dropSamples)
            windowStartOffsetSeconds += commitSeconds
        } else {
            // Less audio than commit window — keep buffer, don't advance offset.
        }
        // Hard cap to prevent runaway memory if transcription stalls.
        let maxSamples = Int(maxWindowSeconds * Double(sampleRate))
        if pcmBuffer.count > maxSamples {
            let extra = pcmBuffer.count - maxSamples
            pcmBuffer.removeFirst(extra)
            windowStartOffsetSeconds += Double(extra) / Double(sampleRate)
        }
        pcmBufferLock.unlock()
    }

    // MARK: - Helpers

    /// Convert little-endian Int16 PCM bytes to normalized Float32 in [-1, 1].
    static func int16PCMToFloat32(_ data: Data) -> [Float] {
        let count = data.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: Int16.self).baseAddress else { return }
            for i in 0..<count {
                out[i] = Float(base[i]) / 32768.0
            }
        }
        return out
    }
}

// MARK: - Batch (one-shot) transcription

extension TranscriptionService {
    /// Transcribe a complete audio buffer (16 kHz mono Int16 PCM) on-device.
    /// Used by PushToTalkManager. Loads its own short-lived WhisperKit instance.
    static func batchTranscribe(
        audioData: Data,
        language: String = "en",
        apiKey: String? = nil
    ) async throws -> String? {
        log("TranscriptionService: Batch transcribing \(audioData.count) bytes via WhisperKit")
        let samples = int16PCMToFloat32(audioData)
        guard !samples.isEmpty else { return nil }

        let kit: WhisperKit
        do {
            kit = try await WhisperKit(
                model: "openai_whisper-base.en",
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
        } catch {
            throw TranscriptionError.modelLoadFailed(error)
        }

        do {
            let results = try await kit.transcribe(audioArray: samples)
            let text = results
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            return text.isEmpty ? nil : text
        } catch {
            throw TranscriptionError.invalidResponse
        }
    }
}

// MARK: - Legacy cloud WebSocket path (commented out for reference)
//
// The original cloud implementation streamed Int16 PCM over a WebSocket to the
// Python backend at `/v4/listen` (conversations) or `/v2/voice-message/transcribe-stream`
// (PTT). It also handled batch transcription via `POST /v2/voice-message/transcribe`.
// All of that is replaced by the on-device WhisperKit pipeline above. The original
// code is preserved below for reference — re-enable only if reintroducing a
// cloud fallback.
//
//    private var webSocketTask: URLSessionWebSocketTask?
//    private var urlSession: URLSession?
//    private let apiKey: String = ""
//    private static let pythonBackendBaseURL: String = {
//        if let cString = getenv("OMI_PYTHON_API_URL"),
//           let url = String(validatingUTF8: cString), !url.isEmpty {
//            return url.hasSuffix("/") ? url : url + "/"
//        }
//        return "https://api.omi.me/"
//    }()
//
//    private func connect() { /* opened wss://…/v4/listen with Firebase auth */ }
//    private func connectToBackend(authHeader: String) { /* set up URLSessionWebSocketTask */ }
//    private func receiveMessage() { /* read JSON arrays of BackendSegment */ }
//    func parseBackendResponse(_ text: String) { /* JSON → BackendSegment / ListenEvent */ }
//    static func batchTranscribe(audioData: Data, language: String, apiKey: String?) async throws -> String? {
//        /* POST audio bytes to /v2/voice-message/transcribe and decode {transcript, language} */
//    }
