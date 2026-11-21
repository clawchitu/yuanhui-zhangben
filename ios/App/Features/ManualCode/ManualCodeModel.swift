import Foundation
import Observation
import ShopCore

/// 手输条码（15）和按名称找（15b）的状态。卖出、进货、盘点共用：选中后交出一个条码，由页面走 `ScanHub.receive(_, from: .manual)`
/// （和相机、扫码枪同一条路，同一个字符规则，§14 S14-5）。
///
/// 输条码：自家数字键盘；接着扫码枪 / 蓝牙键盘时按键也进这里（数字和字母，大小写原样），扫码枪扫完带回车且只有一个候选时直接选它加进去。
/// 满 8 位起按 §5.5 列候选：只剩一个才自动选中，绝不自动选第一个；没选中时主按钮置灰。
/// 按名称找：系统键盘（拼音 / 手写），结果行只有名称、单位和卖价，不带库存（收银员也一样）。
@MainActor @Observable
final class ManualCodeModel {
    enum Tab: String, CaseIterable { case code, name }

    let db: LocalDB
    var tab: Tab = .code {
        didSet { if tab != oldValue { selected = nil; hint = nil } }
    }
    private(set) var input = ""
    var query = "" {
        didSet { if query != oldValue { refreshName() } }
    }
    private(set) var match: BarcodeMatch.Result = .notListed
    private(set) var nameResults: [PackConversion] = []
    /// 选中的那一个（交出去的就是它的代表条码）
    private(set) var selected: PackConversion?
    /// 输入框下面的红字提示（「条码只能是数字和字母」）；nil = 显示平常的说明
    private(set) var hint: String?

    static let invalidCharacterHint = "条码只能是数字和字母"

    init(db: LocalDB) { self.db = db }

    // MARK: 读

    var candidates: [BarcodeMatch.Candidate] { match.shown }
    var canPick: Bool { selected != nil }

    /// 输条码时输入框下面那句话
    var codeHint: String {
        if let hint { return hint }
        if input.count < BarcodeMatch.minPrefixLength { return "输满 \(BarcodeMatch.minPrefixLength) 位就列出来，点对的那个" }
        if match.candidates.isEmpty { return "本机没有这个码开头的商品" }
        if match.moreCount > 0 { return "还有 \(match.moreCount) 个，接着输" }
        return "输几位就列出来，点对的那个"
    }

    func isSelected(_ c: PackConversion) -> Bool { selected == c }

    // MARK: 输条码

    func key(_ k: Keypad.Key) {
        switch k {
        case .digit(let d): append(Character(String(d)))
        case .delete: delete()
        case .dot: break
        }
    }

    /// 硬件键盘 / 扫码枪的一个按键（输条码页上）。返回扫码枪扫完回车后该交出去的码（只剩一个候选时）
    func hardwareKey(_ k: HIDScanParser.Key) -> String? {
        switch k {
        case .character(let c) where c == "\u{8}" || c == "\u{7F}":
            delete()
        case .character(let c):
            if HIDScanParser.isCodeCharacter(c) { append(c) } else { hint = Self.invalidCharacterHint }
        case .enter:
            return pick()
        case .other, .ignored:
            break
        }
        return nil
    }

    /// 一次交进来一整串（粘贴、测试）。含数字、字母以外的字符整串不收，出提示（§14 S14-5）
    func type(_ s: String) {
        guard ScanHub.isAcceptable(s) else { hint = Self.invalidCharacterHint; return }
        s.forEach(append)
    }

    private func append(_ c: Character) {
        guard input.count < Limits.maxBarcodeLength else { return }
        hint = nil
        input.append(c)
        refreshCode()
    }

    private func delete() {
        hint = nil
        guard !input.isEmpty else { return }
        input.removeLast()
        refreshCode()
    }

    private func refreshCode() {
        match = (try? db.prefixMatch(input)) ?? .notListed
        selected = match.autoSelect?.conversion
    }

    // MARK: 按名称找

    private func refreshName() {
        nameResults = (try? db.searchByName(query, limit: 20)) ?? []
        if let s = selected, !nameResults.contains(s) { selected = nil }
    }

    // MARK: 选

    func select(_ c: PackConversion) {
        selected = c
    }

    /// 「就是它，加进去」：交出选中那一个的代表条码；没选中是 nil（按钮本来也是灰的）
    func pick() -> String? {
        guard let s = selected else { return nil }
        return s.barcode.barcode
    }
}
