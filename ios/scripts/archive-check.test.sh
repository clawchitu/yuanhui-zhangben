#!/usr/bin/env bash
# archive-check.sh 的自测：拿一份 Release 配置的 .app（默认现编一份模拟器 Release，不签名），
# 先确认原样全过，再逐个造反例（每个反例一份新拷贝），确认脚本都能抓到、退出码 1。
# 用法（在 ios/ 下）：scripts/archive-check.test.sh [已经编好的 Release .app]   退出码 0 = 全部符合预期
#   不给 .app 时用 DD（默认 /tmp/yh-archive-check-dd）编：xcodebuild build -configuration Release -destination 'generic/platform=iOS Simulator'
set -uo pipefail
export LC_ALL=en_US.UTF-8
cd "$(dirname "$0")/.."
check="$(pwd)/scripts/archive-check.sh"
app="${1:-}"
if [ -z "$app" ]; then
  dd="${DD:-/tmp/yh-archive-check-dd}"
  xcodegen generate -q
  xcodebuild build -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben -configuration Release \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath "$dd" -quiet CODE_SIGNING_ALLOWED=NO >/dev/null || { echo "Release 构建失败" >&2; exit 2; }
  app="$dd/Build/Products/Release-iphonesimulator/YuanhuiZhangben.app"
fi
[ -d "$app" ] || { echo "找不到 $app" >&2; exit 2; }
T=$(mktemp -d -t yh-archive-check-test)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
expect() { # expect <期望退出码> <说明> <要在输出里出现的字样> <路径>
  local want=$1 what=$2 pat=$3 path=$4 rc
  "$check" "$path" > "$T/out" 2>&1; rc=$?
  if [ "$rc" = "$want" ] && grep -qF -- "$pat" "$T/out"; then pass=$((pass + 1)); echo "  符合：${what}（退出码 ${rc}）"
  else fail=$((fail + 1)); echo "  不符合：${what}（退出码 ${rc}，期望 ${want}、含「${pat}」）"; sed 's/^/    | /' "$T/out"; fi
}
# 每个反例：拷一份 .app 到 $T/<名字>/YuanhuiZhangben.app，交给 mutate 改，再跑检查
case_app() { rm -rf "$T/c"; mkdir -p "$T/c"; cp -R "$app" "$T/c/"; echo "$T/c/$(basename "$app")"; }

echo "原样："
expect 0 "Release .app 全过" "归档检查全部通过" "$app"

echo "反例："
a=$(case_app); /usr/libexec/PlistBuddy -c "Add :NSAppTransportSecurity dict" -c "Add :NSAppTransportSecurity:NSAllowsArbitraryLoads bool true" "$a/Info.plist"
expect 1 "Info.plist 加了 ATS 例外" "不过：Info.plist 有 NSAppTransportSecurity" "$a"

a=$(case_app); /usr/libexec/PlistBuddy -c "Delete :ITSAppUsesNonExemptEncryption" "$a/Info.plist"
expect 1 "没有 ITSAppUsesNonExemptEncryption" "不过：ITSAppUsesNonExemptEncryption" "$a"

a=$(case_app); /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier cn.yuanhuishop.zhangben.beta" "$a/Info.plist"
expect 1 "Bundle ID 和备案不一致" "不过：Bundle ID" "$a"

a=$(case_app); rm -f "$a/PrivacyInfo.xcprivacy"
expect 1 "包里没有 PrivacyInfo.xcprivacy" "不过：包里没有合法的 PrivacyInfo.xcprivacy" "$a"

a=$(case_app); mkdir -p "$a/zh-Hans.lproj"; printf '"base" = "https://47.117.184.253";\n' > "$a/zh-Hans.lproj/Extra.strings"
expect 1 "资源文件里有 IP 字面量" "不过：这些文件里有 IP 字面量" "$a"

a=$(case_app); printf '\x00\x01pad47.117.184.253pad\x00' >> "$a/Assets.car"
expect 1 "二进制资源（Assets.car）里有 IP 字面量" "IP 字面量：$a/Assets.car" "$a"

a=$(case_app); printf 'not really a cert' > "$a/beta-ca.cer"
expect 1 "包里有 .cer 证书文件" "不过：包里有证书文件" "$a"

a=$(case_app); printf -- '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n' > "$a/anchor.dat"
expect 1 "文件里有 PEM 证书块（扩展名不像证书）" "不过：这些文件里有 PEM 块" "$a"

a=$(case_app); mkdir -p "$a/Frameworks"; printf 'xxSecTrustSetAnchorCertificatesxx' > "$a/Frameworks/libbeta.dylib"
expect 1 "Frameworks 里有证书锚点固定的符号" "不过：有 Beta / Debug 专用的东西" "$a"

echo "ipa（解包路径、发布签名）："
rm -rf "$T/ipa"; mkdir -p "$T/ipa/Payload"; cp -R "$app" "$T/ipa/Payload/"
(cd "$T/ipa" && ditto -c -k --sequesterRsrc --keepParent Payload "$T/unsigned.ipa")
expect 1 "没有发布签名的 ipa：签名那条不过，内容那几条照查" "不过：签名不是 Apple Distribution" "$T/unsigned.ipa"
grep -qF "过：全部文件里没有 47.117.184.253" "$T/out" && { pass=$((pass + 1)); echo "  符合：ipa 解开后照样查内容"; } || { fail=$((fail + 1)); echo "  不符合：ipa 没有查内容"; }

echo "用法："
"$check" /nonexistent.xcarchive > "$T/out" 2>&1; rc=$?
[ "$rc" = 2 ] && { pass=$((pass + 1)); echo "  符合：路径不存在退出码 2"; } || { fail=$((fail + 1)); echo "  不符合：路径不存在退出码 ${rc}"; }

echo "通过 ${pass}，不符合 ${fail}"
[ "$fail" = 0 ]
