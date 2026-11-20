import Foundation

/// 相机的去重：相机每秒能认出同一个码十几次，同一个码在上一次**被接受**之后 1.5 秒内再出现一律忽略。
/// 换了一个码立刻接受（A、B、A 交替扫的是不同商品）；超过 1.5 秒同一个码再次出现算新的一次。
///
/// 只用于相机。扫码枪每扣一次扳机都算，手输条码也不去重。
struct CameraDeduper: Sendable {
    static let defaultWindow: TimeInterval = 1.5

    let window: TimeInterval
    private var last: (code: String, time: TimeInterval)?

    init(window: TimeInterval = Self.defaultWindow) {
        self.window = window
    }

    /// 这次认出的码要不要算一次扫码
    mutating func accept(_ code: String, at time: TimeInterval) -> Bool {
        if let last, last.code == code, time >= last.time, time - last.time < window {
            return false
        }
        last = (code, time)
        return true
    }

    mutating func reset() {
        last = nil
    }
}
