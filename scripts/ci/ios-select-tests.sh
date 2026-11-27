#!/usr/bin/env bash
# iOS CI 选测：按 PR 改动的路径和 scripts/ci/ios-test-map.txt，决定 PR 上跑全量还是只跑一部分。
#
# 用法（在仓库根下）：
#   scripts/ci/ios-select-tests.sh --base <SHA> --head <SHA>   用 git diff base...head 的文件列表
#   scripts/ci/ios-select-tests.sh --files <文件>              文件列表从文件里读（一行一个路径，- 表示标准输入）
#   scripts/ci/ios-select-tests.sh --self-test                 用几组典型改动检查规则（改了映射后跑一下）
# 输出（标准输出）：
#   全量时只有一行 FULL；
#   否则一行一个 xcodebuild -only-testing 的测试标识（单元测试两个 target + 冒烟集 + 选出来的 UI 测试）。
# 为什么这么选，写在标准错误里（CI 日志里看得到）。
# 映射里写的测试类 / 方法在 ios/UITests 里找不到时退出码 2（防止改名后静默少跑）。
# 兼容 macOS 自带的 bash 3.2（没有关联数组、mapfile）。
set -euo pipefail
set -f   # 规则里的 * 是给 [[ == ]] 用的模式，不让 shell 当成文件名展开
cd "$(dirname "$0")/../.."
MAP="${IOS_TEST_MAP:-scripts/ci/ios-test-map.txt}"
UITESTS=ios/UITests
UI_TARGET=YuanhuiZhangbenUITests
UNIT_TARGETS="YuanhuiZhangbenTests ShopCoreTests"

say() { echo "选测：$*" >&2; }

# 读映射：去掉注释和空行，每行「类型 字段...」
rules() { sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$MAP" | grep -v '^[[:space:]]*$' || true; }

# 测试写法统一成 YuanhuiZhangbenUITests/类[/方法]
norm() { case "$1" in "$UI_TARGET"/*) echo "$1" ;; *) echo "$UI_TARGET/$1" ;; esac; }

# 检查一个 UI 测试（类或类/方法）在 ios/UITests 里存在
test_exists() {
  local id="${1#"$UI_TARGET"/}" cls meth
  cls="${id%%/*}"
  meth=""
  [ "$cls" != "$id" ] && meth="${id#*/}"
  grep -qE "class[[:space:]]+$cls[[:space:]]*:" -r --include="*.swift" "$UITESTS" || return 1
  if [ -n "$meth" ]; then
    grep -qE "func[[:space:]]+$meth[[:space:]]*\(" -r --include="*.swift" "$UITESTS" || return 1
  fi
  return 0
}

validate_map() {
  local bad=0 kind rest t
  while read -r kind rest; do
    case "$kind" in
      smoke) set -- $rest ;;
      ui) set -- $rest; shift ;;
      full|none) continue ;;
      *) echo "映射里有不认识的类型「$kind」：$kind $rest" >&2; bad=1; continue ;;
    esac
    for t in "$@"; do
      test_exists "$(norm "$t")" || { echo "映射里的测试找不到（改名或删了？）：$t" >&2; bad=1; }
    done
  done <<<"$(rules)"
  [ $bad -eq 0 ] || exit 2
}

# 路径是否匹配模式（* 跨目录）
matches() { local f="$1" pat="$2"; [[ "$f" == $pat ]]; }

