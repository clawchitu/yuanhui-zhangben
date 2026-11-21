#!/usr/bin/env bash
# backup.sh、restore.sh 的测试（S10b）：替身 docker 把 compose run backup / exec postgres pg_dump 转给本机 node 和 pg_dump，
# 所以跑的是真脚本、真快照、真加密；对象存储是本机目录（BACKUP_STORE_DIR），不连 OSS、不连服务器。
# 需要 DATABASE_URL（Postgres 16）、pg_dump / pg_restore / psql（PG_BIN 可指定目录）、server/ 已 npm ci。
# 流程：建库造数 → backup.sh → 各种故障：pg_dump 失败、上传失败、重叠运行、残留锁和工作目录 → 写一条删除记录 →
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
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
nbackups() { find "$STORE/backups" -name '*.dump.enc' 2>/dev/null | wc -l | tr -d ' '; }

t "backup.sh 成功：dump 和清单加密上传、心跳、last-success、指标；锁和工作目录都清掉"
backup
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "一份备份" [ "$(nbackups)" = 1 ]
check "清单也在" [ "$(find "$STORE/backups" -name '*.manifest.enc' | wc -l | tr -d ' ')" = 1 ]
check "上传的是密文（YHBK 头）" [ "$(head -c 4 "$(find "$STORE/backups" -name '*.dump.enc')")" = YHBK ]
check "心跳对象" grep -q '"stores":2' "$STORE/heartbeat/backup.json"
check "last-success 写了" grep -Eq '^[0-9]+$' "$R/backup/last-success"
ok() { [ "$(metric last_ok)" = 1 ] && [ "$(metric consecutive_failures)" = 0 ]; }; check "指标 last_ok=1、连续失败 0" ok
check "打印 backup_ok" grep -q '"event":"backup_ok"' "$T/out"
check "锁和工作目录清掉了" [ -z "$(find "$R/backup" -mindepth 1 -maxdepth 1 -type d)" ]
check "pg_dump 用了快照" grep -q "pg_dump -U yuanhui -d yuanhui -Fc --snapshot=" "$FAKE_LOG"
check "指标 lifecycle_stale=0" [ "$(metric lifecycle_stale)" = 0 ]
# S10c：api 容器（node 用户）只读挂 backup/，能按名字读、不能列目录
check "backup/ 是 711（实际 $(perm "$R/backup")）" [ "$(perm "$R/backup")" = 711 ]
check "metrics.prom、status.json、last-success 是 644" [ "$(perm "$R/backup/metrics.prom")$(perm "$R/backup/status.json")$(perm "$R/backup/last-success")" = 644644644 ]
LAST=$(cat "$R/backup/last-success")

t "pg_dump 失败：退出码 1，stage=dump，告警 backup_failed，last-success 和心跳不变，连续失败计数累加"
cp "$STORE/heartbeat/backup.json" "$T/hb"
sleep 1; export FAKE_PGDUMP_FAIL=1; backup; unset FAKE_PGDUMP_FAIL
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "告警行带 stage=dump" grep -q '"alert":"backup_failed","stage":"dump"' "$T/out"
check "last-success 不变" [ "$(cat "$R/backup/last-success")" = "$LAST" ]
check "心跳不变" cmp -s "$T/hb" "$STORE/heartbeat/backup.json"
ok() { [ "$(metric last_ok)" = 0 ] && [ "$(metric consecutive_failures)" = 1 ]; }; check "last_ok=0、连续失败 1" ok
check "成功时间仍是上一次" [ "$(metric last_success_timestamp_seconds)" = "$LAST" ]
export FAKE_UPLOAD_FAIL=1; backup; unset FAKE_UPLOAD_FAIL
ok() { [ "$(rc)" = 1 ] && grep -q '"stage":"upload"' "$T/out" && [ "$(metric consecutive_failures)" = 2 ]; }; check "上传失败：退出码 1、stage=upload、连续失败 2" ok
check "没多出备份" [ "$(nbackups)" = 1 ]

