import Foundation

#if DEBUG
/// 测试和截图用的假扫码器：由启动参数喂码。**只编译进 Debug**（§14 S15-7：调试参数只进 Debug），
/// Beta / Release 构建里这个类型和这些参数都不存在。
///
/// 启动参数：
///   -uiScan 码,码,…                 依次喂这些码（同一个码写两次 = 扫两次）
///   -uiScanSource gun|camera|manual 当作从哪儿来（默认 gun）。gun 按扫码枪的速度逐键打进 `ScanHub.key`
///                                   （走真实的按键解析），camera 走相机去重，manual 当作手输
///   -uiScanGap 0.3                  两个码之间隔几秒（默认 0.3）
///   -uiScanDelay 1                  开页后等几秒再开始喂（默认 1）
struct FakeScanner: Equatable, Sendable {
    var codes: [String]
    var source: ScanSource = .gun
    var gap: TimeInterval = 0.3
    var delay: TimeInterval = 1
    /// 扫码枪模式下相邻两键的间隔（远小于 `HIDScanParser.Config.maxGap`）
    static let keyGap: TimeInterval = 0.005

    static func from(_ args: [String]) -> FakeScanner? {
        guard let list = UIFixture.value(for: "-uiScan", in: args) else { return nil }
        var f = FakeScanner(codes: list.split(separator: ",").map(String.init).filter { !$0.isEmpty })
        if let s = UIFixture.value(for: "-uiScanSource", in: args).flatMap(ScanSource.init(rawValue:)) { f.source = s }
        if let g = UIFixture.value(for: "-uiScanGap", in: args).flatMap(TimeInterval.init), g >= 0 { f.gap = g }
        if let d = UIFixture.value(for: "-uiScanDelay", in: args).flatMap(TimeInterval.init), d >= 0 { f.delay = d }
        return f.codes.isEmpty ? nil : f
    }

    /// 扫码枪打一个码时的按键序列（字符逐个 + 回车），时间从 `start` 起
    static func keystrokes(_ code: String, start: TimeInterval) -> [(HIDScanParser.Key, TimeInterval)] {
        var t = start
        var out: [(HIDScanParser.Key, TimeInterval)] = []
        for c in code {
            out.append((.character(c), t))
            t += keyGap
        }
        out.append((.enter, t))
        return out
    }

    /// 把码喂进 `hub`（真等时间，所以相机去重按真实的 1.5 秒起作用）
    @MainActor
    func run(into hub: ScanHub) async {
        try? await Task.sleep(for: .seconds(delay))
        for code in codes {
            switch source {
            case .gun:
                for (key, t) in Self.keystrokes(code, start: ProcessInfo.processInfo.systemUptime) {
                    hub.key(key, at: t)
                }
            case .camera, .manual:
                hub.receive(code, from: source)
            }
            try? await Task.sleep(for: .seconds(gap))
        }
    }
}
#endif
