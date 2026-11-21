import SwiftUI

/// 金额一律整数分；这里只负责显示。
enum Money {
    static func yuanString(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let a = cents.magnitude
        return sign + String(a / 100) + "." + String(format: "%02d", Int(a % 100))
    }
}

/// ¥ + 金额，DIN Alternate Bold，固定字号。
struct PriceText: View {
    let cents: Int
    var size: CGFloat = Tokens.FixedFontSize.price
    var color: Color = Tokens.Palette.ink

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("¥").font(TypeScale.number(size * 0.6))
            Text(Money.yuanString(cents)).font(TypeScale.number(size))
        }
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Money.yuanString(cents)) 元")
    }
}

/// 商品缩略图；没图时显示商品名的首字（S16「64pt 小图或首字」），首字也没有才显示占位图标。
struct Thumb: View {
    var image: Image?
    var initial: String?
    var size: CGFloat = Tokens.Size.thumb

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2).fill(Tokens.Palette.paper)
            if let image {
                image.resizable().scaledToFill()
            } else if let initial, !initial.isEmpty {
                Text(initial)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(Tokens.Palette.ink2)
            } else {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Tokens.Palette.mute)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
        .accessibilityHidden(true)
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

/// 价签：刚扫到的商品，价签黄底；下面可接一栏（比如「买几个」步进器）。
struct PriceTag<Footer: View>: View {
    let name: String
    var caption: String
    let unitPriceCents: Int
    var thumb: Image?
    /// 没图时缩略图上显示的首字；nil = 占位图标
    var initial: String?
    /// 下面一栏的上下留白（卖出页 03 的「买几个」栏比陈列页紧一点）
    var footerVerticalPadding: CGFloat = 12
    /// 紧凑版（卖出页 03）：黄底上下留白收小，单价收掉 DIN 多出来的行高，整块比原来矮约 23pt，贴近稿子
    var compact = false
    let footer: Footer

    init(name: String, caption: String = "刚扫的 · 单价", unitPriceCents: Int, thumb: Image? = nil, initial: String? = nil,
         footerVerticalPadding: CGFloat = 12, compact: Bool = false, @ViewBuilder footer: () -> Footer) {
        self.footerVerticalPadding = footerVerticalPadding
        self.compact = compact
        self.name = name
        self.caption = caption
        self.unitPriceCents = unitPriceCents
        self.thumb = thumb
        self.initial = initial
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Thumb(image: thumb, initial: initial)
                VStack(alignment: .leading, spacing: compact ? 0 : 6) {
                    Text(name)
                        .font(TypeScale.title)
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .lastTextBaseline) {
                            captionText
                            Spacer(minLength: 8)
                            price
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            captionText
                            price
                        }
                    }
                }
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 16)
            .padding(.top, compact ? 12 : 16)
            .padding(.bottom, compact ? 14 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.tag)
            if Footer.self != EmptyView.self {
                DashedLine()
                    .stroke(Tokens.Palette.ink, style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                    .frame(height: 2)
                footer
                    .padding(.horizontal, 16)
                    .padding(.vertical, footerVerticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tokens.Palette.card)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
    }

    private var price: some View {
        PriceText(cents: unitPriceCents).padding(.vertical, compact ? -6 : 0)
    }

    private var captionText: some View {
        Text(caption).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
    }
}

extension PriceTag where Footer == EmptyView {
    init(name: String, caption: String = "刚扫的 · 单价", unitPriceCents: Int, thumb: Image? = nil) {
        self.init(name: name, caption: caption, unitPriceCents: unitPriceCents, thumb: thumb) { EmptyView() }
    }
}