t "上一次还在跑（有锁）：退出码 2，不重叠；跳过记进 skips.log 和指标"
mkdir "$R/backup/lock.d"; backup
check "退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
check "锁还在（不是我的锁不删）" [ -d "$R/backup/lock.d" ]
check "打 alert=backup_skipped" grep -q '"alert":"backup_skipped"' "$T/out"
check "skips.log 记了一行" [ "$(wc -l < "$R/backup/skips.log" | tr -d ' ')" = 1 ]
ok() { [ "$(metric last_skip_timestamp_seconds)" -gt 0 ] && [ "$(metric consecutive_failures)" = 2 ]; }; check "指标 last_skip 有时间、失败计数不变" ok
sleep 300 & live=$!
echo "$live" > "$R/backup/lock.d/pid"; backup
ok() { [ "$(rc)" = 2 ] && [ -d "$R/backup/lock.d" ]; }; check "拿锁的进程还活着：退出码 2" ok
kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
rm -rf "$R/backup/lock.d"
backup
ok() { [ "$(rc)" = 0 ] && [ "$(metric consecutive_failures)" = 0 ] && [ "$(nbackups)" = 2 ] && [ "$(metric last_skip_timestamp_seconds)" -gt 0 ]; }; check "锁释放后又成功，连续失败清零，last_skip 保留" ok

t "上一次被 kill -9：锁和明文工作目录留下；下一次照常跑、清掉残留（不等 60 分钟）"
mkdir -p "$R/backup/lock.d" "$R/backup/work.dead1"; echo PGDMP > "$R/backup/work.dead1/db.dump"
bash -c 'echo $$' > "$R/backup/lock.d/pid"   # 一个已经退出的进程
backup
ok() { [ "$(rc)" = 0 ] && grep -q '"event":"backup_stale_lock"' "$T/out"; }; check "拿锁的进程不在了：退出码 0（实际 $(rc)）" ok
check "残留的 work.* 清掉了、锁释放了" [ -z "$(find "$R/backup" -mindepth 1 -maxdepth 1 -type d)" ]
mkdir "$R/backup/lock.d"; touch -t 200001010000 "$R/backup/lock.d"   # 没有 pid、超过 16 分钟
backup
ok() { [ "$(rc)" = 0 ] && [ "$(nbackups)" = 4 ]; }; check "锁超过 16 分钟算残留：退出码 0（实际 $(rc)）" ok
FIRST=$(find "$STORE/backups" -name '*.dump.enc' | sort | head -1 | sed 's#.*/##; s#\.dump\.enc$##')

t "S10c：桶里最旧的一份超过 38 天（生命周期没生效）→ 指标 lifecycle_stale=1；失败的那次沿用；删掉后回 0"
OLD=20000101T000000Z-0123456789abcdef
d=$(dirname "$(find "$STORE/backups" -name '*.dump.enc' | head -1)")
cp "$(find "$STORE/backups" -name '*.dump.enc' | head -1)" "$d/$OLD.dump.enc"; cp "$(find "$STORE/backups" -name '*.manifest.enc' | head -1)" "$d/$OLD.manifest.enc"
backup
ok() { [ "$(rc)" = 0 ] && grep -q '"alert":"backup_lifecycle_stale"' "$T/out"; }; check "退出码 0（实际 $(rc)）、转出 alert=backup_lifecycle_stale" ok
check "指标 lifecycle_stale=1（实际 $(metric lifecycle_stale)）" [ "$(metric lifecycle_stale)" = 1 ]
export FAKE_UPLOAD_FAIL=1; backup; unset FAKE_UPLOAD_FAIL
ok() { [ "$(rc)" = 1 ] && [ "$(metric lifecycle_stale)" = 1 ]; }; check "上传失败查不到桶：沿用上一次的 1" ok
lc_stale=0 backup   # 外面的环境变量不能冒充这次的结果
rm -f "$d/$OLD.dump.enc" "$d/$OLD.manifest.enc"
check "这次（还没删）仍是 1，不被环境变量盖掉" [ "$(metric lifecycle_stale)" = 1 ]
backup
ok() { [ "$(rc)" = 0 ] && [ "$(metric lifecycle_stale)" = 0 ]; }; check "删掉以后回 0" ok
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
ok() { [ "$(rc)" = 0 ] && grep -q '"already_restored":true' "$T/out"; }; check "退出码 0（实际 $(rc)）、already_restored" ok
check "新写的那家店还在" [ "$(q "$TGT" "SELECT count(*) FROM stores WHERE id = '$NEWSTORE'")" = 1 ]
check "epoch 没再换" [ "$(q "$TGT" "SELECT epoch FROM stores WHERE id = '$KEEP'")" = "$EPOCH_NOW" ]
restore latest
ok() { [ "$(rc)" = 0 ] && grep -q '"already_restored":true' "$T/out"; }; check "dry-run 也报已恢复完成" ok
restore "$FIRST" --execute
ok() { [ "$(rc)" = 1 ] && grep -q "恢复完成" "$T/out"; }; check "换一个备份：退出码 1、拒绝" ok
check "新写的那家店还在" [ "$(q "$TGT" "SELECT count(*) FROM stores WHERE id = '$NEWSTORE'")" = 1 ]

