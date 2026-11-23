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
        now += 1.5   // 距上次看见满 1.5 秒：没记过的码够了，记过的码要 2.5 秒（防漏帧）
        XCTAssertNil(hub.receive("6921168509256", from: .camera))
        now += ScanHub.recordedWindow
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

    /// 空码、全是空白的码不收；带首尾空白的码整串不收、不裁剪（§14 S14-5，见下面的字符集测试）
    func testBlankCodesAreDroppedAndCodesAreNotTrimmed() {
        let hub = makeHub()
        XCTAssertNil(hub.receive("", from: .manual))
        XCTAssertNil(hub.receive("   ", from: .manual))
        XCTAssertNil(hub.receive(" 6921168509256\n", from: .manual))
        XCTAssertEqual(hub.receive("6921168509256", from: .manual), .known)
        XCTAssertEqual(scans.map(\.code), ["6921168509256"])
        XCTAssertEqual(recorder.played, [.known])
    }

    // MARK: 字符集（§14 S14-5 ⑭）：三个入口同一个规则

    func testCodesWithOtherCharactersAreRejectedWholeOnEveryEntrance() {
        let hub = makeHub()
        for bad in ["ABC-6921168509256", "6921168509256#", "6921 168509256", "６９２１１６８５０９２５６", "69211685092é6"] {
            XCTAssertNil(hub.receive(bad, from: .camera), "相机：\(bad)")
            XCTAssertNil(hub.receive(bad, from: .manual), "手输：\(bad)")
            now += 2
        }
        gun(hub, "ABC-6921168509256")
        XCTAssertEqual(scans, [], "含其他字符的码整串不交给页面、不截断")
        XCTAssertEqual(recorder.played, [], "也不出声")
    }

    /// §14 S14-5：首尾带空格、Tab、换行的码也算「含其他字符」，整串不收——不先裁掉空白再校验
    /// （否则「 6901035600016\n」会被洗成合法码进篮、出声）
    func testLeadingOrTrailingWhitespaceIsRejectedNotTrimmed() {
        let hub = makeHub(known: ["6921168509256"])
        for bad in [" 6921168509256", "6921168509256 ", "\t6921168509256", "6921168509256\t", "6921168509256\n",
                    "\n6921168509256", "6921168509256\r\n", " 6921168509256\n", "\u{3000}6921168509256"] {
            XCTAssertNil(hub.receive(bad, from: .camera), "相机：\(bad.debugDescription)")
            XCTAssertNil(hub.receive(bad, from: .manual), "手输：\(bad.debugDescription)")
            now += 2
        }
        XCTAssertEqual(scans, [], "没有交给页面")
        XCTAssertEqual(recorder.played, [], "没有提示音")
        XCTAssertEqual(hub.receive("6921168509256", from: .camera), .known, "被挡掉的码不占相机去重的计时")
    }

    func testLettersAreKeptAsIsOnEveryEntrance() {
        let hub = makeHub(known: ["Ab12345678"])
        XCTAssertEqual(hub.receive("Ab12345678", from: .camera), .known)
        XCTAssertEqual(hub.receive("Ab12345678", from: .manual), .known)
        gun(hub, "Ab12345678")
        XCTAssertEqual(scans.map(\.code), ["Ab12345678", "Ab12345678", "Ab12345678"], "大小写原样，不折叠")
        XCTAssertEqual(scans.map(\.source), [.camera, .manual, .gun])
    }

    func testRejectedCameraCodeDoesNotStartTheDedupeTimer() {
        let hub = makeHub(known: ["6921168509256"])
        XCTAssertNil(hub.receive("6921168509256-", from: .camera))
        XCTAssertEqual(hub.receive("6921168509256", from: .camera), .known, "被挡掉的码不占去重的计时")
    }

    // MARK: PR #40 第三轮重写：有效时钟 + 资格 + 一次只认一件（相机整帧交来，`receiveFrame`）

    private let a = "6921168509256", b = "6901028075831"

    /// 相机每 0.1 秒交一帧（这一帧识别区里的所有码）
    private func frames(_ hub: ScanHub, _ codes: [String], seconds: Double) {
        for _ in 0..<Int((seconds * 10).rounded()) { hub.receiveFrame(codes); now += 0.1 }
    }

    /// 一帧里两个码：什么都不记、不用掉资格，提示「一次扫一件」（最多 2 秒一次）；挪开一个后剩下那个照常记
    func testTwoCodesInOneFrameRecordNothingAndAskForOneAtATime() {
        let hub = makeHub(known: [a, b])
        var notices = 0
        hub.onSeveralCodes = { notices += 1 }
        frames(hub, [a, b], seconds: 3)
        XCTAssertEqual(scans, [], "同框两码不记")
        XCTAssertEqual(recorder.played, [], "也不出声")
        XCTAssertEqual(notices, 2, "提示「一次扫一件」，2 秒一次")
        frames(hub, [b], seconds: 1)
        XCTAssertEqual(scans.map(\.code), [b], "A 挪开：B 一直有资格，记一次")
        XCTAssertEqual(scans.count, 1, "B 一直在画面里只记一次")
    }

    /// 同帧里不合规的码（带横杠的批号 Code128 等）不算一个码，不挡旁边的商品码
    func testUnacceptableCodeInTheFrameDoesNotCount() {
        let hub = makeHub(known: [a])
        frames(hub, ["LOT-2026-11", a], seconds: 0.5)
        XCTAssertEqual(scans.map(\.code), [a])
    }

    /// 记过的 B 留在画面里、A 进来同框 2 秒、A 再拿走：B 不重记（同框时 B 一直算「看见」）；A 从没单独出现过，也不记
    func testRecordedCodeStaysSeenWhileAnotherCodeSharesTheFrame() {
        let hub = makeHub(known: [a, b])
        frames(hub, [b], seconds: 1)
        frames(hub, [a, b], seconds: 2)
        frames(hub, [b], seconds: 2)
        XCTAssertEqual(scans.map(\.code), [b])
    }

    /// 恢复后 A、B 同框、帧里谁先谁后轮着变（以前「谁靠中心交谁」的问题）：两件都不重记
    func testAlternatingOrderInTheFrameAfterResumeRecordsNothingAgain() {
        let hub = makeHub(known: [a, b])
        frames(hub, [a], seconds: 1)
        frames(hub, [b], seconds: 1)   // A 挪开 1 秒、B 单独：记 B
        frames(hub, [a, b], seconds: 1)
        hub.cameraPaused()
        now += 300   // 停相机期间真实时间过去很久
        hub.cameraResumed()
        for i in 0..<40 { hub.receiveFrame(i % 20 < 10 ? [a, b] : [b, a]); now += 0.1 }
        XCTAssertEqual(scans.map(\.code), [a, b])
        frames(hub, [a], seconds: 1)
        frames(hub, [b], seconds: 1)
        XCTAssertEqual(scans.map(\.code), [a, b], "再单独露出来也不重记：一直在画面里")
    }

    /// 扫 A → 停相机（真实时间过去 10 分钟）→ 再开，首个回调晚 4 秒才到、A 还在：不重放；B 单独出现照记
    func testResumeAfterALongPauseAndALateFirstCallbackDoesNotReplay() {
        let hub = makeHub(known: [a, b])
        frames(hub, [a], seconds: 1)
        hub.cameraPaused()
        now += 600
        hub.cameraResumed()
        now += 4   // 首个识别回调晚到：这段有效时钟不走
        frames(hub, [a], seconds: 3)
        XCTAssertEqual(scans.map(\.code), [a], "A 不重放")
        frames(hub, [b], seconds: 1)
        XCTAssertEqual(scans.map(\.code), [a, b])
    }

    /// A 拿开满阈值（有效时钟；记过的码 2.5 秒）再对上记一次；中间停过相机的那段不算
    func testCodeAwayForAWindowOfEffectiveTimeCountsAgain() {
        let hub = makeHub(known: [a, b])
        frames(hub, [a], seconds: 1)
        frames(hub, [b], seconds: 1)    // A 拿开 1 秒（有效）
        hub.cameraPaused()
        now += 60
        hub.cameraResumed()
        frames(hub, [b], seconds: 0.3)  // 恢复后有效时钟再走 0.3 秒：A 共离开 1.3 秒
        frames(hub, [a], seconds: 0.5)
        XCTAssertEqual(scans.map(\.code), [a, b], "有效时钟没满 1.5 秒：A 不算新的一次")
        frames(hub, [b], seconds: 2.6)  // A 再拿开 2.6 秒（A 记过：阈值 2.5 秒）
        frames(hub, [a], seconds: 0.5)
        XCTAssertEqual(scans.map(\.code), [a, b, a], "拿开满阈值再对上：记一次")
    }

    /// 页面没收（进货商品卡在，`.ignored`）时出现的 B：卡片关掉（`inputResumed`）资格清空，B 还在画面里不自动收；
    /// 拿开 1.5 秒再对上才收（Fable 补洞 c）；已记的码在画面里不再弹
    func testInputResumedClearsEligibilityOfCodesStillInView() {
        let hub = ScanHub(feedback: recorder, clock: { [unowned self] in now })
        var holding = false
        var taken: [String] = []
        hub.handler = { scan in
            if holding { return .ignored }
            taken.append(scan.code)
            holding = true
            return .known
        }
        frames(hub, [a], seconds: 1)
        XCTAssertEqual(taken, [a])
        frames(hub, [b], seconds: 2)   // A 挪开、B 进来：卡片在，不收
        holding = false; hub.inputResumed()   // 确认 A
        frames(hub, [b], seconds: 2)
        XCTAssertEqual(taken, [a], "B 一直在画面里：不自动收")
        now += 1.6
        frames(hub, [b], seconds: 0.5)
        XCTAssertEqual(taken, [a, b], "拿开 1.5 秒再对上：收")
        holding = false; hub.inputResumed()
        frames(hub, [b], seconds: 3)
        XCTAssertEqual(taken, [a, b], "已记的 B 在画面里不再弹")
    }

    /// 过滤：EAN / UPC 校验位不对的丢掉；ITF-14、Code128 只在同帧没有 EAN / UPC 时算；同一码值算一个
    func testProductCodeFilter() {
        let ean = CameraCode("6901234500011", kind: .ean13), bad = CameraCode("6901234500012", kind: .ean13)
        let ean8 = CameraCode("96385074", kind: .ean8), upce = CameraCode("04252614", kind: .upce)
        let itf = CameraCode("16901234500018", kind: .itf14), lot = CameraCode("LOT1123", kind: .code128)
        XCTAssertEqual(ScanHub.productCodes(in: [ean, lot]), [ean.value], "批号不算")
        XCTAssertEqual(ScanHub.productCodes(in: [ean, ean]), [ean.value], "同码两个框算一个")
        XCTAssertEqual(ScanHub.productCodes(in: [bad]), [], "校验位不对丢掉")
        XCTAssertEqual(ScanHub.productCodes(in: [ean8]), [ean8.value])
        XCTAssertEqual(ScanHub.productCodes(in: [upce]), [upce.value])
        XCTAssertEqual(ScanHub.productCodes(in: [CameraCode("04252615", kind: .upce)]), [])
        XCTAssertEqual(ScanHub.productCodes(in: [itf]), [itf.value], "只有 ITF-14：算")
        XCTAssertEqual(ScanHub.productCodes(in: [itf, ean]), [ean.value], "有 EAN 时 ITF-14 不算")
        XCTAssertEqual(ScanHub.productCodes(in: [lot]), [lot.value], "只有 Code128：算")
        XCTAssertEqual(Set(ScanHub.productCodes(in: [ean, ean8])), [ean.value, ean8.value])
    }
}
