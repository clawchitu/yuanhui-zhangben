#!/usr/bin/env bash
# S26 联调（盘点）：本机临时 Postgres（SCRAM、TCP）+ 本机服务端 + 一台模拟器跑 S26LiveUITests。
# 用法：scripts/s26-live.sh <UDID>（先 build-for-testing 到 ${DD}，默认 /tmp/yh-s26-dd）
# 做的事：建临时库 → 迁移（跑两遍，第二遍应「没有新的迁移」）→ 建店「E2E-S26-<时间>」和家用号 → 起服务端 →
# s26-seed.ts 经 /v1/sync 以另一台手机的身份铺三样货（红牛 3 罐、可乐 5 罐、面包 4 袋）→
# testA（没网时「要联网才能盘点」、服务器没收到盘点；离线卖 1 罐红牛留在 outbox → 联网进盘点先传完卖出、账上 2 → 数 1 →
#        服务器记盘亏 1，卖出流水在盘点之前）→
# testB（盘点可乐时另一台手机卖了 1 罐 →「账上现在是 4 罐，你数的还对吗」→ 确认 → 服务器记盘盈 1、库存 5；
#        再用 -uiCountStaleOnce 让真服务器回 stale 走一遍；12b 列出面包，没扫的不变）→ 读库核对 → 停服务端、删库（REVIEW.md 12.6）。
# 口令随机生成，只在环境变量里，不写文件、不打印。
set -euo pipefail
export LC_ALL=en_US.UTF-8   # 不设的话 Postgres 启动时报「postmaster became multithreaded during startup」
udid="$1"
DD="${DD:-/tmp/yh-s26-dd}"
OUT="${OUT:-/tmp/yh-s26-results}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@16/bin}"
here="$(cd "$(dirname "$0")" && pwd)"
server="${here}/../../server"
work=$(mktemp -d /tmp/yh-s26-live.XXXXXX)
pgport=55726; port=8926
pgpw=$(openssl rand -hex 16); pw=$(openssl rand -hex 12)
export PGPASSWORD="${pgpw}"
user="e2e-s26-$(date +%H%M%S)"
store_name="E2E-S26-$(date +%Y%m%d-%H%M%S)"
log() { echo "S26-LIVE $(date '+%F %T %Z') $*"; }
mkdir -p "${OUT}"

cleanup() {
  set +e
  [[ -n "${spid:-}" ]] && kill "${spid}" 2>/dev/null
  "${PGBIN}/pg_ctl" -D "${work}/pg" -m fast stop >/dev/null 2>&1
  rm -rf "${work}"
  log "清理：服务端已停、临时库已删（${work}）"
}
trap cleanup EXIT

printf '%s\n' "${pgpw}" > "${work}/pwfile"
"${PGBIN}/initdb" -D "${work}/pg" -U yh --auth=scram-sha-256 --pwfile="${work}/pwfile" >/dev/null
rm -f "${work}/pwfile"
"${PGBIN}/pg_ctl" -D "${work}/pg" -o "-p ${pgport} -k ${work} -c listen_addresses=127.0.0.1" -l "${work}/pg.log" start >/dev/null
"${PGBIN}/createdb" -h 127.0.0.1 -p ${pgport} -U yh yh_s26
export DATABASE_URL="postgres://yh:${pgpw}@127.0.0.1:${pgport}/yh_s26"
psql() { "${PGBIN}/psql" -h 127.0.0.1 -p ${pgport} -U yh -d yh_s26 -qAt -v ON_ERROR_STOP=1 "$@"; }
cd "${server}"
log "迁移第一遍：$(node scripts/migrate.ts 2>&1 | tr '\n' ' ')"
log "迁移第二遍：$(node scripts/migrate.ts 2>&1 | tr '\n' ' ')"
sid=$(node scripts/create-store.ts --name "${store_name}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
ACCOUNT_PASSWORD="${pw}" node scripts/create-account.ts --store "${sid}" --username "${user}" >/dev/null
log "建店 ${store_name}（${sid}）、家用号 ${user}"

PORT=${port} HOST=127.0.0.1 node src/server.ts > "${work}/server.log" 2>&1 &
spid=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:${port}/healthz" >/dev/null && break; sleep 0.2; done
log "服务端起来了：/healthz $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${port}/healthz)"

readdb() {
  psql -c "SELECT 'products=' || (SELECT count(*) FROM products WHERE store_id = '${sid}')
           || ' entries=' || (SELECT count(*) FROM entries WHERE store_id = '${sid}')
           || ' stock_value_fen=' || (SELECT coalesce(sum(stock_value_fen), 0) FROM products WHERE store_id = '${sid}')"
}
log "写前读：$(readdb)"
export S26_BASE="http://localhost:${port}" S26_USER="${user}" S26_PASSWORD="${pw}"
log "铺夹具：$(node "${here}/s26-seed.ts")"
log "铺完读：$(readdb)"

xcrun simctl uninstall "${udid}" cn.yuanhuishop.zhangben 2>/dev/null || true
export TEST_RUNNER_YH_LIVE_BASE="http://localhost:${port}" TEST_RUNNER_YH_LIVE_USER="${user}" TEST_RUNNER_YH_LIVE_PASSWORD="${pw}"
run() {
  (cd "${here}/.." && xcodebuild -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=${udid}" -derivedDataPath "${DD}" \
    -collect-test-diagnostics never -resultBundlePath "${OUT}/$(date +%s)-$1-${udid}.xcresult" test-without-building \
    "-only-testing:YuanhuiZhangbenUITests/S26LiveUITests/$1" 2>&1 \
    | grep --line-buffered -E "error:|S26-LIVE|Test Case .*(passed|failed|skipped)|Executed|\*\* TEST")
  return ${PIPESTATUS[0]}
}
set +e
log "面包写前：$(psql -c "SELECT stock_qty || ' 袋 stock_ver=' || stock_ver FROM products WHERE store_id = '${sid}' AND name = 'S26 面包'")"
run testA_offlineThenDrainOutboxThenCountLoss; rc=$?
run testB_otherPhoneSoldAsksAndConfirm; rc2=$?
set -e
log "写后读：$(readdb)"
log "库存：$(psql -c "SELECT string_agg(name || ' ' || stock_qty || ' stock_ver=' || stock_ver || ' last_count_at=' || coalesce(to_char(last_count_at AT TIME ZONE 'Asia/Shanghai', 'MM-DD HH24:MI:SS'), '-'), '; ' ORDER BY name) FROM products WHERE store_id = '${sid}'")"
log "流水（按 seq）：$(psql -c "SELECT string_agg(seq || ' ' || e.type || ' ' || p.name || ' qty=' || e.qty_delta || ' value=' || e.value_delta_fen, '; ' ORDER BY seq) FROM entries e JOIN products p ON p.store_id = e.store_id AND p.id = e.product_id WHERE e.store_id = '${sid}' AND e.type IN ('sale', 'count')")"
log "被拒的盘点：$(psql -c "SELECT count(*) || ' 条 stale；盘点 op 共 ' || (SELECT count(*) FROM ops WHERE store_id = '${sid}' AND type = 'count') || ' 条' FROM ops WHERE store_id = '${sid}' AND type = 'count' AND reject_code = 'stale'")"
log "xcodebuild 退出码 testA=${rc} testB=${rc2}"
if [[ ${rc} -ne 0 || ${rc2} -ne 0 ]]; then log "服务端日志最后 30 行："; tail -30 "${work}/server.log" | cut -c1-400; exit 1; fi
