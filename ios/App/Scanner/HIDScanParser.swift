import Foundation

/// 扫码枪（蓝牙 HID 键盘）输入的解析。扫码枪把条码当成一串极快的按键「打」进来，最后跟一个回车。
///
/// 规则：
/// - 相邻两个按键（包括最后的回车）间隔都不超过 `maxGap`，并且回车前攒够 `minLength` 个字符，才算**一次**扫码；
/// - 任意两键间隔超过 `maxGap` 就从这个键重新攒（慢速逐个按键永远攒不够，不算扫码）；
/// - 不认识的键（空格、方向键、带修饰键的组合等）清空正在攒的内容；
/// - 不去重：扫码枪每扣一次扳机都算一次（同一个码连扫两次 = 两次）。相机的去重见 `CameraDeduper`。
///
/// 纯逻辑、时间由调用方传入（UIPress.timestamp），单元测试直接喂时间。
struct HIDScanParser: Sendable {
    /// 一个按键
    enum Key: Equatable, Sendable {
        case character(Character)
        case enter
        case other
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
    /// 这一串已经超长：一直丢到回车或停顿为止
    private var overflowed = false

    init(config: Config = Config()) {
        self.config = config
    }

    /// 喂一个按键；凑成一次完整扫码时返回条码，否则 nil。
    mutating func feed(_ key: Key, at time: TimeInterval) -> String? {
        if let last = lastTime, time - last > config.maxGap || time < last {
            buffer = ""   // 停顿太久（或时间倒流）：之前攒的作废，从这个键重新开始
            overflowed = false
        }
        lastTime = time
        switch key {
        case .character(let c) where Self.isCodeCharacter(c):
            guard !overflowed else { return nil }
            buffer.append(c)
            if buffer.count > config.maxLength {
                buffer = ""
                overflowed = true
            }
            return nil
        case .character, .other:
            reset()
            return nil
        case .enter:
            defer { reset() }
            return buffer.count >= config.minLength ? buffer : nil
        }
    }

    mutating func reset() {
        buffer = ""
        lastTime = nil
        overflowed = false
    }

    /// 条码里可能出现的字符：数字（EAN / UPC / ITF），以及 Code128 里的 ASCII 字母
    static func isCodeCharacter(_ c: Character) -> Bool {
        guard c.isASCII, let v = c.asciiValue else { return false }
        return (0x30...0x39).contains(v) || (0x41...0x5A).contains(v) || (0x61...0x7A).contains(v)
    }
}
