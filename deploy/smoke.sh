#!/usr/bin/env bash
# 发布后冒烟（从本机跑，只读、不写数据）：/healthz、/v1/config、证书链、api 端口不对公网开、伪造 XFF。
# 用法：deploy/smoke.sh [https://47.117.184.253]   （只发 HTTP 请求，不 ssh）
set -euo pipefail
BASE="${1:-https://47.117.184.253}"
HOST=$(echo "$BASE" | sed -E 's#https?://([^/:]+).*#\1#')
curl -fsS "$BASE/healthz" && echo " ← /healthz"
curl -fsS "$BASE/v1/config" >/dev/null && echo "/v1/config 正常"
# 证书链公开受信任（不加 -k）：失败即退出
curl -sS -o /dev/null -w '证书校验：%{ssl_verify_result}（0 = 公开受信任）\n' "$BASE/healthz"
# api 的 3000 端口从公网连不上（S10a 验收 ①）
if curl -sS -m 5 -o /dev/null "http://$HOST:3000/healthz" 2>/dev/null; then echo "失败：3000 端口对公网可达" >&2; exit 1; else echo "3000 端口公网不可达（正确）"; fi
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
