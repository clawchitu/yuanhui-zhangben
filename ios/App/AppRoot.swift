import SwiftUI

@main
struct YuanhuiZhangbenApp: App {
    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
    }
}

struct AppRoot: View {
    static let title = "元辉账本"

    var body: some View {
        Text(Self.title)
            .font(.largeTitle)
    }
}
// S00 示例 PR：只改 ios/
// 第二次提交
