import ShopCore
import SwiftUI

/// S23a「待确认的账」：被退出的手机退出前记的账补传上来了，家里人逐笔「记上 / 不要」（§4.5）。
/// 记上后马上同步一次，这笔出现在「记的账」里；「不要」先弹 26 确认（不要了就不记，回不来）。
@MainActor @Observable
final class HeldModel {
    struct Item: Identifiable, Equatable {
        let op: HeldOp
        let text: String
        var canAccept: Bool
        var id: UUID { op.id }
        var who: String { op.deviceLabel + (op.deviceRole == .cashier ? "（收银员）" : "") + "记的" }
        /// 只能不要的原因
        var onlyDiscardReason: String? {
            guard !canAccept else { return nil }
            return op.deviceRole == .cashier && op.type != "void" && op.type != "sale_batch"
                ? "原来是收银员的手机，收银员不能做这个，只能不要"
                : "账面已经变了，这笔只能不要（要的话重新盘一次）"
        }
    }

    let backend: DeviceBackend
    let db: LocalDB
    let now: () -> Date
    /// 记上之后：马上同步一次，「记的账」里就有了
    var onAccepted: (() -> Void)?

    private(set) var items: [Item]?
    private(set) var error: String?
    private(set) var busy: Set<UUID> = []
    private(set) var flash: String?
    var confirmDiscard: Item?

    init(backend: DeviceBackend, db: LocalDB, now: @escaping () -> Date) {
        self.backend = backend
        self.db = db
        self.now = now
    }

    func load() async {
        do {
            let held = try await backend.heldOps()
            let db = db, at = now()
            // 读本机商品名不在主线程（§8 S22a 约束）；拼文字回到主线程
            let entries = await Task.detached { held.map { try? db.heldEntry($0) } }.value
            items = zip(held, entries).map { h, e in
                Item(op: h, text: e.map { PendingModel.rowText($0, now: at) } ?? h.type, canAccept: h.canAccept)
            }
            error = nil
        } catch {
            self.error = PairingModel.message(error)
        }
    }

    func accept(_ item: Item) async {
        guard !busy.contains(item.id) else { return }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        do {
            switch try await backend.resolveHeld(item.id, true) {
            case .accepted:
                remove(item.id)
                flash = "记上了，记的账里能看到"
                onAccepted?()
            case .onlyDiscard:
                if let i = items?.firstIndex(where: { $0.id == item.id }) { items?[i].canAccept = false }
            case .gone, .discarded:
                remove(item.id)
            }
        } catch {
            flash = PairingModel.message(error)
        }
    }

    func discardConfirmed() async {
        guard let item = confirmDiscard, !busy.contains(item.id) else { return }
        busy.insert(item.id)
        defer { busy.remove(item.id) }
        do {
            _ = try await backend.resolveHeld(item.id, false)
            remove(item.id)
            confirmDiscard = nil
            flash = "这笔不要了"
        } catch {
            flash = PairingModel.message(error)
        }
    }

    private func remove(_ id: UUID) { items?.removeAll { $0.id == id } }
}

struct HeldListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var held: HeldModel?

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.held.title(model.layout), pendingCount: model.figures.pendingCount,
                    offline: model.offline, onBack: { dismiss() })
            if let held {
                HeldContent(held: held)
            } else {
                OfflineNote(text: "要联网才能看")
            }
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .onAppear {
            if held == nil { held = model.makeHeldModel() }
            Task { await held?.load() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.held.pageId)
    }
}

private struct HeldContent: View {
    @Bindable var held: HeldModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("这些是被退出的手机在退出前记的账，补传上来了。看一笔定一笔：记上就算数，不要就不记。")
                    .font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if let flash = held.flash {
                    Text(flash).font(TypeScale.body.weight(.bold)).foregroundStyle(Tokens.Palette.ink)
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
                        .accessibilityIdentifier("held.flash")
                }
                if let items = held.items {
                    if items.isEmpty {
                        Text("没有要确认的账了").font(TypeScale.body).foregroundStyle(Tokens.Palette.ink)
                            .padding(.top, 20)
                            .accessibilityIdentifier("held.empty")
                    }
                    ForEach(items) { item in card(item) }
                } else if let err = held.error {
                    Text(err).font(TypeScale.body).foregroundStyle(Tokens.Palette.ink).accessibilityIdentifier("held.error")
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .refreshable { await held.load() }
        .confirmSheet(item: $held.confirmDiscard) { item in
            ConfirmPanel(title: "这笔不要了？", message: "不要了就不会记进账里，也找不回来。\n\(item.text)",
                         confirmTitle: "不要了", cancelTitle: "再想想", mode: .neutral,
                         confirmStyle: .dark, confirmImage: nil,
                         confirmId: "held.discard.confirm", cancelId: "held.discard.cancel",
                         busy: held.busy.contains(item.id),
                         onConfirm: { Task { await held.discardConfirmed() } },
                         onCancel: { held.confirmDiscard = nil })
        }
    }

    private func card(_ item: HeldModel.Item) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.who).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.ink2)
            Text(item.text).font(TypeScale.body.weight(.semibold)).foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("held.text")
            if let why = item.onlyDiscardReason {
                Text(why).font(TypeScale.secondary).foregroundStyle(Tokens.Palette.sell)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("held.onlyDiscard")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons(item) }
                VStack(spacing: 10) { buttons(item) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("held.item")
    }

    @ViewBuilder private func buttons(_ item: HeldModel.Item) -> some View {
        if item.canAccept {
            PrimaryButton("记上", style: .dark, size: .medium) { Task { await held.accept(item) } }
                .disabled(held.busy.contains(item.id))
                .accessibilityIdentifier("held.accept")
        }
        PrimaryButton("不要", style: .ghost, size: .medium) { held.confirmDiscard = item }
            .disabled(held.busy.contains(item.id))
            .accessibilityIdentifier("held.discard")
    }
}
