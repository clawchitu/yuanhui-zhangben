#!/usr/bin/env bash
# 本地验证 scripts/merge-pr.sh 的「main 红了就拒绝合并」：用一个假的 gh（不连 GitHub）喂固定数据，
# PR 本身各项都满足（CI 绿、两路评审通过），只变 main 上 ios 全量的历史，看脚本放不放行。
# 用法（仓库根下）：scripts/ci/test-merge-pr-main-lock.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
root=$(pwd)
tmp=$(mktemp -d -t merge-pr-lock)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

# 假 gh：按 API 路径回固定 JSON，有 --jq 就用 jq -r 过一遍（和真 gh 一样输出原始字符串）
cat >"$tmp/bin/gh" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = pr ] && [ "$2" = merge ]; then echo "FAKE-MERGED $*"; exit 0; fi
[ "$1" = api ] || { echo "假 gh 不认识：$*" >&2; exit 1; }
shift
path="" jqf="."
while [ $# -gt 0 ]; do
  case "$1" in
    --jq) jqf="$2"; shift 2 ;;
    --paginate) shift ;;
    *) path="$1"; shift ;;
  esac
done
sha=abc1234def
case "$path" in
  */pulls/7) body='{"state":"open","draft":false,"base":{"ref":"main"},"head":{"sha":"'$sha'"},"mergeable":true}' ;;
  */pulls/7/files) body='[{"filename":"ios/App/Features/Expiry/ExpiryView.swift"}]' ;;
  */commits/$sha/check-runs*) body='{"check_runs":[{"name":"server-ci","status":"completed","conclusion":"success","id":1,"started_at":"2026-11-27T01:00:00Z"},{"name":"ios-ci","status":"completed","conclusion":"success","id":2,"started_at":"2026-11-27T01:00:00Z"}]}' ;;
  */commits/$sha/check-suites) body='{"check_suites":[{"created_at":"2026-11-27T01:00:00Z"}]}' ;;
  */issues/7/comments*) body='[{"created_at":"2026-11-27T02:00:00Z","body":"Codex 审核：通过","user":{"login":"x"}},{"created_at":"2026-11-27T02:01:00Z","body":"Opus 审核：通过","user":{"login":"x"}}]' ;;
  */actions/workflows/ios.yml/runs\?branch=main*) body=$(cat "$FAKE_MAIN_RUNS") ;;
  */actions/workflows/ios.yml/runs\?head_sha=*) body=$(cat "$FAKE_PR_DISPATCH_RUNS") ;;
  */compare/*) body="{\"status\":\"${FAKE_COMPARE:-ahead}\"}" ;;
  *) echo "假 gh 没有这个路径：$path" >&2; exit 1 ;;
esac
jq -r "$jqf" <<<"$body"
FAKE
chmod +x "$tmp/bin/gh"

run() { # 名字 期望退出码(0 放行 / 1 拒绝) main 上的 runs JSON 本 PR 的手动全量 runs JSON [merge-pr 参数...]
  local name="$1" want="$2" main="$3" disp="$4" out code; shift 4
  echo "$main" >"$tmp/main.json"; echo "$disp" >"$tmp/disp.json"
  set +e
  out=$(PATH="$tmp/bin:$PATH" FAKE_MAIN_RUNS="$tmp/main.json" FAKE_PR_DISPATCH_RUNS="$tmp/disp.json" FAKE_COMPARE="${FAKE_COMPARE:-ahead}" \
    bash "$root/scripts/merge-pr.sh" 7 --dry-run "$@" 2>&1)
  code=$?
  set -e
  local line; line=$(grep -E "main (的|上)" <<<"$out" | head -1)
  if [ "$code" = "$want" ]; then echo "  [对] $name（退出码 $code）$line"; else echo "  [错] $name：期望 $want 得到 $code"; echo "$out" | sed 's/^/      /'; fail=1; fi
}
r() { # event conclusion created_at [status] [run_attempt]
  local concl="\"$2\""; [ "$2" = null ] && concl=null
  echo "{\"event\":\"$1\",\"conclusion\":$concl,\"created_at\":\"$3\",\"status\":\"${4:-completed}\",\"run_attempt\":${5:-1},\"head_sha\":\"0123456789\",\"html_url\":\"https://example/run\"}"
}
none='{"workflow_runs":[]}'
fail=0
echo "merge-pr.sh 的 main 红锁："
run "main 最新全量绿 → 放行" 0 "{\"workflow_runs\":[$(r push success 2026-11-27T03:00:00Z),$(r push failure 2026-11-27T01:00:00Z)]}" "$none"
run "main 最新全量红 → 拒绝" 1 "{\"workflow_runs\":[$(r push failure 2026-11-27T03:00:00Z),$(r push success 2026-11-27T01:00:00Z)]}" "$none"
run "夜间全量红 → 拒绝" 1 "{\"workflow_runs\":[$(r schedule failure 2026-11-27T19:00:00Z),$(r push success 2026-11-27T03:00:00Z)]}" "$none"
run "红之后的新一轮被取消 → 仍按红拒绝" 1 "{\"workflow_runs\":[$(r push cancelled 2026-11-27T04:00:00Z),$(r push failure 2026-11-27T03:00:00Z)]}" "$none"
run "超时也算红 → 拒绝" 1 "{\"workflow_runs\":[$(r push timed_out 2026-11-27T03:00:00Z)]}" "$none"
run "红之后修绿 → 放行" 0 "{\"workflow_runs\":[$(r push success 2026-11-27T05:00:00Z),$(r push failure 2026-11-27T03:00:00Z)]}" "$none"
run "main 上找不到跑完的全量 → 按红拒绝" 1 "$none" "$none"
run "只有被取消的（第一次跑）→ 找不到，按红拒绝" 1 "{\"workflow_runs\":[$(r push cancelled 2026-11-27T04:00:00Z),$(r schedule cancelled 2026-11-27T03:00:00Z)]}" "$none"
run "对红的那轮点了 Re-run、又被取消 → 仍按红拒绝" 1 "{\"workflow_runs\":[$(r push cancelled 2026-11-27T03:00:00Z completed 2),$(r push success 2026-11-27T01:00:00Z)]}" "$none"
run "main 红 + --fix-main 但没手动全量 → 拒绝" 1 "{\"workflow_runs\":[$(r push failure 2026-11-27T03:00:00Z)]}" "$none" --fix-main
run "main 红 + --fix-main + 手动全量失败 → 拒绝" 1 "{\"workflow_runs\":[$(r push failure 2026-11-27T03:00:00Z)]}" "{\"workflow_runs\":[$(r workflow_dispatch failure 2026-11-27T04:00:00Z)]}" --fix-main
run "main 红 + --fix-main + 手动全量成功 → 放行" 0 "{\"workflow_runs\":[$(r push failure 2026-11-27T03:00:00Z)]}" "{\"workflow_runs\":[$(r workflow_dispatch success 2026-11-27T04:00:00Z)]}" --fix-main
run "新一轮还在跑（第一次）→ 看上一轮跑完的：绿放行" 0 "{\"workflow_runs\":[$(r push null 2026-11-27T05:00:00Z in_progress 1),$(r push success 2026-11-27T03:00:00Z)]}" "$none"
run "新一轮还在跑（第一次）→ 看上一轮跑完的：红拒绝" 1 "{\"workflow_runs\":[$(r push null 2026-11-27T05:00:00Z in_progress 1),$(r push failure 2026-11-27T03:00:00Z)]}" "$none"
run "对红的那轮点了 Re-run、还在跑 → 仍拒绝" 1 "{\"workflow_runs\":[$(r push null 2026-11-27T03:00:00Z in_progress 2),$(r push success 2026-11-27T01:00:00Z)]}" "$none"
FAKE_COMPARE=behind run "main 红 + --fix-main + 手动全量成功，但 PR 没 rebase 到红的提交 → 拒绝" 1 "{\"workflow_runs\":[$(r push failure 2026-11-27T03:00:00Z)]}" "{\"workflow_runs\":[$(r workflow_dispatch success 2026-11-27T04:00:00Z)]}" --fix-main
FAKE_COMPARE=diverged run "--fix-main，PR 和 main 分叉 → 拒绝" 1 "{\"workflow_runs\":[$(r push failure 2026-11-27T03:00:00Z)]}" "{\"workflow_runs\":[$(r workflow_dispatch success 2026-11-27T04:00:00Z)]}" --fix-main
[ $fail -eq 0 ] && echo "全部符合预期" || { echo "有不符合预期的"; exit 1; }
