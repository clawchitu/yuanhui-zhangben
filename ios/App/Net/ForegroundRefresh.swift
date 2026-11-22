import SwiftUI

/// 回到前台的判定（§8 S21「启动和每次回到前台时取一次配置」，§14 S15-2 回前台补报手机名）。
/// 从后台回来时 `scenePhase` 走的是 background → inactive → active，变成 active 时上一个状态是 inactive，
/// 所以不能看「上一个是不是 background」（PR #35 Fable 实测）。这里记一个「进过后台」的标记，下一次 active 时触发一次。
/// 只是下拉通知中心、来电之类 active → inactive → active（没进后台）不触发。
struct ForegroundRefresh {
    private(set) var wasInBackground = false

    /// 喂一个新的 scenePhase；返回 true 表示「刚从后台回到前台」，该取配置、补报了
    mutating func shouldRefresh(on phase: ScenePhase) -> Bool {
        switch phase {
        case .background:
            wasInBackground = true
            return false
        case .active:
            defer { wasInBackground = false }
            return wasInBackground
        default:
            return false
        }
    }
}
