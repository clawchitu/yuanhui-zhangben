#!/usr/bin/env bash
# S16 截图：卖出页 03 / 03b / 03c / 03d / 24b / 27a 和长名商品，在 大字 / 标准 / 系统最大辅助字号（大字开 / 关）
# 四种情况下各截一张；最大辅助字号下购物篮页再截一张滚到底的。
# 用法（在 ios/ 下）：scripts/shots-s16.sh [输出目录]
# 默认新建一台 iPhone 13 专用模拟器并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删，24 小时制要自己先设好）。
# 拍完用 scripts/compare-s16.py 重做和设计稿的对照图（左稿右实拍）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s16}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yuanhui-shots16-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
  dd=$(mktemp -d -t yuanhui-shots16)
  cleanup() { scripts/sim-destroy.sh "$udid"; rm -rf "$dd"; }
  trap cleanup EXIT
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b >/dev/null
  # 状态栏按 24 小时制显示 19:48（和稿子一样）；改完要重启一次才生效
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
# shoot <文件名> <系统字号> <大字模式 on/off> <其余启动参数…>
shoot() {
  local name=$1 size=$2 large=$3; shift 3
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" content_size "$size"
  xcrun simctl launch "$udid" "$bundle" -uiLargeText "$large" "$@" >/dev/null
  sleep 4
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "截图 $out/$name.png" >&2
}
rm -f "$out"/*.png
AX=accessibility-extra-extra-extra-large
# 稿子 03 的购物篮：青岛啤酒 4 罐、牛栏山 1 瓶，最后扫康师傅（价签里）；事先记好 2 笔 →「2 笔待传」
beer=6901035600016 erguotou=6901234500011 noodle=6902514300011 long=6900000000017
design="$beer,$beer,$beer,$beer,$erguotou,$noodle"
base=(-uiFixture home -uiRoute sell -uiPriorSales 2)
shoot_all() {  # shoot_all <名字> <参数…>：四种字号情况各一张
  local name=$1; shift
  shoot "$name-large"            large on  "$@"
  shoot "$name-standard"         large off "$@"
  shoot "$name-axmax-large"      $AX   on  "$@"
  shoot "$name-axmax-standard"   $AX   off "$@"
}
shoot_all sell-basket     "${base[@]}" -uiScan "$design"                                     # 03 / 24b
shoot_all sell-discounted "${base[@]}" -uiScan "$design" -uiPaid 5300                        # 03b
shoot_all sell-empty      "${base[@]}"                                                       # 03c
shoot_all sell-done       "${base[@]}" -uiScan "$design" -uiPaid 5300 -uiAutoCommit -uiHoldDone  # 03d
shoot_all sell-nocam      "${base[@]}" -uiCamera denied                                      # 27a
shoot_all sell-long       "${base[@]}" -uiLongName -uiScan "$long,$long,$long,$erguotou"     # 长名在下面的行里
shoot_all sell-long-tag   "${base[@]}" -uiLongName -uiScan "$erguotou,$long,$long,$long"     # 长名在价签里
shoot sell-basket-cashier-large large on "${base[@]}" -uiRole cashier -uiScan "$design"     # 收银员同一页
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-s16.py "$out"
