#!/usr/bin/env bash
# 从备份恢复到一个新库（S10b，§9.4、§4.6）。两种跑法：
#   本机（恢复演练）：这个仓库（server/ 装好依赖）、pg_restore（16 或更新）、备份桶的读凭据、另存的加密口令，目标是本机的空库。
#   ECS（整机重建，RESTORE_COMPOSE_DIR=/opt/yuanhui）：node 步骤在 backup 容器里跑（docker compose run backup，凭据、口令、
#     DATABASE_URL 都取自 /opt/yuanhui/.env），pg_restore 在 Postgres 容器里跑（docker compose exec postgres）。数据库不映射端口，
#     不需要 ssh -L，也不需要在 ECS 上装 node。步骤见 docs/runbook.md「整机重建」。
# 用法：deploy/restore.sh <备份 id | latest> [--execute]
#   默认 dry-run：下载、解密、核对 sha256、pg_restore --list 校验 dump、检查目标库、列出删除记录和「备份里有、将被删掉的店」。目标库一个字节都不写。
#   --execute：清空目标库并打「恢复中」标记（只许空库或「恢复中」的库）→ pg_restore → 按清单逐项比对 → 重放删除记录
#              （已注销的店再删一遍，旧令牌和重传 401）→ 再比对 → 全部店换新 epoch、标记改「已恢复」。
#   中途失败重跑：「恢复中」的库清空重来。已恢复完成的库再跑：同一个备份报「已恢复完成」退出 0、什么都不动；别的备份拒绝（§14 S10b-5）。
# 环境变量（本机跑法）：
#   DATABASE_URL         目标库（新建的空库；脚本拒绝非空且不是「恢复中」的库）。口令不进 pg_restore 的命令行，经 PGPASSWORD 传
#   BACKUP_PASSPHRASE    加密口令（钥匙串：security find-generic-password -s yuanhui-backup-passphrase -w）
#   BACKUP_OSS_REGION / BACKUP_OSS_BUCKET（yuanhui-backup）/ BACKUP_OSS_ARCHIVE_BUCKET（yuanhui-archive）/
#   BACKUP_OSS_ACCESS_KEY_ID / BACKUP_OSS_ACCESS_KEY_SECRET [/ BACKUP_OSS_ENDPOINT]
#                        或 BACKUP_STORE_DIR（对象已下载到本机目录，backups/ 和 deletions/ 在同一个目录）
#   BACKUP_OSS_ARCHIVE_BUCKET 必填（PR #27 Fable S10r-8）：删除记录 deletions/ 在存档桶。不设的话会去备份桶里找，找到的是空的、
#                        不报错，已注销的店会被恢复回来。所以 OSS 跑法没设就拒绝（退出码 2）；单桶老布局显式写成和 BACKUP_OSS_BUCKET 同名。
#                        整机重建跑法由 compose 从 .env 的 OSS_ARCHIVE_BUCKET 带进 backup 容器，没填同样由 scripts/restore.ts 拒绝。
#                        dry-run 第一行 restore_source 打印 backups/ 和 deletions/ 各从哪个桶读，核对一眼。
#   PG_BIN               可选，pg_restore 所在目录
# 退出码：0 成功（含「已恢复完成」）；1 失败（比对不一致、解密失败、目标库不对等）；2 参数不对
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
SERVER="${YUANHUI_SERVER_DIR:-$HERE/../server}"
WHICH="${1:-}"; EXECUTE=0
for a in "$@"; do [ "$a" = --execute ] && EXECUTE=1; done
[[ $WHICH == latest || $WHICH =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || { echo "用法：deploy/restore.sh <备份 id | latest> [--execute]" >&2; exit 2; }
CD="${RESTORE_COMPOSE_DIR:-}"
if [ -n "$CD" ]; then
  [ -f "$CD/compose.yml" ] && [ -f "$CD/.env" ] || { echo "RESTORE_COMPOSE_DIR=$CD 下缺 compose.yml 或 .env" >&2; exit 2; }
  C=(docker compose -f "$CD/compose.yml" --project-directory "$CD" --env-file "$CD/.env")
else
  [ -n "${DATABASE_URL:-}" ] || { echo "缺 DATABASE_URL（目标新库）" >&2; exit 2; }
  [ -n "${BACKUP_PASSPHRASE:-}" ] || { echo "缺 BACKUP_PASSPHRASE" >&2; exit 2; }
  if [ -z "${BACKUP_STORE_DIR:-}" ] && [ -z "${BACKUP_OSS_ARCHIVE_BUCKET:-}" ]; then
    echo "缺 BACKUP_OSS_ARCHIVE_BUCKET（存档桶 yuanhui-archive，删除记录 deletions/ 在那里）：不设就读不到删除记录，已注销的店会被恢复回来。" >&2
    echo "单桶老布局请显式写成和 BACKUP_OSS_BUCKET 同名。见 docs/runbook.md「恢复」第 2 步" >&2
    exit 2
  fi
fi
t0=$(date +%s)
W=$(mktemp -d "${TMPDIR:-/tmp}/yh-restore.XXXXXX")
STEP=fetch
# 失败一律打一行 restore_failed（S10c，§14 T26）。整机重建（ECS 上）另外追加到 backup/restore-events.log，api 的监控读它告警；
# 本机演练时人就在终端前，只打到 stderr。
on_exit() {
  local rc=$?
  if [ "$rc" != 0 ]; then
    local line
    line=$(printf '{"at":"%s","event":"restore_failed","alert":"restore_failed","stage":"%s","exit_code":%s}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$STEP" "$rc")
    echo "$line" >&2
    if [ -n "$CD" ]; then
      { mkdir -p "$CD/backup" && chmod 711 "$CD/backup" && echo "$line" >> "$CD/backup/restore-events.log" && chmod 644 "$CD/backup/restore-events.log"; } || true
    fi
  fi
  rm -rf "$W"
}
trap on_exit EXIT

if [ -n "$CD" ]; then
  # 容器里是 node 用户（1000），工作目录要让它能写；/work 是同一个目录
  if [ "$(id -u)" = 0 ]; then chown 1000:1000 "$W"; fi
  chmod 700 "$W"
  node_r() { "${C[@]}" run --rm -T -v "$W:/work" backup node scripts/restore.ts "$@"; }
  WD=/work
  pg_list() { "${C[@]}" exec -T postgres pg_restore --list < "$W/db.dump"; }
  pg_load() { "${C[@]}" exec -T postgres pg_restore -U yuanhui -d yuanhui --no-owner --no-acl --exit-on-error < "$W/db.dump"; }
else
  node_r() { node "$SERVER/scripts/restore.ts" "$@"; }
  WD=$W
  PGR="${PG_BIN:+$PG_BIN/}pg_restore"
  pg_list() { "$PGR" --list "$W/db.dump"; }
  # 连接串里的口令拿出来放 PGPASSWORD，命令行（ps 看得到）只留不带口令的连接串（Codex 3、Fable 建议 3）
  pg_load() {
    local conn pw
    { IFS= read -r conn; IFS= read -r pw; } < <(node -e '
      const u = new URL(process.env.DATABASE_URL); const p = decodeURIComponent(u.password); u.password = "";
      process.stdout.write(u.toString() + "\n" + p + "\n");')
    PGPASSWORD=$pw "$PGR" -d "$conn" --no-owner --no-acl --exit-on-error "$W/db.dump"
  }
fi

echo "── 1. 下载、解密、核对 sha256" >&2
node_r fetch --backup "$WHICH" --out "$WD" | tee "$W/fetch.out"
ID=$(sed -n 's/.*"backup_id":"\([^"]*\)".*/\1/p' "$W/fetch.out" | head -1)
[[ $ID =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || { echo "没拿到备份 id" >&2; exit 1; }
STEP=verify
pg_list > /dev/null || { echo "dump 校验失败（pg_restore --list）" >&2; exit 1; }

done_already() {
  echo "目标库已经从备份 $ID 恢复完成，什么都没动" >&2
  printf '{"event":"restore_ok","backup_id":"%s","already_restored":true,"restore_seconds":%s}\n' "$ID" "$(( $(date +%s) - t0 ))"
  exit 0
}

if [ "$EXECUTE" = 0 ]; then
  echo "── 2. [dry-run] 检查目标库、列出删除记录（不写目标库）" >&2
  node_r prepare --backup-id "$ID" | tee "$W/prepare.out"
  grep -q '"state":"done"' "$W/prepare.out" && done_already
  echo "── 删除记录（in_backup=true 的店恢复时会被删掉；核对元辉店的 id 不在 restore_will_delete 里）" >&2
  node_r deletions --manifest "$WD/manifest.json"
  echo "dry-run 完成：备份 $ID 可用。加 --execute 真的恢复" >&2
  exit 0
fi

STEP=prepare
echo "── 2. 清空目标库、打「恢复中」标记" >&2
node_r prepare --backup-id "$ID" --execute | tee "$W/prepare.out"
grep -q '"state":"done"' "$W/prepare.out" && done_already
STEP=pg_restore
echo "── 3. pg_restore" >&2
pg_load
STEP=finish
echo "── 4. 比对清单 → 重放删除记录 → 再比对 → 换 epoch、标记改「已恢复」" >&2
node_r finish --manifest "$WD/manifest.json" --execute
printf '{"event":"restore_ok","backup_id":"%s","restore_seconds":%s}\n' "$ID" "$(( $(date +%s) - t0 ))"
