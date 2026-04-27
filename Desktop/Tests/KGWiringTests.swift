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
                totalNodes: 0,
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
            totalNodes: 0,
            totalMemories: 50,
            processedMemories: 0
        )
        XCTAssertEqual(mode, .backfillNotStarted)
    }

    func testClassifierReturnsCompleteEmptyWhenIdleAndProcessedAllZero() {
        let mode = BrainMapEmptyStateClassifier.mode(
            state: .idleNoWork,
            totalNodes: 0,
            totalMemories: 50,
            processedMemories: 50
        )
        XCTAssertEqual(mode, .backfillCompleteEmpty)
    }

    func testClassifierReturnsCompleteEmptyWhenNoMemoriesAtAll() {
        let mode = BrainMapEmptyStateClassifier.mode(
            state: .idleNoWork,
            totalNodes: 0,
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
}
