import ShopCore
import SwiftUI
import UIKit

/// 登记新商品时的商品图候选（S22d，Fable 方案 2）：查码一回来就开始在后台问，不等存好。
/// - 候选 `ready` / `none`：定了；`pending`：每秒问一次 `GET …/images`，最多 8 秒，到时有几张算几张。
/// - 查码没带回候选（进程内记过的码、查码出错）：先问一次 `/images`（只读库、不扣快鸟次数）。没网直接当没有。
/// - 每张候选的缩图（200px JPEG）拿到了才算「能选」；拿不到的不给选。缩图只在内存里，页面关了就丢。
@MainActor @Observable
final class ImageChoiceModel {
    let barcode: String
    /// 服务器给的顺序
    private(set) var order: [String] = []
    private(set) var thumbs: [String: UIImage] = [:]
    @ObservationIgnored private(set) var bytes: [String: Data] = [:]
    /// 候选和缩图都定了（之后张数不会再变）
    private(set) var settled = false
    var selected: String?

    @ObservationIgnored private let fetchState: @Sendable (String) async throws -> ImageCandidates
    @ObservationIgnored private let fetchImage: @Sendable (String, String) async throws -> Data
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var downloader: Task<Void, Never>?
    @ObservationIgnored private var tried: Set<String> = []

    /// 轮询间隔、最长等多久（规格⑦：每秒一次，最多 8 秒）
    var pollInterval: Duration = .seconds(1)
    var pollLimit: Duration = .seconds(8)

    init(barcode: String, fetchState: @escaping @Sendable (String) async throws -> ImageCandidates,
         fetchImage: @escaping @Sendable (String, String) async throws -> Data) {
        self.barcode = barcode
        self.fetchState = fetchState
        self.fetchImage = fetchImage
    }

    /// 用这个会话的网络：令牌每次现读，读不出来按出错
    convenience init(barcode: String, changes: ImageChanges) {
        let api = changes.api, token = changes.token
        self.init(barcode: barcode,
                  fetchState: { code in
                      guard let t = token() else { throw APIError.server(status: 401, code: "unauthorized", lockedUntil: nil, retryAfterS: nil) }
                      return try await api.imageCandidates(code, token: t)
                  },
                  fetchImage: { code, cid in
                      guard let t = token() else { throw APIError.server(status: 401, code: "unauthorized", lockedUntil: nil, retryAfterS: nil) }
                      return try await api.candidateImage(code, cid: cid, token: t)
                  })
    }

    /// 能选的：缩图已经到了的，按服务器顺序
    var usable: [String] { order.filter { thumbs[$0] != nil } }

    /// 跑到候选定下来（最多 8 秒）再等缩图下完。`initial`：查码带回来的；nil = 先问一次
    func run(initial: ImageCandidates?) async {
        var current = initial
        if current == nil { current = try? await fetchState(barcode) }
        let clock = ContinuousClock()
        let deadline = clock.now + pollLimit
        while !Task.isCancelled {
            if let c = current {
                absorb(c.ids)
                if c.state != .pending { break }
            }
            if clock.now >= deadline { break }
            try? await Task.sleep(for: pollInterval)
            if Task.isCancelled { break }
            do {
                current = try await fetchState(barcode)
            } catch let APIError.server(status, _, _, _) where [403, 404, 429].contains(status) {
                break   // 不让问了（收银员、开关关、限速）：就用已有的
            } catch {
                continue   // 连不上：到点为止接着试
            }
        }
        // 缩图最多再等 3 秒（每张 5 秒超时、一张一张下，网慢时不让「还在找图」转太久）；迟到的照样显示
        let cap = clock.now + .seconds(3)
        while downloader != nil, clock.now < cap, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        settled = true
    }

    private func absorb(_ ids: [String]) {
        for id in ids where !order.contains(id) {
            order.append(id)
            queue.append(id)
        }
        guard downloader == nil, !queue.isEmpty else { return }
        downloader = Task { [weak self] in await self?.drain() }
    }

    /// 缩图一张一张下（最多 6 张、每张约 10 KB）；解码不在主线程
    private func drain() async {
        while !queue.isEmpty, !Task.isCancelled {
            let id = queue.removeFirst()
            guard tried.insert(id).inserted else { continue }
            let code = barcode, fetch = fetchImage
            let got = await Task.detached(priority: .userInitiated) { () -> (Data, UIImage)? in
                guard let d = try? await fetch(code, id), let img = UIImage(data: d) else { return nil }
                return (d, img.preparingForDisplay() ?? img)
            }.value
            if let (d, img) = got {
                bytes[id] = d
                thumbs[id] = img
                if selected == nil { selected = id }
            }
        }
        downloader = nil
    }
}

