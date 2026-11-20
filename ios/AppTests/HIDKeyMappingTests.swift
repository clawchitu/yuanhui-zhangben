import UIKit
import XCTest
@testable import YuanhuiZhangben

/// 扫码枪按键 → 解析器按键的映射（`HIDKeyCaptureView.key(keyCode:characters:modifierFlags:)`，即 `UIKey` 的三个字段）。
/// §14 S14-4 / PR #17 审核：纯修饰键忽略不清空；带 Control / Command / Option 的回车不提交、并让当前整串作废；
/// 大写字母完整保留；真正非法的字符让整串作废。
final class HIDKeyMappingTests: XCTestCase {
    typealias Usage = UIKeyboardHIDUsage

    /// 一次 HID 按下事件（UIKey 的三个字段 + 时间）
    struct Press {
        let code: Usage
        let chars: String
        var flags: UIKeyModifierFlags = []
    }

    private func map(_ p: Press) -> HIDScanParser.Key {
        HIDKeyCaptureView.key(keyCode: p.code, characters: p.chars, modifierFlags: p.flags)
    }

    private static let letterUsage: [Character: Usage] = [
        "A": .keyboardA, "B": .keyboardB, "C": .keyboardC, "X": .keyboardX,
    ]
    private static let digitUsage: [Character: Usage] = [
        "1": .keyboard1, "2": .keyboard2, "3": .keyboard3, "4": .keyboard4, "5": .keyboard5,
        "6": .keyboard6, "7": .keyboard7, "8": .keyboard8, "9": .keyboard9, "0": .keyboard0,
    ]

    /// 扫码枪「打」一个码时的真实按键序列：大写字母前先单独按下 Shift（characters 为空），字母本身带 .shift
    private func gunPresses(_ code: String, enter: Press = Press(code: .keyboardReturnOrEnter, chars: "\r")) -> [Press] {
        var out: [Press] = []
        for c in code {
            if let u = Self.letterUsage[c] {
                out.append(Press(code: .keyboardLeftShift, chars: "", flags: .shift))
                out.append(Press(code: u, chars: String(c), flags: .shift))
            } else if let u = Self.digitUsage[c] {
                out.append(Press(code: u, chars: String(c)))
            } else if c == "-" {
                out.append(Press(code: .keyboardHyphen, chars: "-"))
            } else {
                XCTFail("测试里没配 \(c) 的键码")
            }
        }
        out.append(enter)
        return out
    }

    /// 把按键序列经映射喂给解析器（每键 5 ms），返回凑出的扫码
    private func run(_ presses: [Press], into p: inout HIDScanParser, from start: TimeInterval = 100) -> [String] {
        var t = start
        var out: [String] = []
        for press in presses {
            if let s = p.feed(map(press), at: t) { out.append(s) }
            t += 0.005
        }
        return out
    }

    // MARK: 单个按键

    func testPureModifierKeysAreIgnored() {
        for u in [Usage.keyboardLeftShift, .keyboardRightShift, .keyboardLeftControl, .keyboardRightControl,
                  .keyboardLeftAlt, .keyboardRightAlt, .keyboardLeftGUI, .keyboardRightGUI, .keyboardCapsLock] {
            XCTAssertEqual(map(Press(code: u, chars: "")), .ignored, "\(u.rawValue)")
            XCTAssertEqual(map(Press(code: u, chars: "", flags: [.shift, .control])), .ignored, "\(u.rawValue) 带修饰标志")
        }
    }

    func testCharactersAndShiftedCapitalLetters() {
        XCTAssertEqual(map(Press(code: .keyboard6, chars: "6")), .character("6"))
        XCTAssertEqual(map(Press(code: .keypad6, chars: "6", flags: .numericPad)), .character("6"))
        XCTAssertEqual(map(Press(code: .keyboardA, chars: "A", flags: .shift)), .character("A"))
        XCTAssertEqual(map(Press(code: .keyboardA, chars: "A", flags: .alphaShift)), .character("A"))
        XCTAssertEqual(map(Press(code: .keyboardA, chars: "a")), .character("a"))
    }

