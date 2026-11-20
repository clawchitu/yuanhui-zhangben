import Foundation

/// 扫码枪（蓝牙 HID 键盘）输入的解析。扫码枪把条码当成一串极快的按键「打」进来，最后跟一个回车。
///
/// 规则：
/// - 相邻两个按键（包括最后的回车）间隔都不超过 `maxGap`，并且回车前攒够 `minLength` 个字符，才算**一次**扫码；
/// - 任意两键间隔超过 `maxGap` 就从这个键重新攒（慢速逐个按键永远攒不够，不算扫码）；
/// - 收的字符只有数字和 ASCII 字母（EAN / UPC / ITF 全是数字，Code128 里的大小写字母完整保留）；
/// - 非法的键（空格、Tab、「-」等其他符号、非 ASCII、方向键、带 Control / Command / Option 的组合）让**当前整串作废**，
///   一直丢到回车或停顿（超过 `maxGap`）为止，之后才重新收——不能丢掉前缀把后半截当成另一个有效码交出去
///   （`ABC-6921168509256` 不能变成 `6921168509256`）；
/// - 单独按下的修饰键（Shift、Caps Lock 等，扫码枪打大写字母时会发）是 `.ignored`：不攒、不作废、也不算进按键间隔；
/// - 只认回车（Return / 小键盘 Enter）结尾：扫码枪的后缀必须设成回车，设成 Tab 的一个码也不出（Tab 是非法键），
///   见 §14 S14-4，写进 S29 真机清单和店里的扫码枪设置说明；
/// - 不去重：扫码枪每扣一次扳机都算一次（同一个码连扫两次 = 两次）。相机的去重见 `CameraDeduper`。
///
/// 纯逻辑、时间由调用方传入（UIPress.timestamp），单元测试直接喂时间。
struct HIDScanParser: Sendable {
    /// 一个按键
    enum Key: Equatable, Sendable {
        case character(Character)
        case enter
        /// 非法键：让当前整串作废
        case other
        /// 单独按下的修饰键：当作没按
        case ignored
    }

    struct Config: Equatable, Sendable {
        /// 相邻两键的最大间隔。扫码枪一般 2–30 ms 一个字符（蓝牙会成批到达，间隔有抖动）；
        /// 人手按键再快也在 100 ms 以上，连续 6 个以上都快过 80 ms 实际不会发生。
        var maxGap: TimeInterval = 0.08
        /// 最短的码：UPC-E 6 位（EAN-8 8 位，EAN-13 13 位，ITF-14 14 位）
        var minLength = 6
        /// 超过这个长度就不是商品条码了（Code128 也够用）
        var maxLength = 48
    }

    let config: Config
    private(set) var buffer = ""
    private var lastTime: TimeInterval?
    /// 这一串已经作废（出现过非法键或超长）：一直丢到回车或停顿为止
    private(set) var voided = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// 喂一个按键；凑成一次完整扫码时返回条码，否则 nil。
    mutating func feed(_ key: Key, at time: TimeInterval) -> String? {
        if key == .ignored { return nil }
        if let last = lastTime, time - last > config.maxGap || time < last {
            buffer = ""   // 停顿太久（或时间倒流）：之前攒的（或作废的）都丢掉，从这个键重新开始
            voided = false
        }
        lastTime = time
        switch key {
        case .character(let c) where Self.isCodeCharacter(c):
            guard !voided else { return nil }
            buffer.append(c)
            if buffer.count > config.maxLength { void() }
            return nil
        case .character, .other:
            void()   // 不清时间：紧跟着的按键仍属于这一串，一起丢掉
            return nil
        case .enter:
            defer { reset() }
            return !voided && buffer.count >= config.minLength ? buffer : nil
        case .ignored:
            return nil
        }
    }

    private mutating func void() {
        buffer = ""
        voided = true
    }

    mutating func reset() {
        buffer = ""
        lastTime = nil
        voided = false
    }

    /// 条码里可能出现的字符：数字（EAN / UPC / ITF），以及 Code128 里的 ASCII 字母
    static func isCodeCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }
}
