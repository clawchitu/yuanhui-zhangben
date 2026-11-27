#!/usr/bin/env bash
# S30 验收：对**完整的 Release 归档包**做断言（plan-v2 §8 S30、§10「技术」）。查解开后的全部文件，不只是 Info.plist：
#   1. 最终 Info.plist 没有 ATS 例外（没有 NSAppTransportSecurity 下的任何放宽键）；ITSAppUsesNonExemptEncryption = NO；
#      显示名「元辉账本」、Bundle ID cn.yuanhuishop.zhangben（和备案一致）；包里有 PrivacyInfo.xcprivacy；
#   2. 二进制和资源（含 Frameworks、Assets.car、本地化文件）里搜不到 IP 字面量 47.117.184.253，搜得到 api.yuanhuishop.cn；
#   3. 没有证书文件（.cer/.crt/.der/.pem/.p12/.p7b），任何文件里没有 PEM 证书块；
#   4. 没有 Beta / Debug 专用的代码符号：IP 回退地址、证书锚点固定（SecTrustSetAnchorCertificates）、测试夹具参数；
#   5. 给的是导出的 ipa 时：签名是 Apple Distribution、没有 get-task-allow（.xcarchive 只打印归档时的签名，见第 5 段注释）。
# 用法（在 ios/ 下）：scripts/archive-check.sh <xxx.xcarchive | xxx.ipa | xxx.app>
#   .app 只用于自测（模拟器构建没有发布签名，第 5 条跳过）。make archive-check ARCHIVE=<路径> 同样。退出码：0 全过；1 有不过的项；2 用法错。
set -uo pipefail
src="${1:?需要 .xcarchive、.ipa 或 .app 的路径}"
[ -e "$src" ] || { echo "找不到 $src" >&2; exit 2; }
work=$(mktemp -d -t yh-archive-check)
trap 'rm -rf "$work"' EXIT
kind=app
case "$src" in
  *.ipa) kind=ipa; ditto -x -k "$src" "$work/ipa" || { echo "解不开 $src" >&2; exit 2; }; root="$work/ipa"
         app=$(find "$root/Payload" -maxdepth 1 -name '*.app' -type d | head -1) ;;
  *.xcarchive) kind=archive; root="$src"; app=$(find "$src/Products/Applications" -maxdepth 1 -name '*.app' -type d | head -1) ;;
  *.app) root="$src"; app="$src" ;;
  *) echo "只认 .xcarchive / .ipa / .app：$src" >&2; exit 2 ;;
esac
[ -n "${app:-}" ] && [ -d "$app" ] || { echo "$src 里找不到 .app" >&2; exit 2; }
plist="$app/Info.plist"
bad=0
fail() { echo "不过：$*" >&2; bad=1; }
ok() { echo "过：$*"; }
pv() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }

# 1. Info.plist
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$plist" >/dev/null 2>&1; then
  fail "Info.plist 有 NSAppTransportSecurity：$(plutil -extract NSAppTransportSecurity json -o - "$plist" 2>/dev/null)"
else ok "Info.plist 没有 ATS 例外"; fi
[ "$(pv ITSAppUsesNonExemptEncryption)" = "false" ] && ok "ITSAppUsesNonExemptEncryption = NO" || fail "ITSAppUsesNonExemptEncryption 不是 NO（$(pv ITSAppUsesNonExemptEncryption)）"
[ "$(pv CFBundleDisplayName)" = "元辉账本" ] && ok "显示名 元辉账本" || fail "显示名是「$(pv CFBundleDisplayName)」，要和备案一致：元辉账本"
[ "$(pv CFBundleIdentifier)" = "cn.yuanhuishop.zhangben" ] && ok "Bundle ID cn.yuanhuishop.zhangben" || fail "Bundle ID 是 $(pv CFBundleIdentifier)"
if [ -f "$app/PrivacyInfo.xcprivacy" ] && plutil -lint -s "$app/PrivacyInfo.xcprivacy"; then
  [ "$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$app/PrivacyInfo.xcprivacy" 2>/dev/null)" = "false" ] \
    && ok "PrivacyInfo.xcprivacy 在、不追踪" || fail "PrivacyInfo.xcprivacy 的 NSPrivacyTracking 不是 false"
else fail "包里没有合法的 PrivacyInfo.xcprivacy"; fi

