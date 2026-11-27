#!/usr/bin/env bash
# S25 联调（商品列表、改商品、待确认补全）：本机临时 Postgres（SCRAM、TCP）+ 本机服务端 + 一台模拟器跑 S25LiveUITests。
# 用法：scripts/s25-live.sh <UDID>（先 build-for-testing 到 ${DD}，默认 /tmp/yh-s25-dd）
# 做的事：建临时库 → 迁移（跑两遍，第二遍应「没有新的迁移」）→ 建店「E2E-S25-<时间>」和家用号 → 起服务端 →
# s25-seed.ts 以另一台手机 B 的身份铺商品后断网 → testA（11 的数和接口一致、22 改价、22b 真服务器 stale 后补全、自动建的先填价挂码、
# 不卖了）→ testB（重开扫两个单件码 + 整箱码用新价；扫停用的照卖）→ 服务器上读补全记成什么 → s25-seed.ts --check（B 再联网拿到新价……）→ 停服务端、删库、删临时目录（REVIEW.md 12.6）。
# 测试进程自己以另一台手机的身份调报表接口核对。口令随机生成，只在环境变量里，不写文件、不打印。
set -euo pipefail
export LC_ALL=en_US.UTF-8   # 不设的话 Postgres 启动时报「postmaster became multithreaded during startup」
udid="$1"
DD="${DD:-/tmp/yh-s25-dd}"
OUT="${OUT:-/tmp/yh-s25-results}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@16/bin}"
here="$(cd "$(dirname "$0")" && pwd)"
server="${here}/../../server"
work=$(mktemp -d /tmp/yh-s25-live.XXXXXX)
pgport=55465; port=8815
pgpw=$(openssl rand -hex 16); pw=$(openssl rand -hex 12)
export PGPASSWORD="${pgpw}"
user="e2e-s25-$(date +%H%M%S)"
store_name="E2E-S25-$(date +%Y%m%d-%H%M%S)"
log() { echo "S25-LIVE $(date '+%F %T %Z') $*"; }
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
"${PGBIN}/createdb" -h 127.0.0.1 -p ${pgport} -U yh yh_s25
export DATABASE_URL="postgres://yh:${pgpw}@127.0.0.1:${pgport}/yh_s25"
psql() { "${PGBIN}/psql" -h 127.0.0.1 -p ${pgport} -U yh -d yh_s25 -qAt -v ON_ERROR_STOP=1 "$@"; }
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
export S25_BASE="http://localhost:${port}" S25_USER="${user}" S25_PASSWORD="${pw}" S25_STATE="${work}/b-state.json"
log "B 铺商品后断网：$(node "${here}/s25-seed.ts")"
log "铺完读：$(readdb)"

xcrun simctl uninstall "${udid}" cn.yuanhuishop.zhangben 2>/dev/null || true
export TEST_RUNNER_YH_LIVE_BASE="http://localhost:${port}" TEST_RUNNER_YH_LIVE_USER="${user}" TEST_RUNNER_YH_LIVE_PASSWORD="${pw}"
run() {
  (cd "${here}/.." && xcodebuild -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=${udid}" -derivedDataPath "${DD}" \
    -collect-test-diagnostics never -resultBundlePath "${OUT}/$(date +%s)-$1-${udid}.xcresult" test-without-building \
    "-only-testing:YuanhuiZhangbenUITests/S25LiveUITests/$1" 2>&1 \
    | grep --line-buffered -E "error:|S25-LIVE|Test Case .*(passed|failed|skipped)|Executed|\*\* TEST")
  return ${PIPESTATUS[0]}
}
set +e
run testA_listEditReviewArchive; rc=$?
run testB_scanUsesNewPrice; rc2=$?
set -e
log "写后读：$(readdb)"
log "服务器上 白象 / 自动建的：$(psql -c "SELECT string_agg(name || ' needs_review=' || needs_review || ' price=' || price_fen, '; ') FROM products WHERE store_id = '${sid}' AND (name LIKE '%白象%' OR name LIKE '%散装%')")"
log "服务器上补全记成：$(psql -c "SELECT string_agg(e.type || ' qty_delta=' || e.qty_delta || ' unit_cost=' || coalesce(e.unit_cost_fen::text,'null'), '; ') FROM entries e JOIN products p ON p.store_id = e.store_id AND p.id = e.product_id WHERE e.store_id = '${sid}' AND p.name LIKE '%白象%'")"
set +e
log "B 再联网核对：$(node "${here}/s25-seed.ts" --check 2>&1)"; rc3=${PIPESTATUS[0]}
set -e
log "退出码 testA=${rc} testB=${rc2} check=${rc3}"
if [[ ${rc} -ne 0 || ${rc2} -ne 0 || ${rc3} -ne 0 ]]; then log "服务端日志最后 30 行："; tail -30 "${work}/server.log" | cut -c1-400; exit 1; fi
