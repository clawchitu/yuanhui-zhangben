import Foundation
import ImageIO
import Network
import UIKit
import XCTest

/// S22d 界面验收（选商品图，Fable 方案 9 的用例 1、2、3、5、8、9）：家用夹具在卖出 / 进货页扫到没登记的码 → 04a 填价存好 →
/// 第三步选商品图。查码、候选、缩图、选图都打测试进程里的桩（`ShopStub`，`-uiImages` 给的地址）；全程真点。
/// 登记的 `product_upsert` 由 `-uiConfirmUpsert` 在放够几秒后按「服务器确认了」处理（走真的 `recordResults`）。
/// 要在 iPhone SE（第 3 代）和 iPhone 16 Pro 上各跑一遍；布局用例里默认字号、最大辅助字号都跑。
@MainActor
final class S22dUITests: XCTestCase {
    private var stub: ShopStub!
    /// 演示数据里没有的码
    static let code = "6920152400319"
    static let name = "鸭屎香柠檬茶 500ml"
    static let cids = ["0123456789abcdef", "1111111111111111", "2222222222222222", "3333333333333333", "4444444444444444", "5555555555555555"]
    static let maxAX = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        stub = try ShopStub.start()
    }

    override func tearDown() { stub?.stop() }

    private func el(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func wait(_ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line, _ ok: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("等不到：\(what)", file: file, line: line)
    }

    private func idle(_ s: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

    private func launch(route: String = "sell", role: String = "family", confirmAfter: Int? = 3, off: Bool = false,
                        scan: String = S22dUITests.code, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-uiFixture", "home", "-uiRole", role, "-uiLargeText", "on", "-uiProbe", "-uiFrameProbe", "-uiRoute", route,
                    "-uiScan", scan, "-uiImages", "http://localhost:\(stub.port)"]
        if let confirmAfter { args += ["-uiConfirmUpsert", String(confirmAfter)] }
        if off { args.append("-uiImagesOff") }
        app.launchArguments = args + extra
        app.launch()
        return app
    }

    /// 04a：等查码把名称填上，按数字键填卖价，点「存好」
    private func register(_ app: XCUIApplication, save: String = "newProduct.save") {
        let field = el(app, "newProduct.name")
        XCTAssertTrue(field.waitForExistence(timeout: 15), "进了 04a")
        wait("查码填上名称") { (field.value as? String) == Self.name }
        for c in "35" { app.buttons[String(c)].firstMatch.tap() }
        app.buttons[save].firstMatch.tap()
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = "\(app.windows.firstMatch.frame.height < 700 ? "se" : "16pro")-\(name)"
        a.lifetime = .keepAlways
        add(a)
    }

    private func readyLookup(_ ids: [String]) {
        stub.lookup = #"{"found":true,"name":"\#(Self.name)","has_image":\#(!ids.isEmpty),"image_candidates":{"state":"\#(ids.isEmpty ? "none" : "ready")","ids":[\#(ids.map { "\"\($0)\"" }.joined(separator: ","))]}}"#
    }

    // MARK: 验收

    /// A1：三张候选 → 第三步出选图页，默认选第一张；点第二张、「就用这张」→ 回卖出页；登记确认前一个 select 都不发（A6），
    /// 确认后发且只发一次，带的是第二张的 cid 和这个商品的条码；价签上马上显示这张图（本机预览）
    func testPickSecondCandidate() throws {
        readyLookup(Array(Self.cids.prefix(3)))
        let app = launch(confirmAfter: 6)
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10), "存好后进第三步选图")
        let savedAt = Date()
        wait("三张缩图都到了") { el(app, "imageChoice.option.2").exists }
        XCTAssertTrue(el(app, "imageChoice.option.0").isSelected, "默认选中第一张")
        XCTAssertFalse(el(app, "imageChoice.searching").exists, "ready：不显示「还在找图」")
        shot(app, "pick-three")
        el(app, "imageChoice.option.1").tap()
        XCTAssertTrue(el(app, "imageChoice.option.1").isSelected)
        app.buttons["imageChoice.use"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5), "回到卖出页")
        idle(1.5)
        XCTAssertEqual(stub.requests(method: "POST").count, 0, "登记还没确认：不发 select")
        wait("确认后发 select") { self.stub.requests(method: "POST").count == 1 }
        let sel = try XCTUnwrap(stub.requests(method: "POST").first)
        XCTAssertGreaterThan(sel.at.timeIntervalSince(savedAt), 4.5, "select 在登记确认之后才发")
        XCTAssertTrue(sel.path.hasPrefix("/v1/images/") && sel.path.hasSuffix("/select"), sel.path)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sel.body) as? [String: String])
        XCTAssertEqual(body, ["barcode": Self.code, "candidate_id": Self.cids[1]])
        XCTAssertEqual(sel.auth, "Bearer fixture-token")
        idle(1)
        XCTAssertEqual(stub.requests(method: "POST").count, 1, "成功后不再重发")
        XCTAssertGreaterThanOrEqual(probe(app)["shown"].flatMap(Int.init) ?? 0, 1, "价签上显示了选的图")
        shot(app, "after-pick")
    }

    /// A2：只有一张：不出选图页，直接用它（确认后 select 这张）
    func testSingleCandidateUsedWithoutAsking() throws {
        readyLookup([Self.cids[0]])
        let app = launch(confirmAfter: 2)
        // S22d-16：存好之前 04a 名称旁的方块里就是这张候选图（不然只有一张时人从头到尾看不到图）
        let thumb = el(app, "newProduct.thumb")
        XCTAssertTrue(thumb.waitForExistence(timeout: 15))
        wait("04a 方块显示候选图") { (thumb.value as? String) == "候选图" }
        register(app)
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 10), "直接回卖出页")
        XCTAssertFalse(el(app, "page.newProductImage").exists, "不问")
        wait("select 这张") { self.stub.requests(method: "POST").count == 1 }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stub.requests(method: "POST")[0].body) as? [String: String])
        XCTAssertEqual(body["candidate_id"], Self.cids[0])
    }

    /// A3：查码回 pending → 每秒问一次 /images，先 pending 后 ready 两张：第三步先「还在找图」再出两张
    func testPendingThenReady() {
        stub.lookup = #"{"found":true,"name":"\#(Self.name)","has_image":true,"image_candidates":{"state":"pending","ids":[]}}"#
        stub.states = [#"{"state":"pending","ids":[]}"#, #"{"state":"pending","ids":["\#(Self.cids[0])"]}"#,
                       #"{"state":"ready","ids":["\#(Self.cids[0])","\#(Self.cids[1])"]}"#]
        stub.stateDelayUntil = Date().addingTimeInterval(1000)   // 存好之前不放 ready：轮询停在 pending
        let app = launch()
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        XCTAssertTrue(el(app, "imageChoice.searching").exists, "还在 pending：显示「还在找图」")
        stub.stateDelayUntil = nil
        wait("两张都出来、不再找") { self.el(app, "imageChoice.option.1").exists && !self.el(app, "imageChoice.searching").exists }
        let polls = stub.requests(method: "GET").filter { $0.path.hasSuffix("/images") }
        XCTAssertGreaterThanOrEqual(polls.count, 2, "轮询过")
        for (a, b) in zip(polls, polls.dropFirst()) {
            XCTAssertGreaterThan(b.at.timeIntervalSince(a.at), 0.8, "大约每秒一次")
        }
        app.buttons["imageChoice.use"].tap()
        wait("select 第一张") { self.stub.requests(method: "POST").count == 1 }
    }

    /// S22d-16（真机 11/26 雪碧）：查码回 pending、1 秒后 /images 才 ready：04a 方块先是首字，候选到了就换成图，不用等存好
    func testPendingCandidateShownOn04a() {
        stub.lookup = #"{"found":true,"name":"\#(Self.name)","has_image":true,"image_candidates":{"state":"pending","ids":[]}}"#
        stub.states = [#"{"state":"ready","ids":["\#(Self.cids[0])","\#(Self.cids[1])"]}"#]
        let app = launch()
        let field = el(app, "newProduct.name"), thumb = el(app, "newProduct.thumb")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        wait("查码填上名称") { (field.value as? String) == Self.name }
        wait("候选到了，方块换成图", timeout: 8) { (thumb.value as? String) == "候选图" }
        shot(app, "04a-candidate-thumb")
        XCTAssertTrue(stub.requests(method: "POST").isEmpty, "存好之前不 select")
    }

    /// A3：一直 pending，8 秒到了也没有一张：不再问，转成「这个商品还没有图」提示拍照，一个 select 都不发；轮询不超过 8 秒
    func testPendingTimesOut() {
        stub.lookup = #"{"found":true,"name":"\#(Self.name)","has_image":true,"image_candidates":{"state":"pending","ids":[]}}"#
        stub.states = [#"{"state":"pending","ids":[]}"#]
        let app = launch()
        let start = Date()
        register(app)
        wait("8 秒后转成提示拍照", timeout: 20) { self.el(app, "imageChoice.prompt").exists && !self.el(app, "imageChoice.searching").exists }
        idle(3)
        let polls = stub.requests(method: "GET").filter { $0.path.hasSuffix("/images") }
        XCTAssertGreaterThan(polls.count, 3)
        XCTAssertLessThanOrEqual(polls.count, 10, "最多 8 秒、每秒一次")
        XCTAssertLessThan((polls.last?.at ?? start).timeIntervalSince(start), 15)
        XCTAssertEqual(stub.requests(method: "POST").count, 0)
    }

    /// A3：pending 时点「跳过」：回卖出页，之后一个 select 都不发（服务器兜底任务会落第一张）
    func testSkipWhilePending() {
        stub.lookup = #"{"found":true,"name":"\#(Self.name)","has_image":true,"image_candidates":{"state":"pending","ids":["\#(Self.cids[0])"]}}"#
        stub.states = [#"{"state":"pending","ids":["\#(Self.cids[0])"]}"#]
        let app = launch(confirmAfter: 1)
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        app.buttons["imageChoice.skip"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        idle(10)
        XCTAssertEqual(stub.requests(method: "POST").count, 0, "跳过：不发 select")
    }

    /// S22d-7：第三步点返回键等于「跳过」：回卖出页，刚登记的这一件已在单子上（价签显示它），不发 select、不回 04a
    func testBackOnImageStepSkips() {
        readyLookup(Array(Self.cids.prefix(2)))
        let app = launch(confirmAfter: 1)
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        wait("缩图到了") { el(app, "imageChoice.option.1").exists }
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5), "回卖出页，不回 04a")
        XCTAssertFalse(el(app, "page.newProduct").exists)
        XCTAssertTrue(el(app, "sell.tag").waitForExistence(timeout: 5), "这一件放进了单子")
        XCTAssertTrue(el(app, "sell.tag").label.contains(Self.name) || app.staticTexts[Self.name].exists, "价签是刚登记的商品")
        idle(4)
        XCTAssertEqual(stub.requests(method: "POST").count, 0, "返回 = 跳过：不发 select")
    }

    /// A6：登记一直没被确认（没有 `-uiConfirmUpsert`）：选了图也一个 select 都不发
    func testNoSelectBeforeUpsertConfirmed() {
        readyLookup(Array(Self.cids.prefix(2)))
        let app = launch(confirmAfter: nil)
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        wait("缩图到了") { el(app, "imageChoice.option.1").exists }
        app.buttons["imageChoice.use"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        idle(6)
        XCTAssertEqual(stub.requests(method: "POST").count, 0, "登记没确认：不发")
        XCTAssertGreaterThanOrEqual(probe(app)["shown"].flatMap(Int.init) ?? 0, 1, "本机预览照样显示")
    }

    /// 进货页同样有第三步（04a → 04b 存好 → 选图），选完回进货页
    func testStockInRegistrationAlsoPicks() {
        readyLookup(Array(Self.cids.prefix(2)))
        let app = launch(route: "stockIn", confirmAfter: 2)
        let field = el(app, "newProduct.name")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        wait("查码填上名称") { (field.value as? String) == Self.name }
        for c in "35" { app.buttons[String(c)].firstMatch.tap() }
        app.buttons["newProduct.more"].firstMatch.tap()
        XCTAssertTrue(el(app, "page.newProduct2").waitForExistence(timeout: 5))
        app.buttons["newProduct.saveMore"].tap()
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        wait("缩图到了") { el(app, "imageChoice.option.1").exists }
        el(app, "imageChoice.option.1").tap()
        app.buttons["imageChoice.use"].tap()
        XCTAssertTrue(el(app, "page.stockIn").waitForExistence(timeout: 5))
        wait("select 第二张") { self.stub.requests(method: "POST").count == 1 }
        let body = (try? JSONSerialization.jsonObject(with: stub.requests(method: "POST")[0].body)) as? [String: String]
        XCTAssertEqual(body?["candidate_id"], Self.cids[1])
    }

    /// A9：收银员（04c）、开关关：没有第三步，不问候选、不下缩图、不发 select
    func testNoPickerForCashierOrSwitchOff() {
        readyLookup(Array(Self.cids.prefix(3)))
        for (role, off) in [("cashier", false), ("family", true)] {
            let app = launch(role: role, confirmAfter: 1, off: off)
            let thumb = el(app, "newProduct.thumb")
            XCTAssertTrue(thumb.waitForExistence(timeout: 15))
            XCTAssertEqual(thumb.value as? String, "首字", "\(role) off=\(off) 04a 不显示候选图")
            register(app)
            XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 10), "\(role) off=\(off) 直接回卖出页")
            XCTAssertFalse(el(app, "page.newProductImage").exists)
            idle(3)
            let image = stub.requests(method: "GET").filter { $0.path.hasPrefix("/v1/barcode-lookup/") && $0.path.contains("/images") }
            XCTAssertEqual(image.count, 0, "\(role) off=\(off) 不问候选、不下缩图：\(image.map(\.path))")
            XCTAssertEqual(stub.requests(method: "POST").count, 0)
            app.terminate()
        }
    }

    /// A10：六张候选，默认字号和最大辅助字号下：标题、「就用这张」「跳过」都在屏幕内点得到，按钮不低于 44pt；滚到底能点到第六张
    func testLayoutSixCandidates() {
        readyLookup(Self.cids)
        for ax in [false, true] {
            let app = launch(confirmAfter: nil, extra: ["-uiFakeCamera"] + (ax ? Self.maxAX : []))
            register(app)
            XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
            wait("六张都到了") { el(app, "imageChoice.option.0").exists && self.stub.candidateFetches.count >= 6 }
            let window = app.windows.firstMatch.frame
            for id in ["imageChoice.use", "imageChoice.skip", "photo.camera", "photo.album"] {
                let b = el(app, id)
                XCTAssertTrue(b.isHittable, "ax=\(ax) \(id) 点得到")
                XCTAssertTrue(window.contains(b.frame), "ax=\(ax) \(id) 在屏幕内 \(b.frame)")
                XCTAssertGreaterThanOrEqual(b.frame.height, 44, "ax=\(ax) \(id) 不低于 44pt")
            }
            XCTAssertTrue(el(app, "imageChoice.title").isHittable || el(app, "imageChoice.title").exists)
            XCTAssertTrue(el(app, "imageChoice.option.0").isHittable, "ax=\(ax) 第一张在首屏")
            shot(app, "six-\(ax ? "axmax" : "standard")")
            let last = el(app, "imageChoice.option.5")
            el(app, "imageChoice.scroll").swipeUp()
            el(app, "imageChoice.scroll").swipeUp()
            XCTAssertTrue(last.isHittable, "ax=\(ax) 滚下去第六张点得到")
            last.tap()
            XCTAssertTrue(last.isSelected)
            app.buttons["imageChoice.use"].tap()
            XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    // MARK: 拍照、相册（S22d ②）

    /// 上传件合不合规格：JPEG、≤ 400 KB、长边 ≤ 1024、方向烘进像素（没有 EXIF 方向）。返回像素宽高
    private func checkUpload(_ body: Data, file: StaticString = #filePath, line: UInt = #line) -> CGSize {
        XCTAssertTrue(body.count > 3 && body[0] == 0xFF && body[1] == 0xD8, "是 JPEG", file: file, line: line)
        XCTAssertLessThanOrEqual(body.count, 400 * 1024, "不超过 400 KB（\(body.count)）", file: file, line: line)
        guard let src = CGImageSourceCreateWithData(body as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { XCTFail("解不开", file: file, line: line); return .zero }
        let w = (props[kCGImagePropertyPixelWidth] as? Int) ?? 0, h = (props[kCGImagePropertyPixelHeight] as? Int) ?? 0
        XCTAssertLessThanOrEqual(max(w, h), 1024, "长边 ≤ 1024（\(w)×\(h)）", file: file, line: line)
        XCTAssertGreaterThan(min(w, h), 0)
        XCTAssertEqual((props[kCGImagePropertyOrientation] as? Int) ?? 1, 1, "方向已烘进像素", file: file, line: line)
        XCTAssertNil(props[kCGImagePropertyGPSDictionary], "不带 GPS", file: file, line: line)
        return CGSize(width: w, height: h)
    }

    private func shoot(_ app: XCUIApplication) {
        let camera = app.buttons["photo.camera"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5), "有「拍一张」")
        XCTAssertTrue(camera.isHittable)
        camera.tap()
        let shutter = app.buttons["fakeCamera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5), "打开相机")
        shutter.tap()
    }

    /// A4 / A5：没有候选 → 第三步提示「这个商品还没有图」→ 拍一张（假相机，真点快门）→ 回卖出页；登记确认后 PUT 一次，
    /// 上传件是竖着拍的 4032×3024 压出来的 768×1024 JPEG、≤ 400 KB；不发 select
    func testNoCandidatesPromptsAndUploadsPhoto() throws {
        readyLookup([])
        let app = launch(confirmAfter: 2, extra: ["-uiFakeCamera"])
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10), "没图也进第三步")
        XCTAssertEqual(el(app, "imageChoice.title").label, "这个商品还没有图")
        XCTAssertFalse(el(app, "imageChoice.use").exists, "没有「就用这张」")
        shot(app, "prompt-photo")
        shoot(app)
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 15), "拍完回卖出页")
        wait("PUT 上传") { self.stub.requests(method: "PUT").count == 1 }
        let put = try XCTUnwrap(stub.requests(method: "PUT").first)
        XCTAssertTrue(put.path.hasPrefix("/v1/images/") && put.path.split(separator: "/").count == 3, put.path)
        XCTAssertEqual(put.auth, "Bearer fixture-token")
        XCTAssertEqual(checkUpload(put.body), CGSize(width: 768, height: 1024), "竖拍：方向转正、长边 1024")
        idle(1)
        XCTAssertEqual(stub.requests(method: "PUT").count, 1)
        XCTAssertEqual(stub.requests(method: "POST").count, 0)
        XCTAssertGreaterThanOrEqual(probe(app)["shown"].flatMap(Int.init) ?? 0, 1, "价签上显示拍的图")
    }

    /// 相机权限被拒：点「拍一张」不弹相机，提示「相机没打开」，可以去设置或先从相册选；不上传
    func testCameraDeniedShowsHint() {
        readyLookup([])
        let app = launch(confirmAfter: 1, extra: ["-uiFakeCamera", "-uiCamera", "denied"])
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        app.buttons["photo.camera"].tap()
        XCTAssertTrue(app.alerts["相机没打开"].waitForExistence(timeout: 5), "提示去设置打开")
        XCTAssertFalse(app.buttons["fakeCamera.shutter"].exists, "不弹相机")
        XCTAssertTrue(app.alerts.buttons["去设置打开"].exists)
        shot(app, "camera-denied")
        app.alerts.buttons["先从相册选"].tap()
        XCTAssertTrue(app.buttons["photo.album"].firstMatch.isHittable, "相册照样能点")
        idle(2)
        XCTAssertEqual(stub.requests(method: "PUT").count, 0)
    }

    /// A4：没有候选时点「跳过」：零请求
    func testNoCandidatesSkip() {
        readyLookup([])
        let app = launch(confirmAfter: 1, extra: ["-uiFakeCamera"])
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        app.buttons["imageChoice.skip"].tap()
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 5))
        idle(3)
        XCTAssertEqual(stub.requests(method: "PUT").count + stub.requests(method: "POST").count, 0)
    }

    /// 选图页上也能不选、改拍一张：只 PUT，不 select
    func testShootInsteadOfPicking() {
        readyLookup(Array(Self.cids.prefix(2)))
        let app = launch(confirmAfter: 1, extra: ["-uiFakeCamera"])
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        wait("缩图到了") { el(app, "imageChoice.option.1").exists }
        shoot(app)
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 15))
        wait("PUT 上传") { self.stub.requests(method: "PUT").count == 1 }
        idle(1)
        XCTAssertEqual(stub.requests(method: "POST").count, 0, "改拍了：不 select")
    }

    /// 从相册选（系统相册选择器，真点模拟器自带的照片）→ 压好上传
    func testAlbumPickUploads() throws {
        readyLookup([])
        let app = launch(confirmAfter: 1)
        register(app)
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
        app.buttons["photo.album"].firstMatch.tap()
        // 选择器顶上有「Private Access to Photos」横幅（带一个照片图标），要点的是下面网格里的照片：找第一张宽于 80pt 的图
        XCTAssertTrue(app.scrollViews.images.firstMatch.waitForExistence(timeout: 15), "相册选择器出来了")
        var photo: XCUIElement?
        wait("网格里的照片") {
            photo = app.scrollViews.images.allElementsBoundByIndex.first { $0.frame.width > 80 && $0.isHittable }
            return photo != nil
        }
        shot(app, "album-picker")
        try XCTUnwrap(photo).tap()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot(app, "album-after-tap")
        XCTAssertTrue(el(app, "page.sell").waitForExistence(timeout: 20), "选完回卖出页")
        wait("PUT 上传", timeout: 20) { self.stub.requests(method: "PUT").count == 1 }
        _ = checkUpload(try XCTUnwrap(stub.requests(method: "PUT").first).body)
    }

    /// 离线查不到候选（没网）：同样提示拍照
    func testOfflinePromptsPhoto() {
        let app = launch(confirmAfter: nil, extra: ["-uiFakeCamera", "-uiOffline"])
        let field = el(app, "newProduct.name")
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        for c in "35" { app.buttons[String(c)].firstMatch.tap() }
        app.buttons["newProduct.save"].firstMatch.tap()
        XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10), "没网也提示拍照")
        XCTAssertEqual(el(app, "imageChoice.title").label, "这个商品还没有图")
        XCTAssertEqual(stub.requests(method: "GET").filter { $0.path.contains("/images") }.count, 0, "没网：不问候选")
    }

    /// A8：进货页商品卡点商品图 → 换商品图：候选里选第二张 → 马上 select（已有商品，不用等登记）；再点一次改拍一张 → PUT
    func testStockInCardReplacesImage() throws {
        readyLookup(Array(Self.cids.prefix(2)))
        let app = launch(route: "stockIn", confirmAfter: nil, scan: "6921168509256", extra: ["-uiFakeCamera"])
        let image = el(app, "stockIn.image")
        XCTAssertTrue(image.waitForExistence(timeout: 15), "商品卡上的商品图能点")
        image.tap()
        XCTAssertTrue(el(app, "page.replaceImage").waitForExistence(timeout: 5))
        wait("两张候选") { el(app, "imageChoice.option.1").exists }
        shot(app, "replace-sheet")
        el(app, "imageChoice.option.1").tap()
        app.buttons["imageChoice.use"].tap()
        wait("select") { self.stub.requests(method: "POST").count == 1 }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: stub.requests(method: "POST")[0].body) as? [String: String])
        XCTAssertEqual(body, ["barcode": "6921168509256", "candidate_id": Self.cids[1]])
        XCTAssertTrue(image.waitForExistence(timeout: 5))
        image.tap()
        XCTAssertTrue(el(app, "page.replaceImage").waitForExistence(timeout: 5))
        shoot(app)
        wait("PUT") { self.stub.requests(method: "PUT").count == 1 }
        XCTAssertTrue(el(app, "stockIn.image").waitForExistence(timeout: 5), "回到商品卡")
    }

    /// 换图页开着时扫码枪来的码不换掉商品卡；关掉以后扫码枪接着能用，新扫的商品照常记上进货（自审必须修 1：换图入口加进了进货页的扫码闸门）
    func testStockInScanPausedWhileReplacingThenResumes() {
        readyLookup(Array(Self.cids.prefix(2)))
        // 农夫山泉 → 6 秒后二锅头（换图页开着）→ 12 秒后康师傅红烧牛肉面（换图页已关）。扫码枪速度逐键打进
        let app = launch(route: "stockIn", confirmAfter: nil, scan: "6921168509256,6901234500011,6902514300011",
                         extra: ["-uiFakeCamera", "-uiScanGap", "6"])
        let name = el(app, "stockIn.name")
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        let first = name.label
        el(app, "stockIn.image").tap()
        XCTAssertTrue(el(app, "page.replaceImage").waitForExistence(timeout: 5))
        idle(7)
        XCTAssertTrue(el(app, "page.replaceImage").exists, "换图页还开着")
        app.buttons["imageChoice.skip"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.label, first, "换图页开着时扫到的码没有换掉商品卡")
        wait("关掉以后扫码枪接着能用", timeout: 15) { name.exists && name.label.contains("牛肉面") }
        el(app, "stockIn.qty").tap()
        for c in "2" { app.buttons[String(c)].firstMatch.tap() }
        el(app, "stockIn.cost").tap()
        for c in "3" { app.buttons[String(c)].firstMatch.tap() }
        el(app, "stockIn.commit").tap()
        wait("记上一笔进货") { self.ledgerProbe(app)["stockIns"] == "1" }
        XCTAssertEqual(stub.requests(method: "POST").count + stub.requests(method: "PUT").count, 0, "换图页点了关掉：不发")
    }

    private func ledgerProbe(_ app: XCUIApplication) -> [String: String] {
        var out: [String: String] = [:]
        for part in el(app, "debug.ledger").label.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }

    /// A9：收银员进货页没有（收银员进不了进货）；开关关时商品卡上的图不能点
    func testStockInCardNoEntryWhenOff() {
        let app = launch(route: "stockIn", confirmAfter: nil, off: true, scan: "6921168509256")
        XCTAssertTrue(el(app, "stockIn.name").waitForExistence(timeout: 15))
        XCTAssertFalse(el(app, "stockIn.image").exists)
    }

    /// A10：没图提示页在默认字号和最大辅助字号下，拍一张 / 从相册选 / 跳过都在屏幕内点得到
    func testPromptLayout() {
        readyLookup([])
        for ax in [false, true] {
            let app = launch(confirmAfter: nil, extra: ["-uiFakeCamera"] + (ax ? Self.maxAX : []))
            register(app)
            XCTAssertTrue(el(app, "page.newProductImage").waitForExistence(timeout: 10))
            let window = app.windows.firstMatch.frame
            for id in ["photo.camera", "photo.album", "imageChoice.skip"] {
                let b = el(app, id)
                XCTAssertTrue(b.isHittable, "ax=\(ax) \(id) 点得到")
                XCTAssertTrue(window.contains(b.frame), "ax=\(ax) \(id) 在屏幕内 \(b.frame)")
                XCTAssertGreaterThanOrEqual(b.frame.height, 44, "ax=\(ax) \(id) 不低于 44pt")
            }
            shot(app, "prompt-\(ax ? "axmax" : "standard")")
            app.terminate()
        }
    }

    private func probe(_ app: XCUIApplication) -> [String: String] {
        var out: [String: String] = [:]
        for part in el(app, "debug.images").label.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { out[kv[0]] = kv[1] }
        }
        return out
    }
}

