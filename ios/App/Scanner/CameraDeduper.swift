import Foundation

/// 相机的去重（§14 S14-1）：相机每秒能认出同一个码十几次。按码各记各的「最后一次看见」的时间：
/// 某个码从**最后一次被看见**起 1.5 秒内再出现都忽略（一直对着不动只算一次，拿开 1.5 秒再对上才算第二次）；
/// 别的码不影响它的计时（A、B 同在画面里、或交替出现，各算一次，不来回刷）。记录只留最近 1.5 秒内见过的码。
///
/// 只用于相机。扫码枪每扣一次扳机都算，手输条码也不去重。
struct CameraDeduper: Sendable {
    static let defaultWindow: TimeInterval = 1.5

    let window: TimeInterval
    /// 码 → 最后一次看见的时间
    private var lastSeen: [String: TimeInterval] = [:]

    init(window: TimeInterval = Self.defaultWindow) {
        self.window = window
    }

    /// 这次认出的码要不要算一次扫码（不管算不算，都记作「最后一次看见」）
    mutating func accept(_ code: String, at time: TimeInterval) -> Bool {
        // 清理：超过窗口没再看见的码忘掉；时间倒流时（`time` 比记录早）也一并忘掉，不当作窗口内
        lastSeen = lastSeen.filter { _, seen in time >= seen && time - seen < window }
        let duplicate = lastSeen[code] != nil
        lastSeen[code] = time
        return !duplicate
    }

    /// 现在记着几个码（测试读：确认过期的会清掉）
    var trackedCount: Int { lastSeen.count }

    mutating func reset() {
        lastSeen = [:]
    }
}
