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
check "示例配置里的值都留空（除了默认路径）" no grep -Eq '^(PROBE_URL|PROBE_SITES|PROBE_SSH_TARGET|PROBE_NOTIFY_CMD|PROBE_WEBHOOK_URL|PROBE_WEBHOOK_TOKEN)=.+' "$P/probe.env.example"

t "PROBE_SITES 在白名单里，原样导出"
printf 'PROBE_URL=https://192.0.2.1\nPROBE_SITES=https://api.example.cn/healthz,https://example.cn/\nPROBE_NOTIFY_CMD=cat\n' > "$T/conf"; chmod 600 "$T/conf"
run
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "PROBE_SITES 导出了" grep -qx 'PROBE_SITES=https://api.example.cn/healthz,https://example.cn/' "$T/env"
check "没提示不认识" no grep -q "不认识的键：PROBE_SITES" "$T/out"

t "bark-notify.sh：key 从钥匙串读、不上命令行；第一行标题、其余正文、分组 yuanhui"
printf '#!/usr/bin/env bash\n[ "$1 $2 $3 $4" = "find-generic-password -s chitu-bark-key -w" ] || exit 44\necho K3yAbc123\n' > "$T/security"; chmod +x "$T/security"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/curl-args"\ncat > "%s/curl-conf"\nexit ${CURL_RC:-0}\n' "$T" "$T" > "$T/curl"; chmod +x "$T/curl"
bark() { printf '%s' "$1" | BARK_SECURITY="$T/security" BARK_CURL="$T/curl" bash "$P/bark-notify.sh" > "$T/out" 2>&1; echo $? > "$T/rc"; }
bark $'[元辉账本][告警·严重] 域名 api.example.cn 的证书剩余不到 14 天\n键：site_cert:api.example.cn\ndays_left：3\n'
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "key 只在 curl 的 stdin 配置里" grep -qx 'url = "https://api.day.app/K3yAbc123"' "$T/curl-conf"
check "命令行里没有 key" no grep -q K3yAbc123 "$T/curl-args"
check "标题是第一行" grep -qx 'title=\[元辉账本\]\[告警·严重\] 域名 api.example.cn 的证书剩余不到 14 天' "$T/curl-args"
check "正文是其余行" bash -c "grep -A2 '^body=' '$T/curl-args' | grep -q 'days_left：3'"
check "分组 yuanhui" grep -qx 'group=yuanhui' "$T/curl-args"
CURL_RC=22 bark "x"
check "curl 失败 → 非 0（探测下一轮重发；实际 $(rc)）" [ "$(rc)" != 0 ]
printf '#!/usr/bin/env bash\nexit 44\n' > "$T/security"
bark "x"
check "钥匙串里没有 → 退出码 3（实际 $(rc)）" [ "$(rc)" = 3 ]
check "bark-notify.sh 可执行" [ -x "$P/bark-notify.sh" ]

echo "通过 ${pass}，失败 $fail"
[ "$fail" = 0 ]
