#!/usr/bin/env bash
# 合并 PR 的唯一入口（代替 GitHub 分支保护，原因见 docs/process-deviations.md）。
#
# 用法：scripts/merge-pr.sh <PR号> [--dry-run]
#   --dry-run  只检查，不合并；检查全过时退出码 0，否则 1。
#
# 合并条件（缺一样就拒绝）：
#   1. PR 是 open、不是草稿、没有冲突，目标分支是 main。
#   2. server-ci：对 PR 当前 head 提交必须有一次成功的运行（server 工作流对每个 PR 都触发）。
#   3. ios-ci：PR 改了 ios/**、contracts/** 或 .github/workflows/ios.yml 时必须成功；
#      没改这些路径、工作流按 paths 过滤没触发时视为「不需要」。
#      只要 head 上出现过 ios-ci，不管是否需要，都必须是成功。
#   4. PR 评论里，在当前 head 推上来之后，有以「Codex 审核：通过」开头和以「Fable 审核：通过」开头的评论；
#      每一方以最后一条「X 审核：」开头的评论为准（后来又写了「不通过」就不算过）。
#      有新提交后，旧的「通过」作废，必须重审。
#   合并方式：squash，--match-head-commit 防止检查和合并之间有人再推。
set -euo pipefail

REPO="${REPO:-clawchitu/yuanhui-zhangben}"
pr="${1:-}"
dry=0
[ "${2:-}" = "--dry-run" ] && dry=1
if ! [[ "$pr" =~ ^[0-9]+$ ]]; then
  echo "用法：$0 <PR号> [--dry-run]" >&2
  exit 2
fi

fail=0
ok()  { echo "  [通过] $*"; }
bad() { echo "  [拒绝] $*"; fail=1; }

echo "检查 $REPO#$pr"

info=$(gh api "repos/$REPO/pulls/$pr")
state=$(jq -r .state <<<"$info")
draft=$(jq -r .draft <<<"$info")
base=$(jq -r .base.ref <<<"$info")
sha=$(jq -r .head.sha <<<"$info")
echo "  head = $sha"

[ "$state" = "open" ] && ok "PR 是 open" || bad "PR 状态是 $state"
[ "$draft" = "false" ] && ok "不是草稿" || bad "PR 是草稿"
[ "$base" = "main" ] && ok "目标分支 main" || bad "目标分支是 $base，不是 main"

# mergeable 由 GitHub 异步计算，可能先是 null，等一会儿
mergeable=null
for _ in 1 2 3 4 5; do
  mergeable=$(gh api "repos/$REPO/pulls/$pr" --jq '.mergeable')
  [ "$mergeable" != "null" ] && break
  sleep 2
done
[ "$mergeable" = "true" ] && ok "没有冲突" || bad "GitHub 报告不可合并（mergeable=$mergeable）"

# ---- 改动路径 ----
files=$(gh api --paginate "repos/$REPO/pulls/$pr/files" --jq '.[].filename')
ios_needed=0
if grep -qE '^(ios/|contracts/|\.github/workflows/ios\.yml$)' <<<"$files"; then ios_needed=1; fi

# ---- CI ----
runs=$(gh api --paginate "repos/$REPO/commits/$sha/check-runs?per_page=100" --jq '.check_runs[] | {name, status, conclusion, id, started_at}' | jq -s .)

# 取某个检查在 head 上最近一次运行的结果；没有则输出空
latest_run() {
  jq -r --arg n "$1" '[.[] | select(.name == $n)] | sort_by(.started_at) | last | if . == null then "" else "\(.status)/\(.conclusion)" end' <<<"$runs"
}

check_ci() {
  local name="$1" needed="$2" r
  r=$(latest_run "$name")
  if [ -z "$r" ]; then
    if [ "$needed" = 1 ]; then
      bad "$name 在 head 上没有运行（应该触发却没跑：runner 离线或还没排上？）"
    else
      ok "$name 没触发，本 PR 没改相关路径，不需要"
    fi
  elif [ "$r" = "completed/success" ]; then
    ok "$name 成功"
  else
    bad "$name 状态 $r"
  fi
}
check_ci server-ci 1
check_ci ios-ci "$ios_needed"

# ---- 评审评论 ----
# 「当前 head 推上来的时间」：取 head 提交上最早的 check suite 创建时间（每次推送都会触发 server 工作流）；
# 拿不到就退回用提交时间。评审评论必须晚于这个时间。
pushed_at=$(gh api "repos/$REPO/commits/$sha/check-suites" --jq '[.check_suites[].created_at] | min // empty')
if [ -z "$pushed_at" ]; then
  pushed_at=$(gh api "repos/$REPO/commits/$sha" --jq '.commit.committer.date')
fi
echo "  head 推送时间约 $pushed_at"

comments=$(gh api --paginate "repos/$REPO/issues/$pr/comments?per_page=100" --jq '.[] | {created_at, body, user: .user.login}' | jq -s .)

check_review() {
  local who="$1" last
  # 该评审方在 head 推送之后的最后一条「X 审核：」评论（去掉开头空白）
  last=$(jq -r --arg who "$who" --arg t "$pushed_at" '
    [ .[] | select(.created_at > $t)
          | .body |= sub("^\\s+"; "")
          | select(.body | startswith($who + " 审核："))
    ] | sort_by(.created_at) | last | if . == null then "" else .body end' <<<"$comments")
  if [ -z "$last" ]; then
    stale=$(jq -r --arg who "$who" '[.[] | select((.body | sub("^\\s+"; "")) | startswith($who + " 审核："))] | length' <<<"$comments")
    if [ "$stale" -gt 0 ]; then
      bad "$who 的审核评论都早于当前 head，需要重审"
    else
      bad "没有「$who 审核：通过」评论"
    fi
  elif [[ "$last" == "$who 审核：通过"* ]]; then
    ok "$who 审核：通过"
  else
    bad "$who 最后一条审核评论不是通过：$(head -c 80 <<<"$last" | head -n1)"
  fi
}
check_review Codex
check_review Fable

if [ "$fail" -ne 0 ]; then
  echo "结论：不能合并"
  exit 1
fi
if [ "$dry" -eq 1 ]; then
  echo "结论：可以合并（--dry-run，未合并）"
  exit 0
fi
echo "结论：可以合并，开始 squash 合并"
gh pr merge "$pr" --repo "$REPO" --squash --delete-branch --match-head-commit "$sha"