/// 登记的第三步「选商品图」（S22d，Fable 方案 1、10）：商品已经存好了，这一步只管图。返回键等于「跳过」。
/// 有候选：上面两列方格（最多 6 张，可滚），默认选中第一张；底栏钉在滚动区外：「就用这张」整宽，
/// 下面「拍一张」「从相册选」各半，最下面「跳过」。没有候选（没图、没网）：「这个商品还没有图」，拍一张 / 从相册选 / 跳过。
struct ImageChoiceView: View {
    @Bindable var choice: ImageChoiceModel
    let mode: ShopMode
    let onUse: (String) -> Void
    let onPhoto: (CompressedPhoto) -> Void
    let onSkip: () -> Void
    /// `replace`：进货页商品卡上换图（已有商品），文字换成「换商品图」「关掉」
    var replace = false

    /// 候选定了、一张能用的都没有：只提示拍照
    private var promptOnly: Bool { choice.settled && choice.usable.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(replace ? "换商品图" : (promptOnly ? "这个商品还没有图" : "选一张商品图"))
                        .font(TypeScale.title.weight(.bold))
                        .foregroundStyle(Tokens.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .dynamicTypeSize(...DiscountPanel.labelCap)
                        .accessibilityIdentifier("imageChoice.title")
                    if promptOnly && !replace {
                        Text("拍一张，以后扫到它就显示这张图；不拍也行")
                            .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                            .dynamicTypeSize(...DiscountPanel.labelCap)
                            .accessibilityIdentifier("imageChoice.prompt")
                    }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(Array(choice.usable.enumerated()), id: \.element) { i, id in
                            cell(i, id)
                        }
                    }
                    if !choice.settled {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("还在找图…").font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                        }
                        .dynamicTypeSize(...DiscountPanel.labelCap)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("imageChoice.searching")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("imageChoice.scroll")
            VStack(spacing: 8) {
                if !promptOnly {
                    PrimaryButton("就用这张", systemImage: "checkmark", mode: mode, size: .medium) {
                        if let s = choice.selected { onUse(s) }
                    }
                    .disabled(choice.selected == nil)
                    .accessibilityIdentifier("imageChoice.use")
                }
                PhotoButtons(mode: mode, onPhoto: onPhoto)
                PrimaryButton(replace ? "关掉" : "跳过", mode: mode, style: .ghost, size: .small) { onSkip() }
                    .accessibilityIdentifier("imageChoice.skip")
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(Tokens.Palette.paper)
        }
    }

    private func cell(_ i: Int, _ id: String) -> some View {
        let on = choice.selected == id
        return Button { choice.selected = id } label: {
            ZStack(alignment: .topTrailing) {
                if let img = choice.thumbs[id] {
                    Image(uiImage: img).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if on {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white, mode.color)
                        .padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card)
                .strokeBorder(on ? mode.color : Tokens.Palette.line, lineWidth: on ? 5 : 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressDimStyle())
        .accessibilityLabel("第 \(i + 1) 张")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("imageChoice.option.\(i)")
    }
}

/// 进货页商品卡上点商品图：重新选候选图、重新拍照或从相册选（S22d，Fable 方案 4；商品详情页 S25 之前先放这里）。
/// 只问一次候选（不轮询）。选好、拍好就关掉；换图走同一套暂存和重发
struct ReplaceImageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var choice: ImageChoiceModel
    /// 点了关掉 / 就用这张：之后才压好的照片不再传（不盖掉刚才的选择）
    @State private var closed = false
    let productId: UUID
    let changes: ImageChanges

    init(productId: UUID, barcode: String, changes: ImageChanges) {
        self.productId = productId
        self.changes = changes
        let m = ImageChoiceModel(barcode: barcode, changes: changes)
        m.pollLimit = .zero
        _choice = State(initialValue: m)
    }

    var body: some View {
        ImageChoiceView(choice: choice, mode: .stock, onUse: { cid in
            guard !closed else { return }
            closed = true
            changes.choose(productId: productId, barcode: choice.barcode, candidateId: cid, thumbnail: choice.bytes[cid])
            dismiss()
        }, onPhoto: { photo in
            guard !closed else { return }
            closed = true
            changes.upload(productId: productId, photo: photo)
            dismiss()
        }, onSkip: { closed = true; dismiss() }, replace: true)
        .padding(.top, 8)
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.replaceImage")
        .task { await choice.run(initial: nil) }
    }
}