/// 自家服务器的桩（S22d）：查码、候选现状（可编排 pending → ready）、候选缩图、选图、商品图。一个连接一个请求，读完请求体。
final class ShopStub: @unchecked Sendable {
    struct Request { let method: String; let path: String; let body: Data; let auth: String; let at: Date }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "s22d-shop-stub")
    private let lock = NSLock()
    private var log: [Request] = []
    private var lookupValue = #"{"found":false}"#
    private var statesValue: [String] = []
    private var stateIndex = 0
    private var holdUntil: Date?
    private var selectStatus = 200
    private var vers: [String: Int] = [:]

    private init() throws { listener = try NWListener(using: .tcp, on: .any) }

    static func start() throws -> ShopStub {
        let s = try ShopStub()
        let ready = DispatchSemaphore(value: 0)
        s.listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        s.listener.newConnectionHandler = { [weak s] c in s?.accept(c) }
        s.listener.start(queue: s.queue)
        guard ready.wait(timeout: .now() + 5) == .success else { throw NSError(domain: "ShopStub", code: 1) }
        return s
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }
    func stop() { listener.cancel() }
    /// 查码的响应体
    var lookup: String { get { lock.withLock { lookupValue } } set { lock.withLock { lookupValue = newValue } } }
    /// `/images` 依次回这些（用完了一直回最后一个）；没设就按查码里的候选回
    var states: [String] { get { lock.withLock { statesValue } } set { lock.withLock { statesValue = newValue; stateIndex = 0 } } }
    /// 到这个时刻之前 `/images` 停在第一个
    var stateDelayUntil: Date? { get { lock.withLock { holdUntil } } set { lock.withLock { holdUntil = newValue } } }
    var selectReply: Int { get { lock.withLock { selectStatus } } set { lock.withLock { selectStatus = newValue } } }
    var requests: [Request] { lock.withLock { log } }
    func requests(method: String) -> [Request] { requests.filter { $0.method == method } }
    /// 下过的候选缩图（`/v1/barcode-lookup/码/images/cid`）
    var candidateFetches: [Request] { requests(method: "GET").filter { $0.path.split(separator: "/").count == 5 && $0.path.hasPrefix("/v1/barcode-lookup/") } }

    /// 每个 cid 一种颜色的 200px JPEG
    static func jpeg(_ seed: String) -> Data {
        let h = CGFloat(abs(seed.hashValue % 360)) / 360
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 200), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { c in
            UIColor(hue: h, saturation: 0.7, brightness: 0.9, alpha: 1).setFill(); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
            UIColor.white.setFill(); c.fill(CGRect(x: 60, y: 60, width: 80, height: 80))
        }.jpegData(compressionQuality: 0.8)!
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, Data())
    }

    private func receive(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = buf
            if let data { b.append(data) }
            if let end = b.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: b[..<end.lowerBound], as: UTF8.self)
                let lines = head.components(separatedBy: "\r\n")
                func header(_ n: String) -> String {
                    lines.dropFirst().first { $0.lowercased().hasPrefix(n + ":") }.map { String($0.dropFirst(n.count + 1)).trimmingCharacters(in: .whitespaces) } ?? ""
                }
                let length = Int(header("content-length")) ?? 0
                let body = b[end.upperBound...]
                if body.count >= length {
                    self.respond(c, lines, auth: header("authorization"), body: Data(body.prefix(length)))
                    return
                }
            }
            if done || err != nil { c.cancel() } else { self.receive(c, b) }
        }
    }

    private func respond(_ c: NWConnection, _ lines: [String], auth: String, body: Data) {
        let first = lines.first?.split(separator: " ") ?? []
        let method = first.first.map(String.init) ?? ""
        let target = first.dropFirst().first.map(String.init) ?? ""
        let path = String(target.split(separator: "?").first ?? "")
        lock.withLock { log.append(Request(method: method, path: path, body: body, auth: auth, at: Date())) }
        let parts = path.split(separator: "/").map(String.init)   // v1, barcode-lookup, code, images, cid
        var status = 200, type = "application/json", out = Data("{}".utf8)
        switch (method, parts.count) {
        case ("GET", 3) where parts[1] == "barcode-lookup":
            out = Data(lookup.utf8)
        case ("GET", 4) where parts[1] == "barcode-lookup" && parts[3] == "images":
            out = Data(nextState().utf8)
        case ("GET", 5) where parts[1] == "barcode-lookup" && parts[3] == "images":
            type = "image/jpeg"; out = Self.jpeg(parts[4])
        case ("POST", 4) where parts[1] == "images" && parts[3] == "select":
            status = selectReply
            let v = lock.withLock { () -> Int in vers[parts[2], default: 0] += 1; return vers[parts[2]]! }
            out = Data(status == 200 ? #"{"image_ver":\#(v)}"#.utf8 : #"{"code":"not_found"}"#.utf8)
        case ("PUT", 3) where parts[1] == "images":
            let v = lock.withLock { () -> Int in vers[parts[2], default: 0] += 1; return vers[parts[2]]! }
            out = Data(#"{"image_ver":\#(v)}"#.utf8)
        case ("GET", 3) where parts[1] == "images":
            type = "image/jpeg"; out = Self.jpeg(parts[2])
        default:
            status = 404; out = Data(#"{"code":"not_found"}"#.utf8)
        }
        let h = "HTTP/1.1 \(status) X\r\nContent-Type: \(type)\r\nContent-Length: \(out.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(h.utf8) + out, completion: .contentProcessed { _ in c.cancel() })
    }

    private func nextState() -> String {
        lock.withLock {
            if statesValue.isEmpty {
                // 没编排：按查码里的候选回
                if let d = lookupValue.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let ic = o["image_candidates"], let j = try? JSONSerialization.data(withJSONObject: ic) {
                    return String(decoding: j, as: UTF8.self)
                }
                return #"{"state":"none","ids":[]}"#
            }
            if let h = holdUntil, Date() < h { return statesValue[0] }
            let s = statesValue[min(stateIndex, statesValue.count - 1)]
            stateIndex += 1
            return s
        }
    }
}
