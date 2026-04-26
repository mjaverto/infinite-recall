import Foundation
import OnnxRuntimeBindings

// Silero VAD v5 — minimal mono 16 kHz speech detector backed by ONNX Runtime.
//
// Model contract (silero_vad.onnx, v5):
//   Inputs:
//     "input"  — Float32 [1, N]       raw PCM at 16 kHz
//     "state"  — Float32 [2, 1, 128]  LSTM hidden + cell state (zeros on reset)
//     "sr"     — Int64   [1]          sample rate (must be 16000)
//   Outputs:
//     "output" — Float32 [1, 1]       speech probability in [0, 1]
//     "stateN" — Float32 [2, 1, 128]  updated LSTM state
//
// Window size: 512 samples = 32 ms at 16 kHz (Silero v5 recommendation).
// Fail-open: any error returns `true` so Whisper inference is never skipped
// due to a VAD load or runtime failure.

actor SileroVADService {
    static let shared = SileroVADService()

    // MARK: - Private state

    /// LSTM state: [2, 1, 128] = 256 floats. Persisted across windows within a session.
    private var lstmState: [Float] = .init(repeating: 0, count: 256)

    /// Lazy ONNX session — initialised once on first call.
    private var session: ORTSession?
    private var sessionLoadAttempted = false

    private static let windowSize = 512      // 32 ms at 16 kHz
    private static let sampleRate: Int64 = 16_000
    private static let stateShape: [NSNumber] = [2, 1, 128]
    private static let srShape: [NSNumber] = [1]

    // MARK: - Public API

    /// Returns `true` if any 512-sample window in `samples` exceeds `threshold`.
    /// Fail-open: returns `true` when the model is unavailable or inference errors.
    func isSpeech(_ samples: [Float], threshold: Float = 0.5) async -> Bool {
        guard let sess = loadSessionIfNeeded() else {
            // Model unavailable — let Whisper proceed.
            return true
        }

        var stride = 0
        while stride + Self.windowSize <= samples.count {
            let chunk = Array(samples[stride ..< stride + Self.windowSize])
            if let prob = runWindow(chunk, session: sess), prob > threshold {
                return true
            }
            stride += Self.windowSize
        }
        return false
    }

    /// Reset LSTM state. Call when starting a new recording session.
    /// Safe to call on a cold actor (before the model is loaded).
    func reset() async {
        lstmState = .init(repeating: 0, count: 256)
    }

    // MARK: - Session lifecycle

    private func loadSessionIfNeeded() -> ORTSession? {
        if sessionLoadAttempted { return session }
        sessionLoadAttempted = true

        guard
            let modelURL = Bundle.resourceBundle.url(
                forResource: "silero_vad", withExtension: "onnx")
        else {
            log("SileroVADService: silero_vad.onnx not found in resource bundle — VAD disabled, fail-open")
            return nil
        }

        do {
            let env = try ORTEnv(loggingLevel: .warning)
            let opts = try ORTSessionOptions()
            try opts.setIntraOpNumThreads(1)
            try opts.setGraphOptimizationLevel(.all)
            let sess = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: opts)
            session = sess
            log("SileroVADService: model loaded from \(modelURL.lastPathComponent)")
            return sess
        } catch {
            logError("SileroVADService: failed to load ONNX session — VAD disabled, fail-open", error: error)
            return nil
        }
    }

    // MARK: - Inference

    /// Run one 512-sample window. Returns speech probability, or nil on error.
    /// Carries `lstmState` forward on success.
    private func runWindow(_ chunk: [Float], session sess: ORTSession) -> Float? {
        do {
            // --- input tensor [1, 512] ---
            var pcm = chunk  // local mutable copy for withUnsafeMutableBytes
            let inputData = NSMutableData(
                bytes: &pcm,
                length: chunk.count * MemoryLayout<Float>.size)
            let inputTensor = try ORTValue(
                tensorData: inputData,
                elementType: .float,
                shape: [1, NSNumber(value: chunk.count)])

            // --- state tensor [2, 1, 128] ---
            let stateData = NSMutableData(
                bytes: &lstmState,
                length: lstmState.count * MemoryLayout<Float>.size)
            let stateTensor = try ORTValue(
                tensorData: stateData,
                elementType: .float,
                shape: Self.stateShape)

            // --- sr tensor [1] ---
            var sr = Self.sampleRate
            let srData = NSMutableData(
                bytes: &sr,
                length: MemoryLayout<Int64>.size)
            let srTensor = try ORTValue(
                tensorData: srData,
                elementType: .int64,
                shape: Self.srShape)

            // --- run ---
            let inputs: [String: ORTValue] = [
                "input": inputTensor,
                "state": stateTensor,
                "sr":    srTensor,
            ]
            let outputs = try sess.run(
                withInputs: inputs,
                outputNames: Set(["output", "stateN"]),
                runOptions: nil)

            // --- read speech probability ---
            guard let outputVal = outputs["output"] else { return nil }
            let outputData = try outputVal.tensorData() as Data
            guard outputData.count >= MemoryLayout<Float>.size else { return nil }
            let prob = outputData.withUnsafeBytes { $0.load(as: Float.self) }

            // --- carry LSTM state forward ---
            if let newStateVal = outputs["stateN"] {
                let newStateData = try newStateVal.tensorData() as Data
                let expectedBytes = lstmState.count * MemoryLayout<Float>.size
                if newStateData.count == expectedBytes {
                    newStateData.withUnsafeBytes { src in
                        let floats = src.bindMemory(to: Float.self)
                        for i in 0..<lstmState.count { lstmState[i] = floats[i] }
                    }
                }
            }

            return prob

        } catch {
            logError("SileroVADService: inference error", error: error)
            return nil
        }
    }
}
