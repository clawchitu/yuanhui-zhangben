#!/usr/bin/env bash
# S20 截图：记的账 07a（家用）、07b（收银员）、07c 更早、点开的一天、08 撤销、撤过一行 / 整笔撤后的卡、
# 家用首页「刚记的」与看账页入口、T30 进货日子提醒，在 大字 / 标准 / 系统最大辅助字号（大字开 / 关）四种情况下各截一张。
# 用法（在 ios/ 下）：scripts/shots-s20.sh [输出目录]
# 默认新建一台 iPhone 13 专用模拟器并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删，24 小时制要自己先设好）。
# 拍完用 scripts/compare-s20.py 重做和设计稿的对照图（左稿右实拍）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s20}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yuanhui-shots20-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
  dd=$(mktemp -d -t yuanhui-shots20)
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
  sleep 5
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "截图 $out/$name.png" >&2
}
rm -f "$out"/*.png
AX=accessibility-extra-extra-extra-large
beerPack=6901035600023
fam=(-uiFixture home -uiRecords)
cash=(-uiFixture home -uiRole cashier -uiRecords)
shoot_all() {  # shoot_all <名字> <参数…>：四种字号情况各一张
  local name=$1; shift
  shoot "$name-large"            large on  "$@"
  shoot "$name-standard"         large off "$@"
  shoot "$name-axmax-large"      $AX   on  "$@"
  shoot "$name-axmax-standard"   $AX   off "$@"
}
shoot_all records-07a      "${fam[@]}" -uiRoute records                                   # 07a 今天
shoot_all records-07b      "${cash[@]}" -uiRoute records                                  # 07b 收银员
shoot_all records-07c      "${fam[@]}" -uiRoute records -uiRecordsTab earlier             # 07c 更早
shoot_all undo-08          "${fam[@]}" -uiRoute undoLast                                  # 08（首页「记错了」进来）
shoot_all undo-08-cashier  "${cash[@]}" -uiRoute undoLast
shoot_all home-recent      "${fam[@]}" -uiScrollTo bottom                                 # 首页「刚记的」来自真数据
shoot     records-yesterday-large large on "${fam[@]}" -uiRoute records -uiRecordsTab yesterday
shoot     records-day-large       large on "${fam[@]}" -uiRoute records -uiRecordsTab earlier -uiRecordsDay 0
shoot     reports-link-large      large on -uiFixture home -uiRecords none -uiRoute reports    # 没有流水时从看账进
shoot     t30-direct-large  large on -uiFixture home -uiRoute stockIn -uiScan "$beerPack" -uiStockQty 3 -uiStockCost 55 -uiStockMode direct -uiStockDate 2026-03-01 -uiStockCommit
shoot     t30-produced-large large on -uiFixture home -uiRoute stockIn -uiScan "$beerPack" -uiStockQty 3 -uiStockCost 55 -uiStockDate 2027-11-12 -uiStockMonths 6 -uiStockCommit
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-s20.py "$out"
