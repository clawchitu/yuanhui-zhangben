#!/usr/bin/env bash
# deploy.sh 的单元测试：用 fakes/ 里的 ssh、scp、docker 替身，在本机沙盒里跑完整的发布流程
# （远端命令照样经过「拼成字符串交给 bash -c」这一步）。不连任何服务器、不需要 Docker。
# 用法：deploy/test/deploy.test.sh        退出码 0 = 全部通过
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEPLOY="${DEPLOY_SH:-$HERE/../deploy.sh}"
REG=registry-vpc.cn-shanghai.aliyuncs.com/yuanhui
OLD=1111111; NEW=2222222; BAD=3333333
pass=0; fail=0; T=""

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/remote" "$T/state"
  export FAKE_REMOTE="$T/remote" FAKE_STATE="$T/state" FAKE_LOG="$T/log"
  : > "$FAKE_LOG"
  printf 'POSTGRES_PASSWORD=0123456789abcdef0123\nACME_EMAIL=a@example.invalid\nPUBLIC_IP=47.117.184.253\nCADDY_IMAGE=%s/caddy:2.10.2\nPOSTGRES_IMAGE=%s/postgres:16\nAPI_IMAGE=\n' "$REG" "$REG" > "$T/remote/.env"
  unset FAKE_PULL_FAIL FAKE_MIGRATE_FAIL FAKE_UP_FAIL_IMAGE FAKE_BAD_IMAGE FAKE_CADDY_INVALID FAKE_CADDY_RELOAD_FAIL
}
# 已经成功发布过 $OLD：current-tag、.env、正在跑的容器都是它
with_prev() {
  echo "$OLD" > "$T/remote/current-tag"
  { grep -v '^API_IMAGE=' "$T/remote/.env"; echo "API_IMAGE=$REG/api:$OLD"; } > "$T/e" && mv "$T/e" "$T/remote/.env"
  touch "$T/state/pg_up"; echo "$REG/api:$OLD" > "$T/state/api_image"
}
deploy() { PATH="$HERE/fakes:$PATH" ECS_HOST="${H-root@47.117.184.253}" ACR="${A-$REG}" bash "$DEPLOY" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
tag() { cat "$T/remote/current-tag" 2>/dev/null || echo "(无)"; }
envimg() { sed -n 's/^API_IMAGE=//p' "$T/remote/.env"; }
running() { cat "$T/state/api_image" 2>/dev/null; }
check() { # check <说明> <条件命令…>
  local d=$1; shift
  if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  ✗ $d"; echo "    --- 输出 ---"; sed 's/^/    /' "$T/out"; fi
}
t() { echo "• $1"; }

t "首次发布（没有 current-tag、Postgres 没起来）：先起 Postgres 再迁移，成功后才写 current-tag，重载 Caddy"
setup; deploy "$NEW" --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "迁移跑了新镜像" grep -qs "migrate $REG/api:$NEW" "$T/state/migrations"
check "current-tag = 新标签" [ "$(tag)" = "$NEW" ]
check ".env 指向新镜像" [ "$(envimg)" = "$REG/api:$NEW" ]
check "重载了 Caddy" [ -s "$T/state/caddy_reloads" ]

t "compose up 失败：自动回滚，current-tag 仍是上一个"
setup; with_prev; export FAKE_UP_FAIL_IMAGE=":$NEW"; deploy "$NEW" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 $OLD（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check ".env 换回上一个镜像（实际 $(envimg)）" [ "$(envimg)" = "$REG/api:$OLD" ]
check "正在跑的是上一个镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$OLD" ]

t "故意坏掉的镜像（健康检查失败）：自动回滚到上一个，current-tag 不变"
setup; with_prev; export FAKE_BAD_IMAGE=":$BAD"; deploy "$BAD" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 $OLD（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check ".env 换回上一个镜像（实际 $(envimg)）" [ "$(envimg)" = "$REG/api:$OLD" ]
check "正在跑的是上一个镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$OLD" ]
check "输出写明已回滚" grep -q "已回滚到 $OLD" "$T/out"

t "Caddy 重载失败：算发布失败，回滚"
setup; with_prev; export FAKE_CADDY_RELOAD_FAIL=1; deploy "$NEW" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 $OLD（实际 $(tag)）" [ "$(tag)" = "$OLD" ]

t "迁移失败：不切换，current-tag 和 .env 都不变"
setup; with_prev; export FAKE_MIGRATE_FAIL=1; deploy "$NEW" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 $OLD（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check ".env 仍是上一个镜像（实际 $(envimg)）" [ "$(envimg)" = "$REG/api:$OLD" ]
check "正在跑的仍是上一个镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$OLD" ]

t "新 Caddyfile 校验不过：第一步就停，什么都不切"
setup; with_prev; export FAKE_CADDY_INVALID=1; deploy "$NEW" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 $OLD" [ "$(tag)" = "$OLD" ]
check "没有跑迁移" [ ! -f "$T/state/migrations" ]

t "首次发布就失败（没有上一个可回）：退出码非 0，不写 current-tag"
setup; export FAKE_BAD_IMAGE=":$BAD"; deploy "$BAD" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "没有 current-tag（实际 $(tag)）" [ "$(tag)" = "(无)" ]

t "--execute 参数校验：在第一条 ssh / scp 之前退出，退出码 2"
for case in "A= :缺 ACR" "H= :缺 ECS_HOST" "TAG=abc :标签太短" "TAG=ABCDEF1 :标签大写" "TAG=1234567;touch_PWNED :标签带分号" "A=reg/yuanhui;id :ACR 带分号" "H=-oProxyCommand=x :ECS_HOST 以 - 开头"; do
  setup; spec=${case%% :*}; what=${case#* :}; tg=$NEW
  case "$spec" in A=*) A=${spec#A=}; H=root@47.117.184.253 ;; H=*) H=${spec#H=}; A=$REG ;; TAG=*) tg=${spec#TAG=}; A=$REG; H=root@47.117.184.253 ;; esac
  (cd "$T" && deploy "$tg" --execute)
  check "$what：退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
  check "$what：没有发出 ssh / scp" [ ! -s "$FAKE_LOG" ]
  unset A H
done
check "带分号的标签没有在本机或远端执行" [ ! -e "$T/touch_PWNED" ]

t "POSTGRES_PASSWORD 带 # 之类的字符：发布前拒绝，退出码 2，什么都不切"
setup; with_prev; { grep -v '^POSTGRES_PASSWORD=' "$T/remote/.env"; echo 'POSTGRES_PASSWORD=abc#def@ghi/jkl0123'; } > "$T/e" && mv "$T/e" "$T/remote/.env"
deploy "$NEW" --execute
check "退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
check "current-tag 仍是 $OLD" [ "$(tag)" = "$OLD" ]
check "没有跑迁移" [ ! -f "$T/state/migrations" ]

t "默认 dry-run：只打印，不发 ssh / scp / docker"
setup; with_prev; deploy "$NEW"
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "没有发出任何命令" [ ! -s "$FAKE_LOG" ]
check "current-tag 不变" [ "$(tag)" = "$OLD" ]

echo "通过 $pass，失败 $fail"
[ "$fail" = 0 ]
