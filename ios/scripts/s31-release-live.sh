#!/usr/bin/env bash
# S31 验收：线上测试店走一遍 S28 剧本的精简版（S31ReleaseLiveUITests），两种模式：
#   默认        Release 配置构建的 App 连 https://api.yuanhuishop.cn
#   --old-beta  「旧的 Beta 包（连 IP）仍然可用」：被测 App 换成 f6dc700（#54 改域名）之前的 Beta 配置构建，
#               包内默认 https://47.117.184.253，TestFlight 上家里人装的就是这种。脚本自己把旧代码取到临时 worktree、
#               xcodegen、用 Beta 配置为模拟器构建，再把当前分支 UI 测试包的 .xctestrun 里被测 App 换成它，test-without-building。
# 用法（在 ios/ 下）：YH_S31_PASSWORD=$(security find-generic-password -s yuanhui-test-store -a yuanhui -w) \
#   scripts/s31-release-live.sh [--old-beta] <模拟器 UDID> [用户名，默认 yuanhui] [derivedData 目录，默认 /tmp/yh-s31-dd]
#   模拟器用 scripts/sim-create.sh 建的专用那台。只往线上测试店写假数据（进 2 个、卖 2 个、撤 1 行），最后在界面上退出登录。
#   旧 Beta 的源码 worktree 放 $dd-oldbeta-src（跑完删），构建放 $dd-oldbeta。
# 和 release-check.sh 不同：要真登录，钥匙串要能用，所以构建要签名（模拟器上是本机 ad-hoc 签名，不用证书和描述文件）。
# 口令：只从环境变量进；xcodebuild 输出在写日志之前就洗掉（typeText 会把原文打出来），xcresult 跑完即删，最后查一遍目录里没有口令。
set -euo pipefail
umask 077
cd "$(dirname "$0")/.."
mode=release
if [ "${1:-}" = "--old-beta" ]; then mode=old-beta; shift; fi
udid="${1:?需要模拟器 UDID}"
user="${2:-yuanhui}"
dd="${3:-/tmp/yh-s31-dd}"
: "${YH_S31_PASSWORD:?要 YH_S31_PASSWORD（从钥匙串读，不写文件）}"
export YH_S31_PASSWORD
mkdir -p -m 700 "$dd"; chmod 700 "$dd"
log="$dd/s31-$mode-live.log"
result="$dd/Logs/Test/s31-$mode.xcresult"
rm -rf "$result"
sign=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
bundle=cn.yuanhuishop.zhangben

