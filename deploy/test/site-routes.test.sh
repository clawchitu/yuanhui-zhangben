#!/usr/bin/env bash
# 根域名静态页的真实 HTTP 验收（S31「四个静态页可访问」，PR #76 Codex 第 2 轮）：
# 用仓库里的 deploy/Caddyfile.ip 在本机起一个真的 Caddy，只把证书换成 Caddy 自签（tls internal）、
# 端口换成本机高位端口、站点目录换成仓库的 deploy/site，其余路由原样，然后用 curl 逐个地址打：
#   https://yuanhuishop.cn 的 /、/index.html、/privacy、/privacy.html、/support、/support.html、
#   /review-barcodes、/review-barcodes.html、/favicon.svg → 200，内容是对应的页面；
#   /v1/sync、/healthz、/nope、/privacy/ → 404（根域名不反代 api）；
#   https://www.yuanhuishop.cn/privacy → 301 到 https://yuanhuishop.cn/privacy；http → 308 到 https。
# 用法（仓库根）：deploy/test/site-routes.test.sh。要本机有 caddy（brew install caddy）；没有就退出 2，不算通过。
# 发布前在部署机上跑；发布后再按 runbook 打线上 4 个地址和三个新页面。
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$(pwd)
command -v caddy >/dev/null || { echo "本机没有 caddy（brew install caddy），没跑" >&2; exit 2; }
tmp=$(mktemp -d -t yh-site-routes)
HP=18443 PP=18080
pid=""
cleanup() { [ -n "$pid" ] && kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

# 证书换自签、端口换高位、站点目录换仓库的、不开管理口；路由不动
python3 -I - "$root/deploy/Caddyfile.ip" "$root/deploy/site" "$tmp/Caddyfile" "$HP" "$PP" "$tmp/data" <<'PY'
import re, sys
src, site, out, hp, pp, data = sys.argv[1:7]
s = open(src, encoding="utf-8").read()
n_tls = len(re.findall(r"\ttls \{\n\t\tissuer acme \{\n(?:\t\t\t[^\n]*\n)+\t\t\}\n\t\}\n", s))
s = re.sub(r"\ttls \{\n\t\tissuer acme \{\n(?:\t\t\t[^\n]*\n)+\t\t\}\n\t\}\n", "\ttls internal\n", s)
if n_tls < 4: sys.exit(f"Caddyfile 里认出的 tls 块只有 {n_tls} 个（应有 IP、api、根域名、www 四个），格式变了，改本脚本")
if "/etc/caddy/site" not in s: sys.exit("Caddyfile 里没有 /etc/caddy/site")
s = s.replace("/etc/caddy/site", site)
s = s.replace("{\n\temail {$ACME_EMAIL}\n", "{\n\temail {$ACME_EMAIL}\n\tadmin off\n\tlocal_certs\n\tskip_install_trust\n\tstorage file_system " + data + "\n\thttps_port " + hp + "\n\thttp_port " + pp + "\n", 1)
if "\tlocal_certs\n" not in s: sys.exit("没找到全局选项块的开头，格式变了，改本脚本")
open(out, "w", encoding="utf-8").write(s)
PY

export ACME_EMAIL=test@example.invalid PUBLIC_IP=127.0.0.1
caddy validate --config "$tmp/Caddyfile" --adapter caddyfile >"$tmp/validate.log" 2>&1 \
  || { cat "$tmp/validate.log" >&2; echo "caddy validate 没过" >&2; exit 1; }
caddy run --config "$tmp/Caddyfile" --adapter caddyfile >"$tmp/caddy.log" 2>&1 &
pid=$!
for _ in $(seq 1 50); do
  curl -sk -o /dev/null --resolve "yuanhuishop.cn:$HP:127.0.0.1" "https://yuanhuishop.cn:$HP/" && break
  sleep 0.2
done

fail=0 n=0
get() { # 主机 路径 → 「状态码 Location」，正文写到 $tmp/body
  curl -sk -o "$tmp/body" -w '%{http_code} %{redirect_url}' --resolve "$1:$HP:127.0.0.1" "https://$1:$HP$2"
}
want() { # 说明 实际 期望
  n=$((n + 1))
  if [ "$2" = "$3" ]; then echo "  [对] $1"; else echo "  [错] $1：期望「$3」，实际「$2」"; fail=1; fi
}
page() { # 路径 页面文件
  local r; r=$(get yuanhuishop.cn "$1")
  want "https://yuanhuishop.cn$1 → 200" "${r%% *}" 200
  n=$((n + 1))
  if cmp -s "$tmp/body" "$root/deploy/site/$2"; then echo "  [对] $1 的内容就是 deploy/site/$2"
  else echo "  [错] $1 的内容不是 deploy/site/$2"; fail=1; fi
}

echo "根域名静态页（本机 Caddy $(caddy version | cut -d' ' -f1)，仓库的 Caddyfile.ip）："
page / index.html
page /index.html index.html
page /favicon.svg favicon.svg
for p in privacy support review-barcodes; do
  page "/$p" "$p.html"
  page "/$p.html" "$p.html"
done
for p in /v1/sync /healthz /nope /privacy/ /site/privacy.html; do
  r=$(get yuanhuishop.cn "$p"); want "https://yuanhuishop.cn$p → 404" "${r%% *}" 404
done
r=$(get www.yuanhuishop.cn /privacy)
want "https://www.yuanhuishop.cn/privacy → 301" "${r%% *}" 301
want "www 跳到根域名同一路径" "${r#* }" "https://yuanhuishop.cn/privacy"
r=$(curl -s -o /dev/null -w '%{http_code} %{redirect_url}' --resolve "yuanhuishop.cn:$PP:127.0.0.1" "http://yuanhuishop.cn:$PP/privacy")
want "http://yuanhuishop.cn/privacy → 308" "${r%% *}" 308
r=$(curl -sk -D - -o /dev/null --resolve "yuanhuishop.cn:$HP:127.0.0.1" "https://yuanhuishop.cn:$HP/privacy" | tr -d '\r' | grep -i '^content-type:' || true)
want "/privacy 的类型是 HTML" "$(echo "$r" | grep -ci 'text/html')" 1
[ $fail -eq 0 ] && echo "通过 $n 条" || { echo "有不对的（共 $n 条）；Caddy 日志 $tmp/caddy.log 已随临时目录删除，需要时去掉 trap 重跑" >&2; exit 1; }
