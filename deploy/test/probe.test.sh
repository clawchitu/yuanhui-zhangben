#!/usr/bin/env bash
# deploy/probe/ 的测试（S10c）：run-probe.sh 读配置的规矩（600、只认白名单键、不执行配置里的东西），launchd 配置每 10 分钟。
# node 用替身（PROBE_NODE），只记参数和环境；probe.ts 本身的逻辑在 server/test/monitor.test.ts。
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
P="$HERE/../probe"
pass=0; fail=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  ✗ $d"; sed 's/^/    /' "$T/out"; fi; }
t() { echo "• $1"; }
no() { ! "$@"; }
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/args"\nenv | grep "^PROBE_" | sort > "%s/env"\nexit 0\n' "$T" "$T" > "$T/node"; chmod +x "$T/node"
run() { rm -f "$T/args" "$T/env"; PROBE_NODE="$T/node" PROBE_ENV_FILE="$T/conf" bash "$P/run-probe.sh" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }

t "没有配置文件：退出码 2"
run
check "退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]

t "配置文件不是 600：退出码 2，不跑 node"
printf 'PROBE_URL=https://192.0.2.1\nPROBE_NOTIFY_CMD=cat\n' > "$T/conf"; chmod 644 "$T/conf"
run
check "退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
check "没跑 node" [ ! -e "$T/args" ]

t "600：只导出白名单里的键，值原样（不执行），参数传给 probe.ts"
cat > "$T/conf" <<CONF
# 注释
PROBE_URL=https://192.0.2.1
PROBE_NOTIFY_CMD=cat >> $T/sent
PROBE_WEBHOOK_TOKEN=\$(touch $T/pwned)
PATH=/nowhere
NODE_OPTIONS=--require=/tmp/evil.js
CONF
chmod 600 "$T/conf"
run --test-alert
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "跑的是 server/scripts/probe.ts，带上 --test-alert" bash -c "head -1 '$T/args' | grep -q 'server/scripts/probe.ts\$' && sed -n 2p '$T/args' | grep -qx -- --test-alert"
check "PROBE_URL 导出了" grep -qx 'PROBE_URL=https://192.0.2.1' "$T/env"
check "值里带空格和 >> 也原样" grep -qx "PROBE_NOTIFY_CMD=cat >> $T/sent" "$T/env"
check "配置里的 \$(...) 没被执行" [ ! -e "$T/pwned" ]
check "PATH、NODE_OPTIONS 这种白名单外的键不导出" grep -q "忽略配置里不认识的键：NODE_OPTIONS" "$T/out"

t "launchd 配置：每 10 分钟、跑 run-probe.sh"
check "StartInterval 600" grep -A0 -q '<key>StartInterval</key><integer>600</integer>' "$P/cn.yuanhuishop.probe.plist"
check "跑的是 run-probe.sh" grep -q '__REPO__/deploy/probe/run-probe.sh' "$P/cn.yuanhuishop.probe.plist"
if command -v plutil > /dev/null; then check "plist 语法" plutil -lint "$P/cn.yuanhuishop.probe.plist"; fi
check "示例配置里的值都留空（除了默认路径）" no grep -Eq '^(PROBE_URL|PROBE_SSH_TARGET|PROBE_NOTIFY_CMD|PROBE_WEBHOOK_URL|PROBE_WEBHOOK_TOKEN)=.+' "$P/probe.env.example"

echo "通过 ${pass}，失败 $fail"
[ "$fail" = 0 ]
