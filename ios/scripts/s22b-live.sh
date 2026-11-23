#!/usr/bin/env bash
# S22b 联调：在一台模拟器上跑 S22bLiveUITests（先 build-for-testing 到 $DD），只对本机服务端。
# 用法：scripts/s22b-live.sh <UDID> <base> <用户名> <审核号> [测试名,…]
#   密码从环境变量 YH_LIVE_PASSWORD 读，不写文件；PG 连接从 YH_PG_URL（TCP，SCRAM 临时库）读，口令走 PGPASSWORD。
#   要动数据库的两步看信号文件（/tmp/yh-s22b-signal）：demo-reset（把演示店设备标成 demo_reset 撤销）、
#   backup（pg_dump）、restore（停服务器 → 删库重建 → pg_restore → 全部店换 epoch → 起服务器）。
#   服务器由 YH_SERVER_START（起服务器的命令，后台运行并把进程号写到 YH_SERVER_PID 文件）控制。
set -euo pipefail
udid="$1"; base="$2"; user="$3"; demo="$4"; tests="${5:-}"
: "${YH_LIVE_PASSWORD:?要 YH_LIVE_PASSWORD}" "${YH_PG_URL:?要 YH_PG_URL}" "${YH_SERVER_START:?要 YH_SERVER_START}" "${YH_SERVER_PID:?要 YH_SERVER_PID}"
DD="${DD:-/tmp/yh-s22b-dd}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@16/bin}"
SIG=/tmp/yh-s22b-signal
rm -rf "$SIG"; mkdir -p "$SIG"
# 从干净的安装开始（只动这台模拟器上的本 App）
xcrun simctl uninstall "$udid" cn.yuanhuishop.zhangben 2>/dev/null || true
only=()
if [[ -n "$tests" ]]; then
  IFS=',' read -ra names <<< "$tests"
  for t in "${names[@]}"; do only+=("-only-testing:YuanhuiZhangbenUITests/S22bLiveUITests/$t"); done
else
  only=("-only-testing:YuanhuiZhangbenUITests/S22bLiveUITests")
fi
psql() { "$PGBIN/psql" "$YH_PG_URL" -qAt -v ON_ERROR_STOP=1 "$@"; }
dbname=$(python3 -c 'import sys,urllib.parse as u; print(u.urlparse(sys.argv[1]).path.lstrip("/"))' "$YH_PG_URL")
admin_url="${YH_PG_URL%/*}/postgres"

handle() {
  case "$1" in
    demo-reset)
      psql -c "UPDATE devices SET revoked_at = now(), revoke_reason = 'demo_reset' WHERE store_id IN (SELECT id FROM stores WHERE is_demo)" ;;
    backup)
      "$PGBIN/pg_dump" -Fc -d "$YH_PG_URL" -f /tmp/yh-s22b-backup.dump ;;
    restore)
      kill "$(cat "$YH_SERVER_PID")"; sleep 1
      "$PGBIN/psql" "$admin_url" -qc "DROP DATABASE \"$dbname\" WITH (FORCE)" -c "CREATE DATABASE \"$dbname\""
      "$PGBIN/pg_restore" --exit-on-error -d "$YH_PG_URL" /tmp/yh-s22b-backup.dump
      psql -c "UPDATE stores SET epoch = gen_random_uuid()"
      bash -c "$YH_SERVER_START"; sleep 3 ;;
  esac
  echo "S22B 信号 $1 做完" >&2
  touch "$SIG/$1.done"
}

export TEST_RUNNER_YH_LIVE_BASE="$base" TEST_RUNNER_YH_LIVE_USER="$user" TEST_RUNNER_YH_LIVE_PASSWORD="$YH_LIVE_PASSWORD" TEST_RUNNER_YH_DEMO_USER="$demo"
cd "$(dirname "$0")/.."
xcodebuild -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=$udid" -derivedDataPath "$DD" \
  -resultBundlePath "/tmp/yh-s22b-results/$(date +%s)-$udid.xcresult" test-without-building "${only[@]}" > /tmp/yh-s22b-live.log 2>&1 &
xc=$!
while kill -0 "$xc" 2>/dev/null; do
  for s in demo-reset backup restore; do
    if [[ -f "$SIG/$s" && ! -f "$SIG/$s.done" ]]; then handle "$s"; fi
  done
  sleep 1
done
grep -E "error:|Test Case .*(passed|failed|skipped)|Executed|\*\* TEST" /tmp/yh-s22b-live.log || true
# 退出登录的先后：旧令牌的注销时间晚于它补传的每一笔
if [[ -f "$SIG/logout-device" ]]; then
  d=$(cat "$SIG/logout-device")
  psql -c "SELECT 'S22B 退出登录先后：最后补传 ' || max(o.received_at) || ' ≤ 注销 ' || d.revoked_at || ' → ' || (max(o.received_at) <= d.revoked_at)
           FROM ops o JOIN devices d ON d.id = o.device_id AND d.store_id = o.store_id WHERE o.device_id = '$d' GROUP BY d.revoked_at" || true
fi
