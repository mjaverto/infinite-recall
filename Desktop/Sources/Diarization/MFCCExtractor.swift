// Infinite Recall fork: on-device speaker diarization. No cloud calls.
//
// Pure-Swift mel-frequency cepstral coefficient (MFCC) extractor used as a
// lightweight, deterministic speaker embedding for v1 diarization. Runs
// entirely via Accelerate (vDSP) — no model files, no network.
//
// v1 simplification (intentional): instead of bundling a pyannote-audio /
// WeSpeaker ONNX model (50–100 MB hand-converted), we average MFCC frames
// over a speech turn and L2-normalize. That's enough to cluster speakers in a
// single conversation reliably (cosine threshold ~0.65) without shipping or
// downloading any extra model. A real neural embedding can drop into the same
// `embed(samples:)` interface later — see TODO in `SpeakerDiarizationService`.

import Accelerate
import Foundation

enum MFCCConfig {
    /// Audio sample rate the diarizer expects (matches AudioMixer / WhisperKit).
    static let sampleRate: Float = 16_000
    /// Frame length in samples — 25ms @ 16kHz.
    static let frameLength: Int = 400
    /// Frame hop in samples — 10ms @ 16kHz.
    static let frameHop: Int = 160
    /// FFT length (power of two, ≥ frameLength).
    static let fftLength: Int = 512
    /// log2(fftLength), required by vDSP.
    static let fftLog2N: vDSP_Length = 9
    /// Number of mel filter banks.
    static let melBands: Int = 26
    /// Number of cepstral coefficients to keep (drops c0 — first DCT bin).
    static let mfccDim: Int = 13
    /// Mel filterbank lower cutoff (Hz).
    static let melMinHz: Float = 80
    /// Mel filterbank upper cutoff (Hz).
    static let melMaxHz: Float = 7_600
}

/// Extracts MFCC features from 16 kHz mono Float32 PCM in [-1, 1].
/// Embedding output is `[mean ⊕ std]` per coefficient → 26-dim, L2-normalized.
/// Thread-safe: each instance owns its own FFT setup; create one per consumer.
final class MFCCExtractor {

    private let fftSetup: FFTSetup
    private let melFilters: [[Float]]   // [melBands][fftLength/2 + 1]
    private let dctMatrix: [Float]      // [mfccDim * melBands] row-major