# 主逻辑：标准输入是改动的文件列表
select_tests() {
  local files f kind rest pat t matched is_none full=0 picked="" cls
  files=$(grep -v '^[[:space:]]*$' || true)
  local all_rules
  all_rules=$(rules)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in ios/*|contracts/*|scripts/ci/*|.github/workflows/ios.yml) ;; *) continue ;; esac
    matched=0
    is_none=0
    while read -r kind pat rest; do
      case "$kind" in
        full)
          if matches "$f" "$pat"; then say "$f 命中全量规则 $pat → 全量"; full=1; matched=1; fi ;;
        ui)
          if matches "$f" "$pat"; then
            matched=1
            for t in $rest; do picked="$picked $(norm "$t")"; done
            say "$f → $rest"
          fi ;;
        none)
          if matches "$f" "$pat"; then matched=1; is_none=1; fi ;;
      esac
    done <<<"$all_rules"
    # 改了 UI 测试文件本身：文件名就是类名的，跑这个类；共用的辅助文件 → 全量
    # 命中 none 的测试文件（联调、Release 检查：CI 里本来就跳过）不自动选
    [ $is_none -eq 1 ] || case "$f" in
      "$UITESTS"/*.swift)
        cls=$(basename "$f" .swift)
        if [ ! -f "$f" ]; then
          say "$f 删掉了，不用跑"; matched=1
        elif grep -qE "class[[:space:]]+$cls[[:space:]]*:" "$f"; then
          say "$f → $cls（改了测试本身）"; picked="$picked $UI_TARGET/$cls"; matched=1
        else
          say "$f 不是以类名命名的测试文件（共用辅助代码？）→ 全量"; full=1; matched=1
        fi ;;
    esac
    if [ $matched -eq 0 ]; then
      say "$f 没在 $MAP 里登记 → 全量（新目录请在映射里补一条规则）"; full=1
    fi
  done <<<"$files"

  if [ $full -eq 1 ]; then
    echo FULL
    return
  fi
  local smoke
  smoke=$(awk '$1=="smoke"{print $2}' <<<"$all_rules")
  for t in $smoke; do picked="$picked $(norm "$t")"; done
  # 去重；整类已选时去掉同类的单条方法
  local uniq classes out=""
  uniq=$(tr ' ' '\n' <<<"$picked" | grep -v '^$' | sort -u)
  classes=$(grep -vE "^$UI_TARGET/[^/]+/" <<<"$uniq" || true)
  for t in $uniq; do
    case "$t" in
      "$UI_TARGET"/*/*)
        cls="${t%/*}"
        if grep -qxF "$cls" <<<"$classes"; then continue; fi ;;
    esac
    out="$out$t"$'\n'
  done
  for t in $UNIT_TARGETS; do echo "$t"; done
  printf '%s' "$out"
}