t "整机重建的跑法（RESTORE_COMPOSE_DIR）：node 步骤在 backup 容器、pg_restore 在 Postgres 容器（替身 docker），然后清标记"
TARGET2="${TARGET_DB}_b"; TGT2=$(with_path "${BASE%/*}/$TARGET2" "$SCHEMA")
psql -q "$DATABASE_URL" -c "CREATE DATABASE $TARGET2"
crestore() { PATH="$HERE/fakes:$PATH" FAKE_RESTORE_DB_URL="$TGT2" RESTORE_COMPOSE_DIR="$R" bash "$HERE/../restore.sh" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
: > "$FAKE_LOG"
crestore latest
ok() { [ "$(rc)" = 0 ] && grep -q '"event":"restore_will_delete"' "$T/out"; }; check "dry-run 退出码 0（实际 $(rc)）" ok
crestore latest --execute
ok() { [ "$(rc)" = 0 ] && grep -q '"event":"restore_ok"' "$T/out"; }; check "--execute 退出码 0（实际 $(rc)）" ok
check "只剩留下的店" [ "$(q "$TGT2" "SELECT string_agg(id::text, ',') FROM stores")" = "$KEEP" ]
ok() { grep -q "run --rm -T -v .* backup node scripts/restore.ts finish" "$FAKE_LOG" && grep -q "exec -T postgres pg_restore -U yuanhui -d yuanhui" "$FAKE_LOG"; }; check "用的是 compose run backup 和 compose exec postgres pg_restore" ok
PATH="$HERE/fakes:$PATH" FAKE_RESTORE_DB_URL="$TGT2" docker compose -f "$R/compose.yml" --project-directory "$R" --env-file "$R/.env" run --rm -T backup node scripts/restore.ts clear-marker > "$T/out" 2>&1
check "清标记：之后是普通的在用库" grep -q '"state":"foreign"' "$T/out"
crestore latest --execute
ok() { [ "$(rc)" = 1 ] && grep -q "拒绝覆盖" "$T/out"; }; check "清过标记的库再恢复：拒绝覆盖" ok
ok() { grep -q '"event":"restore_failed","alert":"restore_failed","stage":"prepare"' "$R/backup/restore-events.log"; }; check "整机重建跑法失败写进 restore-events.log（stage=prepare）" ok
psql -q "$DATABASE_URL" -c "DROP DATABASE IF EXISTS $TARGET2 WITH (FORCE)"

t "OSS 跑法没设 BACKUP_OSS_ARCHIVE_BUCKET：拒绝（deletions/ 在存档桶，读成空的话已注销的店会复活），退出码 2，不连 OSS（PR #27 Fable S10r-8）"
# 端点指向本机一个不监听的端口：脚本真去连 OSS 的话会是「连不上」退出码 1，而不是配置检查的退出码 2
ossrestore() {
  env -u BACKUP_STORE_DIR BACKUP_OSS_REGION=oss-cn-shanghai BACKUP_OSS_BUCKET=yuanhui-backup BACKUP_OSS_ACCESS_KEY_ID=test-id \
    BACKUP_OSS_ACCESS_KEY_SECRET=test-secret BACKUP_OSS_ENDPOINT=https://127.0.0.1:9 BACKUP_PASSPHRASE="$PASS" DATABASE_URL="$TGT" \
    "$@" bash "$HERE/../restore.sh" latest > "$T/out" 2>&1; echo $? > "$T/rc"
}
ossrestore
check "退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
check "提示里点名 BACKUP_OSS_ARCHIVE_BUCKET 和后果" grep -q "BACKUP_OSS_ARCHIVE_BUCKET.*已注销的店" "$T/out"
check "没有走到下载那一步" no grep -q "── 1." "$T/out"
ossrestore BACKUP_OSS_ARCHIVE_BUCKET=
check "设成空串也拒绝：退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
ossrestore BACKUP_OSS_ARCHIVE_BUCKET=yuanhui-backup
check "显式写成和 BACKUP_OSS_BUCKET 同名（单桶老布局）：放过配置检查，之后连不上假端点，退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
ossrestore BACKUP_OSS_ARCHIVE_BUCKET=yuanhui-archive
check "设了存档桶：放过配置检查，退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "dry-run 前先打印 backups/ 和 deletions/ 各从哪个桶读" grep -q '"event":"restore_source","backups":"oss://yuanhui-backup","deletions":"oss://yuanhui-archive"' "$T/out"
restore latest
check "本机目录跑法：打印同一个目录" grep -q "\"event\":\"restore_source\",\"backups\":\"dir:$STORE\",\"deletions\":\"dir:$STORE\"" "$T/out"

t "改坏的情形都失败"
rm -f "$R/backup/restore-events.log"
P=wrong-passphrase-0123456789 restore latest --execute
check "口令不对：退出码 1" [ "$(rc)" = 1 ]
psql -q "$DATABASE_URL" -c "CREATE SCHEMA $SCHEMA" -c "CREATE TABLE $SCHEMA.live (x int)"
U=$SRC_URL restore latest --execute
ok() { [ "$(rc)" = 1 ] && grep -q "拒绝覆盖" "$T/out"; }; check "目标库不空又没有恢复标记：退出码 1，拒绝覆盖" ok
check "失败行带 stage=prepare" grep -q '"event":"restore_failed","alert":"restore_failed","stage":"prepare"' "$T/out"
check "那个库没被动" [ "$(q "$DATABASE_URL" "SELECT count(*) FROM pg_tables WHERE schemaname = '$SCHEMA'")" = 1 ]
f=$(find "$STORE/backups" -name '*.dump.enc' | sort | tail -1)
printf 'X' | dd of="$f" bs=1 seek=100 conv=notrunc 2>/dev/null
restore latest --execute
ok() { [ "$(rc)" = 1 ] && grep -q "解密失败" "$T/out"; }; check "备份被改了一个字节：退出码 1（解密失败）" ok
ok() { grep -q '"event":"restore_failed","alert":"restore_failed","stage":"fetch"' "$T/out" && [ ! -e "$R/backup/restore-events.log" ]; }; check "本机演练失败：打一行 restore_failed（stage=fetch），不写 restore-events.log" ok
crestore latest --execute
ok() { [ "$(rc)" = 1 ] && grep -q '"event":"restore_failed".*"exit_code":1' "$R/backup/restore-events.log" && [ "$(perm "$R/backup/restore-events.log")" = 644 ]; }; check "整机重建跑法失败：restore-events.log 追加一行 restore_failed、644（S10c 告警读它）" ok
check "参数不对：退出码 2" bash -c "BACKUP_PASSPHRASE=x DATABASE_URL=x bash '$HERE/../restore.sh' '../etc' >/dev/null 2>&1; [ \$? = 2 ]"

echo "通过 ${pass}，失败 $fail"
[ "$fail" = 0 ]
