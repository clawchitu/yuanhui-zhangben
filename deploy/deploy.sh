#!/usr/bin/env bash
# 发布（§9.1）：本机只做三件事：校验参数 → 把 compose.yml、Caddyfile.ip、remote-deploy.sh 传到 ECS 的 incoming/ →
# 在 ECS 上跑 remote-deploy.sh（校验新 Caddyfile → 拉镜像 → 起 Postgres 等健康 → 迁移 → 换 api → 探 /healthz →
# 镜像内缩图冒烟 → 重载 Caddy；任何一步失败自动换回上一个标签和上一份配置，全部成功后才写 current-tag）。
# 用法：ECS_HOST=root@<ip> ACR=<ACR 的 VPC 地址>/yuanhui deploy/deploy.sh <提交号> [--execute]   默认 dry-run，只打印
# 退出码：0 成功；1 发布失败（已回滚或无可回滚）；2 参数不对（还没连服务器）；3 回滚也失败，需人工处理。
# 幂等：同一个标签重复发布只会重建有变化的容器；迁移本身幂等（「没有新的迁移」）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
TAG="${1:-}"
check_tag "$TAG"
if [ "$DRY_RUN" = 0 ]; then
  # 第一条远程命令之前校验完（Fable 必须改 6）
  [ -n "${ACR:-}" ] || die2 "--execute 需要 ACR（ECS 拉镜像用 VPC 地址，如 <实例>-vpc.cn-shanghai.personal.cr.aliyuncs.com/yuanhui）"
  [ -n "$ECS_HOST" ] || die2 "--execute 需要 ECS_HOST（如 root@47.117.184.253）"
  check_acr "$ACR"; check_host "$ECS_HOST"
fi
REG="${ACR:-<ACR>/yuanhui}"
D=/opt/yuanhui
remote mkdir -p "$D/incoming"
run scp -q "$HERE/compose.yml" "$HERE/Caddyfile.ip" "$HERE/remote-deploy.sh" "${ECS_HOST:-<ECS_HOST>}:$D/incoming/"
remote bash "$D/incoming/remote-deploy.sh" "$TAG" "$REG"
