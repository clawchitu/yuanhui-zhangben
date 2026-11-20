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

    func testDeduperIgnoresSameCodeWithin1_5SecondsOfTheLastSighting() {
        var d = CameraDeduper()
        XCTAssertTrue(d.accept("A", at: 10))
        XCTAssertFalse(d.accept("A", at: 11.25), "距上次看见不到 1.5 秒")
        XCTAssertFalse(d.accept("A", at: 12.5), "距上次看见（11.25）1.25 秒：还是同一次，虽然距接受已 2.5 秒")
        XCTAssertTrue(d.accept("A", at: 14.0), "距上次看见恰好 1.5 秒算新的一次")
        XCTAssertFalse(d.accept("A", at: 15.25))
    }

    /// §14 S14-1：一直对着同一个码不动只算一次；拿开 1.5 秒再对上才算第二次
    func testDeduperWindowCountsFromTheLastSighting() {
        var d = CameraDeduper()
        var accepted: [TimeInterval] = []
        for i in 0...30 {   // 每 0.1 秒认出一次，连续 3 秒
            let t = 10 + Double(i) * 0.1
            if d.accept("A", at: t) { accepted.append(t) }
        }
        XCTAssertEqual(accepted, [10], "对着同一罐不动 3 秒只算 1 罐")
        XCTAssertFalse(d.accept("A", at: 14.25), "拿开 1.25 秒又对上：还是同一次")
        XCTAssertTrue(d.accept("A", at: 15.75), "拿开 1.5 秒再对上：第二次")
    }

    /// §14 S14-1：A、B、A 交替（或同在画面里）各算一次，不来回刷
    func testDeduperKeepsATimerPerCode() {
        var d = CameraDeduper()
        XCTAssertTrue(d.accept("A", at: 10))
        XCTAssertTrue(d.accept("B", at: 10.125), "别的码立刻算")
        XCTAssertFalse(d.accept("A", at: 10.25), "B 不打断 A 的计时")
        XCTAssertFalse(d.accept("B", at: 10.375))
        XCTAssertTrue(d.accept("C", at: 10.5))
        XCTAssertFalse(d.accept("A", at: 11.5), "A 上次看见是 10.25")
        XCTAssertTrue(d.accept("B", at: 11.875), "B 上次看见是 10.375，满 1.5 秒")
    }

    /// 两个码同框：相机每帧都交来 A、B，连续 2 秒只各算一次
    func testDeduperTwoCodesInTheSameFrameCountOnceEach() {
        var d = CameraDeduper()
        var accepted: [String] = []
        for i in 0..<20 {
            let t = 10 + Double(i) * 0.1
            for code in ["6921168509256", "16921168509253"] where d.accept(code, at: t) { accepted.append(code) }
        }
        XCTAssertEqual(accepted, ["6921168509256", "16921168509253"])
    }

    /// 记录只留最近 1.5 秒内见过的码
    func testDeduperForgetsCodesNotSeenFor1_5Seconds() {
        var d = CameraDeduper()
        for (i, code) in ["A", "B", "C"].enumerated() { _ = d.accept(code, at: 10 + Double(i) * 0.25) }
        XCTAssertEqual(d.trackedCount, 3)
        _ = d.accept("D", at: 11.75)   // A（10.0）、B（10.25）满 1.5 秒，C（10.5）还没满
        XCTAssertEqual(d.trackedCount, 2)
        _ = d.accept("D", at: 20)
        XCTAssertEqual(d.trackedCount, 1)
    }

    func testDeduperResetAndClockGoingBackwards() {
        var d = CameraDeduper()
        XCTAssertTrue(d.accept("A", at: 10))
        d.reset()
        XCTAssertEqual(d.trackedCount, 0)
        XCTAssertTrue(d.accept("A", at: 10.1))
        XCTAssertTrue(d.accept("A", at: 5), "时间倒流不当作 1.5 秒内")
    }

    // MARK: 汇合点

    func testCameraSameCodeWithin1_5sIsIgnoredByTheHub() {
        let hub = makeHub()
        XCTAssertEqual(hub.receive("6921168509256", from: .camera), .known)
        now += 0.5
        XCTAssertNil(hub.receive("6921168509256", from: .camera))
        now += 1.25
        XCTAssertNil(hub.receive("6921168509256", from: .camera), "距上次看见 1.25 秒（距接受已 1.75 秒）")
        now += 1.5   // 距上次看见满 1.5 秒
        XCTAssertEqual(hub.receive("6921168509256", from: .camera), .known)
        XCTAssertEqual(scans.count, 2)
        XCTAssertEqual(recorder.played, [.known, .known], "被忽略的那次不出声")
    }

    func testCameraAlternatingCodesCountOnceEachInTheHub() {
        let hub = makeHub(known: ["6921168509256", "6901028075831"])
        for _ in 0..<10 {
            hub.receive("6921168509256", from: .camera)
            hub.receive("6901028075831", from: .camera)
            now += 0.1
        }
        XCTAssertEqual(scans.map(\.code), ["6921168509256", "6901028075831"])
        XCTAssertEqual(recorder.played, [.known, .known])
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
        XCTAssertNil(hub.receive("6921168509256", from: .camera), "相机仍按自己上次看见的时间去重")
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
