import ShopCore
import SwiftUI

/// 「待传的账」（首页顶栏的同步状态、首页 25a 提醒条点进来；Fable 裁定 3）：推入新页面，有返回钮。
/// 顶上一句为什么没传上去（按优先级）、小字、「再传一次」；下面最多 20 笔，超出的写「还有 N 笔…」；
/// 恢复队列只给笔数；今天没记上的给一个去记的账的入口。面板开着时跟着自动同步刷新，传完的行消失；
/// 全部传完写「都传上去了」，不自动关页面。
struct PendingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    @State private var model: PendingModel

    init(db: LocalDB, clock: @escaping () -> Date) {
        _model = State(initialValue: PendingModel(db: db, clock: clock))
    }

    private var reason: PendingReason {
        #if DEBUG
        if let r = app.pendingReasonFixture { return r }
        #endif
        return .from(deleting: app.sync?.status?.deletePendingUntil != nil, failure: app.sync?.lastFailure, offline: app.offline)
    }

    private var retrying: Bool { app.sync?.retrying ?? model.localRetrying }

    /// 同步跑完一趟、或本机待传数变了，就重读
    private var refreshKey: String { "\(app.sync?.rounds ?? 0)-\(app.livePendingCount)" }

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(title: Route.pending.title(app.layout), onBack: { dismiss() })
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let o = model.overview { content(o) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Tokens.Palette.paper.ignoresSafeArea())
        .task(id: refreshKey) { await model.reload() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(Route.pending.pageId)
    }

    @ViewBuilder private func content(_ o: PendingOverview) -> some View {
        if o.total == 0 {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "checkmark.circle").font(.system(size: 30, weight: .semibold)).accessibilityHidden(true)
                Text(PendingModel.doneText).font(TypeScale.title).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(Tokens.Palette.ink)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("pending.done")
        } else {
            let r = reason
            Text(r.headline(count: o.total))
                .font(TypeScale.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pending.headline")
            if r.showsFootnote {
                Text(PendingReason.footnote)
                    .font(TypeScale.secondary)
                    .foregroundStyle(Tokens.Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pending.footnote")
            }
            if r.allowsRetry {
                PrimaryButton(retrying ? "正在传…" : "再传一次", systemImage: retrying ? nil : "arrow.clockwise",
                              style: .ghost, size: .medium) {
                    Task { await model.retry(sync: app.sync) }
                }
                .disabled(retrying)
                .accessibilityIdentifier("pending.retry")
            }
            if o.recoveryCount > 0 {
                note(PendingModel.recoveryText(o.recoveryCount), id: "pending.recovery")
            }
            ForEach(o.entries) { e in row(e) }
            if o.moreCount > 0 {
                note(PendingModel.moreText(o.moreCount), id: "pending.more")
            }
        }
        if o.rejectedToday > 0 {
            NavigationLink(value: Route.records) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 22, weight: .semibold))
                    Text(PendingModel.rejectedText(o.rejectedToday))
                        .font(TypeScale.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 20, weight: .semibold))
                }
                .foregroundStyle(Tokens.Palette.ink)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .frame(minHeight: 60)
                .background(Tokens.Palette.tagTint, in: RoundedRectangle(cornerRadius: Tokens.Radius.banner))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.banner).strokeBorder(Tokens.Palette.ink, lineWidth: 2.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDimStyle())
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
            .accessibilityIdentifier("pending.rejected")
        }
    }

    private func row(_ e: PendingEntry) -> some View {
        Text(PendingModel.rowText(e, now: model.now))
            .font(TypeScale.body)
            .foregroundStyle(Tokens.Palette.ink)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tokens.Palette.card, in: RoundedRectangle(cornerRadius: Tokens.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.card).strokeBorder(Tokens.Palette.line, lineWidth: 1.5))
            .accessibilityIdentifier("pending.row")
    }

    private func note(_ text: String, id: String) -> some View {
        Text(text)
            .font(TypeScale.secondary)
            .foregroundStyle(Tokens.Palette.ink2)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }
}
