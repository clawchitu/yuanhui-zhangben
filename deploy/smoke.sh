#!/usr/bin/env bash
# 发布后冒烟（从本机跑，只读、不写数据）：/healthz、/v1/config、证书链、3000 / 5432 不对公网开、伪造 XFF。
# 没有 dry-run：默认就向 https://47.117.184.253 发只读请求（不 ssh、不改服务器上任何东西）。
# 用法：deploy/smoke.sh [https://47.117.184.253]
set -euo pipefail
BASE="${1:-https://47.117.184.253}"
HOST=$(echo "$BASE" | sed -E 's#https?://([^/:]+).*#\1#')
curl -fsS "$BASE/healthz" && echo " ← /healthz"
curl -fsS "$BASE/v1/config" >/dev/null && echo "/v1/config 正常"
# 证书链公开受信任（不加 -k）：失败即退出
curl -sS -o /dev/null -w '证书校验：%{ssl_verify_result}（0 = 公开受信任）\n' "$BASE/healthz"
# 只放行 /v1/* 和 /healthz，其余 404（Codex 6）
[ "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/")" = 404 ] && echo "/ → 404（正确）" || { echo "失败：/ 不是 404" >&2; exit 1; }
# 3000（api）、5432（postgres）从公网连不上（S10a 验收 ①）。只看 TCP 能不能建连：连上就算可达，
# 被拒绝或超时才算不可达。不能用 curl 的退出码判断：TCP 已连上、对端不先说话（Postgres 就是等客户端先发）时
# curl 也是 28，会把暴露的数据库当成「不可达」（PR #22 第二轮 Codex 2）。
# SMOKE_PORTS、SMOKE_TCP_TIMEOUT 只给单元测试用（deploy/test/smoke.test.sh）
tcp_open() { # tcp_open <主机> <端口> <秒>：0 = 建连成功；1 = 拒绝 / 超时 / 无路由
  local pid i
  # shellcheck disable=SC2016  # $0 $1 由内层 bash 展开
  bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null &
  pid=$!
  for ((i = 0; i < $3 * 10; i++)); do
    if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; return; fi
    sleep 0.1
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 1
}
for port in ${SMOKE_PORTS:-3000 5432}; do
  if tcp_open "$HOST" "$port" "${SMOKE_TCP_TIMEOUT:-5}"; then echo "失败：$port 端口对公网可达（TCP 建连成功）" >&2; exit 1; fi
  echo "$port 端口公网不可达（正确）"
done
# 伪造 X-Forwarded-For（S10a 验收 ②）：每次换一个伪造的头，用错误口令登录 31 次，第 31 次必须 429。
# 会占用本机 IP 15 分钟的登录额度；只在 SMOKE_XFF=1 时做
if [ "${SMOKE_XFF:-0}" = 1 ]; then
  code=""
  for i in $(seq 1 31); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Forwarded-For: 10.$i.0.1" -H 'content-type: application/json' \
      -d "{\"username\":\"smoke-nobody\",\"password\":\"x\",\"device_id\":\"$(uuidgen | tr A-Z a-z)\"}" "$BASE/v1/auth/login")
  done
  [ "$code" = 429 ] && echo "伪造 XFF 换不出额度（第 31 次 429，正确）" || { echo "失败：第 31 次是 $code" >&2; exit 1; }
fi