# 洗掉口令：typeText 的那一行整句换掉，另外凡是口令原文一律换掉（perl 从环境变量取，不进命令行）
scrub() { perl -pe 'BEGIN { $p = $ENV{YH_S31_PASSWORD}; $| = 1 } s/Type \x27.*?\x27 into (.*login\.password)/Type \x27<已隐去>\x27 into $1/g; s/\Q$p\E/<已隐去>/g if length $p'; }
cleanup() {
  rm -rf "$dd"/Logs/Test/*.xcresult
  # 查本脚本和 xcodebuild 写下的东西：日志、Logs/、xctestrun（不查 SourcePackages 和编译产物：第三方源码里本来就有各种字样，会误报）
  local hits
  hits=$(grep -rlF -- "$YH_S31_PASSWORD" "$dd"/*.log "$dd/Logs" "$dd"/Build/Products/*.xctestrun 2>/dev/null || true)
  if [ -n "$hits" ]; then echo "查到口令原文，删掉这些文件：" >&2; echo "$hits" >&2; echo "$hits" | while IFS= read -r f; do rm -f "$f"; done; exit 1; fi
}
trap cleanup EXIT

xcrun simctl uninstall "$udid" "$bundle" 2>/dev/null || true
export TEST_RUNNER_YH_S31_USER="$user" TEST_RUNNER_YH_S31_PASSWORD="$YH_S31_PASSWORD"
[ -n "${YH_S31_BASE:-}" ] && export TEST_RUNNER_YH_S31_BASE="$YH_S31_BASE"
filter() { tee "$log" | grep --line-buffered -E "error:|S31 |Test Case .*(passed|failed|skipped)|Executed|\*\* TEST|XCTAssert|等不到|找不到" || true; }

if [ "$mode" = release ]; then
  xcodebuild test -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben-ReleaseCheck \
    -destination "id=$udid" -derivedDataPath "$dd" "${sign[@]}" \
    -collect-test-diagnostics never -resultBundlePath "$result" \
    -only-testing:YuanhuiZhangbenUITests/S31ReleaseLiveUITests \
    2>&1 | scrub | filter || true
  app="$dd/Build/Products/Release-iphonesimulator/YuanhuiZhangben.app"
else
  export TEST_RUNNER_YH_S31_OLD_BETA=1
  old_rev="f6dc700^"
  src="$dd-oldbeta-src" odd="$dd-oldbeta"
  [ -e "$src" ] && { echo "$src 已存在，先删掉（git worktree remove）" >&2; exit 1; }
  git worktree add --quiet --detach "$src" "$old_rev"
  trap 'git worktree remove --force "$src" 2>/dev/null || true; cleanup' EXIT
  echo "S31 旧 Beta 源码：$(git -C "$src" log --oneline -1)"
  (cd "$src/ios" && xcodegen generate >/dev/null && \
    xcodebuild build -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben-Beta -configuration Beta \
      -destination "id=$udid" -derivedDataPath "$odd" "${sign[@]}" >"$odd.build.log" 2>&1) \
    || { echo "旧 Beta 构建失败，日志 $odd.build.log" >&2; exit 1; }
  app="$odd/Build/Products/Beta-iphonesimulator/YuanhuiZhangben.app"
  # 当前分支的 UI 测试包（Release 配置的 ReleaseCheck scheme）
  xcodebuild build-for-testing -project YuanhuiZhangben.xcodeproj -scheme YuanhuiZhangben-ReleaseCheck \
    -destination "id=$udid" -derivedDataPath "$dd" "${sign[@]}" >"$dd/s31-old-beta-build-for-testing.log" 2>&1 \
    || { echo "UI 测试包构建失败，日志 $dd/s31-old-beta-build-for-testing.log" >&2; exit 1; }
  run=$(ls -t "$dd"/Build/Products/*ReleaseCheck*.xctestrun | head -1)
  patched="$dd/Build/Products/s31-old-beta.xctestrun"
  cp "$run" "$patched"
  # 被测 App 换成旧 Beta：UITargetAppPath、DependentProductPaths 里那一项、被测 App 的 DYLD_* 目录（xctestrun 格式 1 和 2 都认）
  python3 -I - "$patched" "$app" <<'PY'
import plistlib, sys, os
path, app = sys.argv[1], sys.argv[2]
d = plistlib.load(open(path, "rb"))
targets = [t for c in d.get("TestConfigurations", []) for t in c.get("TestTargets", [])] if "TestConfigurations" in d \
    else [v for k, v in d.items() if k != "__xctestrun_metadata__" and isinstance(v, dict)]
n = 0
for t in targets:
    if "UITargetAppPath" not in t: continue
    old = t["UITargetAppPath"]
    t["UITargetAppPath"] = app
    t["DependentProductPaths"] = [app if p == old else p for p in t.get("DependentProductPaths", [])]
    olddir, newdir = os.path.dirname(old), os.path.dirname(app)
    env = t.get("UITargetAppEnvironmentVariables", {})
    for k, v in env.items():
        if isinstance(v, str): env[k] = v.replace(olddir, newdir)
    n += 1
if n == 0: sys.exit("xctestrun 里找不到 UITargetAppPath")
plistlib.dump(d, open(path, "wb"))
PY
  grep -qF "$app" "$patched" || { echo "xctestrun 里没换成旧 Beta 的 App" >&2; exit 1; }
  grep -F "Release-iphonesimulator/YuanhuiZhangben.app<" "$patched" >/dev/null && { echo "xctestrun 里还留着 Release App 的路径" >&2; exit 1; }
  xcodebuild test-without-building -xctestrun "$patched" -destination "id=$udid" \
    -collect-test-diagnostics never -resultBundlePath "$result" \
    -only-testing:YuanhuiZhangbenUITests/S31ReleaseLiveUITests \
    2>&1 | scrub | filter || true
fi

grep -q "\*\* TEST.* SUCCEEDED \*\*" "$log" || { echo "S31 联调没过，日志 $log" >&2; exit 1; }
grep -qE "Test Case .*S31ReleaseLiveUITests.* passed" "$log" || { echo "S31 用例没有真正跑（被跳过？）" >&2; exit 1; }
bin="$app/YuanhuiZhangben"
installed="$(xcrun simctl get_app_container "$udid" "$bundle" app)/YuanhuiZhangben"
# 模拟器上装着跑的就是这个二进制
[ "$(shasum -a 256 <"$bin")" = "$(shasum -a 256 <"$installed")" ] || { echo "模拟器上装的不是 $bin" >&2; exit 1; }
if [ "$mode" = release ]; then
  # 跑的确实是 Release 构建：二进制里没有 IP 字面量、有域名
  LC_ALL=C grep -aqF "47.117.184.253" "$bin" && { echo "跑的二进制里有 IP，不是 Release 构建？" >&2; exit 1; }
  LC_ALL=C grep -aqF "api.yuanhuishop.cn" "$bin" || { echo "跑的二进制里找不到 api.yuanhuishop.cn" >&2; exit 1; }
  echo "S31 Release 连域名精简剧本通过"
else
  # 跑的确实是默认连 IP 的旧 Beta：二进制里有整条 IP 地址；全程没有采用服务器下发的别的地址（没存 apiBase.adopted，或存的就是 IP）
  LC_ALL=C grep -aqF "https://47.117.184.253" "$bin" || { echo "跑的二进制里没有 https://47.117.184.253，不是旧 Beta？" >&2; exit 1; }
  prefs="$(xcrun simctl get_app_container "$udid" "$bundle" data)/Library/Preferences/$bundle.plist"
  adopted=$( [ -f "$prefs" ] && /usr/libexec/PlistBuddy -c "Print :apiBase.adopted" "$prefs" 2>/dev/null || true)
  case "$adopted" in ""|https://47.117.184.253|https://47.117.184.253/) ;; *) echo "旧 Beta 跑的时候换到了 $adopted，不是连 IP" >&2; exit 1 ;; esac
  echo "S31 旧 Beta 实际地址：包内默认 https://47.117.184.253，已存地址「${adopted:-无}」"
  echo "S31 旧 Beta 包（连 IP）精简剧本通过"
fi
