#!/usr/bin/env bash
# S23b 联调（账号与密码；S23b-2 起加注销申请、撤回）：本机临时 Postgres（SCRAM、TCP）+ 本机服务端 + 一台模拟器跑 S23bLiveUITests。
# 用法：scripts/s23b-live.sh <UDID> [测试名,…]（先 build-for-testing 到 ${DD}，默认 /tmp/yh-s23b-dd）
# 做的事：建临时库 → 迁移（跑两遍，第二遍应「没有新的迁移」）→ 建店「E2E-S23b-<时间>」和家用号 → 起服务端 →
# 测试前后各读一次库里的设备、流水、注销状态、密码改没改过 → 停服务端、删库、删临时目录（REVIEW.md 12.6）。
# 测试进程自己以另一台手机的身份走 API（登录、核对密码、/v1/me、登记商品、数流水）。口令随机生成，只在环境变量里，不写文件、不打印。
set -euo pipefail
export LC_ALL=en_US.UTF-8   # 不设的话 Postgres 启动时报「postmaster became multithreaded during startup」
udid="$1"; tests="${2:-}"
DD="${DD:-/tmp/yh-s23b-dd}"
OUT="${OUT:-/tmp/yh-s23b-results}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@16/bin}"
here="$(cd "$(dirname "$0")" && pwd)"
server="${here}/../../server"
work=$(mktemp -d /tmp/yh-s23b-live.XXXXXX)
pgport=55463; port=8813
pgpw=$(openssl rand -hex 16); pw=$(openssl rand -hex 12)
export PGPASSWORD="${pgpw}"
user="e2e-s23b-$(date +%H%M%S)"
store_name="E2E-S23b-$(date +%Y%m%d-%H%M%S)"
log() { echo "S23B-LIVE $(date '+%F %T %Z') $*"; }
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
"${PGBIN}/createdb" -h 127.0.0.1 -p ${pgport} -U yh yh_s23b
export DATABASE_URL="postgres://yh:${pgpw}@127.0.0.1:${pgport}/yh_s23b"
psql() { "${PGBIN}/psql" -h 127.0.0.1 -p ${pgport} -U yh -d yh_s23b -qAt -v ON_ERROR_STOP=1 "$@"; }
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
  psql -c "SELECT 'devices=' || (SELECT count(*) FROM devices WHERE store_id = '${sid}')
           || ' revoked=' || (SELECT count(*) FROM devices WHERE store_id = '${sid}' AND revoked_at IS NOT NULL)
           || ' entries=' || (SELECT count(*) FROM entries WHERE store_id = '${sid}')
           || ' delete_requested=' || (SELECT coalesce(to_char(delete_requested_at, 'YYYY-MM-DD\"T\"HH24:MI:SS'), 'null') FROM accounts WHERE store_id = '${sid}')
           || ' password_changed=' || (SELECT (password_hash <> '${hash0:-}')::text FROM accounts WHERE store_id = '${sid}')"
}
hash0=$(psql -c "SELECT password_hash FROM accounts WHERE store_id = '${sid}'")
log "写前读：$(readdb)"

xcrun simctl uninstall "${udid}" cn.yuanhuishop.zhangben 2>/dev/null || true
only=()
if [[ -n "${tests}" ]]; then
  IFS=',' read -ra names <<< "${tests}"
  for t in "${names[@]}"; do only+=("-only-testing:YuanhuiZhangbenUITests/S23bLiveUITests/${t}"); done
else
  only=("-only-testing:YuanhuiZhangbenUITests/S23bLiveUITests")
fi
export TEST_RUNNER_YH_LIVE_BASE="http://localhost:${port}" TEST_RUNNER_YH_LIVE_USER="${user}" TEST_RUNNER_YH_LIVE_PASSWORD="${pw}"
cd "${here}/.."
set +e
xcodebuild -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=${udid}" -derivedDataPath "${DD}" \
  -collect-test-diagnostics never -resultBundlePath "${OUT}/$(date +%s)-${udid}.xcresult" test-without-building "${only[@]}" 2>&1 \
  | grep --line-buffered -E "error:|S23B-LIVE|Test Case .*(passed|failed|skipped)|Executed|\*\* TEST"
rc=${PIPESTATUS[0]}
set -e
log "写后读：$(readdb)"
log "服务端日志里的改密码：$(grep -c '/v1/account/password' "${work}/server.log" || true) 条、申请注销：$(grep -c '/v1/account/delete-request' "${work}/server.log" || true) 条、撤回：$(grep -c '/v1/account/delete-cancel' "${work}/server.log" || true) 条"
log "xcodebuild 退出码 ${rc}"
[[ ${rc} -ne 0 ]] && { log "服务端日志最后 30 行："; tail -30 "${work}/server.log" | cut -c1-400; }
exit ${rc}
