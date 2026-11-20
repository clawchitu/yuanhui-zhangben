import SwiftUI

/// 组件陈列页：所有共用组件在当前字号下的样子。用 `-uiFixture gallery[-1…-5]` 直接打开。
/// 分 5 页，保证最大辅助字号下每页内容也能在 iPhone 13 一屏里截全。
struct ComponentGallery: View {
    static let pageCount = 5

    var page: Int?
    var onBack: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var qty = 1
    @State private var qtySmall = 4
    @State private var typed = "4.50"

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: pageTitle, mode: .neutral, onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if show(1) { pageType }
                    if show(2) { pageBarsAndButtons }
                    if show(3) { pagePriceTag }
                    if show(4) { pageKeypadAndBanners }
                    if show(5) { pageSheet }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
    }

    private func show(_ n: Int) -> Bool { page == nil || page == n }

    private var pageTitle: String {
        page.map { "组件陈列 \($0)/\(Self.pageCount)" } ?? "组件陈列"
    }

    private func pt(_ role: TypeRole) -> Int {
        Int(TypeScale.pointSize(role, system: typeSize, largeMode: false).rounded())
    }

    @ViewBuilder private var pageType: some View {
        section("字号（当前 \(String(describing: typeSize))）") {
            VStack(alignment: .leading, spacing: 6) {
                Text("标题 \(pt(.title))pt").font(TypeScale.title)
                Text("正文：今天卖了 12 笔 · \(pt(.body))pt").font(TypeScale.body)
                Text("次要：上次进货 11月18日 · \(pt(.secondary))pt").font(TypeScale.secondary)
                    .foregroundStyle(Tokens.Palette.ink2)
            }
            .foregroundStyle(Tokens.Palette.ink)
        }
        section("颜色") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                ForEach(Tokens.Palette.all) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        RoundedRectangle(cornerRadius: 10).fill(c.color).frame(height: 30)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tokens.Palette.line))
                        Text(c.label).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink)
                    }
                }
            }
        }
    }

    @ViewBuilder private var pageBarsAndButtons: some View {
        section("顶栏") {
            VStack(spacing: 8) {
                ModeBar(title: "卖出", mode: .sell, pendingCount: 2, onBack: {})
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                ModeBar(title: "进货", mode: .stock, onBack: {})
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        section("主按钮（固定 \(Int(Tokens.Size.primaryButton))pt 高）") {
            VStack(spacing: 10) {
                PrimaryButton("收好钱了，记账", systemImage: "checkmark", mode: .sell) {}
                PrimaryButton("进货入库", systemImage: "shippingbox", mode: .stock) {}
                PrimaryButton("抹零 / 改总价", style: .ghost, size: .medium) {}
            }
        }
    }

    @ViewBuilder private var pagePriceTag: some View {
        section("价签 + 步进器") {
            PriceTag(name: "康师傅红烧牛肉面", unitPriceCents: 450) {
                HStack {
                    Text("买几个").font(TypeScale.title).foregroundStyle(Tokens.Palette.ink)
                    Spacer()
                    QuantityStepper(value: $qty, range: 1...999)
                }
            }
        }
        section("小步进器") {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("青岛啤酒 500ml").font(TypeScale.body)
                    Spacer()
                    QuantityStepper(value: $qtySmall, compact: true).accessibilityIdentifier("gallery.stepperCompact")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("青岛啤酒 500ml").font(TypeScale.body)
                    QuantityStepper(value: $qtySmall, compact: true).accessibilityIdentifier("gallery.stepperCompact")
                }
            }
            .foregroundStyle(Tokens.Palette.ink)
        }
        section("总价（固定字号）") {
            HStack(alignment: .lastTextBaseline) {
                Text("要收").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                Spacer()
                PriceText(cents: 5350, size: Tokens.FixedFontSize.total)
            }
        }
    }

    @ViewBuilder private var pageKeypadAndBanners: some View {
        section("数字键盘") {
            VStack(spacing: 8) {
                Text(typed.isEmpty ? " " : typed)
                    .font(TypeScale.number(32))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Keypad { key in
                    switch key {
                    case .digit(let n): typed.append(String(n))
                    case .dot: if !typed.contains(".") { typed.append(".") }
                    case .delete: if !typed.isEmpty { typed.removeLast() }
                    }
                }
            }
        }
        section("标签与横幅") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Pill(text: "刚扫到")
                    Pill(text: "已过期", kind: .ink)
                    Pill(text: "收银员", kind: .outline)
                }
                Banner(kind: .alert, text: "有 3 样快过期了")
                Banner(kind: .soft, text: "还有 2 笔没传上去", systemImage: "arrow.up.to.line")
                Banner(kind: .expired, text: "这批已过期，别再卖了", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    @ViewBuilder private var pageSheet: some View {
        section("底部抽屉 + 确认面板") {
            BottomSheet {
                ConfirmPanel(
                    title: "撤销这笔卖出？",
                    rows: [.init(label: "时间", value: "今天 19:48"), .init(label: "金额", value: "¥53.50")],
                    confirmTitle: "确认撤销",
                    onConfirm: {},
                    onCancel: {}
                )
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(TypeScale.secondary.weight(.semibold))
                .foregroundStyle(Tokens.Palette.ink2)
            content()
        }
    }
}
