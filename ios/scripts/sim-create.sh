#!/usr/bin/env bash
# 新建一台本次运行专用的模拟器，只在 stdout 打印它的 UDID。
# 用法：scripts/sim-create.sh <名字> [设备型号ID]
# 规则（CLAUDE.md）：只关、只删自己建的这台 UDID；绝不 shutdown all，不碰 shuai-* 模拟器。
set -euo pipefail
name="${1:?需要模拟器名字}"
devtype="${2:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"
# 从新到旧试每个可用的 iOS 运行时（本机 iOS 27.1 运行时目前建不了设备，会自动退到 27.0）
runtimes=$(xcrun simctl list runtimes -j | /usr/bin/python3 -c '
import json,sys
rs=[r for r in json.load(sys.stdin)["runtimes"] if r.get("platform")=="iOS" and r.get("isAvailable")]
rs.sort(key=lambda r:[int(x) for x in r["version"].split(".")], reverse=True)
print("\n".join(r["identifier"] for r in rs))')
for rt in $runtimes; do
  if udid=$(xcrun simctl create "$name" "$devtype" "$rt" 2>/dev/null); then
    echo "用运行时 $rt 建了 $name ($udid)" >&2
    echo "$udid"
    exit 0
  fi
done
echo "没有能用的 iOS 运行时建 $devtype" >&2
exit 1
