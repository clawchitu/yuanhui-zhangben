#!/usr/bin/env bash
# backup.sh、restore.sh 的测试（S10b）：替身 docker 把 compose run backup / exec postgres pg_dump 转给本机 node 和 pg_dump，
# 所以跑的是真脚本、真快照、真加密；对象存储是本机目录（BACKUP_STORE_DIR），不连 OSS、不连服务器。
# 需要 DATABASE_URL（Postgres 16）、pg_dump / pg_restore / psql（PG_BIN 可指定目录）、server/ 已 npm ci。
# 流程：建库造数 → backup.sh → 各种故障：pg_dump 失败、上传失败、重叠运行 → 写一条删除记录 →
#       restore.sh dry-run（目标库不动）→ --execute → 已注销的店不在、epoch 换了、口令不进命令行 → 转正后重跑（不清库）→
#       整机重建跑法（compose）→ 口令不对、目标库不空、备份被改坏。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SERVER=$(cd "$HERE/../../server" && pwd)
: "${DATABASE_URL:?需要 DATABASE_URL}"
[ -n "${PG_BIN:-}" ] && PATH="$PG_BIN:$PATH"
pass=0; fail=0
T=$(mktemp -d)
SCHEMA="bk_$(date +%s)_$RANDOM"
TARGET_DB="yh_rt_$(date +%s)_$RANDOM"
PASS=test-only-passphrase-0123456789
export PGOPTIONS="-c client_min_messages=warning"
with_path() { # 连接串加 search_path（node 脚本和 pg_restore 都认）
  case "$1" in *\?*) echo "$1&options=-c%20search_path%3D$2" ;; *) echo "$1?options=-c%20search_path%3D$2" ;; esac
}
SRC_URL=$(with_path "$DATABASE_URL" "$SCHEMA")
BASE=${DATABASE_URL%%\?*}; TGT=$(with_path "${BASE%/*}/$TARGET_DB" "$SCHEMA")
cleanup() {
  psql -q "$DATABASE_URL" -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE" -c "DROP DATABASE IF EXISTS $TARGET_DB WITH (FORCE)" -c "DROP DATABASE IF EXISTS ${TARGET_DB}_b WITH (FORCE)" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  ✗ $d"; sed 's/^/    /' "$T/out" | tail -20; fi; }
t() { echo "• $1"; }
no() { ! "$@"; }
q() { psql -tAq "$1" -c "$2"; }

# ── 源库：迁移后建两家店 ──
psql -q "$DATABASE_URL" -c "CREATE SCHEMA $SCHEMA" || exit 1
DATABASE_URL=$SRC_URL node "$SERVER/scripts/migrate.ts" > /dev/null || exit 1
KEEP=$(q "$SRC_URL" "INSERT INTO stores (name) VALUES ('留下的店') RETURNING id")
GONE=$(q "$SRC_URL" "INSERT INTO stores (name) VALUES ('注销的店') RETURNING id")
KEEP_EPOCH=$(q "$SRC_URL" "SELECT epoch FROM stores WHERE id = '$KEEP'")
psql -q "$DATABASE_URL" -c "CREATE DATABASE $TARGET_DB" || exit 1

# ── ECS 沙盒：/opt/yuanhui ──
R="$T/remote"; STORE="$T/bucket"; mkdir -p "$R" "$STORE"
cp "$HERE/../compose.yml" "$R/compose.yml"
printf 'POSTGRES_PASSWORD=0123456789abcdef0123\nACME_EMAIL=a@example.invalid\nPUBLIC_IP=47.117.184.253\nCADDY_IMAGE=r/caddy\nPOSTGRES_IMAGE=r/pg\nAPI_IMAGE=r/api:1111111\n' > "$R/.env"
export FAKE_LOG="$T/log" FAKE_STATE="$T/state" FAKE_BACKUP_SERVER="$SERVER" FAKE_BACKUP_DB_URL="$SRC_URL" FAKE_BACKUP_STORE="$STORE" \
  FAKE_BACKUP_PASSPHRASE="$PASS" FAKE_PG_URL="$DATABASE_URL" FAKE_PG_SCHEMA="$SCHEMA"
