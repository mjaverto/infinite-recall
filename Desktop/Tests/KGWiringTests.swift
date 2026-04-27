import XCTest
@testable import Omi_Computer

/// Tests for Lane C wiring: dedup-key contract, payload shape,
/// empty-state classifier, scheduler readiness gating, and progress
/// publisher invariants.
///
/// DB-bound paths (extractor outcomes → KnowledgeGraphStorage upsert) are
/// covered by `KnowledgeGraphStorageTests` and `KGExtractorTests`. These
/// tests focus on the wiring seams Lane C owns.
final class KGWiringTests: XCTestCase {

    // MARK: - Dedup key contract

    func testDedupKeyMatchesColonStyleConvention() {
        XCTAssertEqual(
            KGBackfillService.dedupKey(forMemoryId: 42),
            "extractKG:42",
            "Dedup key must be `extractKG:<id>` to match the summarize/<id> convention used by the scheduler."
        )
    }

    func testDedupKeyDistinctPerMemoryId() {
        let a = KGBackfillService.dedupKey(forMemoryId: 1)
        let b = KGBackfillService.dedupKey(forMemoryId: 2)
        XCTAssertNotEqual(a, b)
    }

    func testDedupKeyHandlesNegativeAndLargeIds() {
        XCTAssertEqual(KGBackfillService.dedupKey(forMemoryId: -1), "extractKG:-1")
        XCTAssertEqual(
            KGBackfillService.dedupKey(forMemoryId: Int64.max),
            "extractKG:\(Int64.max)"
        )
    }

    // MARK: - Migration key

    func testMigrationKeyIsKgBackfillV1() {
        XCTAssertEqual(KGBackfillService.migrationKey, "kg_backfill_v1")
    }

    // MARK: - Pending work label