# 跨目录引用核对：文件 A 里定义的（非 private）顶层类型被 B 目录用到，改 A 时选出的测试必须包含改 B 时选出的测试
# （A、B 取 ios/App/Features/*、App/Scanner、App/Net、ShopCore/Sources/ShopCore/*；按类型名 grep，注释里同名也算，宁可多报）
# （A 是全量的不用核；B 是全量的也不核，见下）。漏了就是「改了 A，用它的 B 页面坏了，PR 上测不出来」。
# dir_of 文件 目录...：输出文件所在的那个目录（列表里第一个是它前缀的）
dir_of() {
  local f="$1" x; shift
  for x in "$@"; do
    case "$f" in
      "$x"/*) echo "$x"; return 0 ;;
    esac
  done
}

cross_dir_check() {
  local root base dirs files f d t u bad=0 ta tb x
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd); base="$root/ios"
  [ -d "$base/App/Features" ] || { echo "  [跳过] 跨目录引用核对：找不到 ios/App/Features"; return 0; }
  echo "跨目录引用核对："
  # 本脚本关了通配（set -f），目录用 find 列：App 下的页面、扫码层、网络层，ShopCore 的各个模块
  dirs=$(cd "$base" && { find App/Features ShopCore/Sources/ShopCore -mindepth 1 -maxdepth 1 -type d; find App/Scanner App/Net -maxdepth 0 -type d; } 2>/dev/null | sort)
  [ "$(grep -c '^App/Features/' <<<"$dirs")" -ge 5 ] && [ "$(grep -c '^ShopCore/' <<<"$dirs")" -ge 5 ] \
    || { echo "  [错] 跨目录引用核对：没列出 App/Features 或 ShopCore 下的目录"; return 1; }
  # 按文件核（Net 这类目录只有按文件写的规则）：改这个文件选出的测试，必须包含其他目录里用到它的顶层类型的文件选出的测试
  files=$(cd "$base" && find $dirs -name '*.swift' -type f | sort)
  for f in $files; do
    d=$(dir_of "$f" $dirs)
    ta=$(printf 'ios/%s\n' "$f" | select_tests 2>/dev/null)
    [ "$ta" = FULL ] && continue
    for t in $(grep -hoE '^(@MainActor )?((public|final|internal) )*(struct|class|enum|protocol|actor) [A-Z][A-Za-z0-9]+' "$base/$f" | awk '{print $NF}' | sort -u); do
      # 引用方也按文件取（Net 这类只有按文件规则的目录，按目录探针会是 FULL 而被跳过，PR #73 第 3 轮评审）
      for u in $(cd "$base" && grep -rlw --include='*.swift' "$t" $dirs | grep -v "^$d/" | sort -u); do
        tb=$(printf 'ios/%s\n' "$u" | select_tests 2>/dev/null)
        # 用它的文件本身改了就跑全量（Navigation 引用每个页面、AppServices 这类公共层）：
        # 页面接到导航上由冒烟集的遍历兜着，不要求页面全量
        [ "$tb" = FULL ] && continue
        # 缺的：B 的测试里不在 A 里的（A 选了整个类，就算包含这个类的单条方法）
        x=$(while IFS= read -r y; do
              grep -qxF "$y" <<<"$ta" || grep -qxF "${y%/*}" <<<"$ta" || echo "$y"
            done <<<"$tb")
        [ -z "$x" ] || { echo "  [错] $u 用了 $f 的 $t，改它时缺 $(tr '\n' ' ' <<<"$x")"; bad=1; }
      done
    done
  done
  [ $bad -eq 0 ] && echo "  [对] 各文件的规则包含了引用它的文件的测试（App 页面、扫码层、网络层、ShopCore 模块）"
  return $bad
}

self_test() {
  local fail=0
  check() { # 描述 期望(FULL|包含的测试|-不包含的测试) 文件...
    local desc="$1" want="$2" got; shift 2
    got=$(printf '%s\n' "$@" | select_tests 2>/dev/null)
    case "$want" in
      FULL) [ "$got" = FULL ] ;;
      NOTFULL) [ "$got" != FULL ] ;;
      -*) [ "$got" != FULL ] && ! grep -qxF "${want#-}" <<<"$got" ;;
      *) grep -qxF "$want" <<<"$got" ;;
    esac && echo "  [对] $desc" || { echo "  [错] $desc：期望 $want，得到 $(tr '\n' ' ' <<<"$got")"; fail=1; }
  }
  validate_map
  echo "选测规则自检："
  check "只改快过期页 → 不全量" NOTFULL ios/App/Features/Expiry/ExpiryView.swift
  check "只改快过期页 → 跑 S27UITests" "$UI_TARGET/S27UITests" ios/App/Features/Expiry/ExpiryView.swift
  check "只改快过期页 → 带冒烟的全页面遍历" "$UI_TARGET/S15UITests/testFamilyTraversalReachesEveryPage" ios/App/Features/Expiry/ExpiryView.swift
  check "只改快过期页 → 单元测试照跑" YuanhuiZhangbenTests ios/App/Features/Expiry/ExpiryView.swift
  check "只改快过期页 → ShopCore 测试照跑" ShopCoreTests ios/App/Features/Expiry/ExpiryView.swift
  check "只改快过期页 → 不跑无关的 S22dUITests" "-$UI_TARGET/S22dUITests" ios/App/Features/Expiry/ExpiryView.swift
  check "改 Route → 全量" FULL ios/App/Features/Navigation/Route.swift
  check "改 AppModel → 全量" FULL ios/App/AppModel.swift
  check "改 Design → 全量" FULL ios/App/Design/Components/Buttons.swift
  check "改 ShopCore Models → 全量" FULL ios/ShopCore/Sources/ShopCore/Models/Models.swift
  check "改 ShopCore 同步 → 全量" FULL ios/ShopCore/Sources/ShopCore/SyncClient/SyncEngine.swift
  check "改契约 → 全量" FULL contracts/openapi.yaml
  check "页面 + Route 一起改 → 全量" FULL ios/App/Features/Expiry/ExpiryView.swift ios/App/Features/Navigation/Route.swift
  check "新功能目录没登记 → 全量" FULL ios/App/Features/Brandnew/BrandnewView.swift
  check "改 UI 测试本身 → 跑这个类" "$UI_TARGET/S24UITests" ios/UITests/S24UITests.swift
  check "改 S23a 的共用桩 → 也跑 S23aHeldUITests" "$UI_TARGET/S23aHeldUITests" ios/UITests/S23aUITests.swift
  check "只改单元测试 → 不全量" NOTFULL ios/AppTests/S27Tests.swift
  check "只改服务端 → 不全量" NOTFULL server/src/app.ts
  check "改 CI 自己 → 不全量" NOTFULL .github/workflows/ios.yml scripts/ci/ios-test-map.txt
  check "改联调测试 → 不选它（CI 里本来就跳过）" "-$UI_TARGET/S27LiveUITests" ios/UITests/S27LiveUITests.swift
  check "改 ReleaseBuildUITests → 不在 Debug 里选它" "-$UI_TARGET/ReleaseBuildUITests" ios/UITests/ReleaseBuildUITests.swift
  check "中文路径在 Navigation 下 → 全量" FULL "ios/App/Features/Navigation/路由.swift"
  check "改首页 → 整类 S15 没选上，只选两条" "-$UI_TARGET/S15UITests" ios/App/Features/Home/HomeView.swift
  check "改扫码层 ScanHub → 全量" FULL ios/App/Scanner/ScanHub.swift
  check "改卖出夹具 SellFixture（进货测试也靠它）→ 跑 S19UITests" "$UI_TARGET/S19UITests" ios/App/Features/Sell/SellFixture.swift
  check "改打折面板（进货、新商品也用）→ 跑 S19UITests" "$UI_TARGET/S19UITests" ios/App/Features/Discount/DiscountPanel.swift
  check "改 PendingModel（配对页也用）→ 跑 S23aHeldUITests" "$UI_TARGET/S23aHeldUITests" ios/App/Features/Pending/PendingModel.swift
  check "任何页面 → 带收银员遍历" "$UI_TARGET/S15UITests/testCashierTraversalNeverReachesFamilyPages" ios/App/Features/Expiry/ExpiryView.swift
  check "改整件换算 PackConversion（进货也用）→ 跑 S19UITests" "$UI_TARGET/S19UITests" ios/ShopCore/Sources/ShopCore/Basket/PackConversion.swift
  check "改商品图缓存（网络层 ProductImages 按文件登记、在用）→ 跑 S19UITests" "$UI_TARGET/S19UITests" ios/ShopCore/Sources/ShopCore/Images/ProductImageDisk.swift
  cross_dir_check || fail=1
  # 改名：Route.swift 挪到 Expiry 下，旧路径也要算（真的 git 仓库里做一次）
  local g; g=$(mktemp -d -t ios-select-rename)
  ( cd "$g" && git init -q && mkdir -p ios/App/Features/Navigation ios/App/Features/Expiry \
    && echo a > ios/App/Features/Navigation/Route.swift && git add -A && git -c user.name=t -c user.email=t@t commit -qm a \
    && git mv ios/App/Features/Navigation/Route.swift ios/App/Features/Expiry/Route.swift \
    && git -c user.name=t -c user.email=t@t commit -qm b ) >/dev/null
  got=$(git -C "$g" -c core.quotepath=off diff --name-only --no-renames HEAD~1...HEAD | select_tests 2>/dev/null)
  rm -rf "$g"
  [ "$got" = FULL ] && echo "  [对] 把 Route.swift 挪出 Navigation → 全量" || { echo "  [错] 把 Route.swift 挪出 Navigation：得到 $(tr '\n' ' ' <<<"$got")"; fail=1; }
  [ $fail -eq 0 ] && echo "自检通过" || { echo "自检有错"; exit 1; }
}

case "${1:-}" in
  --base)
    base="${2:?}"; [ "${3:-}" = --head ] || { echo "用法见文件开头" >&2; exit 2; }; head="${4:?}"
    validate_map
    # --no-renames：改名 / 移动时旧路径作为删除出现（从 Navigation 挪走也算改了 Navigation）；quotepath=off：中文路径原样输出
    git -c core.quotepath=off diff --name-only --no-renames "$base...$head" | select_tests ;;
  --files)
    validate_map
    if [ "${2:?}" = - ]; then select_tests; else select_tests <"$2"; fi ;;
  --self-test) self_test ;;
  *) sed -n '2,13p' "$0" >&2; exit 2 ;;
esac
