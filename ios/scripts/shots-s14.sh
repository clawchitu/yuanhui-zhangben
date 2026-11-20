#!/usr/bin/env bash
# S14 截图：扫码测试页（Debug 的 -uiFixture scanner / scanner-login）上的相机权限三态，27a / 27b 对照。
# 用法（在 ios/ 下）：scripts/shots-s14.sh [输出目录]
# 默认新建一台 iPhone 13 专用模拟器并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删，24 小时制要自己先设好）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s14}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yuanhui-shots14-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
  dd=$(mktemp -d -t yuanhui-shots14)
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
# shoot <文件名> <系统字号> <大字模式 on/off> <等几秒> <其余启动参数…>
shoot() {
  local name=$1 size=$2 large=$3 wait=$4; shift 4
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" content_size "$size"
  xcrun simctl launch "$udid" "$bundle" -uiLargeText "$large" "$@" >/dev/null
  sleep "$wait"
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "截图 $out/$name.png" >&2
}
rm -f "$out"/*.png
AX=accessibility-extra-extra-extra-large
shoot 27a-nocam-large     large on  3 -uiFixture scanner -uiCamera denied
shoot 27a-nocam-standard  large off 3 -uiFixture scanner -uiCamera denied
shoot 27a-nocam-axmax     $AX   on  3 -uiFixture scanner -uiCamera denied
# 相机被拒时扫码枪照常能用：FakeScanner 按扫码枪速度逐键喂三次（同码两次都算），日志里列出
shoot 27a-nocam-gun       large on  5 -uiFixture scanner -uiCamera denied \
  -uiScan 6921168509256,6921168509256,6900000000000 -uiScanSource gun -uiScanGap 0.3
shoot 27b-nocam-large     large on  3 -uiFixture scanner-login -uiCamera denied
shoot 27b-nocam-axmax     $AX   on  3 -uiFixture scanner-login -uiCamera denied
# 另外两态（模拟器没有相机，取景框里是说明文字；真机画面留 S29）
shoot state-authorized    large on  3 -uiFixture scanner -uiCamera authorized
shoot state-notdetermined large on  3 -uiFixture scanner -uiCamera notDetermined
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-s14.py "$out"
