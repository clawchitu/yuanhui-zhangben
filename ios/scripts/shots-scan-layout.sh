#!/usr/bin/env bash
# 扫码页布局方案截图：卖出页、进货页（取景框在下、按钮在框下、内容区在上），在 大字 / 标准 / 系统最大辅助字号（大字开 / 关）下各截一张；
# 扫码登录页（S21，不受影响）截一张对照。拍完调 scripts/compare-scan-layout.py 做和设计稿的对照图（左稿右实拍）。
# 用法（在 ios/ 下）：scripts/shots-scan-layout.sh [输出目录]
# 默认新建一台 iPhone 17（和 CI 同型号）专用模拟器并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/scan-layout}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yuanhui-shots-scan-$$")
  dd=$(mktemp -d -t yuanhui-shots-scan)
  cleanup() { scripts/sim-destroy.sh "$udid"; rm -rf "$dd"; }
  trap cleanup EXIT
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array zh-Hans
  xcrun simctl spawn "$udid" defaults write -g AppleICUForce24HourTime -bool true
  xcrun simctl shutdown "$udid"
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  xcodebuild build -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben \
    -destination "id=$udid" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -quiet
  app="$dd/Build/Products/Debug-iphonesimulator/YuanhuiZhangben.app"
fi
xcrun simctl install "$udid" "$app"
xcrun simctl status_bar "$udid" override --time 19:48 --batteryState discharging --batteryLevel 90 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true
shoot() {
  local name=$1 size=$2 large=$3; shift 3
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" content_size "$size"
  xcrun simctl launch "$udid" "$bundle" -uiLargeText "$large" "$@" >/dev/null
  sleep 7   # FakeScanner：开页等 1 秒 + 每码 0.3 秒，再留出启动时间
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "截图 $out/$name.png" >&2
}
rm -f "$out"/*.png
AX=accessibility-extra-extra-extra-large
beer=6901035600016 erguotou=6901234500011 noodle=6902514300011
colaPack=6925303770020 beerPack=6901035600023
shoot_all() {
  local name=$1; shift
  shoot "$name-large"            large on  "$@"
  shoot "$name-standard"         large off "$@"
  shoot "$name-axmax-large"      $AX   on  "$@"
  shoot "$name-axmax-standard"   $AX   off "$@"
}
sell=(-uiFixture home -uiRoute sell)
stock=(-uiFixture home -uiRoute stockIn)
shoot_all sell-empty     "${sell[@]}"                                                    # 03c：空篮在上，结算条，取景框在下
shoot_all sell-two       "${sell[@]}" -uiScan "$beer,$erguotou"                          # 两行：取景框正常大小
shoot_all sell-three     "${sell[@]}" -uiScan "$beer,$beer,$beer,$beer,$erguotou,$noodle" # 03 的三样：取景框收到 16%
shoot     sell-discounted-large large on "${sell[@]}" -uiScan "$beer,$beer,$beer,$beer,$erguotou,$noodle" -uiPaid 5300  # 03b
shoot     sell-done-large  large on "${sell[@]}" -uiScan "$beer,$erguotou,$noodle" -uiAutoCommit -uiHoldDone          # 03d
shoot     sell-nocam-large large on "${sell[@]}" -uiCamera denied                                                    # 27a
shoot_all stock-empty    "${stock[@]}"                                                   # 进货空态
shoot_all stock-card     "${stock[@]}" -uiScan "$colaPack" -uiStockQty 5 -uiStockCost 48 # 商品卡 + 取景框压暗
shoot_all stock-keypad   "${stock[@]}" -uiScan "$colaPack" -uiStockQty 5 -uiStockCost 48 -uiStockField cost  # 06a：键盘出来，相机区收起
shoot     stock-expiry-large large on "${stock[@]}" -uiScan "$beerPack" -uiStockQty 3 -uiStockCost 55 -uiStockDate 2026-11-12 -uiStockMonths 6  # 06b 商品卡
shoot     stock-nocam-large  large on "${stock[@]}" -uiCamera denied
shoot     scan-login-14-large large on -uiLoginScreen scan -uiCamera authorized           # 扫码登录页：不受影响
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-scan-layout.py "$out" || echo "对照图没做成（要 Pillow）" >&2
