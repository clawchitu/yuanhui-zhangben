#!/usr/bin/env bash
# 关掉并删除指定 UDID 的模拟器（只处理传进来的这一台）。
set -uo pipefail
udid="${1:-}"
[ -z "$udid" ] && { echo "没有 UDID，跳过" >&2; exit 0; }
xcrun simctl shutdown "$udid" 2>/dev/null || true
xcrun simctl delete "$udid" 2>/dev/null || true
echo "已清理模拟器 $udid" >&2
