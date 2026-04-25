import Foundation

/// One-time backfill actor that re-embeds historical screenshots whose
/// `embedding` column is NULL or zero-length.  These rows pre-date Sprint Q
/// when `NLEmbedding` was wired into the capture pipeline.
///
/// Idempotency guarantee: the UserDefaults flag `embeddingBackfillCompleted_v1`
/// is set only after two consecutive empty query batches confirm there is
/// nothing left to process.  Running this 100 times is safe.
///
/// Battery awareness: the heavy loop only runs when
/// `BatteryAwareScheduler.shared.allowHeavyWork` is true.  If the machine is
/// on battery or in low-power mode at launch the service logs a skip message
/// and exits; the flag is intentionally NOT set so the next launch retries.
actor EmbeddingBackfillService {
    static let shared = EmbeddingBackfillService()

    private static let userDefaultsKey = "embeddingBackfillCompleted_v1"
    private static let batchSize = 50
    private static let throttleNanoseconds: UInt64 = 250_000_000  // 250 ms

    private init() {}

    // MARK: - Public API

    /// Entry point.  Call once after capture services are initialized.
    /// Returns immediately if the backfill has already completed or if the
    /// machine lacks headroom to run heavy work.
    func runIfNeeded() async {
        // Fast-path: already done.
        guard !UserDefaults.standard.bool(forKey: Self.userDefaultsKey) else {
            log("EmbeddingBackfillService: already complete (v1), skipping")
            return
        }

        // Battery gate: skip and let the next launch retry.
        guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
            log("EmbeddingBackfillService: heavy work not allowed (battery/thermal), will retry next launch")
            return
        }

        log("EmbeddingBackfillService: starting historical OCR re-embed")
        let startTime = Date()

        do {
            try await backfillLoop(startTime: startTime)
        } catch {
            logError("EmbeddingBackfillService: backfill loop failed, will retry next launch", error: error)
        }
    }

    // MARK: - Private

    private func backfillLoop(startTime: Date) async throws {
        var totalProcessed = 0
        var consecutiveEmptyBatches = 0

        while consecutiveEmptyBatches < 2 {
            // Re-check power state between batches so we don't pin the CPU
            // when the user unplugs mid-backfill.
            guard await MainActor.run(body: { BatteryAwareScheduler.shared.allowHeavyWork }) else {
                log("EmbeddingBackfillService: pausing — power conditions changed after \(totalProcessed) rows, will retry next launch")
                return
            }

            let rows = try await RewindDatabase.shared.getScreenshotsMissingEmbeddings(
                limit: Self.batchSize
            )

            guard !rows.isEmpty else {
                consecutiveEmptyBatches += 1
                log("EmbeddingBackfillService: empty batch (\(consecutiveEmptyBatches)/2)")
                continue
            }

            consecutiveEmptyBatches = 0

            // Embed using the on-device NLEmbedding path already in EmbeddingService.
            let texts = rows.map {
                OCREmbeddingService.formatForEmbedding(
                    ocrText: $0.ocrText,
                    appName: $0.appName,
                    windowTitle: $0.windowTitle
                )
            }

            let embeddings = try await EmbeddingService.shared.embedBatch(texts: texts)

            for (index, embedding) in embeddings.enumerated() where index < rows.count {
                let data = await EmbeddingService.shared.floatsToData(embedding)
                try await RewindDatabase.shared.updateScreenshotEmbedding(
                    id: rows[index].id,
                    embedding: data
                )
            }

            totalProcessed += rows.count

            if totalProcessed % 500 == 0 || totalProcessed == rows.count {
                log("EmbeddingBackfillService: \(totalProcessed) rows embedded so far")
            }

            // Throttle: yield CPU for 250 ms between batches.
            try await Task.sleep(nanoseconds: Self.throttleNanoseconds)
        }

        // Two consecutive empty batches — we are done.
        let elapsed = Date().timeIntervalSince(startTime)
        UserDefaults.standard.set(true, forKey: Self.userDefaultsKey)
        log(String(format: "EmbeddingBackfillService: complete — %d rows in %.1fs", totalProcessed, elapsed))
    }
}
