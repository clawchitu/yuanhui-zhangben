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
# 3000（api）、5432（postgres）从公网连不上（S10a 验收 ①）。只认「连不上」（curl 7）和「超时」（28），
# 其余返回码（连上了但协议不对等）都算可达
for port in 3000 5432; do
  rc=0; curl -s -m 5 -o /dev/null "telnet://$HOST:$port" </dev/null 2>/dev/null || rc=$?
  if [ "$rc" = 7 ] || [ "$rc" = 28 ]; then echo "$port 端口公网不可达（正确）"; else echo "失败：$port 端口对公网可达（curl $rc）" >&2; exit 1; fi
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
