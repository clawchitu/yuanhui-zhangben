#!/usr/bin/env bash
# S22a 联调：在一台模拟器上跑 S22aLiveUITests 的某几条（先 build-for-testing 到 $DD）。
# 用法：scripts/s22a-live.sh <UDID> <base> <用户名> <测试名,…> [destructive|observer]
#   密码从环境变量 YH_LIVE_PASSWORD 读（线上测试店：YH_LIVE_PASSWORD=$(security find-generic-password -s yuanhui-test-store -w)），不写文件。
#   破坏性用例只对本机服务端（SCRAM 临时 PG，见 docs/runbook.md），先 `node scripts/s22a-seed.ts` 铺货。
set -euo pipefail
udid="$1"; base="$2"; user="$3"; tests="$4"; mode="${5:-}"
: "${YH_LIVE_PASSWORD:?要 YH_LIVE_PASSWORD}"
DD="${DD:-/tmp/yh-s22a-dd}"
only=()
IFS=',' read -ra names <<< "$tests"
for t in "${names[@]}"; do only+=("-only-testing:YuanhuiZhangbenUITests/S22aLiveUITests/$t"); done
export TEST_RUNNER_YH_LIVE_BASE="$base" TEST_RUNNER_YH_LIVE_USER="$user" TEST_RUNNER_YH_LIVE_PASSWORD="$YH_LIVE_PASSWORD"
[[ "$mode" == destructive ]] && export TEST_RUNNER_YH_S22A_DESTRUCTIVE=1
[[ "$mode" == observer ]] && export TEST_RUNNER_YH_S22A_OBSERVER=1
cd "$(dirname "$0")/.."
xcodebuild -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=$udid" -derivedDataPath "$DD" \
  -resultBundlePath "/tmp/yh-s22a-results/$(date +%s)-$udid.xcresult" test-without-building "${only[@]}" 2>&1 | grep --line-buffered -E "error:|S22A|Test Case .*(passed|failed|skipped)|Executed|\*\* TEST" || true
