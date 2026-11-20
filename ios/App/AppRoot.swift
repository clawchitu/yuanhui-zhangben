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