    init() {
        guard let setup = vDSP_create_fftsetup(MFCCConfig.fftLog2N, FFTRadix(kFFTRadix2)) else {
            fatalError("MFCCExtractor: vDSP_create_fftsetup failed")
        }
        self.fftSetup = setup
        self.melFilters = MFCCExtractor.buildMelFilterbank(
            bands: MFCCConfig.melBands,
            fftSize: MFCCConfig.fftLength,
            sampleRate: MFCCConfig.sampleRate,
            minHz: MFCCConfig.melMinHz,
            maxHz: MFCCConfig.melMaxHz
        )
        self.dctMatrix = MFCCExtractor.buildDCTMatrix(rows: MFCCConfig.mfccDim, cols: MFCCConfig.melBands)
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    /// Compute a 26-dim L2-normalized embedding from the given Float32 mono
    /// samples (16 kHz). Returns `nil` if the segment is too short to embed
    /// (< 1 frame) or is silent.
    func embed(samples: [Float]) -> [Float]? {
        guard samples.count >= MFCCConfig.frameLength else { return nil }

        var mfccFrames: [[Float]] = []
        mfccFrames.reserveCapacity(samples.count / MFCCConfig.frameHop)

        var frameStart = 0
        while frameStart + MFCCConfig.frameLength <= samples.count {
            let slice = Array(samples[frameStart..<(frameStart + MFCCConfig.frameLength)])
            if let mfcc = computeMFCCFrame(slice) {
                mfccFrames.append(mfcc)
            }
            frameStart += MFCCConfig.frameHop
        }

        guard !mfccFrames.isEmpty else { return nil }

        // Compute mean & std per coefficient across frames.
        let dim = MFCCConfig.mfccDim
        var mean = [Float](repeating: 0, count: dim)
        var sqMean = [Float](repeating: 0, count: dim)
        let invN = 1.0 / Float(mfccFrames.count)

        for frame in mfccFrames {
            for i in 0..<dim {
                mean[i] += frame[i]
                sqMean[i] += frame[i] * frame[i]
            }
        }
        for i in 0..<dim {
            mean[i] *= invN
            let variance = max(0, sqMean[i] * invN - mean[i] * mean[i])
            sqMean[i] = sqrt(variance)
        }

        // Concat [mean, std] then L2-normalize.
        var embedding = mean + sqMean
        var norm: Float = 0
        vDSP_svesq(embedding, 1, &norm, vDSP_Length(embedding.count))
        norm = sqrt(norm)
        guard norm > 1e-6 else { return nil }
        var inv = 1.0 / norm
        vDSP_vsmul(embedding, 1, &inv, &embedding, 1, vDSP_Length(embedding.count))
        return embedding
    }

    // MARK: - Per-frame MFCC

    private func computeMFCCFrame(_ frame: [Float]) -> [Float]? {
        precondition(frame.count == MFCCConfig.frameLength)

        // 1) Pre-emphasis (alpha = 0.97), Hamming window.
        var preemphasized = [Float](repeating: 0, count: frame.count)
        preemphasized[0] = frame[0]
        for i in 1..<frame.count {
            preemphasized[i] = frame[i] - 0.97 * frame[i - 1]
        }
        var window = [Float](repeating: 0, count: frame.count)
        vDSP_hamm_window(&window, vDSP_Length(frame.count), 0)
        vDSP_vmul(preemphasized, 1, window, 1, &preemphasized, 1, vDSP_Length(frame.count))

        // 2) Zero-pad to FFT length.
        var padded = [Float](repeating: 0, count: MFCCConfig.fftLength)
        for i in 0..<preemphasized.count {
            padded[i] = preemphasized[i]
        }

        // 3) Real FFT → magnitude squared (power spectrum), bins [0..N/2].
        let halfN = MFCCConfig.fftLength / 2
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)
        var power = [Float](repeating: 0, count: halfN + 1)

        realp.withUnsafeMutableBufferPointer { realpPtr in
            imagp.withUnsafeMutableBufferPointer { imagpPtr in
                guard let realBase = realpPtr.baseAddress, let imagBase = imagpPtr.baseAddress else {
                    return
                }
                var split = DSPSplitComplex(realp: realBase, imagp: imagBase)
                padded.withUnsafeBufferPointer { paddedPtr in
                    paddedPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
                        cplxPtr in
                        vDSP_ctoz(cplxPtr, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, MFCCConfig.fftLog2N, FFTDirection(FFT_FORWARD))

                // vDSP packs Nyquist into imagp[0]; separate them for an honest spectrum.
                let nyquist = imagBase[0]
                imagBase[0] = 0
                for i in 0..<halfN {
                    let re = realBase[i]
                    let im = imagBase[i]
                    power[i] = re * re + im * im
                }
                power[halfN] = nyquist * nyquist
            }
        }

        // 4) Mel filterbank → log energy.
        var melEnergies = [Float](repeating: 0, count: MFCCConfig.melBands)
        for b in 0..<MFCCConfig.melBands {
            var energy: Float = 0
            vDSP_dotpr(power, 1, melFilters[b], 1, &energy, vDSP_Length(power.count))
            melEnergies[b] = log(max(energy, 1e-10))
        }

        // 5) DCT-II → MFCCs (drop c0, keep next mfccDim coefficients).
        var mfcc = [Float](repeating: 0, count: MFCCConfig.mfccDim)
        for i in 0..<MFCCConfig.mfccDim {
            var sum: Float = 0
            let row = i * MFCCConfig.melBands
            for j in 0..<MFCCConfig.melBands {
                sum += dctMatrix[row + j] * melEnergies[j]
            }
            mfcc[i] = sum
        }
        return mfcc
    }

    // MARK: - Filterbank construction

    private static func buildMelFilterbank(
        bands: Int,
        fftSize: Int,
        sampleRate: Float,
        minHz: Float,
        maxHz: Float
    ) -> [[Float]] {
        let halfN = fftSize / 2
        let melMin = hzToMel(minHz)
        let melMax = hzToMel(maxHz)
        let stepMel = (melMax - melMin) / Float(bands + 1)

        // Mel-spaced points → Hz → FFT bin.
        var binPoints = [Float](repeating: 0, count: bands + 2)
        for i in 0..<(bands + 2) {
            let melCenter = melMin + Float(i) * stepMel
            let hzCenter = melToHz(melCenter)
            binPoints[i] = hzCenter * Float(fftSize) / sampleRate
        }

        var filters = [[Float]](repeating: [Float](repeating: 0, count: halfN + 1), count: bands)
        for b in 0..<bands {
            let left = binPoints[b]
            let center = binPoints[b + 1]
            let right = binPoints[b + 2]
            for k in 0...halfN {
                let kf = Float(k)
                if kf >= left && kf <= center {
                    filters[b][k] = (kf - left) / max(center - left, 1e-6)
                } else if kf > center && kf <= right {
                    filters[b][k] = (right - kf) / max(right - center, 1e-6)
                }
            }
        }
        return filters
    }

    private static func buildDCTMatrix(rows: Int, cols: Int) -> [Float] {
        // DCT-II: out[i] = sum_j x[j] * cos(pi * i * (j + 0.5) / cols)
        // Skip the i=0 (energy) coefficient by starting our output at i=1.
        var matrix = [Float](repeating: 0, count: rows * cols)
        let scale = sqrt(2.0 / Float(cols))
        for i in 0..<rows {
            for j in 0..<cols {
                let theta = Float.pi * Float(i + 1) * (Float(j) + 0.5) / Float(cols)
                matrix[i * cols + j] = scale * cos(theta)
            }
        }
        return matrix
    }

    private static func hzToMel(_ hz: Float) -> Float {
        return 1127.0 * log(1.0 + hz / 700.0)
    }

    private static func melToHz(_ mel: Float) -> Float {
        return 700.0 * (exp(mel / 1127.0) - 1.0)
    }
}

/// Cosine similarity between two equal-length L2-normalized vectors.
/// Returns a value in roughly [-1, 1]; for L2-normalized inputs == dot product.
@inlinable
func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    return dot
}
