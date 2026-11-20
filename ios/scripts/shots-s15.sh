#!/usr/bin/env bash
# S15 截图：首页（01 / 02 / 24a / 25a）、首次进入（16 / 16b）、设置（21a / 21b），
# 在 大字 / 标准 / 系统最大辅助字号（大字开 / 关）四种情况下各截一张；最大辅助字号下首页再截一张滚到底的。
# 用法（在 ios/ 下）：scripts/shots-s15.sh [输出目录]
# 默认新建一台 iPhone 13 专用模拟器并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删，24 小时制要自己先设好）。
# 拍完用 scripts/compare-s15.py 重做和设计稿的对照图（左稿右实拍）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s15}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yuanhui-shots15-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
  dd=$(mktemp -d -t yuanhui-shots15)
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
  sleep 3
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "截图 $out/$name.png" >&2
}
rm -f "$out"/*.png
AX=accessibility-extra-extra-extra-large
for screen in "home family" "home cashier" "home-unsynced family" "home-unsynced cashier" \
              "onboarding family" "onboarding cashier" "settings family" "settings cashier"; do
  set -- $screen
  fx=$1 role=$2 base="$1-$2"
  shoot "$base-large"    large on  -uiFixture "$fx" -uiRole "$role"   # 大字模式（默认），系统默认字号
  shoot "$base-standard" large off -uiFixture "$fx" -uiRole "$role"   # 标准，系统默认字号
  shoot "$base-axmax-large"    $AX on  -uiFixture "$fx" -uiRole "$role"   # 系统最大辅助字号 + 大字（封顶 accessibility2）
  shoot "$base-axmax-standard" $AX off -uiFixture "$fx" -uiRole "$role"   # 系统最大辅助字号 + 标准（同样封顶，S11-1）
  case $fx in home*)
    shoot "$base-axmax-large-bottom"    $AX on  -uiFixture "$fx" -uiRole "$role" -uiScrollTo bottom
    shoot "$base-axmax-standard-bottom" $AX off -uiFixture "$fx" -uiRole "$role" -uiScrollTo bottom ;;
  esac
done
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-s15.py "$out"
