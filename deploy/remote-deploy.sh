#!/usr/bin/env bash
# 在 ECS 上执行的发布步骤：由 deploy/deploy.sh 传到 /opt/yuanhui/incoming/ 后调用，不要在本机跑。
# 用法：bash /opt/yuanhui/incoming/remote-deploy.sh <提交号> <镜像仓库> [--skip-backup-gate]
# 状态：/opt/yuanhui/current-tag 只在整套发布成功后写；.env 的 API_IMAGE 在切换时改、失败时改回；
#       上一份 compose.yml / Caddyfile 备在 prev/，失败时一起换回（Codex 3、Fable 必须改 2）。
# 迁移前备份门禁（S10b，§14 T20）：动任何东西之前看 backup/last-success（backup.sh 上传和心跳都成功才写）。
#   营业时间（上海 8:00–22:59）超过 2 小时、其余时间超过 6 小时（22:00 → 02:30 → 8:00 的间隔最长 5.5 小时）没有成功备份
#   → 拒绝发布，退出码 5。--skip-backup-gate 跳过（首次发布还没有备份时用），跳过一律记进 backup/gate-skips.log。
# 发布成功后装上 backup.sh 和备份定时器（yuanhui-backup.timer）；装不上退出码 4（发布本身已成功）。
set -euo pipefail
umask 077
TAG="${1:-}"; REG="${2:-}"; SKIP_GATE=0
[ "${3:-}" = --skip-backup-gate ] && SKIP_GATE=1
[[ $TAG =~ ^[0-9a-f]{7,40}$ ]] || { echo "标签不对：$TAG" >&2; exit 2; }
[[ $REG =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9][a-z0-9._-]*$ || $REG == "<ACR>/yuanhui" ]] || { echo "镜像仓库不对：$REG" >&2; exit 2; }
IN=$(cd "$(dirname "$0")" && pwd)
D=$(dirname "$IN")
ENV="$D/.env"
[ -f "$ENV" ] || { echo "缺 ${ENV}（按 deploy/.env.example 填好再发布）" >&2; exit 2; }
NEW="$REG/api:$TAG"
envval() { sed -n "s/^$1=//p" "$ENV" | tail -1; }
# 口令原样拼进 DATABASE_URL 和 compose 插值，只许字母数字（Codex 8、Fable 必须改 9）
[[ $(envval POSTGRES_PASSWORD) =~ ^[A-Za-z0-9]{16,}$ ]] || { echo "POSTGRES_PASSWORD 只许字母数字、至少 16 位（openssl rand -hex 24）" >&2; exit 2; }
# 备份配置有空的只警告不拒绝（首次发布可能还没配；Fable 建议 5）
for v in BACKUP_OSS_ACCESS_KEY_ID BACKUP_OSS_ACCESS_KEY_SECRET BACKUP_PASSPHRASE; do
  [ -n "$(envval "$v")" ] || echo "警告：.env 里 ${v} 是空的，备份会失败（见 docs/cloud-manual-steps.md 第 4 步）" >&2
done
[ "$(envval RECOVERY_MODE)" = 1 ] && echo "警告：.env 里 RECOVERY_MODE=1（恢复模式开着），补交完要改回 0" >&2
C=(docker compose -f "$D/compose.yml" --project-directory "$D" --env-file "$ENV")
set_image() { { grep -v '^API_IMAGE=' "$ENV" || true; echo "API_IMAGE=$1"; } > "$ENV.tmp" && mv "$ENV.tmp" "$ENV"; }
PREV=$(cat "$D/current-tag" 2>/dev/null || true)
PREV_IMAGE=$(envval API_IMAGE)
echo "上一个标签：${PREV:-（无）} → 新标签：$TAG"

# ── 0. 迁移前备份门禁（T20）──
backup_gate() {
  local now last age hour max
  now=${GATE_NOW:-$(date +%s)}   # GATE_NOW 只给测试用
  last=$(cat "$D/backup/last-success" 2>/dev/null || true)
  hour=$(TZ=Asia/Shanghai date -d "@$now" +%H 2>/dev/null || TZ=Asia/Shanghai date -r "$now" +%H)
  if [ "$((10#$hour))" -ge 8 ] && [ "$((10#$hour))" -le 22 ]; then max=7200; else max=21600; fi
  if [[ $last =~ ^[0-9]+$ ]]; then age=$((now - last)); else age=""; fi
  if [ -n "$age" ] && [ "$age" -le "$max" ]; then echo "备份门禁：最近一次成功备份在 $((age / 60)) 分钟前"; return 0; fi
  local why="${age:+最近一次成功备份在 $((age / 60)) 分钟前（上限 $((max / 60)) 分钟）}"; why=${why:-没有任何成功的备份记录}
  if [ "$SKIP_GATE" = 1 ]; then
    mkdir -p "$D/backup" && chmod 711 "$D/backup"
    printf '%s tag=%s 跳过备份门禁：%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TAG" "$why" >> "$D/backup/gate-skips.log"
    chmod 644 "$D/backup/gate-skips.log"   # api 容器的监控要读（S10c：gate-skips.log 有新行就告警）
    echo "警告：--skip-backup-gate，跳过备份门禁（${why}），已记入 backup/gate-skips.log" >&2
    return 0
  fi
  echo "备份门禁：${why}，拒绝在迁移前发布。先在 ECS 上跑 bash $D/backup.sh，成功后再发布；确需跳过加 --skip-backup-gate" >&2
  exit 5
}
backup_gate

