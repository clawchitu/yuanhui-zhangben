#!/usr/bin/env bash
# 备份一次（S10b，§9.4）：在 ECS 上由 yuanhui-backup.timer 触发（也可手动 bash /opt/yuanhui/backup.sh）。
#   1. backup 容器开一个可重复读事务、导出快照、在同一快照里算清单（scripts/backup.ts snapshot），
#   2. Postgres 容器里 pg_dump --snapshot=<同一快照>（版本和服务端一致），
#   3. backup 容器加密、上传 dump 和清单、写心跳对象（scripts/backup.ts upload），
#   4. 成功才写 backup/last-success（deploy 的迁移前门禁看它，§14 T20）。
# 每一次（成功或失败）都更新 backup/status.json 和 backup/metrics.prom（Prometheus 文本格式，给 S10c 接告警），
# 并打印一行 JSON：event=backup_ok，或 event=backup_failed + alert=backup_failed + stage（snapshot / dump / upload）。
# 不删任何备份：备份账号对 backups/ 只写不删，35 天后由 OSS 生命周期规则删除（§14 T21）。
# 退出码：0 成功；1 失败；2 已有一次在跑（不重叠）。
set -euo pipefail
umask 077
D=${YUANHUI_DIR:-$(cd "$(dirname "$0")" && pwd)}
ENV="$D/.env"
S="$D/backup"
C=(docker compose -f "$D/compose.yml" --project-directory "$D" --env-file "$ENV")
mkdir -p "$S"
t0=$(date +%s)
stage=lock
W=""
json() { printf '{"at":"%s","event":"%s"%s}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-}"; }
# 状态文件：上一次成功的时间保留；失败次数连续累加
prev() { sed -n "s/^yuanhui_backup_$1 //p" "$S/metrics.prom" 2>/dev/null | tail -1; }
write_state() { # write_state <ok 0|1> <backup_id> <dump_bytes>
  local ok=$1 id=$2 bytes=$3 now dur last fails
  now=$(date +%s); dur=$((now - t0))
  last=$(cat "$S/last-success" 2>/dev/null || echo 0)
  if [ "$ok" = 1 ]; then fails=0; last=$now; else fails=$(( $(prev consecutive_failures || echo 0) + 1 )); fi
  printf '%s\n' \
    "# 元辉账本备份（S10b）。时间是 Unix 秒" \
    "yuanhui_backup_last_attempt_timestamp_seconds $now" \
    "yuanhui_backup_last_success_timestamp_seconds $last" \
    "yuanhui_backup_last_ok $ok" \
    "yuanhui_backup_consecutive_failures $fails" \
    "yuanhui_backup_duration_seconds $dur" \
    "yuanhui_backup_dump_bytes ${bytes:-0}" > "$S/metrics.prom.tmp"
  mv "$S/metrics.prom.tmp" "$S/metrics.prom"
  printf '{"last_attempt":%s,"last_success":%s,"ok":%s,"consecutive_failures":%s,"stage":"%s","backup_id":"%s","duration_s":%s}\n' \
    "$now" "$last" "$( [ "$ok" = 1 ] && echo true || echo false )" "$fails" "$stage" "$id" "$dur" > "$S/status.json.tmp"
  mv "$S/status.json.tmp" "$S/status.json"
}
cleanup() {
  [ -n "$W" ] && rm -rf "$W"
  [ "$stage" != lock ] && rmdir "$S/lock.d" 2>/dev/null
  return 0
}
trap cleanup EXIT
fail() {
  write_state 0 "" 0
  json backup_failed ",\"alert\":\"backup_failed\",\"stage\":\"$stage\"" >&2
  [ -n "$W" ] && for f in "$W"/*.log; do [ -s "$f" ] && sed 's/^/  /' "$f" >&2; done
  exit 1
}

# 不重叠：上一次还在跑就退出；锁超过 60 分钟算残留（进程被杀），清掉再拿
if ! mkdir "$S/lock.d" 2>/dev/null; then
  if [ -n "$(find "$S/lock.d" -maxdepth 0 -mmin +60 2>/dev/null)" ]; then rmdir "$S/lock.d" && mkdir "$S/lock.d"
  else json backup_skipped ',"reason":"already_running"' >&2; exit 2; fi
fi
stage=prepare
[ -f "$ENV" ] || fail
W=$(mktemp -d "$S/work.XXXXXX")
# backup 容器里是 node 用户（1000），工作目录要让它能写
if [ "$(id -u)" = 0 ]; then chown 1000:1000 "$W"; fi

stage=snapshot
"${C[@]}" run --rm -T -v "$W:/work" backup node scripts/backup.ts snapshot --dir /work > "$W/snapshot.log" 2>&1 &
snap_pid=$!
for _ in $(seq 1 600); do
  [ -s "$W/snapshot" ] && break
  kill -0 "$snap_pid" 2>/dev/null || break
  sleep 0.2
done
[ -s "$W/snapshot" ] || { wait "$snap_pid" || true; fail; }
snap=$(head -1 "$W/snapshot")
[[ $snap =~ ^[0-9A-Fa-f-]+$ ]] || { touch "$W/dump.failed"; wait "$snap_pid" || true; fail; }

stage=dump
if "${C[@]}" exec -T postgres pg_dump -U yuanhui -d yuanhui -Fc --snapshot="$snap" > "$W/db.dump" 2> "$W/dump.log"; then
  touch "$W/dump.done"
else
  touch "$W/dump.failed"; wait "$snap_pid" || true; fail
fi
stage=snapshot
wait "$snap_pid" || fail

stage=upload
if [ "$(id -u)" = 0 ]; then chown 1000:1000 "$W/db.dump"; fi
"${C[@]}" run --rm -T -v "$W:/work" backup node scripts/backup.ts upload --dir /work > "$W/upload.out" 2> "$W/upload.log" || fail
id=$(sed -n 's/.*"event":"backup_uploaded","backup_id":"\([^"]*\)".*/\1/p' "$W/upload.out" | head -1)
bytes=$(sed -n 's/.*"dump_bytes":\([0-9]*\).*/\1/p' "$W/upload.out" | head -1)
[ -n "$id" ] || fail
# 生命周期没生效（最旧的一份超过 36 天）：backup.ts 打 alert=backup_lifecycle_stale，原样转出来
grep -h '"event":"backup_status"' "$W/upload.out" || true

stage=finish
date +%s > "$S/last-success.tmp" && mv "$S/last-success.tmp" "$S/last-success"
write_state 1 "$id" "$bytes"
json backup_ok ",\"backup_id\":\"$id\",\"dump_bytes\":${bytes:-0},\"duration_s\":$(( $(date +%s) - t0 ))"
