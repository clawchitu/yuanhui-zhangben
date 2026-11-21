#!/usr/bin/env bash
# §14 S15-4 / S15-7：验证非 Debug 构建里没有演示会话和会开出会话的夹具。
#  1. 用 Release 配置构建 App，查二进制里没有这些夹具参数和演示会话的字样（代码根本没编译进去）；
#  2. 在模拟器上跑 ReleaseBuildUITests：带上各种夹具参数启动，都只出「还没登录」页。
# 用法（在 ios/ 下）：scripts/release-check.sh <模拟器 UDID> [derivedData 目录] [Debug 构建的二进制，用作对照]
set -euo pipefail
cd "$(dirname "$0")/.."
udid="${1:?需要模拟器 UDID（用 scripts/sim-create.sh 建的那台）}"
dd="${2:-$(mktemp -d -t yuanhui-release-check)}"
log="$dd/release-check.log"
mkdir -p "$dd"
set -o pipefail
xcodebuild test -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben-ReleaseCheck \
  -destination "id=$udid" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO \
  -only-testing:YuanhuiZhangbenUITests/ReleaseBuildUITests \
  | tee "$log" | grep -E "error:|Test Case|Executed|\*\* TEST" || true
grep -q "\*\* TEST SUCCEEDED \*\*" "$log" || { echo "Release 构建的 UI 检查没过" >&2; exit 1; }
# 不写死用例数：至少跑了 1 个、0 失败、无跳过（有跳过时汇总行格式不同，匹配不上），且通过的用例数与汇总一致
ran=$(grep -Eo "Executed [0-9]+ tests?, with 0 failures" "$log" | tail -1 | grep -Eo "[0-9]+" | head -1 || true)
passed=$(grep -ciE "Test Case .*ReleaseBuildUITests.* passed" "$log" || true)
{ [ "${ran:-0}" -ge 1 ] && [ "$passed" -eq "$ran" ]; } || { echo "ReleaseBuildUITests 没有真正跑（被跳过？）：汇总 ${ran:-无}，通过 $passed" >&2; exit 1; }
bin="$dd/Build/Products/Release-iphonesimulator/YuanhuiZhangben.app/YuanhuiZhangben"
[ -f "$bin" ] || { echo "找不到 Release 构建的二进制 $bin" >&2; exit 1; }
# 查二进制：只在 Debug 里编译的代码留下的字样（演示策略的分支名进反射元数据；长字符串字面量进常量区）。
# 短于 16 字节的字符串 Swift 内联进指令，查不到，所以不查 -uiRole 这类短参数名，由上面的 UI 测试管。
markers=(demoSession scannerLab zhangben-demo.sqlite 5EED0000-0000-4000-8000-00000000F001 5EED0000-0000-4000-8000-00000000F002)
has() { LC_ALL=C grep -aqF -- "$2" "$1"; }
bad=0
for s in "${markers[@]}"; do
  if has "$bin" "$s"; then echo "Release 二进制里还有「$s」" >&2; bad=1; fi
done
# 对照：Release 里应有的字样查得到（查法有效）
has "$bin" signedOut || { echo "Release 二进制里找不到「signedOut」，查法可能失效" >&2; bad=1; }
# 对照：给了 Debug 构建的话，这些字样在 Debug 里确实都在（证明不是查法本身查不到）
if [ -n "${3:-}" ]; then
  for s in "${markers[@]}"; do
    has "$3" "$s" || { echo "Debug 构建 $3 里也找不到「$s」，查法可能失效" >&2; bad=1; }
  done
fi
[ $bad -eq 0 ] || exit 1
echo "Release 检查通过：没有演示会话和会话夹具"
