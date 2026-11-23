import ShopCore
import SwiftUI

/// 29 首次同步：「正在把店里的商品搬过来 / 194 / 312 样」。商品流拉到底（`catalogDone`）就进 16 / 首页开卖，
/// 流水在后台接着拉（S22a 验收）。分子是本机已有的商品数，强杀重开后接着数。
struct FirstSyncView: View {
    @Environment(AppModel.self) private var model

    private var figures: (done: Int, total: Int?) {
        if let f = model.firstSyncFixture { return (f.done, f.total) }
        return model.sync?.firstSyncFigures ?? (0, nil)
    }

    var body: some View {
        let f = figures
        VStack(spacing: 0) {
            Text(model.session.storeName)
                .font(TypeScale.body.weight(.bold))
                .foregroundStyle(Tokens.Palette.ink)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.modeBar)
            ScrollView {
                VStack(spacing: 0) {
                    ZStack {
                        Circle().fill(Tokens.Palette.card)
                        Circle().strokeBorder(Tokens.Palette.ink, lineWidth: 2.5)
                        Image(systemName: "shippingbox").font(.system(size: 50, weight: .semibold))
                            .foregroundStyle(Tokens.Palette.ink)
                    }
                    .frame(width: 110, height: 110)
                    .accessibilityHidden(true)
                    .padding(.top, 120)
                    Text("正在把店里的商品搬过来")
                        .font(TypeScale.title.weight(.bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 28)
                    Text("第一次登录要等一会儿，别关 App")
                        .font(TypeScale.body)
                        .foregroundStyle(Tokens.Palette.ink2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                    bar(done: f.done, total: f.total).padding(.top, 28)
                    HStack(alignment: .firstTextBaseline) {
                        Text("商品").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink)
                        Spacer(minLength: 8)
                        count(done: f.done, total: f.total)
                    }
                    .padding(.top, 10)
                    if let e = model.sync?.lastError, !e.isEmpty, model.offline || model.sync?.running == false {
                        Text(model.offline ? "没网，连上就接着搬" : "这会儿连不上，过一会儿自动再试")
                            .font(TypeScale.secondary.weight(.medium))
                            .foregroundStyle(Tokens.Palette.sell)
                            .padding(.top, 16)
                            .accessibilityIdentifier("firstSync.error")
                    }
                    Text("商品搬完就能开始卖；\n商品图片在后台慢慢补，不耽误记账")
                        .font(TypeScale.secondary)
                        .foregroundStyle(Tokens.Palette.ink2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 36)
                }
                .padding(.horizontal, 20)
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.firstSync")
    }

    private func bar(done: Int, total: Int?) -> some View {
        GeometryReader { geo in
            let frac = total.map { $0 > 0 ? min(1, CGFloat(done) / CGFloat($0)) : 0 } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.Palette.line)
                Capsule().fill(Tokens.Palette.ink).frame(width: max(18, geo.size.width * frac))
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)
    }

    private func count(done: Int, total: Int?) -> some View {
        (Text("\(done)").font(.system(size: 30, weight: .bold)) +
         Text(total.map { " / \($0) 样" } ?? " 样").font(.system(size: 28)))
            .foregroundStyle(Tokens.Palette.ink)
            .monospacedDigit()
            .accessibilityIdentifier("firstSync.count")
    }
}
