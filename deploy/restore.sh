#!/usr/bin/env bash
# 从备份恢复到一个新库（S10b，§9.4、§4.6）。在另一台机器上跑（恢复演练用本机 Postgres；整机重建时连新 ECS 的库），
# 只需要：这个仓库（server/ 装好依赖）、pg_restore（16 或更新）、备份桶的读凭据、另存的加密口令。
# 用法：deploy/restore.sh <备份 id | latest> [--execute]
#   默认 dry-run：下载、解密、核对 sha256、pg_restore --list 校验 dump、检查目标库、列出要重放的删除记录。目标库一个字节都不写。
#   --execute：清空并标记目标库（只许空库或之前恢复留下的库）→ pg_restore → 按清单逐项比对 → 重放删除记录
#              （已注销的店再删一遍，旧令牌和重传 401）→ 再比对 → 全部店换新 epoch。重跑结果一样（幂等）。
# 环境变量：
#   DATABASE_URL         目标库（新建的空库；不许指向在用的库，脚本也会拒绝非空且没有恢复标记的库）
#   BACKUP_PASSPHRASE    加密口令（钥匙串：security find-generic-password -s yuanhui-backup-passphrase -w）
#   BACKUP_OSS_REGION / BACKUP_OSS_BUCKET / BACKUP_OSS_ACCESS_KEY_ID / BACKUP_OSS_ACCESS_KEY_SECRET [/ BACKUP_OSS_ENDPOINT]
#                        或 BACKUP_STORE_DIR（对象已下载到本机目录）
#   PG_BIN               可选，pg_restore 所在目录
# 退出码：0 成功；1 失败（比对不一致、解密失败等）；2 参数不对
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
SERVER="${YUANHUI_SERVER_DIR:-$HERE/../server}"
WHICH="${1:-}"; EXECUTE=0
for a in "$@"; do [ "$a" = --execute ] && EXECUTE=1; done
[[ $WHICH == latest || $WHICH =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || { echo "用法：deploy/restore.sh <备份 id | latest> [--execute]" >&2; exit 2; }
[ -n "${DATABASE_URL:-}" ] || { echo "缺 DATABASE_URL（目标新库）" >&2; exit 2; }
[ -n "${BACKUP_PASSPHRASE:-}" ] || { echo "缺 BACKUP_PASSPHRASE" >&2; exit 2; }
PGR="${PG_BIN:+$PG_BIN/}pg_restore"
node_r() { node "$SERVER/scripts/restore.ts" "$@"; }
t0=$(date +%s)
W=$(mktemp -d "${TMPDIR:-/tmp}/yh-restore.XXXXXX")
trap 'rm -rf "$W"' EXIT

echo "── 1. 下载、解密、核对 sha256" >&2
node_r fetch --backup "$WHICH" --out "$W" | tee "$W/fetch.out"
ID=$(sed -n 's/.*"backup_id":"\([^"]*\)".*/\1/p' "$W/fetch.out" | head -1)
[[ $ID =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}$ ]] || { echo "没拿到备份 id" >&2; exit 1; }
"$PGR" --list "$W/db.dump" > /dev/null || { echo "dump 校验失败（pg_restore --list）" >&2; exit 1; }

if [ "$EXECUTE" = 0 ]; then
  echo "── 2. [dry-run] 检查目标库、列出删除记录（不写目标库）" >&2
  node_r prepare --backup-id "$ID"
  node_r deletions
  echo "dry-run 完成：备份 $ID 可用。加 --execute 真的恢复" >&2
  exit 0
fi

echo "── 2. 清空并标记目标库" >&2
node_r prepare --backup-id "$ID" --execute
echo "── 3. pg_restore" >&2
"$PGR" -d "$DATABASE_URL" --no-owner --no-acl --exit-on-error "$W/db.dump"
echo "── 4. 比对清单 → 重放删除记录 → 再比对 → 换 epoch" >&2
node_r finish --manifest "$W/manifest.json" --execute
printf '{"event":"restore_ok","backup_id":"%s","restore_seconds":%s}\n' "$ID" "$(( $(date +%s) - t0 ))"
