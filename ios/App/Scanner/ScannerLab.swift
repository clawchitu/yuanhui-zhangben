#if DEBUG
import ShopCore
import SwiftUI

/// Debug 的扫码测试页（`-uiFixture scanner` / `scanner-login`）：把扫码层的各件东西摆在一起，
/// 给 XCUITest 和截图用。正式页面（卖出 S16、扫码登录 S21）各自接 `ScanHub`，不用这一页。
///
/// - `scanner`：27a 的样子（卖出页顶上的相机条）；被拒时是 `NoCameraBand`，否则是取景框
/// - `scanner-login`：27b 的样子（黑底，扫码登录页的取景框位置）；被拒时是 `NoCameraCard`
/// 下面列出收到的每一次扫码（码 / 从哪儿来 / 登记过没有），`scanner.log` 里是同样内容的一行文字给测试读。
struct ScannerLab: View {
    let login: Bool
    @State private var permission: CameraPermission
    @State private var gun = ScannerGunMonitor()
    @State private var hub = ScanHub(feedback: ScanFeedback.shared)
    @State private var log: [(scan: Scan, outcome: ScanOutcome)] = []
    @State private var manualOpen = false
    @State private var manualText = ""
    @Environment(\.scenePhase) private var scenePhase
    private let fake: FakeScanner?
    private let known: Set<String>

    init(login: Bool, args: [String]) {
        self.login = login
        _permission = State(initialValue: CameraPermission(forced: CameraPermission.forcedAccess(from: args)))
        fake = FakeScanner.from(args)
        known = Set(((try? DemoSeed.baseline(includePrivate: false))?.barcodes ?? []).map(\.barcode))
    }

    private var dark: Bool { login }

    var body: some View {
        VStack(spacing: 0) {
            header
            if login { loginCamera } else { sellCamera }
            logList
        }
        .background((dark ? Tokens.Palette.ink : Tokens.Palette.paper).ignoresSafeArea())
        .scannerInput(hub, active: !manualOpen)
        .onAppear { hub.handler = handle }
        .task {
            if let fake { await fake.run(into: hub) }
        }
        // 被拒时页面上没有取景框，回前台读权限要页面自己做（有取景框时 CameraController 也会读，重复无害）
        .onChange(of: scenePhase) { _, phase in if phase == .active { permission.refresh() } }
        .alert("手输条码", isPresented: $manualOpen) {
            TextField("条码", text: $manualText).keyboardType(.numberPad).accessibilityIdentifier("scanner.manualField")
            Button("加入") {
                hub.receive(manualText, from: .manual)
                manualText = ""
            }
            Button("不输了", role: .cancel) { manualText = "" }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.scannerLab")
    }

    private func handle(_ scan: Scan) -> ScanOutcome {
        let outcome: ScanOutcome = known.contains(scan.code) ? .known : .unknown
        log.append((scan, outcome))
        return outcome
    }

    private var header: some View {
        ZStack {
            Text(login ? "扫码登录" : "卖出").font(.system(size: 22, weight: .bold))
            HStack {
                Image(systemName: "chevron.left").font(.system(size: 22, weight: .semibold))
                Spacer()
                Text("扫码测试").font(.system(size: 15))
            }
        }
        .foregroundStyle(Tokens.Palette.card)
        .padding(.horizontal, 20)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .background((login ? Tokens.Palette.ink : Tokens.Palette.sell).ignoresSafeArea(edges: .top))
    }

    @ViewBuilder private var sellCamera: some View {
        if permission.access == .denied {
            NoCameraBand(onManual: { manualOpen = true })
        } else {
            HStack(spacing: 12) {
                CameraViewfinder(hub: hub, permission: permission, hasCamera: permission.forced == nil && CameraSession.hasCamera,
                                 paused: manualOpen)
                Button { manualOpen = true } label: {
                    Label("手输条码", systemImage: "keyboard").font(.system(size: 17, weight: .medium))
                }
                .foregroundStyle(Tokens.Palette.card)
                .accessibilityIdentifier("scanner.manual")
            }
            .padding(12)
            .frame(height: 112)
            .background(NoCameraBand.background)
        }
    }

    @ViewBuilder private var loginCamera: some View {
        Group {
            if permission.access == .denied {
                NoCameraCard()
            } else {
                CameraViewfinder(hub: hub, permission: permission, includeQR: true,
                                 hasCamera: permission.forced == nil && CameraSession.hasCamera, paused: manualOpen)
                    .frame(height: 300)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 50)
    }

    private var logList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("扫码枪：\(gun.connected ? "已连上" : "没连")　相机：\(permission.access.rawValue)")
                .font(TypeScale.secondary)
                .accessibilityIdentifier("scanner.status")
            ForEach(Array(log.enumerated()), id: \.offset) { _, item in
                Text("\(item.scan.code)　\(item.scan.source.label)　\(item.outcome == .known ? "登记过" : "没登记")")
                    .font(TypeScale.body)
            }
            Text(log.map { "\($0.scan.code)/\($0.scan.source.rawValue)/\($0.outcome == .known ? "known" : "unknown")" }
                    .joined(separator: "|"))
                .font(.system(size: 1))
                .opacity(0.01)
                .accessibilityIdentifier("scanner.log")
            Spacer(minLength: 0)
        }
        .foregroundStyle(dark ? Tokens.Palette.card : Tokens.Palette.ink)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
#endif
