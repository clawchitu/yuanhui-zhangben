import XCTest
@testable import YuanhuiZhangben

/// S14 验收：相机同码 1.5 秒内忽略，扫码枪每次扣扳机都算；扫到后按登记过 / 没登记出两种提示音。
@MainActor
final class ScanHubTests: XCTestCase {
    final class Recorder: ScanFeedbackPlaying {
        var played: [ScanOutcome] = []
        func play(_ outcome: ScanOutcome) { played.append(outcome) }
    }

    private var now: TimeInterval = 1000
    private var scans: [Scan] = []
    private var recorder = Recorder()

    private func makeHub(known: Set<String> = ["6921168509256"]) -> ScanHub {
        let hub = ScanHub(feedback: recorder, clock: { [unowned self] in now })
        hub.handler = { [unowned self] scan in
            scans.append(scan)
            return known.contains(scan.code) ? .known : .unknown
        }
        return hub
    }

    private func gun(_ hub: ScanHub, _ code: String) {
        for c in code {
            hub.key(.character(c), at: now)
            now += 0.01
        }
        hub.key(.enter, at: now)
    }

    // MARK: 相机去重（纯逻辑）

    func testDeduperIgnoresSameCodeWithin1_5Seconds() {
        var d = CameraDeduper()
        XCTAssertTrue(d.accept("A", at: 10))
        XCTAssertFalse(d.accept("A", at: 10.1))
        XCTAssertFalse(d.accept("A", at: 11.0))
        XCTAssertFalse(d.accept("A", at: 11.499))
        XCTAssertTrue(d.accept("A", at: 11.5), "满 1.5 秒算新的一次")
        XCTAssertFalse(d.accept("A", at: 12.9))
        XCTAssertTrue(d.accept("A", at: 13.0))
    }

    func testDeduperAcceptsADifferentCodeImmediately() {
        var d = CameraDeduper()
        XCTAssertTrue(d.accept("A", at: 10))
        XCTAssertTrue(d.accept("B", at: 10.1))
        XCTAssertTrue(d.accept("A", at: 10.2), "A、B、A 交替是不同商品，都算")
        XCTAssertFalse(d.accept("A", at: 10.3))
    }

    func testDeduperWindowCountsFromTheAcceptedScanNotTheLastSighting() {
        // 一直对着同一个码（每 0.1 秒认出一次）：每满 1.5 秒算一次，不会因为一直看得见就永远不算
        var d = CameraDeduper()
        var accepted: [TimeInterval] = []
        for i in 0...40 {
            let t = 10 + Double(i) * 0.1
            if d.accept("A", at: t) { accepted.append(t) }
        }
        XCTAssertEqual(accepted.map { ($0 * 10).rounded() / 10 }, [10, 11.5, 13])
    }

    func testDeduperResetAndClockGoingBackwards() {
        var d = CameraDeduper()
        XCTAssertTrue(d.accept("A", at: 10))
        d.reset()
        XCTAssertTrue(d.accept("A", at: 10.1))
        XCTAssertTrue(d.accept("A", at: 5), "时间倒流不当作 1.5 秒内")
    }

    // MARK: 汇合点

    func testCameraSameCodeWithin1_5sIsIgnoredByTheHub() {
        let hub = makeHub()
        XCTAssertEqual(hub.receive("6921168509256", from: .camera), .known)
        now += 0.5
        XCTAssertNil(hub.receive("6921168509256", from: .camera))
        now += 0.9
        XCTAssertNil(hub.receive("6921168509256", from: .camera))
        now += 0.1   // 距上次被接受 1.5 秒
        XCTAssertEqual(hub.receive("6921168509256", from: .camera), .known)
        XCTAssertEqual(scans.count, 2)
        XCTAssertEqual(recorder.played, [.known, .known], "被忽略的那次不出声")
    }

    func testGunCountsEveryTriggerEvenWithin1_5s() {
        let hub = makeHub()
        for _ in 0..<3 {
            gun(hub, "6921168509256")
            now += 0.1
        }
        XCTAssertEqual(scans, Array(repeating: Scan(code: "6921168509256", source: .gun), count: 3))
        XCTAssertEqual(recorder.played, [.known, .known, .known])
    }

    func testCameraDedupeDoesNotAffectGunOrManual() {
        let hub = makeHub()
        hub.receive("6921168509256", from: .camera)
        now += 0.1
        gun(hub, "6921168509256")
        now += 0.1
        hub.receive("6921168509256", from: .manual)
        now += 0.1
        hub.receive("6921168509256", from: .manual)
        XCTAssertEqual(scans.map(\.source), [.camera, .gun, .manual, .manual])
        now += 0.1
        XCTAssertNil(hub.receive("6921168509256", from: .camera), "相机仍按自己上次接受的时间去重")
    }

    func testSlowTypingOnTheGunPathIsNotAScan() {
        let hub = makeHub()
        for c in "6921168509256" {
            hub.key(.character(c), at: now)
            now += 0.3
        }
        XCTAssertNil(hub.key(.enter, at: now))
        XCTAssertEqual(scans, [])
        XCTAssertEqual(recorder.played, [])
    }

    func testUnknownCodePlaysTheLowTone() {
        let hub = makeHub()
        XCTAssertEqual(hub.receive("6900000000000", from: .camera), .unknown)
        gun(hub, "6921168509256")
        XCTAssertEqual(recorder.played, [.unknown, .known])
    }

    func testIgnoredOutcomeAndNoHandlerAreSilent() {
        let hub = ScanHub(feedback: recorder, clock: { [unowned self] in now })
        XCTAssertEqual(hub.receive("6921168509256", from: .manual), .ignored)
        hub.handler = { _ in .ignored }
        XCTAssertEqual(hub.receive("6921168509256", from: .manual), .ignored)
        XCTAssertEqual(recorder.played, [])
    }

    func testBlankCodesAreDroppedAndCodesAreTrimmed() {
        let hub = makeHub()
        XCTAssertNil(hub.receive("   ", from: .manual))
        XCTAssertEqual(hub.receive(" 6921168509256\n", from: .manual), .known)
        XCTAssertEqual(scans.map(\.code), ["6921168509256"])
    }
}
