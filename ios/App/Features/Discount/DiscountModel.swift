import Foundation
import Observation
import ShopCore

/// 抹零 / 改总价面板（18）和二次确认（28）的状态。不碰界面，单元测试直接测它。
///
/// - 输入是「元」：整数部分最多 9 位，小数最多 2 位（自家键盘，没有别的字符进得来）。全程整数分，不经过浮点。
/// - 快捷键「抹到整元」「抹到整十」：原价往下取整到元 / 十元；取整后是 0 或等于原价时不可用。
/// - 「就收这么多」：实收低于原价七折、或高于原价时先出 28 问一次（§5.1，判断用 ShopCore 的
///   `Basket.needsPaidConfirmation`，和服务器同一口径）；否则直接定。实收等于原价当作「不抹了」。
/// - 超出 §5.0 实收上限的数不让定，提示用店里人看得懂的话（§14 S16-6）。
@MainActor @Observable
final class DiscountModel {
    enum Stage: Equatable {
        case input
        /// 28：低于七折 / 多收，要再问一次
        case confirm(paidFen: Int64, over: Bool)
    }

    /// 面板关掉时交给页面的结果
    enum Outcome: Equatable {
        /// 定了实收（分）
        case paid(Int64)
        /// 不抹了：恢复原价
        case restore
    }

    let basket: Basket
    let listFen: Int64
    private(set) var text: String {
        didSet { rejectMessage = nil }
    }
    /// 「就收这么多」被 ShopCore 拒了时的一句话（现在的规则下到不了；以后规则变了不会变成按了没反应的哑按钮）
    private(set) var rejectMessage: String?
    static let rejectedHint = "这个数收不了，换一个"
    private(set) var stage: Stage = .input

    static let maxIntegerDigits = 9

    init(basket: Basket) {
        self.basket = basket
        listFen = (try? basket.listTotal().raw) ?? 0
        text = basket.paidOverrideFen.map { Self.yuanText($0.raw) } ?? ""
    }

    // MARK: 读

    /// 现在输入的实收（分）；空、只有小数点时是 nil
    var paidFen: Int64? { Self.parseFen(text) }

    /// 「优惠」那一行：原价 − 实收；多收为负；没输是 nil
    var discountFen: Int64? { paidFen.map { listFen - $0 } }

    /// 超出 §5.0 实收上限时的一句话；没超是 nil
    var limitMessage: String? {
        if let rejectMessage { return rejectMessage }
        guard let p = paidFen, p > Limits.maxPaidTotalFen else { return nil }
        return "一笔最多收 ¥\(Money.yuanString(Int(Limits.maxPaidTotalFen)))"
    }

    var canSubmit: Bool { paidFen != nil && limitMessage == nil }

    /// 抹到整元（往下取整到元）
    var roundYuanFen: Int64 { listFen / 100 * 100 }
    /// 抹到整十（往下取整到十元）
    var roundTenFen: Int64 { listFen / 1000 * 1000 }

    /// 快捷键能不能按：取整后比 0 大、比原价小
    func canRound(to fen: Int64) -> Bool { fen > 0 && fen < listFen }

    /// 快捷键亮不亮（现在输入的数正好是它）
    func isSelected(_ fen: Int64) -> Bool { paidFen == fen }

    // MARK: 动作

    func key(_ k: Keypad.Key) {
        guard stage == .input else { return }
        switch k {
        case .delete:
            if !text.isEmpty { text.removeLast() }
        case .dot:
            if text.contains(".") { return }
            text = text.isEmpty ? "0." : text + "."
        case .digit(let d):
            let parts = text.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count == 2 {
                if parts[1].count >= 2 { return }
            } else if text == "0" {
                text = ""
            } else if text.count >= Self.maxIntegerDigits {
                return
            }
            text += String(d)
        }
    }

    func round(to fen: Int64) {
        guard stage == .input, canRound(to: fen) else { return }
        text = Self.yuanText(fen)
    }

    /// 「就收这么多」。返回定下来的结果；要先问一次（28）时返回 nil，`stage` 变成 `.confirm`
    func submit() -> Outcome? {
        guard stage == .input, canSubmit, let p = paidFen else { return nil }
        if p == listFen { return .restore }
        var b = basket
        do {
            try b.setPaid(Fen(p))
            if try b.needsPaidConfirmation() {
                stage = .confirm(paidFen: p, over: p > listFen)
                return nil
            }
        } catch {
            rejectMessage = Self.rejectedHint
            return nil
        }
        return .paid(p)
    }

    /// 28「没错，就收 ¥x」
    func confirm() -> Outcome? {
        guard case .confirm(let p, _) = stage else { return nil }
        return .paid(p)
    }

    /// 28「输错了，重填」：回到键盘，清掉刚才输的
    func refill() {
        stage = .input
        text = ""
    }

    // MARK: 文案（28）

    func confirmTitle(paidFen p: Int64, over: Bool) -> String {
        "原价 \(Self.yuan(listFen))，\n\(over ? "要收" : "只收") \(Self.yuan(p))？"
    }

    func confirmDetail(paidFen p: Int64, over: Bool) -> String {
        if over { return "比原价多收了 \(Self.yuan(p - listFen))，是不是多按了一位？" }
        // 「少了一大半」只在不到原价一半时说；七折到五折之间如实说「不到七折」
        if p * 2 < listFen { return "比原价少了一大半，是不是少按了一位？" }
        return "比原价少了 \(Self.yuan(listFen - p))，不到七折，是不是按错了？"
    }

    // MARK: 换算（整数，不经过浮点）

    static func yuan(_ fen: Int64) -> String { "¥" + Money.yuanString(Int(fen)) }

    /// 分 → 输入框里的字：整元不带小数（「53」），否则带两位（「53.50」）
    static func yuanText(_ fen: Int64) -> String {
        fen % 100 == 0 ? String(fen / 100) : Money.yuanString(Int(fen))
    }

    /// 输入框里的字 → 分。「53」「53.」「53.5」「53.50」「.5」都认；空或只有「.」是 nil
    static func parseFen(_ s: String) -> Int64? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2 else { return nil }
        let intPart = parts[0], frac = parts.count == 2 ? parts[1] : ""
        guard !(intPart.isEmpty && frac.isEmpty), frac.count <= 2, intPart.count <= maxIntegerDigits,
              (intPart + frac).allSatisfy(\.isASCIIDigit) else { return nil }
        let yuan = Int64(intPart) ?? 0
        let cents = Int64(frac.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        return yuan * 100 + cents
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
