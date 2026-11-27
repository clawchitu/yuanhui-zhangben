#!/usr/bin/env bash
# 审核用条码页能不能被扫出来（S30 验收「屏幕对屏幕能扫」的离线替身，PR #76 Codex 第 2 轮）：
# 用 Chrome 无头模式把 deploy/site/review-barcodes.html 按普通笔记本屏幕（1440 宽、2 倍屏）截图，
# 再模拟手机隔着屏幕拍到的密度：缩到一半宽，两种图都用 macOS Vision 认 EAN-13，
# 页面上写的每一个码（aria-label 里的 13 位）都必须认得出来，且认出来的不能有页面上没有的码。
# 真机对着屏幕扫一遍写在 S29 真机清单里（模拟器没有摄像头）。
# 用法（仓库根）：deploy/test/review-barcodes-scan.sh。要本机有 Google Chrome 和 Xcode 命令行工具（swift）。
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$(pwd)
chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$chrome" ] || { echo "没有 Google Chrome，没跑" >&2; exit 2; }
tmp=$(mktemp -d -t yh-bc-scan); trap 'rm -rf "$tmp"' EXIT
page="$root/deploy/site/review-barcodes.html"
want=$(grep -oE 'aria-label="EAN-13 [0-9]{13}' "$page" | grep -oE '[0-9]{13}' | sort -u)
[ "$(wc -l <<<"$want" | tr -d ' ')" -ge 10 ] || { echo "页面上认出的码不到 10 个，页面格式变了？" >&2; exit 1; }
"$chrome" --headless=new --disable-gpu --hide-scrollbars --no-first-run --user-data-dir="$tmp/prof" \
  --force-device-scale-factor=2 --window-size=1440,4000 --screenshot="$tmp/full.png" "file://$page" >/dev/null 2>&1
[ -s "$tmp/full.png" ] || { echo "Chrome 没截出图" >&2; exit 1; }
# 隔着屏幕拍：缩到一半宽（每个条码约 4 像素一格，接近手机隔着笔记本屏幕拍到的密度）
sips --resampleWidth 1440 "$tmp/full.png" --out "$tmp/half.png" >/dev/null
fail=0
for shot in full half; do
  got=$(swift "$root/deploy/test/decode-barcodes.swift" "$tmp/$shot.png" | sort -u)
  miss=$(comm -23 <(echo "$want") <(echo "$got")); extra=$(comm -13 <(echo "$want") <(echo "$got"))
  echo "$shot：页面上 $(wc -l <<<"$want" | tr -d ' ') 个码，认出 $(grep -c . <<<"$got" || true) 个"
  [ -z "$miss" ] || { echo "  认不出：$(tr '\n' ' ' <<<"$miss")"; fail=1; }
  [ -z "$extra" ] || { echo "  认出了页面上没有的码：$(tr '\n' ' ' <<<"$extra")"; fail=1; }
done
[ $fail -eq 0 ] && echo "审核用条码页：每个码都认得出" || exit 1
