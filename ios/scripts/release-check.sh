#!/usr/bin/env bash
# §14 S15-4 / S15-7：验证非 Debug 构建里没有演示会话和会开出会话的夹具。
#  1. 用 Release（或 Beta）配置构建 App，查二进制里没有这些夹具参数和演示会话的字样（代码根本没编译进去）；
#  2. 在模拟器上跑 ReleaseBuildUITests：带上各种夹具参数启动，都只出登录页。
# Beta 配置同样跑一遍（§8 S21「Release 检查补 Beta」，PR #12 Fable 第二轮）：防止有人用 `#if BETA` 开夹具而检查抓不到。
# 两种配置只差 IP 那一条：Release 二进制里不许有 IP 字面量；Beta 白名单里留着 IP 回退地址（默认已是域名），必须查得到。
# 用法（在 ios/ 下）：scripts/release-check.sh [--config Release|Beta] <模拟器 UDID> [derivedData 目录] [Debug 构建的二进制，用作对照]
set -euo pipefail
cd "$(dirname "$0")/.."
config=Release
if [ "${1:-}" = "--config" ]; then config="${2:?--config 后要跟 Release 或 Beta}"; shift 2; fi
case "$config" in
  Release) scheme=YuanhuiZhangben-ReleaseCheck ;;
  Beta) scheme=YuanhuiZhangben-BetaCheck ;;
  *) echo "--config 只认 Release 或 Beta：$config" >&2; exit 2 ;;
esac
udid="${1:?需要模拟器 UDID（用 scripts/sim-create.sh 建的那台）}"
dd="${2:-$(mktemp -d -t yuanhui-release-check)}"
log="$dd/release-check-$config.log"
mkdir -p "$dd"
set -o pipefail
# 先卸掉模拟器上的 App：同一台模拟器先跑过 Debug UI 测试，库里会留下当前会话；检查用的构建没签名，读钥匙串
# 必然失败（-34018），按 PR #35 评审修 3 读失败不结束会话，会停在「手机还没准备好」而不是登录页。
# 本检查验证的是「没有会话时」的表现，从干净安装开始
xcrun simctl uninstall "$udid" cn.yuanhuishop.zhangben 2>/dev/null || true
# -collect-test-diagnostics never：不让 xcodebuild 测完再跑 `simctl diagnose`（这台 Mac 上每次卡 600 秒，D-1126-1）
xcodebuild test -project YuanhuiZhangben.xcodeproj -scheme "$scheme" \
  -destination "id=$udid" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO \
  -collect-test-diagnostics never \
  -only-testing:YuanhuiZhangbenUITests/ReleaseBuildUITests \
  | tee "$log" | grep -E "error:|Test Case|Executed|\*\* TEST" || true
grep -q "\*\* TEST SUCCEEDED \*\*" "$log" || { echo "$config 构建的 UI 检查没过" >&2; exit 1; }
# 不写死用例数：至少跑了 1 个、0 失败、无跳过（有跳过时汇总行格式不同，匹配不上），且通过的用例数与汇总一致
ran=$(grep -Eo "Executed [0-9]+ tests?, with 0 failures" "$log" | tail -1 | grep -Eo "[0-9]+" | head -1 || true)
passed=$(grep -ciE "Test Case .*ReleaseBuildUITests.* passed" "$log" || true)
{ [ "${ran:-0}" -ge 1 ] && [ "$passed" -eq "$ran" ]; } || { echo "ReleaseBuildUITests 没有真正跑（被跳过？）：汇总 ${ran:-无}，通过 $passed" >&2; exit 1; }
bin="$dd/Build/Products/$config-iphonesimulator/YuanhuiZhangben.app/YuanhuiZhangben"
[ -f "$bin" ] || { echo "找不到 $config 构建的二进制 $bin" >&2; exit 1; }
# 查二进制：只在 Debug 里编译的代码留下的字样（演示策略的分支名进反射元数据；长字符串字面量进常量区）。
# 短于 16 字节的字符串 Swift 内联进指令，查不到，所以不查 -uiRole 这类短参数名，由上面的 UI 测试管。
markers=(-uiSeedStoredAPIBase -uiResetStoredAPIBase -uiLoginLockedUntil scannerLab zhangben-demo.sqlite 5EED0000-0000-4000-8000-00000000F001 5EED0000-0000-4000-8000-00000000F002)
has() { LC_ALL=C grep -aqF -- "$2" "$1"; }
bad=0
for s in "${markers[@]}"; do
  if has "$bin" "$s"; then echo "$config 二进制里还有「$s」" >&2; bad=1; fi
done
# 对照：两种配置里都应有的字样查得到（查法有效）
has "$bin" signedOut || { echo "$config 二进制里找不到「signedOut」，查法可能失效" >&2; bad=1; }
# 对照：给了 Debug 构建的话，这些字样在 Debug 里确实都在（证明不是查法本身查不到）
if [ -n "${3:-}" ]; then
  for s in "${markers[@]}"; do
    has "$3" "$s" || { echo "Debug 构建 $3 里也找不到「$s」，查法可能失效" >&2; bad=1; }
  done
fi
# S21：Release 包里不许出现 IP 字面量（Beta / Debug 的地址写成长于 15 字节的整条地址，进常量区，所以查得到）；
# Beta 反过来必须有（IP 仍在 Beta 白名单里作回退；默认地址已改成域名），同时也证明这个查法对 IP 有效
if [ "$config" = Release ]; then
  if has "$bin" "47.117.184.253"; then echo "Release 二进制里有 IP 地址 47.117.184.253" >&2; bad=1; fi
  if [ -n "${3:-}" ]; then has "$3" "https://47.117.184.253" || { echo "Debug 构建里也找不到 IP 地址，查法可能失效" >&2; bad=1; }; fi
else
  has "$bin" "https://47.117.184.253" || { echo "Beta 二进制里找不到回退地址 https://47.117.184.253" >&2; bad=1; }
fi
[ $bad -eq 0 ] || exit 1
echo "$config 检查通过：没有演示会话和会话夹具"
