import XCTest
@testable import Omi_Computer

final class ActivityMonitorServiceQueueDepthTests: XCTestCase {
    func testSnapshotOverlayUsesPendingWorkDepthByKind() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snap = ActivitySnapshot(
            kinds: [
                KindRow(kind: .transcribe, inFlight: nil, queued: 0, failed: 0, lastDoneAt: nil, pausedUntil: nil),
                KindRow(kind: .summarize, inFlight: nil, queued: 0, failed: 0, lastDoneAt: nil, pausedUntil: nil),
                KindRow(kind: .extractMemory, inFlight: nil, queued: 99, failed: 99, lastDoneAt: nil, pausedUntil: nil),
                KindRow(kind: .extractActionItems, inFlight: nil, queued: 99, failed: 99, lastDoneAt: nil, pausedUntil: nil)
            ],
            capture: [],
            resources: ResourceSample(
                cpuPercent: 0,
                rssMb: 0,
                gpuSystemPercent: nil,
                thermalState: .nominal,
                onBattery: false,
                lowPower: false,
                processBreakdown: []
            ),
            processingGate: .allowed(since: now),
            generatedAt: now
        )

        var depth = PendingWorkDepth()
        depth.queued = [
            PendingWork.Kind.transcribe.rawValue: 2,
            PendingWork.Kind.summarize.rawValue: 1,
            PendingWork.Kind.extractMemory.rawValue: 3
        ]
        depth.failed = [
            PendingWork.Kind.summarize.rawValue: 4,
            PendingWork.Kind.extractActionItems.rawValue: 5
        ]

        let overlaid = ActivityMonitorService.snapshot(snap, applying: depth)
        let byKind = Dictionary(uniqueKeysWithValues: overlaid.kinds.map { ($0.kind, $0) })

        XCTAssertEqual(byKind[.transcribe]?.queued, 2)
        XCTAssertEqual(byKind[.transcribe]?.failed, 0)
        XCTAssertEqual(byKind[.summarize]?.queued, 1)
        XCTAssertEqual(byKind[.summarize]?.failed, 4)
        XCTAssertEqual(byKind[.extractMemory]?.queued, 3)
        XCTAssertEqual(byKind[.extractMemory]?.failed, 0)
        XCTAssertEqual(byKind[.extractActionItems]?.queued, 0)
        XCTAssertEqual(byKind[.extractActionItems]?.failed, 5)
    }
}
