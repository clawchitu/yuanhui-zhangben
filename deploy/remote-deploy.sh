#!/usr/bin/env bash
# 在 ECS 上执行的发布步骤：由 deploy/deploy.sh 传到 /opt/yuanhui/incoming/ 后调用，不要在本机跑。
# 用法：bash /opt/yuanhui/incoming/remote-deploy.sh <提交号> <镜像仓库>
# 状态：/opt/yuanhui/current-tag 只在整套发布成功后写；.env 的 API_IMAGE 在切换时改、失败时改回；
#       上一份 compose.yml / Caddyfile 备在 prev/，失败时一起换回（Codex 3、Fable 必须改 2）。
# 迁移前的备份门禁不在这里：S10a 时还没有备份、库里只有假数据，挪到 S10b（§14 S10a-8、T20）。
set -euo pipefail
umask 077
TAG="${1:-}"; REG="${2:-}"
[[ $TAG =~ ^[0-9a-f]{7,40}$ ]] || { echo "标签不对：$TAG" >&2; exit 2; }
[[ $REG =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9][a-z0-9._-]*$ || $REG == "<ACR>/yuanhui" ]] || { echo "镜像仓库不对：$REG" >&2; exit 2; }
IN=$(cd "$(dirname "$0")" && pwd)
D=$(dirname "$IN")
ENV="$D/.env"
[ -f "$ENV" ] || { echo "缺 $ENV（按 deploy/.env.example 填好再发布）" >&2; exit 2; }
NEW="$REG/api:$TAG"
envval() { sed -n "s/^$1=//p" "$ENV" | tail -1; }
# 口令原样拼进 DATABASE_URL 和 compose 插值，只许字母数字（Codex 8、Fable 必须改 9）
[[ $(envval POSTGRES_PASSWORD) =~ ^[A-Za-z0-9]{16,}$ ]] || { echo "POSTGRES_PASSWORD 只许字母数字、至少 16 位（openssl rand -hex 24）" >&2; exit 2; }
C=(docker compose -f "$D/compose.yml" --project-directory "$D" --env-file "$ENV")
set_image() { { grep -v '^API_IMAGE=' "$ENV" || true; echo "API_IMAGE=$1"; } > "$ENV.tmp" && mv "$ENV.tmp" "$ENV"; }
PREV=$(cat "$D/current-tag" 2>/dev/null || true)
PREV_IMAGE=$(envval API_IMAGE)
echo "上一个标签：${PREV:-（无）} → 新标签：$TAG"

healthy() {

  for _ in $(seq 1 30); do
    "${C[@]}" exec -T api node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))" && return 0
    sleep 2
  done
  return 1
}
caddy_reload() { "${C[@]}" exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; }

# ── 1. 切换之前：新配置先过校验、镜像先拉下来（这里失败什么都没动）──
docker compose -f "$IN/compose.yml" --project-directory "$D" --env-file "$ENV" config -q
docker run --rm --network none -e ACME_EMAIL="$(envval ACME_EMAIL)" -e PUBLIC_IP="$(envval PUBLIC_IP)" \
  -v "$IN/Caddyfile.ip:/etc/caddy/Caddyfile:ro" "$(envval CADDY_IMAGE)" \
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
    echo "已回滚到 $PREV（current-tag 仍是 $PREV）" >&2
    exit 1
  fi
  echo "回滚到 $PREV 也失败，需人工处理：看 docker compose ps、docker logs yuanhui-api-1" >&2
  exit 3
}

# ── 3. 切换到检查整段进失败处理（在 if 里 set -e 不生效，每步显式 || return 1）──
release() {
  "${C[@]}" up -d --wait postgres || return 1
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
