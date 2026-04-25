import AppKit
import CoreGraphics
import Foundation

/// Decides which captured frames are worth feeding to the local VLM
/// (`VisionLLMClient`, owned by Sprint GG). Sampling every frame would be
/// prohibitively expensive — even on a Studio M2 Ultra running a 7B Qwen2.5-VL
/// at 4-bit, a `describe(image:)` call costs hundreds of milliseconds and a
/// few watts.
///
/// **Sampling triggers** (any one fires):
///   1. Scene change — perceptual hash (8x8 dHash) Hamming distance against
///      the last sampled frame ≥ `sceneChangeThreshold` bits.
///   2. App switch — `appName` differs from the last sampled frame's app.
///   3. Time floor — at least `forceSampleInterval` seconds have elapsed
///      since the last sample (default 60s).
///
/// **Battery gating**: every decision is short-circuited by
/// `BatteryAwareScheduler.shared.allowHeavyWork`. When false, frames are
/// dropped (NOT enqueued in `BatteryAwareScheduler.pending_work` — the next
/// useful frame after AC reconnect is captured fresh, no need to play
/// catch-up on stale screen contents).
///
/// **Lifecycle**: `start()` / `stop()` are no-ops today (no background timer
/// — sampling is fully driven by `RewindIndexer.processFrame` calling
/// `considerFrame(_:)`). They exist so callers can flip a feature flag or
/// debug menu cleanly without touching the call site.
@MainActor
final class VisualActivitySampler: ObservableObject {
    static let shared = VisualActivitySampler()

    // MARK: - Tunable knobs

    /// Hamming distance (in bits, out of 64) against the previous sampled
    /// frame's dHash that counts as "scene changed". 8x8 dHash → 64 bits;
    /// empirically values in the 8-16 range catch real scene changes
    /// (different document, different tab, modal dialog) while ignoring
    /// cursor blink and 1px pan jitter.
    var sceneChangeThreshold: Int = 12

    /// If neither scene-change nor app-switch has triggered, force a sample
    /// after this many seconds. Bounds the worst-case "I sat staring at the
    /// same Figma frame for an hour" gap in the visual activity log.
    var forceSampleInterval: TimeInterval = 60

    /// If the same hash repeats within this window, suppress the sample
    /// entirely (idle screen, sleeping display, etc.). Prevents the time-floor
    /// from filling the table with 100 identical rows during an idle hour.
    var idleSuppressionInterval: TimeInterval = 300

    // MARK: - Published state

    /// Number of frames currently sitting in the indexer's processing queue.
    /// Surfaced so the Settings UI can show "VLM busy" vs "idle".
    @Published private(set) var samplesQueued: Int = 0

    /// Cumulative count of frames the indexer has processed (success or
    /// failure) since this session began.
    @Published private(set) var samplesProcessed: Int = 0

    // MARK: - Internal state

