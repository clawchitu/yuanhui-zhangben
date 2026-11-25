#!/usr/bin/env bash
# S22d 联调（选商品图）：本机临时 Postgres（SCRAM、TCP）+ 本机服务端（图片开关开、本机目录对象存储）+ 一台模拟器跑 S22dLiveUITests。
# 用法：scripts/s22d-live.sh <UDID>（先 build-for-testing 到 ${DD}，默认 /tmp/yh-s22d-dd）
# 做的事：建临时库 → 迁移（跑两遍，第二遍应「没有新的迁移」）→ 建店「E2E-S22d-<时间>」和家用号 → 铺两个条码的条码库行和
# 两张 ready 候选（缩图文件放进本机对象存储目录）→ 起服务端 → 跑测试 → 测试前后各读一次库里商品的 image_ver / image_source →
# 停服务端、删库、删临时目录。口令随机生成，只在环境变量里，不写文件、不打印。
set -euo pipefail
export LC_ALL=en_US.UTF-8   # 不设的话 Postgres 启动时报「postmaster became multithreaded during startup」
udid="$1"
DD="${DD:-/tmp/yh-s22d-dd}"
PGBIN="${PGBIN:-/opt/homebrew/opt/postgresql@16/bin}"
here="$(cd "$(dirname "$0")" && pwd)"
server="${here}/../../server"
work=$(mktemp -d /tmp/yh-s22d-live.XXXXXX)
pgport=55452; port=8797
pgpw=$(openssl rand -hex 16); pw=$(openssl rand -hex 12)
export PGPASSWORD="${pgpw}"
user="e2e-s22d-$(date +%H%M%S)"
store_name="E2E-S22d-$(date +%Y%m%d-%H%M%S)"
log() { echo "S22D-LIVE $(date '+%F %T %Z') $*"; }

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
"${PGBIN}/createdb" -h 127.0.0.1 -p ${pgport} -U yh yh_s22d
export DATABASE_URL="postgres://yh:${pgpw}@127.0.0.1:${pgport}/yh_s22d"
psql() { "${PGBIN}/psql" -h 127.0.0.1 -p ${pgport} -U yh -d yh_s22d -qAt -v ON_ERROR_STOP=1 "$@"; }
cd "${server}"
log "迁移第一遍：$(node scripts/migrate.ts 2>&1 | tr '\n' ' ')"
log "迁移第二遍：$(node scripts/migrate.ts 2>&1 | tr '\n' ' ')"
sid=$(node scripts/create-store.ts --name "${store_name}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')
ACCOUNT_PASSWORD="${pw}" node scripts/create-account.ts --store "${sid}" --username "${user}" >/dev/null
log "建店 ${store_name}（${sid}）、家用号 ${user}"

# 两个条码（演示数据里都没有）：A 在线选图，B 断网选图、强杀、联网后重发。每个两张 ready 候选
mkdir -p "${work}/objects" "${work}/cache"
codes="6970000220011 6970000220028"
python3 - "${work}/objects" ${codes} > "${work}/seed.sql" <<'PY'
import hashlib, os, struct, sys, zlib
root, codes = sys.argv[1], sys.argv[2:]
def jpeg(seed):
    # 不依赖第三方库：用系统 sips 把 PNG 转成 JPEG
    w = h = 200
    r, g, b = seed[0], seed[1], seed[2]
    raw = b"".join(b"\x00" + bytes([r, g, b]) * w for _ in range(h))
    def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    p = os.path.join(root, "tmp.png"); open(p, "wb").write(png)
    os.system(f"sips -s format jpeg {p} --out {p}.jpg >/dev/null 2>&1")
    d = open(p + ".jpg", "rb").read(); os.remove(p); os.remove(p + ".jpg"); return d
for code in codes:
    print(f"INSERT INTO barcode_catalog (barcode, found, name, spec, source) VALUES ('{code}', true, 'E2E 选图测试 {code[-3:]}', '500ml', 'e2e');")
    bh = hashlib.sha256(code.encode()).hexdigest()[:32]
    for idx in range(2):
        d = jpeg(hashlib.sha256(f"{code}-{idx}".encode()).digest())
        cid = hashlib.sha256(d).hexdigest()[:16]
        key = f"images/_catalog/{bh}/{cid}.jpg"
        os.makedirs(os.path.join(root, os.path.dirname(key)), exist_ok=True)
        open(os.path.join(root, key), "wb").write(d)
        print(f"INSERT INTO catalog_image_candidates (barcode, idx, source_url, state, cid, object_key, fetched_at) VALUES ('{code}', {idx}, 'https://e2e.invalid/{idx}.jpg', 'ready', '{cid}', '{key}', now());")
PY
psql -f "${work}/seed.sql"
log "铺条码库和候选：$(psql -c "SELECT barcode || ':' || string_agg(cid, ',' ORDER BY idx) FROM catalog_image_candidates GROUP BY barcode" | tr '\n' ' ')"

PORT=${port} HOST=127.0.0.1 PRODUCT_IMAGES_ENABLED=1 OBJECT_STORE=local OBJECT_STORE_DIR="${work}/objects" IMAGE_CACHE_DIR="${work}/cache" \
  node src/server.ts > "${work}/server.log" 2>&1 &
spid=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:${port}/healthz" >/dev/null && break; sleep 0.2; done
log "服务端起来了：/healthz $(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:${port}/healthz)，/v1/config $(curl -s http://127.0.0.1:${port}/v1/config)"

readdb() {
  psql -c "SELECT coalesce(string_agg(b.barcode || ' → ver=' || p.image_ver || ' source=' || coalesce(p.image_source, '-') || ' sha=' || left(coalesce(p.image_sha256, '-'), 16), '; '), '（店里还没有这两个商品）')
           FROM product_barcodes b JOIN products p ON p.store_id = b.store_id AND p.id = b.product_id
           WHERE b.store_id = '${sid}' AND b.barcode IN ('6970000220011', '6970000220028')"
}
log "写前读：$(readdb)"

xcrun simctl uninstall "${udid}" cn.yuanhuishop.zhangben 2>/dev/null || true
export TEST_RUNNER_YH_LIVE_BASE="http://localhost:${port}" TEST_RUNNER_YH_LIVE_USER="${user}" TEST_RUNNER_YH_LIVE_PASSWORD="${pw}"
cd "${here}/.."
set +e
xcodebuild -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -destination "id=${udid}" -derivedDataPath "${DD}" \
  -resultBundlePath "/tmp/yh-s22d-results/$(date +%s)-${udid}.xcresult" test-without-building \
  -only-testing:YuanhuiZhangbenUITests/S22dLiveUITests 2>&1 | grep --line-buffered -E "error:|S22D|Test Case .*(passed|failed|skipped)|Executed|\*\* TEST"
rc=${PIPESTATUS[0]}
set -e
log "写后读：$(readdb)"
log "服务端日志里的选图请求：$(grep -c '/select' "${work}/server.log" || true) 条；image 相关告警：$(grep -c 'image_discard_failed' "${work}/server.log" || true)"
log "xcodebuild 退出码 ${rc}"
exit ${rc}
