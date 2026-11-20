#!/usr/bin/env bash
# make shots：新建一台 iPhone 13（390×844）专用模拟器，用 -uiFixture 打开组件陈列页，
# 在 大字 / 标准 / 系统最大辅助字号 下截图，结束后只关、只删这台模拟器。
# 用法：scripts/shots.sh [输出目录]   （在 ios/ 下运行）
set -euo pipefail
cd "$(dirname "$0")/.."
out="${1:-../docs/screenshots/s11}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
bundle=cn.yuanhuishop.zhangben
xcodegen generate >/dev/null
udid=$(scripts/sim-create.sh "yuanhui-shots-$$" com.apple.CoreSimulator.SimDeviceType.iPhone-13)
dd=$(mktemp -d -t yuanhui-shots)
cleanup() { scripts/sim-destroy.sh "$udid"; rm -rf "$dd"; }
trap cleanup EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
xcodebuild build -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben \
  -destination "id=$udid" -derivedDataPath "$dd" CODE_SIGNING_ALLOWED=NO -quiet
xcrun simctl install "$udid" "$dd/Build/Products/Debug-iphonesimulator/YuanhuiZhangben.app"
xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
  --cellularMode active --cellularBars 4 --wifiBars 3 || true
# shoot <文件名> <系统字号> <大字模式 on/off> <页>
shoot() {
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl ui "$udid" content_size "$2"
  xcrun simctl launch "$udid" "$bundle" -uiFixture "gallery-$4" -uiLargeText "$3" >/dev/null
  sleep 3
  xcrun simctl io "$udid" screenshot "$out/$1-p$4.png" >/dev/null 2>&1
  echo "截图 $out/$1-p$4.png" >&2
}
for p in 1 2; do
  shoot large-mode        large                                 on  "$p"   # 大字模式（默认开），系统默认字号
  shoot standard          large                                 off "$p"   # 标准：大字模式关，跟随系统默认字号
  shoot ax-max-large-mode accessibility-extra-extra-extra-large on  "$p"   # 系统最大辅助字号 + 大字模式（封顶 accessibility2）
  shoot ax-max-standard   accessibility-extra-extra-extra-large off "$p"   # 系统最大辅助字号 + 大字模式关（不封顶）
done
