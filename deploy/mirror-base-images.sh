#!/usr/bin/env bash
# 把基础镜像（锁定版本、linux/amd64）推到 ACR：大陆拉不动 Docker Hub（§1、S10a）。在能访问 Docker Hub 的机器上跑，
# 推送用 ACR 的公网地址（ECS 上拉取用 VPC 地址，见 docs/cloud-manual-steps.md 第 4 步）。
# 默认 dry-run；真执行：ACR=<ACR 公网地址>/yuanhui deploy/mirror-base-images.sh --execute
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
if [ "$DRY_RUN" = 0 ]; then
  [ -n "${ACR:-}" ] || die2 "--execute 需要 ACR（如 <实例>.cn-shanghai.personal.cr.aliyuncs.com/yuanhui）"
  check_acr "$ACR"
fi
ACR="${ACR:-<ACR>/yuanhui}"
for img in node:24-bookworm-slim postgres:16 caddy:2.10.2; do
  run docker pull --platform linux/amd64 "$img"
  run docker tag "$img" "$ACR/$img"
  run docker push "$ACR/$img"
done
