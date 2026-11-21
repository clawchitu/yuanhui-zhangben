#!/usr/bin/env bash
# 一次性初始化 ECS（Ubuntu 24.04）：Docker、防火墙、2 GB swap、数据目录。幂等：每步先查再做。
# 默认 dry-run；真执行：ECS_HOST=root@<ip> deploy/bootstrap-ecs.sh --execute
set -euo pipefail
. "$(dirname "$0")/lib.sh"
remote 'command -v docker >/dev/null || (apt-get update && apt-get install -y docker.io docker-compose-v2)'
remote 'swapon --show | grep -q /swapfile || (fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile && grep -q /swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab)'
remote 'mkdir -p /opt/yuanhui /data/pg /data/img /data/caddy/data /data/caddy/config && chown 1000:1000 /data/img && chmod 700 /opt/yuanhui'
remote 'test -f /opt/yuanhui/.env || (install -m 600 /dev/null /opt/yuanhui/.env && echo "已建空的 /opt/yuanhui/.env，按 deploy/.env.example 手工填写")'
# 主机防火墙只放 22、80、443（安全组另外收紧，见 docs/cloud-manual-steps.md）
remote 'ufw status | grep -q "Status: active" || (ufw default deny incoming && ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw allow 443/udp && ufw --force enable)'
echo "完成。下一步：填 /opt/yuanhui/.env，ACR 登录（docker login），再跑 deploy/deploy.sh <标签>"
