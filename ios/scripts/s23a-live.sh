#!/usr/bin/env bash
# S23a 联调：在一台模拟器上跑 S23aLiveUITests（先 build-for-testing 到 $DD），只对本机服务端。
# 用法：scripts/s23a-live.sh <UDID> <base> <用户名> [测试名,…]
#   密码从环境变量 YH_LIVE_PASSWORD 读，不写文件。测试进程自己以另外几台手机的身份走 API（出码、兑码、补传）。
set -euo pipefail
udid="$1"; base="$2"; user="$3"; tests="${4:-}"
: "${YH_LIVE_PASSWORD:?要 YH_LIVE_PASSWORD}"
DD="${DD:-/tmp/yh-s23a-dd}"
OUT="${OUT:-/tmp/yh-s23a-results}"
mkdir -p "$OUT"
xcrun simctl uninstall "$udid" cn.yuanhuishop.zhangben 2>/dev/null || true
only=()
if [[ -n "$tests" ]]; then
  IFS=',' read -ra names <<< "$tests"
  for t in "${names[@]}"; do only+=("-only-testing:YuanhuiZhangbenUITests/S23aLiveUITests/$t"); done
else
  only=("-only-testing:YuanhuiZhangbenUITests/S23aLiveUITests")
fi
export TEST_RUNNER_YH_LIVE_BASE="$base" TEST_RUNNER_YH_LIVE_USER="$user" TEST_RUNNER_YH_LIVE_PASSWORD="$YH_LIVE_PASSWORD"
cd "$(dirname "$0")/.."
log="$OUT/live-$(date +%s)-$udid.log"
xcodebuild -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=$udid" -derivedDataPath "$DD" \
  -resultBundlePath "$OUT/$(date +%s)-$udid.xcresult" test-without-building "${only[@]}" > "$log" 2>&1 || true
grep -E "error:|S23A-LIVE|Test Case .*(passed|failed|skipped)|Executed|\*\* TEST" "$log" || true
