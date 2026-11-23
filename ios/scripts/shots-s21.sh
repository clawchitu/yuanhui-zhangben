#!/usr/bin/env bash
# S21 截图：13 登录页（记住了用户名）、25c 锁定、14 扫码登录、27b 没打开相机、整屏「请更新」，
# 13 / 25c 在 大字 / 标准 / 系统最大辅助字号（大字开 / 关）四种情况下各截一张，其余大字一张。
# 用法（在 ios/ 下）：scripts/shots-s21.sh [输出目录]
# 默认新建一台 iPhone 13 专用模拟器（名字 yh-s21-shots-*）并在结束后删掉；设了 SHOTS_UDID + SHOTS_APP 就用现成的（不删）。
# 每次启动都带 -uiAPIBase http://127.0.0.1:9（没人监听的端口）：不碰本机 8787 上可能跑着的别的服务，
# 页面上的内容只来自夹具参数。拍完用 scripts/compare-s21.py 重做和设计稿的对照图（左稿右实拍）。
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s21}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
if [ -n "${SHOTS_UDID:-}" ] && [ -n "${SHOTS_APP:-}" ]; then
  udid=$SHOTS_UDID; app=$SHOTS_APP
else
  xcodegen generate >/dev/null
  udid=$(scripts/sim-create.sh "yh-s21-shots-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
  dd=$(mktemp -d -t yuanhui-shots21)
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
# shoot <文件名> <系统字号> <大字模式 on/off> <其余启动参数…>
shoot() {
  local name=$1 size=$2 large=$3; shift 3
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" content_size "$size"
  xcrun simctl launch "$udid" "$bundle" -uiAPIBase http://127.0.0.1:9 -uiFreshInstall -uiResetStoredAPIBase \
    -uiLargeText "$large" "$@" >/dev/null
  sleep 5
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "截图 $out/$name.png" >&2
}
rm -f "$out"/*.png
AX=accessibility-extra-extra-extra-large
shoot_all() {  # shoot_all <名字> <参数…>：四种字号情况各一张
  local name=$1; shift
  shoot "$name-large"            large on  "$@"
  shoot "$name-standard"         large off "$@"
  shoot "$name-axmax-large"      $AX   on  "$@"
  shoot "$name-axmax-standard"   $AX   off "$@"
}
login=(-uiLoginUser yuanhui -uiLoginPassword 123456789)
shoot_all login-13        "${login[@]}"                                               # 13 登录页
shoot_all login-25c       "${login[@]}" -uiLoginLockedUntil 2026-11-19T12:03:00Z      # 25c 锁到 20:03
shoot     scan-14-large        large on -uiLoginScreen scan -uiCamera authorized      # 14 扫码登录
shoot     scan-27b-large       large on -uiLoginScreen scan -uiCamera denied          # 27b 没打开相机
shoot     scan-27b-axmax-large $AX   on -uiLoginScreen scan -uiCamera denied
shoot     update-required-large large on -uiRequireUpdate                             # 请更新
xcrun simctl ui "$udid" content_size large
/usr/bin/python3 scripts/compare-s21.py "$out"
