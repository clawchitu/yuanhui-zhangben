#!/usr/bin/env bash
# 发布标签（PR #27 Codex）：动本机仓库和 origin 上的 git 标签；连服务器只为读 ECS 上的 current-tag（只读）。
#   ECS_HOST=root@<ECS> deploy/release-tag.sh --from-ecs   补救用（发布后标签没推上，deploy.sh 退出码 6）：
#     从 ECS 读 /opt/yuanhui/current-tag，按它跑下面的 <提交号>。不带提交号，所以隔了几次发布再补也只会补当前线上那一版。
#   ECS_HOST=root@<ECS> deploy/release-tag.sh <提交号>   把这个提交记成「已发布、当前线上」（deploy.sh 发布成功后调用）：
#     0. 先读 ECS 上的 current-tag，和 <提交号> 不是同一个提交 → 什么都不动，退出码 3（Codex 第三轮：A 的标签没推上、
#        B 已发布成功后，再照旧提示跑 A 会把 release-current 拨回 A，线上却是 B）。读不到 current-tag → 退出码 1。
#     1. 每个发布过的提交一个附注标签 release-<前 12 位>（永不移动）。幂等：
#        本机和 origin 都没有 → 打上并推送；本机已有且指向同一个提交 → 只推送（origin 已有同一提交就不推）；
#        origin 有、本机没有 → 取下来；本机或 origin 上同名标签指向别的提交 → 不动它，退出码 3。
#     2. 移动标签 release-current 强制改到这个提交并强制推送（origin 上已经是它就不动）。
#        deploy.sh 每次发布成功（含手工回滚 = 用旧提交再发布一次）后调用，所以它和 ECS 上的 current-tag 一致；
#        发布失败自动回滚时 current-tag 不变，release-current 也不变。
#     先推 release-<前 12 位> 再动 release-current：release-current 指向的提交一定有自己的发布标签。
#   deploy/release-tag.sh --current  整机恢复取版本：从 origin 强制取 release-current，打印「<40 位提交号> release-<前 12 位>」。
#     不按标签创建时间取（回滚后最新创建的是被回滚掉的版本）。不连 ECS（ECS 可能已经没了）。
# 退出码：0 成功；1 找不到提交 / 连不上 origin 或 ECS / 推送失败（可重跑）；2 参数或 ECS_HOST 不对；
#   3 同名标签指向别的提交，或 <提交号> 不是 ECS 上的 current-tag（需人工看）。
# RELEASE_GIT_DIR（默认本仓库）、RELEASE_REMOTE（默认 origin）只给测试换成沙盒仓库。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO="${RELEASE_GIT_DIR:-$HERE/..}"
ORIGIN="${RELEASE_REMOTE:-origin}"
CUR=release-current
g() { git -C "$REPO" "$@"; }
die() { local c=$1; shift; echo "$*" >&2; exit "$c"; }
# origin 上标签指向的提交（附注标签取 ^{} 那一行）；没有这个标签输出空；连不上返回 1
remote_commit() {
  local out
  out=$(g ls-remote --tags "$ORIGIN" "refs/tags/$1" "refs/tags/$1^{}") || return 1
  printf '%s\n' "$out" | awk -v r="refs/tags/$1" '$2 == r "^{}" { p = $1 } $2 == r { l = $1 } END { print (p != "" ? p : l) }'
}
local_commit() { g rev-parse --verify --quiet "refs/tags/$1^{commit}" || true; }

if [ "${1:-}" = --current ]; then
  [ $# = 1 ] || die 2 "用法：deploy/release-tag.sh --current"
  g fetch -q --force "$ORIGIN" "refs/tags/$CUR:refs/tags/$CUR" 2> /dev/null \
    || die 1 "从 $ORIGIN 取不到 ${CUR}（连不上，或者还没有任何一次带标签的发布）"
  sha=$(local_commit "$CUR"); name="release-${sha:0:12}"
  rc=$(remote_commit "$name") || die 1 "连不上 $ORIGIN"
  [ "$rc" = "$sha" ] || die 3 "$CUR 指向 ${sha}，但 $ORIGIN 上的 $name 是「${rc:-（没有）}」，需人工核对"
  echo "$sha $name"
  exit 0
fi

[ $# = 1 ] || die 2 "用法：ECS_HOST=root@<ECS> deploy/release-tag.sh --from-ecs | <提交号>；deploy/release-tag.sh --current"
[[ ${ECS_HOST:-} =~ ^([a-z_][a-z0-9_-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
  || die 2 "需要 ECS_HOST（如 root@47.117.184.253），要先核对 ECS 上的 current-tag：${ECS_HOST:-（空）}"
ecs=$(ssh -o BatchMode=yes "$ECS_HOST" -- cat /opt/yuanhui/current-tag) || die 1 "读不到 $ECS_HOST 上的 /opt/yuanhui/current-tag（连不上？），没动任何标签"
[[ $ecs =~ ^[0-9a-f]{7,40}$ ]] || die 1 "$ECS_HOST 上的 current-tag 不是提交号：「${ecs}」，没动任何标签"
arg=$1; [ "$arg" = --from-ecs ] && arg=$ecs
[[ $arg =~ ^[0-9a-f]{7,40}$ ]] || die 2 "提交号只收 7–40 位小写十六进制：$arg"
sha=$(g rev-parse --verify --quiet "${arg}^{commit}") || die 1 "本机仓库里找不到提交 ${arg}（先 git fetch origin）"
esha=$(g rev-parse --verify --quiet "${ecs}^{commit}") || die 1 "本机仓库里找不到 ECS current-tag 的提交 ${ecs}（先 git fetch origin）"
[ "$esha" = "$sha" ] || die 3 "ECS 上线上的是 ${esha}，不是 ${sha}：没动任何标签（之后又发布过？补救请用 ECS_HOST=$ECS_HOST deploy/release-tag.sh --from-ecs）"
name="release-${sha:0:12}"
have=$(local_commit "$name")
rhave=$(remote_commit "$name") || die 1 "连不上 $ORIGIN"
[ -z "$have" ] || [ "$have" = "$sha" ] || die 3 "本机标签 $name 已存在、指向别的提交 ${have}，没动它"
[ -z "$rhave" ] || [ "$rhave" = "$sha" ] || die 3 "$ORIGIN 上的标签 $name 已存在、指向别的提交 ${rhave}，没动它"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [ -z "$have" ]; then
  if [ -n "$rhave" ]; then
    g fetch -q "$ORIGIN" "refs/tags/$name:refs/tags/$name" || die 1 "从 $ORIGIN 取标签 $name 失败"
  else
    g tag -a "$name" -m "发布 $sha → ${ECS_HOST}，$now" "$sha"
  fi
fi
if [ -z "$rhave" ]; then
  g push -q "$ORIGIN" "refs/tags/$name" || die 1 "发布标签 $name 推不上 ${ORIGIN}（本机标签已在，修好后重跑本脚本即可）"
fi
if [ "$(remote_commit "$CUR" || echo '?')" = "$sha" ] && [ "$(local_commit "$CUR")" = "$sha" ]; then
  :
else
  g tag -f -a "$CUR" -m "当前线上 ${sha}（${name}）→ ${ECS_HOST}，$now" "$sha" > /dev/null
  g push -q -f "$ORIGIN" "refs/tags/$CUR" || die 1 "$CUR 推不上 ${ORIGIN}（$name 已推上；修好后重跑本脚本即可）"
fi
echo "发布标签：$name → ${sha}，$CUR 已指向它（整机恢复：deploy/release-tag.sh --current 取版本，再 gh workflow run image.yml --ref ${name}，见 runbook「整机重建」）"
