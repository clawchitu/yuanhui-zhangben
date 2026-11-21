#!/usr/bin/env bash
# 在 ECS（Ubuntu 24.04）上执行的一次性初始化：由 bootstrap-ecs.sh 经 ssh 以 `bash -s` 喂进来，不要在本机跑。
# 远端同样严格模式：任何一步失败立即退出、返回非 0（Codex 9）。幂等：每步先查再做。
# YH_ROOT 只给测试用（把所有路径挪进沙盒），真机上为空。
set -euo pipefail
R="${YH_ROOT:-}"

# ── 1. Docker（Ubuntu 源里的 docker.io + compose v2；ECS 默认用阿里云 apt 镜像）──
if ! command -v docker >/dev/null; then
  apt-get update
  apt-get install -y docker.io docker-compose-v2
fi
systemctl enable --now docker

# ── 2. 2 GB swap：swapon 成功之后才写 fstab（Fable 必须改 7）──
SWAP="$R/swapfile"; FSTAB="$R/etc/fstab"
if ! swapon --show=NAME --noheadings | grep -qx "$SWAP"; then
  if [ ! -f "$SWAP" ]; then
    fallocate -l 2G "$SWAP" || { rm -f "$SWAP"; echo "fallocate 失败，没有写 fstab" >&2; exit 1; }
  fi
  chmod 600 "$SWAP"
  mkswap "$SWAP" || { echo "mkswap 失败，没有写 fstab" >&2; exit 1; }
  swapon "$SWAP" || { echo "swapon 失败，没有写 fstab" >&2; exit 1; }
fi
if ! grep -q '^/swapfile ' "$FSTAB"; then
  echo "/swapfile none swap sw 0 0" >> "$FSTAB"
fi

# ── 3. SSH 只许密钥登录（§9.1）。先确认 root 有公钥，否则禁了口令会把自己锁在外面 ──
AK="$R/root/.ssh/authorized_keys"
[ -s "$AK" ] || { echo "root 还没有 authorized_keys：先在控制台绑定密钥对、确认能用密钥登录，再跑这一步" >&2; exit 1; }
# sshd 取第一次出现的值，00- 排在云镜像自带的 50-cloud-init.conf 之前
CONF="$R/etc/ssh/sshd_config.d/00-yuanhui.conf"
WANT=$'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin prohibit-password'
if [ "$(cat "$CONF" 2>/dev/null || true)" != "$WANT" ]; then
  mkdir -p "$(dirname "$CONF")"
  printf '%s\n' "$WANT" > "$CONF"
  sshd -t || { rm -f "$CONF"; echo "sshd 配置校验失败，已撤回" >&2; exit 1; }
  systemctl reload ssh
fi

# ── 4. 目录和 .env ──
mkdir -p "$R/opt/yuanhui/caddy" "$R/data/pg" "$R/data/img" "$R/data/monitor" "$R/data/caddy/data" "$R/data/caddy/config"
# /data/monitor：api 的监控状态和告警 outbox（S10c），本机探测 ssh 进来读 outbox.jsonl
chown 1000:1000 "$R/data/img" "$R/data/monitor"
chmod 700 "$R/opt/yuanhui"
if [ ! -f "$R/opt/yuanhui/.env" ]; then
  install -m 600 /dev/null "$R/opt/yuanhui/.env"
  echo "已建空的 /opt/yuanhui/.env，按 deploy/.env.example 手工填写"
fi

# ── 5. 主机防火墙只放 22、80、443/tcp（不开 443/udp，§14 S10a-5）。
#    注意 ufw 管不到 Docker 映射的端口（Docker 直接改 iptables），真正的边界是安全组 ──
if ! ufw status | grep -q "Status: active"; then
  ufw default deny incoming
  ufw allow 22/tcp
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw --force enable
fi
echo "初始化完成"
