import ShopCore
import SwiftUI
import UIKit

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
/// S22c：给了 `ref`（商品 id + `image_ver`）就从 `ProductImages` 取真图。只同步读内存；没命中在后台读盘 / 下载，
/// 加载中、没图（404）、开关关、演示店都显示首字，不转圈。
struct Thumb: View {
    var image: Image?
    var initial: String?
    /// 商品图（`image_ver` 为 0 = 没图）
    var ref: ImageKey?
    var size: CGFloat = Tokens.Size.thumb
    /// 底色：放在白卡、价签上用米纸；直接放在米纸页面上时调深一点，不然看不出框（04a / 05）
    var fill: Color = Tokens.Palette.paper

    @Environment(\.productImages) private var images
    @State private var loaded: Loaded?

    struct Loaded { let key: ImageKey; let generation: Int; let image: UIImage }

    init(image: Image? = nil, initial: String? = nil, ref: ImageKey? = nil, size: CGFloat = Tokens.Size.thumb,
         fill: Color = Tokens.Palette.paper) {
        self.image = image; self.initial = initial; self.ref = ref; self.size = size; self.fill = fill
    }

    /// 商品 → Thumb 的图片引用。`image_ver` 为 0（服务器上还没图）也给：本机刚选 / 刚拍的图先显示（S22d）
    static func ref(_ p: Product?) -> ImageKey? {
        guard let p else { return nil }
        return ImageKey(p.id, p.imageVer)
    }

    private var remote: UIImage? {
        guard let images, images.enabled, let ref else { return nil }
        if let p = images.preview(ref) { return p }
        guard ref.ver > 0 else { return nil }
        if let m = images.cached(ref) { return m }
        if let l = loaded, l.generation == images.generation, l.key.productId == ref.productId, l.key.ver <= ref.ver { return l.image }
        return nil
    }

    private struct LoadID: Equatable { let ref: ImageKey?; let generation: Int; let arrivals: Int; let enabled: Bool }

    var body: some View {
        let remote = remote
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.2).fill(fill)
            if let image {
                image.resizable().scaledToFill()
            } else if let remote {
                Image(uiImage: remote).resizable().scaledToFill()
                    #if DEBUG
                    .onAppear { images?.debugShown += 1 }
                    .onDisappear { images?.debugShown -= 1 }
                    #endif
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
        .task(id: LoadID(ref: ref, generation: images?.generation ?? 0, arrivals: ref.flatMap { images?.arrivals[$0] } ?? 0,
                         enabled: images?.enabled ?? false)) {
            guard let images, let ref, ref.ver > 0, images.enabled, images.cached(ref) == nil else { return }
            let gen = images.generation
            if let img = await images.load(ref), !Task.isCancelled {
                loaded = Loaded(key: ref, generation: gen, image: img)
            }
        }
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
    /// 商品图（S22c）
    var imageRef: ImageKey?
    /// 下面一栏的上下留白（卖出页 03 的「买几个」栏比陈列页紧一点）
    var footerVerticalPadding: CGFloat = 12
    /// 紧凑版（卖出页 03）：黄底上下留白收小，单价收掉 DIN 多出来的行高，整块比原来矮约 23pt，贴近稿子
    var compact = false
    /// 收紧档（卖出页按购物篮区的可用高度挑，真机 11/26：长名折两行把「买几个」挤到结算条底下）。
    /// 0 照稿子；1 名称用正文字号、最多两行，缩略图 48；2 名称一行（放不下先缩小、再截尾），不要说明行，缩略图 40；
    /// 3 不要缩略图，名称和单价同一行。下面一栏（步进器）每一档都一样大
    var tight: Int = 0
    let footer: Footer

    init(name: String, caption: String = "刚扫的 · 单价", unitPriceCents: Int, thumb: Image? = nil, initial: String? = nil,
         imageRef: ImageKey? = nil, footerVerticalPadding: CGFloat = 12, compact: Bool = false, tight: Int = 0,
         @ViewBuilder footer: () -> Footer) {
        self.imageRef = imageRef
        self.footerVerticalPadding = footerVerticalPadding
        self.compact = compact
        self.tight = tight
        self.name = name
        self.caption = caption
        self.unitPriceCents = unitPriceCents
        self.thumb = thumb
        self.initial = initial
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: tight == 0 ? 14 : 10) {
                if tight < 3 {
                    Thumb(image: thumb, initial: initial, ref: imageRef, size: Self.thumbSize(tight))
                }
                VStack(alignment: .leading, spacing: compact ? 0 : 6) {
                    if tight >= 3 {
                        HStack(alignment: .center, spacing: 8) {
                            nameText.frame(maxWidth: .infinity, alignment: .leading)
                            price
                        }
                    } else {
                        nameText
                    }
                    if tight == 2 {
                        price
                    } else if tight < 2 {
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
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.horizontal, 16)
            .padding(.top, tight > 0 ? 8 : (compact ? 12 : 16))
            .padding(.bottom, tight > 0 ? 8 : (compact ? 14 : 16))
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

    static func thumbSize(_ tight: Int) -> CGFloat {
        switch tight { case 0: Tokens.Size.thumb; case 1: 48; default: 40 }
    }

    /// 名称：0 档照稿子不限行；1 档两行；2、3 档一行，放不下先缩到七成再截尾（开头永远可见）
    private var nameText: some View {
        Text(name)
            .font(tight == 0 ? TypeScale.title : TypeScale.body.weight(.semibold))
            .lineLimit(tight == 0 ? nil : (tight == 1 ? 2 : 1))
            .minimumScaleFactor(tight >= 2 ? 0.7 : 1)
            .truncationMode(.tail)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("priceTag.name")
    }

    private var price: some View {
        PriceText(cents: unitPriceCents).padding(.vertical, compact ? -6 : 0)
    }

    private var captionText: some View {
        // 卖出页（紧凑版）照稿子用深色：灰字压在黄底上太浅（Fable 视觉 4）
        Text(caption).font(TypeScale.secondary).foregroundStyle(compact ? Tokens.Palette.ink : Tokens.Palette.ink2)
    }
}

extension PriceTag where Footer == EmptyView {
    init(name: String, caption: String = "刚扫的 · 单价", unitPriceCents: Int, thumb: Image? = nil) {
        self.init(name: name, caption: caption, unitPriceCents: unitPriceCents, thumb: thumb) { EmptyView() }
    }
}