# 2. IP 字面量：查 .app 里的全部文件（二进制、Frameworks、资源），归档的话连 dSYM 以外的全部
scan_root="$app"; [ "$kind" = app ] || scan_root="$root"
hits=$(LC_ALL=C grep -rlaF --exclude-dir='*.dSYM' -- "47.117.184.253" "$scan_root" 2>/dev/null)
[ -z "$hits" ] && ok "全部文件里没有 47.117.184.253" || fail "这些文件里有 IP 字面量：$hits"
LC_ALL=C grep -qaF "api.yuanhuishop.cn" "$app/$(pv CFBundleExecutable)" && ok "二进制里有 api.yuanhuishop.cn（查法有效）" || fail "二进制里找不到 api.yuanhuishop.cn，查法可能失效"

# 3. 证书文件
certs=$(find "$scan_root" -type f \( -iname '*.cer' -o -iname '*.crt' -o -iname '*.der' -o -iname '*.pem' -o -iname '*.p12' -o -iname '*.p7b' -o -iname '*.pfx' \) -not -path '*.dSYM/*')
[ -z "$certs" ] && ok "没有证书文件" || fail "包里有证书文件：$certs"
pem=$(LC_ALL=C grep -rlaE --exclude-dir='*.dSYM' -- "-----BEGIN (TRUSTED )?CERTIFICATE-----|-----BEGIN (RSA |EC )?PRIVATE KEY-----" "$scan_root" 2>/dev/null)
[ -z "$pem" ] && ok "没有 PEM 证书或私钥块" || fail "这些文件里有 PEM 块：$pem"

# 4. Beta / Debug 专用符号和字样（短于 16 字节的字符串会内联进指令查不到，这里只列长的；短参数由 release-check.sh 的 UI 测试管）
markers=("https://47.117.184.253" betaIPBase betaIPHost SecTrustSetAnchorCertificates SecTrustSetAnchorCertificatesOnly
         -uiSeedStoredAPIBase -uiResetStoredAPIBase -uiLoginLockedUntil zhangben-demo.sqlite
         5EED0000-0000-4000-8000-00000000F001 5EED0000-0000-4000-8000-00000000F002)
bin="$app/$(pv CFBundleExecutable)"
found=()
while IFS= read -r -d '' f; do
  for m in "${markers[@]}"; do LC_ALL=C grep -qaF -- "$m" "$f" && found+=("$m @ ${f#"$scan_root"/}"); done
done < <(find "$app" -type f \( -perm -u+x -o -name '*.dylib' \) -print0)
if command -v nm >/dev/null; then
  syms=$(nm -u "$bin" 2>/dev/null | grep -E "_SecTrustSetAnchorCertificates|_SecTrustSetPolicies" || true)
  [ -n "$syms" ] && found+=("导入符号 $syms")
fi
[ ${#found[@]} -eq 0 ] && ok "没有 Beta / Debug 专用的地址、证书锚点和夹具符号" || fail "有 Beta / Debug 专用的东西：${found[*]}"

# 5. 发布签名（只对导出的 ipa）。自动签名下 Xcode 归档时用的是 Apple Development 签名、带 get-task-allow，
#    导出（App Store Connect 方式）时才换成 Apple Distribution，所以 .xcarchive 只打印现状、不判不过（11/27 实测）。
if [ "$kind" = archive ]; then
  auth=$(codesign -dvv "$app" 2>&1 | grep '^Authority=' | head -1)
  echo "跳过：.xcarchive 的签名是归档时的（${auth:-没签名}），发布签名在导出的 .ipa 上查"
elif [ "$kind" = ipa ]; then
  auth=$(codesign -dvv "$app" 2>&1 | grep '^Authority=' | head -1)
  [[ "$auth" == "Authority=Apple Distribution"* ]] && ok "签名 $auth" || fail "签名不是 Apple Distribution：${auth:-没签名}"
  ent=$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -extract get-task-allow raw -o - - 2>/dev/null || echo absent)
  [ "$ent" = "true" ] && fail "entitlements 里 get-task-allow = true（开发包）" || ok "没有 get-task-allow"
else
  echo "跳过：.app 不查发布签名"
fi

[ $bad -eq 0 ] && echo "归档检查全部通过：$src" || echo "归档检查有不过的项：$src" >&2
exit $bad
