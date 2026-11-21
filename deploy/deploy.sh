#!/usr/bin/env bash
# 发布（§9.1）：ECS 拉镜像 → 跑迁移 → 换 api → 探 /healthz → 冒烟；失败自动换回上一个标签。
# 用法：ECS_HOST=root@<ip> deploy/deploy.sh <提交号> [--execute]      默认 dry-run，只打印
# 幂等：同一个标签重复发布只会重启一次 api；迁移本身幂等（「没有新的迁移」）。
set -euo pipefail
. "$(dirname "$0")/lib.sh"
TAG="${1:?用法：deploy.sh <提交号> [--execute]}"
REG="${ACR:-<ACR>/yuanhui}"
D=/opt/yuanhui
C="docker compose -f $D/compose.yml --env-file $D/.env"
run scp -q "$(dirname "$0")/compose.yml" "$(dirname "$0")/Caddyfile.ip" "${ECS_HOST:-<ECS_HOST>}:$D/"
PREV=$(remote "cat $D/current-tag 2>/dev/null || true")
echo "上一个标签：${PREV:-（无）} → 新标签：$TAG"
set_tag() { remote "sed -i 's#^API_IMAGE=.*#API_IMAGE=$REG/api:$1#' $D/.env && echo $1 > $D/current-tag"; }
healthy() { remote "for i in \$(seq 1 30); do docker exec yuanhui-api-1 node -e \"fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))\" && exit 0; sleep 2; done; exit 1"; }
remote "docker pull $REG/api:$TAG"
remote "API_IMAGE=$REG/api:$TAG $C run --rm --no-deps api node scripts/migrate.ts"
set_tag "$TAG"
remote "$C up -d"
if healthy && remote "docker exec yuanhui-api-1 node scripts/smoke-image.ts"; then
  echo "发布成功：$TAG"
else
  echo "健康检查失败，回滚到 ${PREV:-（无上一个标签，停在失败状态，需人工处理）}" >&2
  [ -n "$PREV" ] || exit 1
  set_tag "$PREV"; remote "$C up -d api"; healthy && echo "已回滚到 $PREV"; exit 1
fi