    func testPlainReturnAndKeypadEnterSubmit() {
        XCTAssertEqual(map(Press(code: .keyboardReturnOrEnter, chars: "\r")), .enter)
        XCTAssertEqual(map(Press(code: .keypadEnter, chars: "\r", flags: .numericPad)), .enter)
        XCTAssertEqual(map(Press(code: .keyboardReturnOrEnter, chars: "\r", flags: .shift)), .enter, "Shift 不算快捷键")
    }

    /// 修饰键先于回车检查：带 Control / Command / Option 的回车（含小键盘回车）不提交，当作非法键
    func testReturnWithControlCommandOrOptionIsNotEnter() {
        for flags: UIKeyModifierFlags in [.control, .command, .alternate, [.shift, .command]] {
            XCTAssertEqual(map(Press(code: .keyboardReturnOrEnter, chars: "\r", flags: flags)), .other, "\(flags.rawValue)")
            XCTAssertEqual(map(Press(code: .keypadEnter, chars: "\r", flags: flags.union(.numericPad))), .other,
                           "小键盘 \(flags.rawValue)")
        }
    }

    func testShortcutsAndNonCharacterKeysAreInvalid() {
        XCTAssertEqual(map(Press(code: .keyboardV, chars: "v", flags: .command)), .other)
        XCTAssertEqual(map(Press(code: .keyboard6, chars: "6", flags: .control)), .other)
        XCTAssertEqual(map(Press(code: .keyboard6, chars: "§", flags: .alternate)), .other)
        XCTAssertEqual(map(Press(code: .keyboardRightArrow, chars: "")), .other)
        XCTAssertEqual(map(Press(code: .keyboardTab, chars: "\t")), .character("\t"), "Tab 是字符，交给解析器判非法")
    }

    // MARK: 经映射到解析器的整串

    /// Fable：Shift 单独按下不能清空缓冲，否则 AB12345678 会被交成 12345678
    func testCapitalLettersWithSeparateShiftPressesStayWhole() {
        var p = HIDScanParser()
        XCTAssertEqual(run(gunPresses("AB12345678"), into: &p), ["AB12345678"])
        XCTAssertEqual(run(gunPresses("6921168509256"), into: &p, from: 200), ["6921168509256"])
    }

    /// Codex：ABC-6921168509256 不能被截成 6921168509256 交出去
    func testInvalidCharacterVoidsTheWholeScanEvenWithALongValidTail() {
        var p = HIDScanParser()
        XCTAssertEqual(run(gunPresses("ABC-6921168509256"), into: &p), [])
        // 下一次正常扫码照收
        XCTAssertEqual(run(gunPresses("6921168509256"), into: &p, from: 200), ["6921168509256"])
    }

    /// Codex：带修饰键的回车不提交已有缓冲，且当前整串作废（后面紧跟的普通回车也不出码）
    func testModifiedReturnDoesNotSubmitAndVoidsTheBuffer() {
        for flags: UIKeyModifierFlags in [.control, .command, .alternate] {
            for code in [Usage.keyboardReturnOrEnter, .keypadEnter] {
                var p = HIDScanParser()
                let presses = gunPresses("6921168509256", enter: Press(code: code, chars: "\r", flags: flags))
                    + [Press(code: .keyboardReturnOrEnter, chars: "\r")]
                XCTAssertEqual(run(presses, into: &p), [], "\(flags.rawValue) + \(code.rawValue)")
            }
        }
    }

    /// 修饰键单独按下夹在字符之间（Shift、Control 按下又松开）不影响这次扫码
    func testModifierPressesBetweenCharactersAreTransparent() {
        var p = HIDScanParser()
        var presses = gunPresses("6921168509256")
        presses.insert(Press(code: .keyboardLeftControl, chars: "", flags: .control), at: 4)
        presses.insert(Press(code: .keyboardRightShift, chars: "", flags: .shift), at: 8)
        XCTAssertEqual(run(presses, into: &p), ["6921168509256"])
    }
}
