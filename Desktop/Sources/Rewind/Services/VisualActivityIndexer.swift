import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Timeout helper

/// Races `work` against a deadline. Cancels `work` and throws `TimeoutError`
/// if `seconds` elapse before the closure returns.
struct TimeoutError: Error {}

func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    work: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await work() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError()
        }
        // Return the first result (work or timeout — whichever finishes first).
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// Consumes frames from `VisualActivitySampler`, calls the local VLM
/// (`VisionLLMClient.shared`, owned by Sprint GG) for a 1-2 sentence
/// description, and persists a `visual_activity` row.
///
/// **Sprint GG dependency**: `VisionLLMClient` is being wired up in parallel.
/// Until it lands we stub the call site behind `isVLMAvailable()` — when the
/// VLM is unreachable we still insert a `visual_activity` row with the OCR
/// snapshot and perceptual hash so the FTS index stays useful for the
/// "what was on my screen at 3pm" query, just without the model-generated
/// summary. When Agent GG ships their client, this file's stubs collapse to
/// real `try await VisionLLMClient.shared.describe(...)` calls.
///
/// **Concurrency**: `actor`-isolated, single-flight. The sampler enqueues
/// asynchronously; we drain serially so we never have two concurrent VLM
/// calls fighting for the GPU.
///
/// **Failure modes**:
///   - VLM unreachable → insert OCR-only row, leave `visualSummary` nil.
///   - VLM call timeout (5s) → log + insert OCR-only row, do not retry.
///   - Image too large → resize to 1024px on the long edge before encoding.
///   - Disk pressure → after each insert, trim the oldest rows so the table
///     stays under `maxRows` (default 30k).
actor VisualActivityIndexer {
    static let shared = VisualActivityIndexer()

    /// Soft cap on total rows. After each insert we trim oldest above this.
    /// 30k rows ≈ ~21 days at 60s time-floor with frequent app switches —
    /// plenty for a useful visual recall window.
    var maxRows: Int = 30_000

    /// VLM call timeout. Above this, abandon the describe() and insert the
    /// row OCR-only. Pipeline must not block on a stuck VLM.
    var vlmTimeout: TimeInterval = 5

    /// Long-edge pixel cap for images sent to the VLM. 1024 is a reasonable
    /// trade-off — preserves enough detail for OCR-grade UI element
    /// recognition while keeping prefill latency in single-digit seconds.
    var maxImageEdge: Int = 1024

    private var inFlight: Task<Void, Never>?

    private init() {}

    // MARK: - Sampler entry point

    /// Called by `VisualActivitySampler` once it decides a frame is worth
    /// VLM-describing. Returns immediately — the actual work runs on a
    /// background `Task` so the sampler doesn't stall capture.
    func enqueue(
        frame: Screenshot,
        cgImage: CGImage,
        perceptualHash: PerceptualHash,
        reason: SampleReason
    ) async {
        guard let screenshotId = frame.id else { return }

        // Single-flight: if a previous indexer task is still running, wait
        // for it to finish before kicking off the next one. Keeps GPU
        // contention bounded; the sampler's own decision logic ensures we
        // don't accumulate a long backlog.
        await inFlight?.value

        let task = Task { [weak self] in
            guard let self else { return }
            await self.process(
                screenshotId: screenshotId,
                frame: frame,
                cgImage: cgImage,
                perceptualHash: perceptualHash,
                reason: reason
            )
        }
        inFlight = task
    }

    // MARK: - Pipeline

    private func process(
        screenshotId: Int64,
        frame: Screenshot,
        cgImage: CGImage,
        perceptualHash: PerceptualHash,
        reason: SampleReason
    ) async {
        // Pull OCR snapshot off the source frame. Cheaper than a join.
        let ocrSnapshot: String? = {
            if let text = frame.ocrText, !text.isEmpty { return text }
            return nil
        }()

        // VLM describe — gated on reachability. If the VLM client isn't
        // wired up yet (Sprint GG dependency) or the server is down, we
        // still insert the row with OCR + hash; the row remains useful for
        // text search and a backfill task can fill in `visualSummary` later.
        let summary: String?
        let uiState: String?
        if await isVLMAvailable() {
            let resized = resizeIfNeeded(cgImage, maxEdge: maxImageEdge)
            (summary, uiState) = await describeWithTimeout(
                cgImage: resized ?? cgImage,
                appName: frame.appName,
                windowTitle: frame.windowTitle
            )
        } else {
            summary = nil
            uiState = nil
        }

        let record = VisualActivityRecord(
            screenshotId: screenshotId,
            sampledAt: frame.timestamp,
            appName: frame.appName,
            windowTitle: frame.windowTitle,
            visualSummary: summary,
            uiState: uiState,
            ocrTextSnapshot: ocrSnapshot,
            perceptualHash: perceptualHash.hexString
        )

        do {
            _ = try await RewindDatabase.shared.insertVisualActivity(record)
            await MainActor.run {
                VisualActivitySampler.shared.recordCompletion()
            }
            log("VisualActivityIndexer: indexed screenshot=\(screenshotId) reason=\(reason) hasSummary=\(summary != nil)")
        } catch {
            logError("VisualActivityIndexer: failed to insert visual_activity row: \(error)")
            await MainActor.run {
                VisualActivitySampler.shared.recordRejection()
            }
            return
        }

        // Disk pressure: keep the table bounded. Cheap COUNT + conditional
        // DELETE; runs ad hoc on each insert rather than as a periodic sweep
        // so we never quietly exceed the cap.
        do {
            let trimmed = try await RewindDatabase.shared.trimVisualActivity(keeping: maxRows)
            if trimmed > 0 {
                log("VisualActivityIndexer: trimmed \(trimmed) old rows (cap=\(maxRows))")
            }
        } catch {
            logError("VisualActivityIndexer: trim failed: \(error)")
        }
    }

    // MARK: - VLM availability + call

    /// Returns true when the local VLM sidecar is reachable on 127.0.0.1:8081.
    ///
    /// INVARIANT: `VisionLLMClient.isReachable()` must NOT call
    /// `IdleAIController.shared.recordAICall()`. A polling probe that records
    /// AI calls would pin the VLM alive, defeating idle-unload entirely.
    /// Verified: `VisionLLMClient.isReachable()` is a bare URLSession GET to
    /// `/v1/models` with a 2s timeout — no `recordAICall()` in its body.
    private func isVLMAvailable() async -> Bool {
        return await VisionLLMClient.shared.isReachable()
    }

    /// Calls `VisionLLMClient.shared.describe(image:prompt:)` wrapped in a
    /// `withTimeout` guard. On timeout or any error, returns `(nil, nil)` and
    /// logs so the caller can insert an OCR-only row.
    private func describeWithTimeout(
        cgImage: CGImage,
        appName: String,
        windowTitle: String?
    ) async -> (summary: String?, uiState: String?) {
        // Convert CGImage → NSImage. VisionLLMClient.describe takes NSImage.
        let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))

        let contextHint: String
        if let title = windowTitle, !title.isEmpty {
            contextHint = "\(appName) — \(title)"
        } else {
            contextHint = appName
        }
        let prompt = "Describe what is happening on this screen in 1-2 sentences. "
            + "Note the app, document, or content visible. Context: \(contextHint)"

        let uiStateSchema = VisualActivityIndexer.uiStateSchema
        let timeout = vlmTimeout

        do {
            let (summary, uiState) = try await withTimeout(seconds: timeout) { () async throws -> (String, String?) in
                let text = try await VisionLLMClient.shared.describe(image: nsImage, prompt: prompt)
                let structured = try? await VisionLLMClient.shared.extractStructured(
                    image: nsImage,
                    schemaJSON: uiStateSchema
                )
                let serialized = structured.flatMap { dict -> String? in
                    guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else { return nil }
                    return String(data: data, encoding: .utf8)
                }
                return (text, serialized)
            }
            return (summary.isEmpty ? nil : summary, uiState)
        } catch is TimeoutError {
            log("VisualActivityIndexer: VLM describe timed out after \(timeout)s — inserting OCR-only row")
            return (nil, nil)
        } catch {
            log("VisualActivityIndexer: VLM describe failed: \(error) — inserting OCR-only row")
            return (nil, nil)
        }
    }

    // MARK: - UI state schema

    /// JSON schema string sent to `VisionLLMClient.extractStructured`.
    private static let uiStateSchema = """
        {
          "type": "object",
          "properties": {
            "appName":     { "type": "string" },
            "windowTitle": { "type": "string" },
            "uiMode":      { "type": "string", "description": "e.g. editor, browser, terminal, video, document" },
            "focusedElement": { "type": "string", "description": "The most prominent UI element or content area" }
          },
          "required": ["appName"]
        }
        """

    // MARK: - Image resizing

    /// Resize `image` so its longest edge ≤ `maxEdge`, preserving aspect
    /// ratio. Returns nil if no resize is needed (caller should use the
    /// original CGImage as-is).
    private func resizeIfNeeded(_ image: CGImage, maxEdge: Int) -> CGImage? {
        let w = image.width
        let h = image.height
        let longest = max(w, h)
        guard longest > maxEdge else { return nil }

        let scale = Double(maxEdge) / Double(longest)
        let newW = Int((Double(w) * scale).rounded())
        let newH = Int((Double(h) * scale).rounded())

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: nil,
            width: newW,
            height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        return ctx.makeImage()
    }
}
