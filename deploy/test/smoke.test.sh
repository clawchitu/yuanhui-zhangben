#!/usr/bin/env bash
# smoke.sh 端口检查的单元测试：本机起一个「接受连接但不先说话」的监听（和 Postgres 一样），
# 端口检查必须判成可达并失败；关着的端口、黑洞地址判成不可达。HTTP 部分用 fakes/curl 顶替，不连任何服务器。
# 用法：deploy/test/smoke.test.sh        退出码 0 = 全部通过
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SMOKE="${SMOKE_SH:-$HERE/../smoke.sh}"
REAL_CURL=$(command -v curl); export REAL_CURL
pass=0; fail=0; T=$(mktemp -d); LPID=""
cleanup() { [ -n "$LPID" ] && { kill "$LPID"; wait "$LPID"; } 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT
# 监听一个空闲端口，只 listen 不 accept、不发任何字节；端口号写到 $T/port
python3 -I -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(16)
open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(600)' "$T/port" &
LPID=$!
for _ in $(seq 1 50); do [ -s "$T/port" ] && break; sleep 0.1; done
OPEN=$(cat "$T/port")
# 关着的端口：拿一个空闲端口号后立刻关掉
CLOSED=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
smoke() { # smoke <主机> <端口…>
  local h=$1; shift
  PATH="$HERE/fakes:$PATH" SMOKE_PORTS="$*" SMOKE_TCP_TIMEOUT=2 bash "$SMOKE" "https://$h" > "$T/out" 2>&1; echo $? > "$T/rc"
}
rc() { cat "$T/rc"; }
check() {
  local d=$1; shift
  if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  ✗ $d"; sed 's/^/    /' "$T/out"; fi
}

echo "• 端口在监听、对端不先说话（像暴露的 Postgres）：判成可达，冒烟失败"
smoke 127.0.0.1 "$OPEN"
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "输出写明端口可达" grep -q "失败：${OPEN} 端口对公网可达" "$T/out"

echo "• 关着的端口（连接被拒绝）：判成不可达，冒烟通过"
smoke 127.0.0.1 "$CLOSED"
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "输出写明不可达" grep -q "${CLOSED} 端口公网不可达（正确）" "$T/out"

echo "• 黑洞地址（192.0.2.1，超时或无路由）：判成不可达"
smoke 192.0.2.1 5432
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]

echo "• 两个端口里有一个开着：冒烟失败"
smoke 127.0.0.1 "$CLOSED" "$OPEN"
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]

echo "通过 ${pass}，失败 $fail"
[ "$fail" = 0 ]