    private var lastSampleHash: PerceptualHash?
    private var lastSampleTime: Date = .distantPast
    private var lastSampleApp: String?
    private var isStarted: Bool = false

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isStarted else { return }
        isStarted = true
        // Seed last-known perceptual hash from the most recent indexed row so
        // we don't immediately re-fire on app launch when the screen looks
        // the same as before the relaunch.
        Task {
            if let stored = try? await RewindDatabase.shared.mostRecentVisualActivityPerceptualHash(),
               let hash = PerceptualHash(hex: stored)
            {
                await MainActor.run { self.lastSampleHash = hash }
            }
        }
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        lastSampleHash = nil
        lastSampleApp = nil
    }

    /// Called by `VisualActivityIndexer` whenever it completes processing a
    /// frame (success or skipped) so the Settings UI badge stays accurate.
    func recordCompletion() {
        samplesProcessed += 1
        samplesQueued = max(0, samplesQueued - 1)
    }

    /// Called by `VisualActivityIndexer` when a frame is rejected before
    /// kicking off VLM work (e.g. VLM unreachable, image decode failed).
    func recordRejection() {
        samplesQueued = max(0, samplesQueued - 1)
    }

    // MARK: - Sampling decision

    /// Given a freshly-inserted screenshot, decide whether it's worth
    /// VLM-describing and, if so, hand it off to `VisualActivityIndexer`.
    ///
    /// Cheap operations only on this path: a single CGImage decode + 8x8
    /// downsample for the perceptual hash. The expensive VLM call happens
    /// off-thread inside the indexer.
    func considerFrame(_ frame: Screenshot) async {
        guard isStarted else { return }
        guard frame.id != nil else { return }

        // Battery gate. We drop on battery rather than enqueueing so we don't
        // play catch-up on minutes-old screen contents on AC reconnect.
        guard BatteryAwareScheduler.shared.allowHeavyWork else { return }

        // Try to load the underlying CGImage so we can hash it. If the load
        // fails (video chunk still encoding, etc.) we silently drop — the
        // sampler will catch the next frame.
        guard let cgImage = await loadCGImage(for: frame) else { return }

        let hash = PerceptualHash(cgImage: cgImage)
        let now = frame.timestamp

        // Decision logic — first matching reason wins, in priority order.
        let reason: SampleReason? = {
            // 1. App switch beats everything; new context, want a fresh
            //    summary even if the visual content overlaps.
            if let last = lastSampleApp, last != frame.appName {
                return .appSwitch
            }
            // 2. Scene change.
            if let prev = lastSampleHash {
                let distance = prev.hammingDistance(to: hash)
                if distance >= sceneChangeThreshold {
                    return .sceneChange(distance: distance)
                }
                // Idle suppression: identical hash within the suppression
                // window means nothing changed and time-floor shouldn't fire.
                if distance == 0,
                   now.timeIntervalSince(lastSampleTime) < idleSuppressionInterval
                {
                    return nil
                }
            }
            // 3. Time floor.
            if now.timeIntervalSince(lastSampleTime) >= forceSampleInterval {
                return .timeFloor
            }
            return nil
        }()

        guard let reason = reason else { return }

        // Commit the sampling decision before kicking off the indexer so two
        // back-to-back near-identical frames don't both get sampled.
        lastSampleHash = hash
        lastSampleTime = now
        lastSampleApp = frame.appName
        samplesQueued += 1

        await VisualActivityIndexer.shared.enqueue(
            frame: frame,
            cgImage: cgImage,
            perceptualHash: hash,
            reason: reason
        )
    }

    // MARK: - Helpers

    /// Load the CGImage backing this `Screenshot` row, if available. Wraps
    /// the call in an autoreleasepool to keep NSImage's Obj-C representations
    /// from accumulating on the sampling hot path.
    private func loadCGImage(for screenshot: Screenshot) async -> CGImage? {
        do {
            let nsImage = try await RewindStorage.shared.loadScreenshotImage(for: screenshot)
            return autoreleasepool {
                nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
            }
        } catch {
            return nil
        }
    }
}

/// Why the sampler decided to forward a frame. Logged for tuning the
/// thresholds; not persisted.
enum SampleReason: CustomStringConvertible {
    case sceneChange(distance: Int)
    case appSwitch
    case timeFloor

    var description: String {
        switch self {
        case .sceneChange(let d): return "scene-change(d=\(d))"
        case .appSwitch: return "app-switch"
        case .timeFloor: return "time-floor"
        }
    }
}

// MARK: - Perceptual hash (8x8 dHash)

/// 8x8 difference hash. Cheap (≈1 ms on Apple Silicon for a Retina capture),
/// resilient to small visual changes (cursor blinks, scrolling 1-2 px),
/// catches real scene changes (different app, modal dialog, document switch).
///
/// Algorithm:
///   1. Convert source to grayscale.
///   2. Downsample to 9x8 using CoreGraphics' bilinear interpolation.
///   3. For each row, compare each pixel to its right neighbour — bit set if
///      left > right. 9 columns → 8 comparisons per row → 64 bits total.
///
/// Hamming distance between two hashes correlates well with visual
/// similarity. A distance of 0 means "identical or near-identical screen".
struct PerceptualHash: Equatable {
    /// Packed 64 bits, big-endian conceptually (row 0 leftmost in MSB).
    let bits: UInt64

    init(bits: UInt64) {
        self.bits = bits
    }

    init?(hex: String) {
        guard hex.count == 16, let parsed = UInt64(hex, radix: 16) else {
            return nil
        }
        self.bits = parsed
    }

    /// Compute the dHash for a CGImage.
    init(cgImage: CGImage) {
        self.bits = Self.computeDHash(cgImage)
    }

    /// 16-character lowercase hex representation suitable for storage.
    var hexString: String {
        String(format: "%016llx", bits)
    }

    /// Number of differing bits between two hashes (0…64). Lower = more similar.
    func hammingDistance(to other: PerceptualHash) -> Int {
        (bits ^ other.bits).nonzeroBitCount
    }

    private static func computeDHash(_ image: CGImage) -> UInt64 {
        let width = 9
        let height = 8
        let bytesPerRow = width
        var pixels = [UInt8](repeating: 0, count: width * height)

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return 0
        }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bitIndex: UInt64 = 0
        // Row-major; for each row compare adjacent columns.
        for row in 0..<height {
            for col in 0..<(width - 1) {
                let left = pixels[row * width + col]
                let right = pixels[row * width + col + 1]
                if left > right {
                    hash |= (UInt64(1) << bitIndex)
                }
                bitIndex += 1
            }
        }
        return hash
    }
}
