#!/usr/bin/env bash
# S18 截图：新商品登记 04a / 04b / 04c、断网 25e、整箱 05（从卖出进来朱红、从进货进来靛青），在 大字 / 标准 /
# 系统最大辅助字号（大字开 / 关）四种情况下各截一张。
# 用法（在 ios/ 下）：scripts/shots-s18.sh [输出目录]
# 默认新建一台 iPhone 13 专用模拟器并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删，24 小时制要自己先设好）。
# 拍完用 scripts/compare-s18.py 重做和设计稿的对照图（左稿右实拍）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s18}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yuanhui-shots18-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
  dd=$(mktemp -d -t yuanhui-shots18)
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
new=6924743919211 cashier=6920152400319 offline=6901028075831 cola=6925303770013 pack=6925303770099
base=(-uiFixture home -uiRoute sell)
shoot_all() {  # shoot_all <名字> <参数…>：四种字号情况各一张
  local name=$1; shift
  shoot "$name-large"            large on  "$@"
  shoot "$name-standard"         large off "$@"
  shoot "$name-axmax-large"      $AX   on  "$@"
  shoot "$name-axmax-standard"   $AX   off "$@"
}
shoot_all new-04a        "${base[@]}" -uiScan "$new" -uiNewPrice 7.5                                   # 04a
shoot_all new-04b        "${base[@]}" -uiScan "$new" -uiNewPrice 7.5 -uiNewStep2 -uiNewQty 12 -uiNewExpiry 2027-05-20 -uiNewWarn 15  # 04b 黄字 + 保质期
shoot_all new-04b-unknown "${base[@]}" -uiScan "$new" -uiNewPrice 7.5 -uiNewStep2 -uiNewQty 12 -uiNewCost 5.2 -uiNewExpiry unknown  # 「不知道，先不填」
shoot     new-04b-off-large large on "${base[@]}" -uiScan "$new" -uiNewPrice 7.5 -uiNewStep2              # 开关关着：没有到期日
shoot_all new-04c        "${base[@]}" -uiRole cashier -uiScan "$cashier" -uiNewName "白象 老母鸡汤面" -uiNewPrice 4.5  # 04c
shoot_all new-25e        "${base[@]}" -uiOffline -uiScan "$offline" -uiNewPrice 3                          # 25e
shoot_all pack-05        "${base[@]}" -uiScan "$cola,$pack" -uiNewPack -uiPackQty 24 -uiPackPrice 60      # 05（从卖出：朱红）
shoot_all pack-05-stock  "${base[@]}" -uiScan "$cola,$pack" -uiNewPack -uiPackQty 24 -uiPackPrice 60 -uiNewMode stock  # 05 从进货：靛青
shoot     new-04a-stock-large large on "${base[@]}" -uiScan "$new" -uiNewPrice 7.5 -uiNewMode stock      # 04a 从进货：靛青
shoot     new-04b-stock-large large on "${base[@]}" -uiScan "$new" -uiNewPrice 7.5 -uiNewStep2 -uiNewQty 12 -uiNewMode stock
shoot     pack-05-noprice-large large on "${base[@]}" -uiScan "$cola,$pack" -uiNewPack -uiPackQty 24      # 不填整箱价的说明
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-s18.py "$out"
