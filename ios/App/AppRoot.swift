import SwiftUI

@main
struct YuanhuiZhangbenApp: App {
    init() {
        UIFixture.applyLaunchOverrides()
    }

    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
    }
}

enum AppSettings {
    /// 大字模式开关，默认开（§设计：老人用，大字是默认）。
    static let largeTextModeKey = "largeTextMode"
}

/// 所有界面的根外壳：读「大字模式」设置并套上字号范围、浅色外观。
/// AppRoot 用它包住全部内容；字号测试也直接测它，保证测的就是实际生效链路。
struct AppShell<Content: View>: View {
    @AppStorage(AppSettings.largeTextModeKey) private var largeTextMode = true
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .largeTextMode(largeTextMode)
            .preferredColorScheme(.light)
    }
}

struct AppRoot: View {
    static let title = "元辉账本"

    @AppStorage(AppSettings.largeTextModeKey) private var largeTextMode = true
    private let screen = UIFixture.screen(from: ProcessInfo.processInfo.arguments)

    var body: some View {
        AppShell { content }
    }

    @ViewBuilder private var content: some View {
        switch screen {
        case .gallery(let page):
            ComponentGallery(page: page)
        case nil:
            HomePlaceholder(largeTextMode: $largeTextMode)
        }
    }
}

/// S11 只有骨架：首页占位 + 进组件陈列页的入口。真正的首页在后面的段里做。
private struct HomePlaceholder: View {
    @Binding var largeTextMode: Bool
    @State private var showGallery = false

    var body: some View {
        VStack(spacing: 24) {
            Text(AppRoot.title)
                .font(TypeScale.title)
                .foregroundStyle(Tokens.Palette.ink)
            Toggle("大字模式", isOn: $largeTextMode)
                .font(TypeScale.body)
                .tint(Tokens.Palette.ink)
            PrimaryButton("组件陈列", mode: .neutral) { showGallery = true }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .fullScreenCover(isPresented: $showGallery) {
            ComponentGallery(onBack: { showGallery = false })
                .largeTextMode(largeTextMode)
        }
    }
}