healthy() {
  for _ in $(seq 1 30); do
    "${C[@]}" exec -T api node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" && return 0
    sleep 2
  done
  return 1
}
caddy_reload() { "${C[@]}" exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; }

# ── 1. 切换之前：新配置先过校验、镜像先拉下来（这里失败什么都没动）──
# 首次发布时 .env 的 API_IMAGE 是空的，而 compose.yml 是 ${API_IMAGE:?}，Compose 对整份文件插值、不管只起哪个服务。
# 所以切换前的 compose 命令（这里的 config、release() 里的起库和迁移）都在命令前临时带上 API_IMAGE="$NEW"，
# 不改 .env、也不在脚本里整体 export（那样回滚时的 up -d 会被环境变量盖过 .env，起的还是新镜像）。（PR #22 第二轮 Codex 1、Fable 必须改）
API_IMAGE="$NEW" docker compose -f "$IN/compose.yml" --project-directory "$D" --env-file "$ENV" config -q
# 校验容器要看到的文件和 Caddy 容器一致：新 Caddyfile，加上方案 B 时宿主机 caddy/tls/ 里的证书（Codex 第二轮 3）
TLS_MOUNT=(); [ -d "$D/caddy/tls" ] && TLS_MOUNT=(-v "$D/caddy/tls:/etc/caddy/tls:ro")
docker run --rm --network none -e ACME_EMAIL="$(envval ACME_EMAIL)" -e PUBLIC_IP="$(envval PUBLIC_IP)" \
  -v "$IN/Caddyfile.ip:/etc/caddy/Caddyfile:ro" ${TLS_MOUNT[@]+"${TLS_MOUNT[@]}"} "$(envval CADDY_IMAGE)" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker pull "$NEW"

# ── 2. 备份当前配置，装上新配置 ──
mkdir -p "$D/prev" "$D/caddy"
for f in compose.yml caddy/Caddyfile; do
  if [ -f "$D/$f" ]; then cp -p "$D/$f" "$D/prev/${f//\//_}"; else rm -f "$D/prev/${f//\//_}"; fi
done
cp "$IN/compose.yml" "$D/compose.yml"
cp "$IN/Caddyfile.ip" "$D/caddy/Caddyfile"

rollback() {
  echo "发布失败，回滚到 ${PREV:-（无上一个标签）}" >&2
  local f
  for f in compose.yml caddy/Caddyfile; do
    [ -f "$D/prev/${f//\//_}" ] && cp -p "$D/prev/${f//\//_}" "$D/$f"
  done
  set_image "$PREV_IMAGE"
  if [ -z "$PREV" ]; then
    echo "没有上一个成功的标签，停在失败状态，需人工处理（current-tag 未写）" >&2
    exit 1
  fi
  if "${C[@]}" up -d --remove-orphans && healthy && caddy_reload; then
    echo "已回滚到 ${PREV}（current-tag 仍是 ${PREV}）" >&2
    exit 1
  fi
  echo "回滚到 $PREV 也失败，需人工处理：看 docker compose ps、docker logs yuanhui-api-1" >&2
  exit 3
}

# ── 3. 切换到检查整段进失败处理（在 if 里 set -e 不生效，每步显式 || return 1）──
release() {
  API_IMAGE="$NEW" "${C[@]}" up -d --wait postgres || return 1
  API_IMAGE="$NEW" "${C[@]}" run --rm -T migrate || return 1
  set_image "$NEW" || return 1
  "${C[@]}" up -d --remove-orphans || return 1
  healthy || return 1
  "${C[@]}" exec -T api node scripts/smoke-image.ts || return 1
  # up -d 不会因挂载文件内容变了重建 Caddy，新 Caddyfile 要显式重载（Codex 5、Fable 必须改 3）
  caddy_reload || return 1
}
if release; then
  echo "$TAG" > "$D/current-tag"
  echo "发布成功：$TAG"
else
  rollback
fi

# ── 4. 装上备份脚本和定时器（S10b）。发布本身已经成功，这里失败不回滚，退出码 4 ──
UNITS="${SYSTEMD_DIR:-/etc/systemd/system}"   # SYSTEMD_DIR 只给测试用
if cp "$IN/backup.sh" "$D/backup.sh" && cp "$IN/yuanhui-backup.service" "$IN/yuanhui-backup.timer" "$UNITS/" \
  && systemctl daemon-reload && systemctl enable --now yuanhui-backup.timer; then
  echo "备份定时器已启用（systemctl list-timers yuanhui-backup.timer）"
else
  echo "发布成功，但备份脚本或定时器没装上，需人工处理（看 systemctl status yuanhui-backup.timer）" >&2
  exit 4
fi