mkdir -p "$FAKE_STATE"
backup() { PATH="$HERE/fakes:$PATH" YUANHUI_DIR="$R" bash "$HERE/../backup.sh" > "$T/out" 2>&1; echo $? > "$T/rc"; }
restore() { BACKUP_STORE_DIR="$STORE" BACKUP_PASSPHRASE="${P-$PASS}" DATABASE_URL="${U-$TGT}" bash "$HERE/../restore.sh" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
metric() { sed -n "s/^yuanhui_backup_$1 //p" "$R/backup/metrics.prom"; }
nbackups() { find "$STORE/backups" -name '*.dump.enc' 2>/dev/null | wc -l | tr -d ' '; }

t "backup.sh 成功：dump 和清单加密上传、心跳、last-success、指标；锁和工作目录都清掉"
backup
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "一份备份" [ "$(nbackups)" = 1 ]
check "清单也在" [ "$(find "$STORE/backups" -name '*.manifest.enc' | wc -l | tr -d ' ')" = 1 ]
check "上传的是密文（YHBK 头）" [ "$(head -c 4 "$(find "$STORE/backups" -name '*.dump.enc')")" = YHBK ]
check "心跳对象" grep -q '"stores":2' "$STORE/heartbeat/backup.json"
check "last-success 写了" grep -Eq '^[0-9]+$' "$R/backup/last-success"
check "指标 last_ok=1、连续失败 0" [ "$(metric last_ok)" = 1 ] && [ "$(metric consecutive_failures)" = 0 ]
check "打印 backup_ok" grep -q '"event":"backup_ok"' "$T/out"
check "锁和工作目录清掉了" [ -z "$(find "$R/backup" -mindepth 1 -maxdepth 1 -type d)" ]
check "pg_dump 用了快照" grep -q "pg_dump -U yuanhui -d yuanhui -Fc --snapshot=" "$FAKE_LOG"
LAST=$(cat "$R/backup/last-success")

t "pg_dump 失败：退出码 1，stage=dump，告警 backup_failed，last-success 和心跳不变，连续失败计数累加"
cp "$STORE/heartbeat/backup.json" "$T/hb"
sleep 1; export FAKE_PGDUMP_FAIL=1; backup; unset FAKE_PGDUMP_FAIL
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "告警行带 stage=dump" grep -q '"alert":"backup_failed","stage":"dump"' "$T/out"
check "last-success 不变" [ "$(cat "$R/backup/last-success")" = "$LAST" ]
check "心跳不变" cmp -s "$T/hb" "$STORE/heartbeat/backup.json"
check "last_ok=0、连续失败 1" [ "$(metric last_ok)" = 0 ] && [ "$(metric consecutive_failures)" = 1 ]
check "成功时间仍是上一次" [ "$(metric last_success_timestamp_seconds)" = "$LAST" ]
export FAKE_UPLOAD_FAIL=1; backup; unset FAKE_UPLOAD_FAIL
check "上传失败：退出码 1、stage=upload、连续失败 2" [ "$(rc)" = 1 ] && grep -q '"stage":"upload"' "$T/out" && [ "$(metric consecutive_failures)" = 2 ]
check "没多出备份" [ "$(nbackups)" = 1 ]

t "上一次还在跑（有锁）：退出码 2，不重叠"
mkdir "$R/backup/lock.d"; backup
check "退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
check "锁还在（不是我的锁不删）" [ -d "$R/backup/lock.d" ]
rmdir "$R/backup/lock.d"
backup
check "锁释放后又成功，连续失败清零" [ "$(rc)" = 0 ] && [ "$(metric consecutive_failures)" = 0 ] && [ "$(nbackups)" = 2 ]
FIRST=$(find "$STORE/backups" -name '*.dump.enc' | sort | head -1 | sed 's#.*/##; s#\.dump\.enc$##')

# 备份之后：注销的店被清除（往 deletions/ 写记录、删在线数据），之后源库整个丢了
mkdir -p "$STORE/deletions"
printf '{"store_id":"%s","purged_at":"2026-11-20T03:00:00.000Z"}\n' "$GONE" > "$STORE/deletions/$GONE.json"
psql -q "$DATABASE_URL" -c "DROP SCHEMA $SCHEMA CASCADE"

t "restore.sh dry-run：解密、校验 dump、列出要重放的删除记录，目标库一个表都不建"
restore latest
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "列出删除记录" grep -q "\"store_id\":\"$GONE\"" "$T/out"
check "单独一行列出备份里有、将被删掉的店" grep -q "\"event\":\"restore_will_delete\",\"store_ids\":\[\"$GONE\"\]" "$T/out"
check "目标库还是空的" [ "$(q "${BASE%/*}/$TARGET_DB" "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')")" = 0 ]

t "restore.sh --execute：恢复、比对清单、重放删除记录（注销的店不在）、换 epoch；口令不进 pg_restore 的命令行"
mkdir -p "$T/pgbin"; REAL_PGR=$(command -v pg_restore)
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\necho "PGPASSWORD=${PGPASSWORD:+set}" >> "%s"\nexec "%s" "$@"\n' "$T/pgr.log" "$T/pgr.log" "$REAL_PGR" > "$T/pgbin/pg_restore"
chmod +x "$T/pgbin/pg_restore"
PW=$(node -e 'process.stdout.write(decodeURIComponent(new URL(process.env.DATABASE_URL).password))')
PG_BIN="$T/pgbin" restore latest --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "只剩留下的店" [ "$(q "$TGT" "SELECT string_agg(id::text, ',') FROM stores")" = "$KEEP" ]
check "epoch 换了" [ "$(q "$TGT" "SELECT epoch FROM stores WHERE id = '$KEEP'")" != "$KEEP_EPOCH" ]
check "store_purges 记了注销的店" [ "$(q "$TGT" "SELECT count(*) FROM store_purges WHERE store_id = '$GONE'")" = 1 ]
check "打印 restore_ok 和用时" grep -q '"event":"restore_ok".*"restore_seconds"' "$T/out"
check "单独一行列出被删掉的店" grep -q "\"event\":\"restore_deleted_stores\",\"store_ids\":\[\"$GONE\"\]" "$T/out"
check "标记改成「已恢复」" [ "$(q "$TGT" "SELECT shobj_description(oid, 'pg_database') FROM pg_database WHERE datname = current_database()")" = "yuanhui-restored $(sed -n 's/.*"event":"restore_ok","backup_id":"\([^"]*\)".*/\1/p' "$T/out")" ]
check "pg_restore 走了 PGPASSWORD" grep -q '^PGPASSWORD=set$' "$T/pgr.log"
check "pg_restore 的命令行里没有口令" no grep -qF ":$PW@" "$T/pgr.log"

t "恢复完成的库已在用（又写了一家店）：重跑同一个备份 → 「已恢复完成」、什么都不动；换一个备份 → 拒绝"
NEWSTORE=$(q "$TGT" "INSERT INTO stores (name) VALUES ('转正后新开的店') RETURNING id")
EPOCH_NOW=$(q "$TGT" "SELECT epoch FROM stores WHERE id = '$KEEP'")
restore latest --execute
check "退出码 0（实际 $(rc)）、already_restored" [ "$(rc)" = 0 ] && grep -q '"already_restored":true' "$T/out"
check "新写的那家店还在" [ "$(q "$TGT" "SELECT count(*) FROM stores WHERE id = '$NEWSTORE'")" = 1 ]
check "epoch 没再换" [ "$(q "$TGT" "SELECT epoch FROM stores WHERE id = '$KEEP'")" = "$EPOCH_NOW" ]
restore latest
check "dry-run 也报已恢复完成" [ "$(rc)" = 0 ] && grep -q '"already_restored":true' "$T/out"
restore "$FIRST" --execute
check "换一个备份：退出码 1、拒绝" [ "$(rc)" = 1 ] && grep -q "恢复完成" "$T/out"
check "新写的那家店还在" [ "$(q "$TGT" "SELECT count(*) FROM stores WHERE id = '$NEWSTORE'")" = 1 ]

t "整机重建的跑法（RESTORE_COMPOSE_DIR）：node 步骤在 backup 容器、pg_restore 在 Postgres 容器（替身 docker），然后清标记"
TARGET2="${TARGET_DB}_b"; TGT2=$(with_path "${BASE%/*}/$TARGET2" "$SCHEMA")
psql -q "$DATABASE_URL" -c "CREATE DATABASE $TARGET2"
crestore() { PATH="$HERE/fakes:$PATH" FAKE_RESTORE_DB_URL="$TGT2" RESTORE_COMPOSE_DIR="$R" bash "$HERE/../restore.sh" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
: > "$FAKE_LOG"
crestore latest
check "dry-run 退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ] && grep -q '"event":"restore_will_delete"' "$T/out"
crestore latest --execute
check "--execute 退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ] && grep -q '"event":"restore_ok"' "$T/out"
check "只剩留下的店" [ "$(q "$TGT2" "SELECT string_agg(id::text, ',') FROM stores")" = "$KEEP" ]
check "用的是 compose run backup 和 compose exec postgres pg_restore" grep -q "run --rm -T -v .* backup node scripts/restore.ts finish" "$FAKE_LOG" && grep -q "exec -T postgres pg_restore -U yuanhui -d yuanhui" "$FAKE_LOG"
PATH="$HERE/fakes:$PATH" FAKE_RESTORE_DB_URL="$TGT2" docker compose -f "$R/compose.yml" --project-directory "$R" --env-file "$R/.env" run --rm -T backup node scripts/restore.ts clear-marker > "$T/out" 2>&1
check "清标记：之后是普通的在用库" grep -q '"state":"foreign"' "$T/out"
crestore latest --execute
check "清过标记的库再恢复：拒绝覆盖" [ "$(rc)" = 1 ] && grep -q "拒绝覆盖" "$T/out"
psql -q "$DATABASE_URL" -c "DROP DATABASE IF EXISTS $TARGET2 WITH (FORCE)"

t "改坏的情形都失败"
P=wrong-passphrase-0123456789 restore latest --execute
check "口令不对：退出码 1" [ "$(rc)" = 1 ]
psql -q "$DATABASE_URL" -c "CREATE SCHEMA $SCHEMA" -c "CREATE TABLE $SCHEMA.live (x int)"
U=$SRC_URL restore latest --execute
check "目标库不空又没有恢复标记：退出码 1，拒绝覆盖" [ "$(rc)" = 1 ] && grep -q "拒绝覆盖" "$T/out"
check "那个库没被动" [ "$(q "$DATABASE_URL" "SELECT count(*) FROM pg_tables WHERE schemaname = '$SCHEMA'")" = 1 ]
f=$(find "$STORE/backups" -name '*.dump.enc' | sort | tail -1)
printf 'X' | dd of="$f" bs=1 seek=100 conv=notrunc 2>/dev/null
restore latest --execute
check "备份被改了一个字节：退出码 1（解密失败）" [ "$(rc)" = 1 ] && grep -q "解密失败" "$T/out"
check "参数不对：退出码 2" bash -c "BACKUP_PASSPHRASE=x DATABASE_URL=x bash '$HERE/../restore.sh' '../etc' >/dev/null 2>&1; [ \$? = 2 ]"

echo "通过 ${pass}，失败 $fail"
[ "$fail" = 0 ]
