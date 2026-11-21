#!/usr/bin/env bash
# 把基础镜像（锁定版本、linux/amd64）推到 ACR：大陆拉不动 Docker Hub（§1、S10a）。在能访问 Docker Hub 的机器上跑。
# 默认 dry-run；真执行：ACR=<registry>/yuanhui deploy/mirror-base-images.sh --execute
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ACR="${ACR:-<ACR>/yuanhui}"
for img in node:24-bookworm-slim postgres:16 caddy:2.10.2; do
  run docker pull --platform linux/amd64 "$img"
  run docker tag "$img" "$ACR/$img"
  run docker push "$ACR/$img"
done
