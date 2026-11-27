#!/usr/bin/env bash
# S30 商店截图（`make store-shots`）：用审核号登录「演示小店」，截 6.9 寸和 6.5 寸两套，每套 6 张（StoreShotsUITests）。
# 用法（在 ios/ 下）：scripts/store-shots.sh [输出目录，默认 ../docs/appstore/screenshots]
# 做的事：本机临时 Postgres（SCRAM、TCP）→ 迁移 → `create-demo-store.ts` 建演示小店和审核号（用户名、密码现生成，只在环境变量里）→
#   起本机服务端 → Debug 构建（只用 -uiAPIBase 指到本机，其余全是真实界面、真实数据，不用任何内容夹具）→
#   两台专用模拟器（iPhone 17 Pro Max 1320×2868 = 6.9 寸；iPhone 14 Plus 1284×2778 = 6.5 寸），简体中文、状态栏 9:41 →
#   跑 StoreShotsUITests 截图 → 删模拟器、停服务端、删库。
# 截完要人工逐张看：没有烟、酒、「烟酒店」字样，没有真实包装图（§10 内容、S30 验收）。
set -euo pipefail
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."
here=$(pwd)
out="${1:-../docs/appstore/screenshots}"
mkdir -p "$out"; out=$(cd "$out" && pwd)
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@16/bin}"
server="$here/../server"
work=$(mktemp -d /tmp/yh-store-shots.XXXXXX)
dd="${DD:-$work/dd}"
pgport="${SHOTS_PGPORT:-55730}"; port="${SHOTS_PORT:-8830}"
pgpw=$(openssl rand -hex 16); pw=$(openssl rand -hex 12)
user="review-shots"
export PGPASSWORD="$pgpw"
log() { echo "STORE-SHOTS $(date '+%F %T') $*"; }
udids=()
cleanup() {
  local rc=$?
  set +e
  for u in ${udids[@]+"${udids[@]}"}; do "$here/scripts/sim-destroy.sh" "$u" >/dev/null 2>&1; done
  [ -n "${spid:-}" ] && kill "$spid" 2>/dev/null
  "$PGBIN/pg_ctl" -D "$work/pg" -m fast stop >/dev/null 2>&1
  rm -rf "$work"
  log "清理：模拟器已删、服务端已停、临时库已删"
  exit "$rc"
}
trap cleanup EXIT

printf '%s\n' "$pgpw" > "$work/pwfile"
"$PGBIN/initdb" -D "$work/pg" -U yh --auth=scram-sha-256 --pwfile="$work/pwfile" >/dev/null
rm -f "$work/pwfile"
"$PGBIN/pg_ctl" -D "$work/pg" -o "-p $pgport -k $work -c listen_addresses=127.0.0.1" -l "$work/pg.log" start >/dev/null
"$PGBIN/createdb" -h 127.0.0.1 -p "$pgport" -U yh yh_shots
export DATABASE_URL="postgres://yh:$pgpw@127.0.0.1:$pgport/yh_shots"
psql() { "$PGBIN/psql" -h 127.0.0.1 -p "$pgport" -U yh -d yh_shots -qAt -v ON_ERROR_STOP=1 "$@"; }
(cd "$server" && node scripts/migrate.ts >/dev/null)
sid=$(cd "$server" && printf '%s\n' "$pw" | node scripts/create-demo-store.ts --username "$user" | python3 -c 'import json,sys; print(json.load(sys.stdin)["store_id"])')
log "演示小店 ${sid}、审核号 ${user}"
code() { psql -c "SELECT b.barcode FROM product_barcodes b JOIN products p ON p.store_id = b.store_id AND p.id = b.product_id
                  WHERE b.store_id = '$sid' AND p.name = '$1' AND b.pack_qty = 1 LIMIT 1"; }
codes="$(code '雪碧 500ml'),$(code '乐事薯片 75g'),$(code '康师傅红烧牛肉面'),$(code '清风抽纸')"
[[ "$codes" =~ ^[0-9]{13},[0-9]{13},[0-9]{13},[0-9]{13}$ ]] || { log "种子里找不到截图用的商品：$codes"; exit 1; }

(cd "$server" && PORT=$port HOST=127.0.0.1 exec node src/server.ts > "$work/server.log" 2>&1) &
spid=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$port/healthz" >/dev/null && break; sleep 0.2; done
curl -fs "http://127.0.0.1:$port/healthz" >/dev/null || { log "服务端没起来"; tail -20 "$work/server.log"; exit 1; }

xcodegen generate -q
first=""
export TEST_RUNNER_YH_SHOTS_BASE="http://localhost:$port" TEST_RUNNER_YH_SHOTS_USER="$user" TEST_RUNNER_YH_SHOTS_PASSWORD="$pw" TEST_RUNNER_YH_SHOTS_CODES="$codes"
for spec in "6.9:com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max" "6.5:com.apple.CoreSimulator.SimDeviceType.iPhone-14-Plus"; do
  size=${spec%%:*}; type=${spec#*:}
  udid=$("$here/scripts/sim-create.sh" "yh-store-shots-$size-$$" "$type"); udids+=("$udid")
  log "$size 寸：启动模拟器 $udid"
  xcrun simctl boot "$udid"; xcrun simctl bootstatus "$udid" -b >/dev/null || { log "模拟器启动超时（机器忙时会这样，重跑一次）"; exit 1; }
  xcrun simctl spawn "$udid" defaults write -g AppleLanguages -array zh-Hans
  xcrun simctl spawn "$udid" defaults write -g AppleLocale zh_CN
  xcrun simctl spawn "$udid" defaults write -g AppleICUForce24HourTime -bool true
  xcrun simctl shutdown "$udid"; xcrun simctl boot "$udid"; xcrun simctl bootstatus "$udid" -b >/dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 --cellularMode active --cellularBars 4 --wifiBars 3 || true
  # 先给相机权限，免得卖出页、进货页弹系统询问挡住界面（模拟器没有相机，取景框是黑的）
  xcrun simctl privacy "$udid" grant camera cn.yuanhuishop.zhangben
  if [ -z "$first" ]; then
    xcodebuild build-for-testing -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=$udid" -derivedDataPath "$dd" -quiet
    first=1
  fi
  dir="$out/$size"; rm -rf "$dir"; mkdir -p "$dir"
  export TEST_RUNNER_YH_SHOTS_DIR="$dir"
  xcodebuild test-without-building -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=$udid" -derivedDataPath "$dd" \
    -collect-test-diagnostics never -test-timeouts-enabled YES -maximum-test-execution-time-allowance 900 -only-testing:YuanhuiZhangbenUITests/StoreShotsUITests 2>&1 \
    | tee "$work/test-$size.log" | grep --line-buffered -E "error:|STORE-SHOT|Test Case .*(passed|failed|skipped)|\*\* TEST" || true
  grep -q "Test Case .*StoreShotsUITests.* passed" "$work/test-$size.log" || { log "$size 寸没截完"; tail -30 "$work/server.log" | cut -c1-300; exit 1; }
  n=$(ls "$dir"/*.png | wc -l | tr -d ' ')
  dims=$(sips -g pixelWidth -g pixelHeight "$dir"/1-home.png | awk '/pixel/{print $2}' | paste -sd x -)
  log "$size 寸：$n 张，$dims → $dir"
done
log "截完。上传前人工逐张看：没有烟、酒、「烟酒店」字样，没有真实包装图"
