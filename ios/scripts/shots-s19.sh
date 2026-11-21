#!/usr/bin/env bash
# S19 截图：进货 06a / 06b / 06c、空页、进货中登记新商品（04a 靛青、无「存好，接着卖」）、0 元确认、
# 05 底部带商品名（§14 S18-3），在 大字 / 标准 / 系统最大辅助字号（大字开 / 关）四种情况下各截一张。
# 用法（在 ios/ 下）：scripts/shots-s19.sh [输出目录]
# 默认新建一台 iPhone 13 专用模拟器并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删，24 小时制要自己先设好）。
# 拍完用 scripts/compare-s19.py 重做和设计稿的对照图（左稿右实拍）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s19}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yuanhui-shots19-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
  dd=$(mktemp -d -t yuanhui-shots19)
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
  sleep 6   # FakeScanner：开页等 1 秒 + 每码 0.3 秒（§14 S14-3 ⑫），再留出启动时间
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "截图 $out/$name.png" >&2
}
rm -f "$out"/*.png
AX=accessibility-extra-extra-extra-large
colaPack=6925303770020 carton=6901028075879 beerPack=6901035600023 erguotou=6901234500011 new=6924743919211
cola=6925303770013 pack=6925303770099
base=(-uiFixture home -uiRoute stockIn)
shoot_all() {  # shoot_all <名字> <参数…>：四种字号情况各一张
  local name=$1; shift
  shoot "$name-large"            large on  "$@"
  shoot "$name-standard"         large off "$@"
  shoot "$name-axmax-large"      $AX   on  "$@"
  shoot "$name-axmax-standard"   $AX   off "$@"
}
shoot_all stock-06a      "${base[@]}" -uiScan "$colaPack" -uiStockQty 5 -uiStockCost 48 -uiStockField cost           # 06a
shoot_all stock-06b      "${base[@]}" -uiScan "$beerPack" -uiStockQty 3 -uiStockCost 55 -uiStockDate 2026-11-12 -uiStockMonths 6 -uiStockField none  # 06b
shoot_all stock-06c      "${base[@]}" -uiScan "$beerPack" -uiStockQty 3 -uiStockCost 55 -uiStockDate 2026-11-1 -uiStockField day  # 06c
shoot_all stock-carton   "${base[@]}" -uiScan "$carton" -uiStockQty 5 -uiStockCost 400 -uiStockField none            # 5 条 × ¥400，原有 6 包
shoot     stock-empty-large large on "${base[@]}" -uiCamera denied                                                     # 还没扫
shoot     stock-direct-large large on "${base[@]}" -uiScan "$beerPack" -uiStockQty 3 -uiStockCost 55 -uiStockMode direct -uiStockDate 2027-03-01 -uiStockField none
shoot     stock-unknown-large large on "${base[@]}" -uiScan "$beerPack" -uiStockQty 3 -uiStockCost 55 -uiStockUnknown -uiStockField none
shoot     stock-saved-large large on "${base[@]}" -uiHoldDone -uiCamera denied -uiScan "$carton" -uiStockQty 5 -uiStockCost 400 -uiStockCommit
shoot     stock-zero-large  large on "${base[@]}" -uiScan "$erguotou" -uiStockQty 2 -uiStockCost 0 -uiStockCommit       # 0 元确认
shoot_all stock-new-04a  "${base[@]}" -uiScan "$new" -uiNewPrice 7.5                                                   # 进货中新商品
shoot_all pack-05        -uiFixture home -uiRoute sell -uiScan "$cola,$pack" -uiNewPack -uiPackQty 24 -uiPackPrice 60   # §14 S18-3
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-s19.py "$out"
