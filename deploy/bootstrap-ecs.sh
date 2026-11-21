#!/usr/bin/env bash
# 一次性初始化 ECS（Ubuntu 24.04）：Docker、2 GB swap、SSH 只许密钥、数据目录、防火墙。步骤在 remote-bootstrap.sh 里，
# 经 ssh 以 `bash -s` 在远端执行（远端严格模式，任一步失败返回非 0）。幂等：每步先查再做。
# 默认 dry-run；真执行：ECS_HOST=root@<ip> deploy/bootstrap-ecs.sh --execute
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
if [ "$DRY_RUN" = 0 ]; then
  [ -n "$ECS_HOST" ] || die2 "--execute 需要 ECS_HOST（如 root@47.117.184.253）"
  check_host "$ECS_HOST"
fi
[ "$DRY_RUN" = 1 ] && echo "[dry-run] 将在远端执行 $HERE/remote-bootstrap.sh："
remote bash -s < "$HERE/remote-bootstrap.sh"
echo "完成。下一步：填 /opt/yuanhui/.env，ACR 登录（docker login <ACR 的 VPC 地址>），再跑 deploy/deploy.sh <标签>"
