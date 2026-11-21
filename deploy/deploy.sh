#!/usr/bin/env bash
# 发布（§9.1）：本机只做三件事：校验参数 → 把 compose.yml、Caddyfile.ip、remote-deploy.sh 传到 ECS 的 incoming/ →
# 在 ECS 上跑 remote-deploy.sh（校验新 Caddyfile → 拉镜像 → 起 Postgres 等健康 → 迁移 → 换 api → 探 /healthz →
# 镜像内缩图冒烟 → 重载 Caddy；任何一步失败自动换回上一个标签和上一份配置，全部成功后才写 current-tag）。
# 用法：ECS_HOST=root@<ip> ACR=<ACR 的 VPC 地址>/yuanhui deploy/deploy.sh <提交号> [--execute] [--skip-backup-gate]
#   不用 ACR（默认做法，负责人 11/22 决定）：IMAGES_TAR=<image.yml 产出的 yuanhui-images-<提交号>.tar.gz> ECS_HOST=… deploy/deploy.sh <提交号>
#     tar 传到 ECS 的 incoming/，remote-deploy.sh 先 docker load、不再 docker pull；ACR 不填时镜像名前缀是 local/yuanhui
#   默认 dry-run，只打印。--skip-backup-gate：跳过迁移前备份门禁（§14 T20），ECS 上记进 backup/gate-skips.log
# 退出码：0 成功；1 发布失败（已回滚或无可回滚）；2 参数不对（还没连服务器）；3 回滚也失败，需人工处理；
#   4 发布成功但备份定时器没装上；5 备份门禁拒绝（没动任何东西）；6 发布成功但发布标签没打上 / 没推上去（见下）。
# 发布标签（PR #27 Codex）：发布成功（退出码 0 或 4）后跑 deploy/release-tag.sh <提交号>：给这次的提交打附注标签
#   release-<提交号前 12 位>，并把移动标签 release-current 强制移到它，都推到 origin（幂等，见该脚本头部）。
#   镜像 tar 的 artifact 只留 3 天，ECS 整机丢了以后按 release-current 取版本、按 release-<前 12 位> 重打同一个提交的镜像
#   （workflow_dispatch 的 ref 只收分支或标签，不收提交号）。手工回滚 = 用旧提交再发布一次，release-current 跟着回到旧提交。
#   没推上时的补救命令是 ECS_HOST=… deploy/release-tag.sh --from-ecs（不带提交号，按 ECS 当时的 current-tag 补，Codex 第三轮）。
#   RELEASE_GIT_DIR（默认本仓库）、RELEASE_REMOTE（默认 origin）只给测试换成沙盒仓库。
# 幂等：同一个标签重复发布只会重建有变化的容器；迁移本身幂等（「没有新的迁移」）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
TAG="${1:-}"
check_tag "$TAG"
IMAGES_TAR="${IMAGES_TAR:-}"
[ -n "$IMAGES_TAR" ] && ACR="${ACR:-local/yuanhui}"
if [ -n "$IMAGES_TAR" ]; then
  [ -f "$IMAGES_TAR" ] || die2 "IMAGES_TAR 指的文件不存在：$IMAGES_TAR"
  [[ $(basename "$IMAGES_TAR") =~ ^[A-Za-z0-9._-]+\.tar(\.gz)?$ ]] || die2 "IMAGES_TAR 文件名只许字母数字 . _ -，以 .tar 或 .tar.gz 结尾"
fi
if [ "$DRY_RUN" = 0 ]; then
  # 第一条远程命令之前校验完（Fable 必须改 6）
  [ -n "${ACR:-}" ] || die2 "--execute 需要 ACR（ECS 拉镜像用 VPC 地址，如 <实例>-vpc.cn-shanghai.personal.cr.aliyuncs.com/yuanhui）"
  [ -n "$ECS_HOST" ] || die2 "--execute 需要 ECS_HOST（如 root@47.117.184.253）"
  check_acr "$ACR"; check_host "$ECS_HOST"
fi
REG="${ACR:-<ACR>/yuanhui}"
D=/opt/yuanhui
remote mkdir -p "$D/incoming"
run scp -q "$HERE/compose.yml" "$HERE/Caddyfile.ip" "$HERE/remote-deploy.sh" "$HERE/backup.sh" \
  "$HERE/yuanhui-backup.service" "$HERE/yuanhui-backup.timer" "${ECS_HOST:-<ECS_HOST>}:$D/incoming/"
GATE=(); for a in "$@"; do [ "$a" = --skip-backup-gate ] && GATE=(--skip-backup-gate); done
if [ -n "$IMAGES_TAR" ]; then
  run scp -q "$IMAGES_TAR" "${ECS_HOST:-<ECS_HOST>}:$D/incoming/"
  GATE+=(--load-images "$D/incoming/$(basename "$IMAGES_TAR")")
fi
rc=0
remote bash "$D/incoming/remote-deploy.sh" "$TAG" "$REG" ${GATE[@]+"${GATE[@]}"} || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 4 ] || exit "$rc"

# 发布标签 release-<前 12 位> 和移动标签 release-current（deploy/release-tag.sh，幂等）。到这里 ECS 上的 current-tag 已经是 $TAG，
# release-current 跟着它走；发布失败自动回滚时不会走到这里，两者都还是上一个。
if [ "$DRY_RUN" = 1 ]; then
  printf '[dry-run] 发布成功后：deploy/release-tag.sh %s（打 release-<前 12 位> 并把 release-current 移到它，推到 origin）\n' "$TAG"
elif ! ECS_HOST="$ECS_HOST" bash "$HERE/release-tag.sh" "$TAG"; then
  echo "发布本身已成功，但发布标签没打上 / 没推上去：修好后跑 ECS_HOST=$ECS_HOST deploy/release-tag.sh --from-ecs（按 ECS 上当时的 current-tag 补，之后又发布过也不会拨回这一版；幂等，见 runbook「发布 / 回滚」），否则 3 天后 artifact 过期就没法按标签重打这次的镜像，整机恢复也取不到这一版" >&2
  [ "$rc" = 0 ] && rc=6
fi
exit "$rc"
