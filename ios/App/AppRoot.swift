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

struct AppRoot: View {
    static let title = "元辉账本"

    @AppStorage(AppSettings.largeTextModeKey) private var largeTextMode = true
    private let screen = UIFixture.screen(from: ProcessInfo.processInfo.arguments)

    var body: some View {
        content
            .largeTextMode(largeTextMode)
            .preferredColorScheme(.light)
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