    func testWorkLabelDecodesExtractKGPayload() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["memory_id": 123])
        let work = PendingWork(
            kind: .extractKG,
            payload: payload
        )
        let label = WorkLabels.humanLabel(work)
        XCTAssertTrue(
            label.contains("123"),
            "extractKG label must include the memory id; got: \(label)"
        )
        XCTAssertTrue(
            label.lowercased().contains("brain map") || label.lowercased().contains("entit"),
            "extractKG label should reference brain map / entities; got: \(label)"
        )
    }

    func testWorkLabelExtractKGFallsBackOnUndecodablePayload() {
        let work = PendingWork(
            kind: .extractKG,
            payload: Data("not-json".utf8)
        )
        let label = WorkLabels.humanLabel(work)
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: - Scheduler readiness gating

    func testExtractKGRequiresAutonomousReadiness() {
        // The autonomous-readiness gate determines whether the scheduler
        // demands MLX-loaded + idle/lock state before draining. KG
        // extraction calls into the local LLM, so it must opt in.
        // We can't access fileprivate `requiresAutonomousReadiness` directly
        // here, but the contract is exercised end-to-end by
        // `BatteryAwareSchedulerReadinessTests`. This guard is a smoke check
        // that the enum cases needed by Lane C exist.
        let kinds = PendingWork.Kind.allCases
        XCTAssertTrue(
            kinds.contains(.extractKG),
            "PendingWork.Kind.extractKG must be present so handlers can register."
        )
        XCTAssertTrue(kinds.contains(.summarize))
    }

    // MARK: - Empty-state classifier

    func testClassifierReturnsBuildingWhilePending() {
        for state: BuildState in [.building, .pausedThermal, .pausedBattery, .pausedNotIdle, .modelNotReady] {
            let mode = BrainMapEmptyStateClassifier.mode(
                state: state,
                totalMemories: 100,
                processedMemories: 5
            )
            XCTAssertEqual(
                mode, .backfillRunningNoNodesYet,
                "State \(state) with pending work should report backfillRunningNoNodesYet"
            )
        }
    }

    func testClassifierReturnsNotStartedWhenIdleAndUntouched() {
        let mode = BrainMapEmptyStateClassifier.mode(
            state: .idleNoWork,
            totalMemories: 50,
            processedMemories: 0
        )
        XCTAssertEqual(mode, .backfillNotStarted)
    }

    func testClassifierReturnsCompleteEmptyWhenIdleAndProcessedAllZero() {
        let mode = BrainMapEmptyStateClassifier.mode(
            state: .idleNoWork,
            totalMemories: 50,
            processedMemories: 50
        )
        XCTAssertEqual(mode, .backfillCompleteEmpty)
    }

    func testClassifierReturnsCompleteEmptyWhenNoMemoriesAtAll() {
        let mode = BrainMapEmptyStateClassifier.mode(
            state: .idleNoWork,
            totalMemories: 0,
            processedMemories: 0
        )
        XCTAssertEqual(mode, .backfillCompleteEmpty)
    }

    // MARK: - Build progress equality / decoding

    func testBuildProgressEquatableSemantics() {
        let a = KGBuildProgress(
            totalMemories: 10, processedMemories: 4, succeededMemories: 3,
            totalNodes: 7, state: .building, etaSeconds: 12
        )
        let b = KGBuildProgress(
            totalMemories: 10, processedMemories: 4, succeededMemories: 3,
            totalNodes: 7, state: .building, etaSeconds: 12
        )
        let c = KGBuildProgress(
            totalMemories: 10, processedMemories: 5, succeededMemories: 3,
            totalNodes: 7, state: .building, etaSeconds: 12
        )
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    // MARK: - Progress publisher

    func testProgressPublisherDeliversAfterTick() async {
        // The publisher is a singleton actor backed by the real DB. We
        // assert only that subscribing + ticking yields at least one
        // snapshot (the publisher replays its last cached snapshot on
        // subscribe and emits on tick).
        let publisher = KGProgressPublisher.shared
        let stream = await publisher.stream

        let task = Task<KGBuildProgress?, Never> {
            for await snap in stream {
                return snap
            }
            return nil
        }

        // Trigger a sample.
        await publisher.tick()

        let received = await withTaskGroup(of: KGBuildProgress?.self) { group in
            group.addTask { await task.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        task.cancel()

        XCTAssertNotNil(received, "Publisher must yield a snapshot after tick().")
    }

    func testProgressPublisherRecordDrainSampleDoesNotCrash() async {
        // Recording samples before subscribers attach must be safe.
        await KGProgressPublisher.shared.recordDrainSample(seconds: 0.5)
        await KGProgressPublisher.shared.recordDrainSample(seconds: 0.4)
        await KGProgressPublisher.shared.recordDrainSample(seconds: 0.6)
        // No crash + tick still works.
        await KGProgressPublisher.shared.tick()
    }

    // MARK: - Cluster D3 — saturating progress invariants

    func testBuildProgressClampsProcessedOverTotal() {
        let p = KGBuildProgress(
            totalMemories: 10,
            processedMemories: 15,   // race window, clamp to total
            succeededMemories: 12,
            totalNodes: 0,
            state: .building,
            etaSeconds: nil
        )
        XCTAssertEqual(p.totalMemories, 10)
        XCTAssertEqual(p.processedMemories, 10, "processed must clamp to total")
        XCTAssertEqual(p.succeededMemories, 10, "succeeded must clamp to processed")
    }

    func testBuildProgressClampsSucceededOverProcessed() {
        let p = KGBuildProgress(
            totalMemories: 10,
            processedMemories: 4,
            succeededMemories: 9,    // bogus — succeeded must trail processed
            totalNodes: 0,
            state: .building,
            etaSeconds: nil
        )
        XCTAssertEqual(p.processedMemories, 4)
        XCTAssertEqual(p.succeededMemories, 4, "succeeded must clamp to processed")
    }

    func testBuildProgressClampsNegativeInputs() {
        let p = KGBuildProgress(
            totalMemories: -1,
            processedMemories: -5,
            succeededMemories: -3,
            totalNodes: -2,
            state: .idleNoWork,
            etaSeconds: nil
        )
        XCTAssertEqual(p.totalMemories, 0)
        XCTAssertEqual(p.processedMemories, 0)
        XCTAssertEqual(p.succeededMemories, 0)
        XCTAssertEqual(p.totalNodes, 0)
    }

    // MARK: - Cluster H1 — extractKG depth cap

    func testExtractKGNotCapDroppedAtLowDepth() async throws {
        // Cluster H1: the depthCaps entry for extractKG must be high enough
        // that a single enqueue at low queue depth doesn't trigger a
        // cap-drop. We use the recentDrops counter delta to detect cap-drop
        // — a nil return from `enqueue` could also mean a dedup hit, which
        // is fine for this assertion.
        let storage = PendingWorkStorage.shared
        let dropsBefore = await storage.recentDrops

        let key = "extractKG-test-\(UUID().uuidString)"
        let payload = try JSONSerialization.data(withJSONObject: ["memory_id": Int64.max])
        _ = try await storage.enqueue(
            workType: PendingWork.Kind.extractKG.rawValue,
            payload: payload,
            dedupKey: key
        )

        let dropsAfter = await storage.recentDrops
        XCTAssertEqual(
            dropsAfter, dropsBefore,
            "extractKG must not be cap-dropped at low queue depth (recentDrops bumped)"
        )
    }

    // MARK: - Cluster K — classifier no longer takes totalNodes

    func testClassifierIsPureFunctionOfStateAndCounts() {
        // Same (state, totals) must produce same mode regardless of
        // anything else — the only inputs are the three params.
        XCTAssertEqual(
            BrainMapEmptyStateClassifier.mode(state: .idleNoWork, totalMemories: 5, processedMemories: 0),
            .backfillNotStarted
        )
        XCTAssertEqual(
            BrainMapEmptyStateClassifier.mode(state: .idleNoWork, totalMemories: 5, processedMemories: 5),
            .backfillCompleteEmpty
        )
        XCTAssertEqual(
            BrainMapEmptyStateClassifier.mode(state: .building, totalMemories: 5, processedMemories: 2),
            .backfillRunningNoNodesYet
        )
    }
}
