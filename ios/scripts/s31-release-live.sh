#!/usr/bin/env bash
# S31 验收：Release 配置构建的 App 连 https://api.yuanhuishop.cn 走一遍 S28 剧本的精简版（S31ReleaseLiveUITests）。
# 用法（在 ios/ 下）：YH_S31_PASSWORD=$(security find-generic-password -s yuanhui-test-store -a yuanhui -w) \
#   scripts/s31-release-live.sh <模拟器 UDID> [用户名，默认 yuanhui（runbook 里旧写的 yh_test_a 已不对）] [derivedData 目录]
#   模拟器用 scripts/sim-create.sh 建的专用那台。只往线上测试店写假数据（进 2 个、卖 2 个、撤 1 行）。
# 和 release-check.sh 不同：要真登录，钥匙串要能用，所以构建要签名（模拟器上是本机 ad-hoc 签名，不用证书和描述文件）。
set -euo pipefail
cd "$(dirname "$0")/.."
udid="${1:?需要模拟器 UDID}"
user="${2:-yuanhui}"
dd="${3:-/tmp/yh-s31-dd}"
: "${YH_S31_PASSWORD:?要 YH_S31_PASSWORD（从钥匙串读，不写文件）}"
log="$dd/s31-release-live.log"
mkdir -p "$dd"
xcrun simctl uninstall "$udid" cn.yuanhuishop.zhangben 2>/dev/null || true
export TEST_RUNNER_YH_S31_USER="$user" TEST_RUNNER_YH_S31_PASSWORD="$YH_S31_PASSWORD"
[ -n "${YH_S31_BASE:-}" ] && export TEST_RUNNER_YH_S31_BASE="$YH_S31_BASE"
xcodebuild test -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben-ReleaseCheck \
  -destination "id=$udid" -derivedDataPath "$dd" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
  -collect-test-diagnostics never \
  -only-testing:YuanhuiZhangbenUITests/S31ReleaseLiveUITests \
  2>&1 | tee "$log" | grep --line-buffered -E "error:|S31 |Test Case .*(passed|failed|skipped)|Executed|\*\* TEST|XCTAssert|等不到|找不到" || true
grep -q "\*\* TEST SUCCEEDED \*\*" "$log" || { echo "S31 联调没过，日志 $log" >&2; exit 1; }
grep -qE "Test Case .*S31ReleaseLiveUITests.* passed" "$log" || { echo "S31 用例没有真正跑（被跳过？）" >&2; exit 1; }
# 跑的确实是 Release 构建：二进制里没有 IP 字面量、有域名
bin="$dd/Build/Products/Release-iphonesimulator/YuanhuiZhangben.app/YuanhuiZhangben"
LC_ALL=C grep -aqF "47.117.184.253" "$bin" && { echo "跑的二进制里有 IP，不是 Release 构建？" >&2; exit 1; }
LC_ALL=C grep -aqF "api.yuanhuishop.cn" "$bin" || { echo "跑的二进制里找不到 api.yuanhuishop.cn" >&2; exit 1; }
echo "S31 Release 连域名精简剧本通过"
