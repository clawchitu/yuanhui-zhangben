#!/usr/bin/env bash
# deploy.sh 的单元测试：用 fakes/ 里的 ssh、scp、docker 替身，在本机沙盒里跑完整的发布流程
# （远端命令照样经过「拼成字符串交给 bash -c」这一步）。不连任何服务器、不需要 Docker。
# 用法：deploy/test/deploy.test.sh        退出码 0 = 全部通过
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
DEPLOY="${DEPLOY_SH:-$HERE/../deploy.sh}"
REG=registry-vpc.cn-shanghai.aliyuncs.com/yuanhui
# 标签要是本机仓库里真有的提交（发布成功后打 release-<前 12 位> 标签、推到 origin，PR #27 Codex）：沙盒仓库里建三个空提交
G=$(mktemp -d)
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
git -C "$G" init -q && for n in 1 2 3; do git -C "$G" commit -q --allow-empty -m "c$n"; done
OLD=$(git -C "$G" rev-parse HEAD~2); NEW=$(git -C "$G" rev-parse HEAD~1); BAD=$(git -C "$G" rev-parse HEAD)
export RELEASE_GIT_DIR=$G
trap 'rm -rf "$G"' EXIT
pass=0; fail=0; T=""
# 用 UTF-8 区域跑（Mac 的 /bin/bash 3.2 在 UTF-8 下把「$why，」里紧跟的中文字节算进变量名，报 unbound variable；
# LC_ALL=C 时测不出来，PR #23 Codex 5、Fable 必须改 3）。Mac 上 C.UTF-8 测不出来，先挑 en_US.UTF-8；CI 的 Ubuntu 只有 C.UTF-8
for _l in en_US.UTF-8 C.UTF-8; do if locale -a 2>/dev/null | grep -ix "$_l" > /dev/null; then export LC_ALL=$_l; break; fi; done

setup() {
  T=$(mktemp -d)
  mkdir -p "$T/remote" "$T/state"
  export FAKE_REMOTE="$T/remote" FAKE_STATE="$T/state" FAKE_LOG="$T/log"
  : > "$FAKE_LOG"
  printf 'POSTGRES_PASSWORD=0123456789abcdef0123\nACME_EMAIL=a@example.invalid\nPUBLIC_IP=47.117.184.253\nCADDY_IMAGE=%s/caddy:2.10.2\nPOSTGRES_IMAGE=%s/postgres:16\nAPI_IMAGE=\n' "$REG" "$REG" > "$T/remote/.env"
  unset FAKE_IMAGE_PRESENT FAKE_PULL_FAIL FAKE_MIGRATE_FAIL FAKE_UP_FAIL_IMAGE FAKE_BAD_IMAGE FAKE_UNHEALTHY_IMAGE FAKE_CADDY_INVALID FAKE_CADDY_RELOAD_FAIL FAKE_SYSTEMCTL_FAIL GATE_NOW
  # 默认有一份刚成功的备份（迁移前门禁放行，S10b、T20）；定时器装进沙盒目录
  mkdir -p "$T/remote/backup" "$T/units"; date +%s > "$T/remote/backup/last-success"
  export SYSTEMD_DIR="$T/units"
  # 每个用例一个新的空 origin，沙盒仓库里的发布标签清掉
  git init -q --bare "$T/origin.git"; git -C "$G" remote remove origin 2>/dev/null; git -C "$G" remote add origin "$T/origin.git"
  for x in $(git -C "$G" tag -l 'release-*'); do git -C "$G" tag -d "$x" > /dev/null; done
}
rtags() { git -C "$T/origin.git" for-each-ref --format='%(refname:short) %(objecttype) %(*objectname)' 'refs/tags/release-*' | grep -v '^release-current ' || true; }
# origin 上 release-current 指向的提交（没有就空）
rcur() { git -C "$T/origin.git" rev-parse --verify --quiet 'refs/tags/release-current^{commit}' || true; }
# 已经成功发布过 ${OLD}：current-tag、.env、正在跑的容器、上一份 compose.yml / Caddyfile 都是它
with_prev() {
  echo "$OLD" > "$T/remote/current-tag"
  { grep -v '^API_IMAGE=' "$T/remote/.env"; echo "API_IMAGE=$REG/api:$OLD"; } > "$T/e" && mv "$T/e" "$T/remote/.env"
  touch "$T/state/pg_up"; echo "$REG/api:$OLD" > "$T/state/api_image"
  # 旧 compose.yml 用真文件加一行标记（FAKE_REAL_COMPOSE 时真 Compose 要能解析它）
  mkdir -p "$T/remote/caddy"; { cat "$HERE/../compose.yml"; echo "# old compose $OLD"; } > "$T/remote/compose.yml"; echo "# old caddy $OLD" > "$T/remote/caddy/Caddyfile"
}
old_conf() { [ "$(tail -1 "$T/remote/compose.yml")" = "# old compose $OLD" ] && [ "$(cat "$T/remote/caddy/Caddyfile")" = "# old caddy $OLD" ]; }
new_conf() { cmp -s "$HERE/../compose.yml" "$T/remote/compose.yml" && cmp -s "$HERE/../Caddyfile.ip" "$T/remote/caddy/Caddyfile"; }
reloads() { wc -l < "$T/state/caddy_reloads" 2>/dev/null | tr -d ' ' || echo 0; }
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
no() { ! "$@"; }

t "首次发布（没有 current-tag、Postgres 没起来）：先起 Postgres 再迁移，成功后才写 current-tag，重载 Caddy"
setup; deploy "$NEW" --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "迁移跑了新镜像" grep -qs "migrate $REG/api:$NEW" "$T/state/migrations"
check "current-tag = 新标签" [ "$(tag)" = "$NEW" ]
check ".env 指向新镜像" [ "$(envimg)" = "$REG/api:$NEW" ]
check "重载了 Caddy" [ -s "$T/state/caddy_reloads" ]
check "装上了新 compose.yml 和 Caddyfile" new_conf

t "已有部署正常发布：换上新配置，旧配置备在 prev/，重载 Caddy 一次"
setup; with_prev; deploy "$NEW" --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "current-tag = 新标签" [ "$(tag)" = "$NEW" ]
check "正在跑的是新镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$NEW" ]
check "装上了新配置" new_conf
check "prev/ 里是上一份配置" grep -qs "# old compose $OLD" "$T/remote/prev/compose.yml"
check "重载 Caddy 1 次（实际 $(reloads)）" [ "$(reloads)" = 1 ]

t "compose up 失败：自动回滚，current-tag 仍是上一个"
setup; with_prev; export FAKE_UP_FAIL_IMAGE=":$NEW"; deploy "$NEW" --execute
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "current-tag 仍是 ${OLD}（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check ".env 换回上一个镜像（实际 $(envimg)）" [ "$(envimg)" = "$REG/api:$OLD" ]
check "正在跑的是上一个镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$OLD" ]
check "compose.yml、Caddyfile 换回上一份" old_conf
check "回滚后重载了 Caddy（实际 $(reloads) 次）" [ "$(reloads)" = 1 ]

t "故意坏掉的镜像（健康检查失败）：自动回滚到上一个，current-tag 不变"
setup; with_prev; export FAKE_BAD_IMAGE=":$BAD"; deploy "$BAD" --execute
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "current-tag 仍是 ${OLD}（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check ".env 换回上一个镜像（实际 $(envimg)）" [ "$(envimg)" = "$REG/api:$OLD" ]
check "正在跑的是上一个镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$OLD" ]
check "compose.yml、Caddyfile 换回上一份" old_conf
check "回滚后重载了 Caddy（实际 $(reloads) 次）" [ "$(reloads)" = 1 ]
check "输出写明已回滚" grep -q "已回滚到 $OLD" "$T/out"

t "只有 /healthz 不通（缩图冒烟能过）：healthy 这一步拦下，回滚"
setup; with_prev; export FAKE_UNHEALTHY_IMAGE=":$BAD"; deploy "$BAD" --execute
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "current-tag 仍是 ${OLD}（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check "正在跑的是上一个镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$OLD" ]

t "Caddy 重载失败：发布失败，回滚里的重载也失败 → 退出码 3（需人工）"
setup; with_prev; export FAKE_CADDY_RELOAD_FAIL=1; deploy "$NEW" --execute
check "退出码 3（实际 $(rc)）" [ "$(rc)" = 3 ]
check "current-tag 仍是 ${OLD}（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check "compose.yml、Caddyfile 换回上一份" old_conf
check "输出写明需人工处理" grep -q "也失败，需人工处理" "$T/out"

t "迁移失败：不切换，current-tag 和 .env 都不变"
setup; with_prev; export FAKE_MIGRATE_FAIL=1; deploy "$NEW" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 ${OLD}（实际 $(tag)）" [ "$(tag)" = "$OLD" ]
check ".env 仍是上一个镜像（实际 $(envimg)）" [ "$(envimg)" = "$REG/api:$OLD" ]
check "正在跑的仍是上一个镜像（实际 $(running)）" [ "$(running)" = "$REG/api:$OLD" ]

t "新 Caddyfile 校验不过：第一步就停，什么都不切"
setup; with_prev; export FAKE_CADDY_INVALID=1; deploy "$NEW" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 $OLD" [ "$(tag)" = "$OLD" ]
check "没有跑迁移" [ ! -f "$T/state/migrations" ]
check "配置没动" old_conf

t "新 compose 插值不过（.env 缺 CADDY_IMAGE）：第一步 config 就停，什么都不切"
setup; with_prev; grep -v '^CADDY_IMAGE=' "$T/remote/.env" > "$T/e" && mv "$T/e" "$T/remote/.env"; deploy "$NEW" --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "current-tag 仍是 $OLD" [ "$(tag)" = "$OLD" ]
check "没有拉镜像" no grep -q "^docker pull" "$FAKE_LOG"
check "配置没动" old_conf

t "Caddyfile 校验容器挂载：有 caddy/tls/（方案 B）时一并挂上，没有时不挂"
setup; with_prev; deploy "$NEW" --execute
check "没有 tls 目录：不挂" no grep -q "/etc/caddy/tls" "$FAKE_LOG"
setup; with_prev; mkdir -p "$T/remote/caddy/tls"; deploy "$NEW" --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "有 tls 目录：校验容器挂了 caddy/tls（只读）" grep -q "^docker run .*-v $T/remote/caddy/tls:/etc/caddy/tls:ro .*caddy validate" "$FAKE_LOG"

t "首次发布就失败（没有上一个可回）：退出码非 0，不写 current-tag"
setup; export FAKE_BAD_IMAGE=":$BAD"; deploy "$BAD" --execute
check "退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
check "没有 current-tag（实际 $(tag)）" [ "$(tag)" = "(无)" ]

t "--execute 参数校验：在第一条 ssh / scp 之前退出，退出码 2"
for case in "A= :缺 ACR" "H= :缺 ECS_HOST" "TAG=abc :标签太短" "TAG=ABCDEF1 :标签大写" "TAG=1234567;touch_PWNED :标签带分号" "A=reg/yuanhui;id :ACR 带分号" "H=-oProxyCommand=x :ECS_HOST 以 - 开头"; do
  setup; spec=${case%% :*}; what=${case#* :}; tg=$NEW
  case "$spec" in A=*) A=${spec#A=}; H=root@47.117.184.253 ;; H=*) H=${spec#H=}; A=$REG ;; TAG=*) tg=${spec#TAG=}; A=$REG; H=root@47.117.184.253 ;; esac
  (cd "$T" && deploy "$tg" --execute)
  check "${what}：退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
  check "${what}：没有发出 ssh / scp" [ ! -s "$FAKE_LOG" ]
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

# ── 迁移前备份门禁（S10b，§14 T20）和备份定时器 ──
# 上海时间 2026-11-20 10:00（营业时间）和 04:00（非营业时间）
BIZ=$(( $(date -u -j -f '%Y-%m-%dT%H:%M:%S' 2026-11-20T02:00:00 +%s 2>/dev/null || date -u -d 2026-11-20T02:00:00 +%s) ))
NIGHT=$((BIZ - 6 * 3600))
untouched() { [ "$(tag)" = "$OLD" ] && [ "$(envimg)" = "$REG/api:$OLD" ] && [ ! -s "$T/state/migrations" ] && old_conf; }

t "门禁：没有任何成功的备份 → 拒绝，退出码 5，迁移没跑、什么都没动"
setup; with_prev; rm "$T/remote/backup/last-success"; deploy "$NEW" --execute
check "退出码 5（实际 $(rc)）" [ "$(rc)" = 5 ]
check "什么都没动" untouched
check "没拉镜像" no grep -q "docker pull" "$FAKE_LOG"
check "提示了跳过开关" grep -q -- "--skip-backup-gate" "$T/out"

t "门禁：营业时间内最近一次备份在 3 小时前 → 拒绝；同样 3 小时、非营业时间 → 放行"
setup; with_prev; export GATE_NOW=$BIZ; echo $((BIZ - 3 * 3600)) > "$T/remote/backup/last-success"; deploy "$NEW" --execute
check "营业时间 3 小时：退出码 5（实际 $(rc)）" [ "$(rc)" = 5 ]
check "什么都没动" untouched
setup; with_prev; export GATE_NOW=$BIZ; echo $((BIZ - 110 * 60)) > "$T/remote/backup/last-success"; deploy "$NEW" --execute
check "营业时间 110 分钟：放行（实际 $(rc)）" [ "$(rc)" = 0 ]
setup; with_prev; export GATE_NOW=$NIGHT; echo $((NIGHT - 3 * 3600)) > "$T/remote/backup/last-success"; deploy "$NEW" --execute
check "凌晨 4 点、3 小时前：放行（实际 $(rc)）" [ "$(rc)" = 0 ]
setup; with_prev; export GATE_NOW=$NIGHT; echo $((NIGHT - 7 * 3600)) > "$T/remote/backup/last-success"; deploy "$NEW" --execute
check "凌晨 4 点、7 小时前：退出码 5（实际 $(rc)）" [ "$(rc)" = 5 ]

t "门禁：--skip-backup-gate 显式跳过，照常发布并记进 gate-skips.log"
setup; with_prev; rm "$T/remote/backup/last-success"; deploy "$NEW" --execute --skip-backup-gate
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "current-tag = 新标签" [ "$(tag)" = "$NEW" ]
check "gate-skips.log 记了标签和原因" grep -q "tag=$NEW 跳过备份门禁：没有任何成功的备份记录" "$T/remote/backup/gate-skips.log"
perm() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
check "gate-skips.log 是 644、backup/ 是 711（api 的监控只读挂进去读它，S10c）" [ "$(perm "$T/remote/backup/gate-skips.log")$(perm "$T/remote/backup")" = 644711 ]
check "输出里有警告" grep -q "跳过备份门禁" "$T/out"

t "发布成功后装上 backup.sh 和定时器；systemctl 失败 → 退出码 4，发布本身不回滚"
setup; with_prev; deploy "$NEW" --execute
check "backup.sh 装到 /opt/yuanhui" cmp -s "$HERE/../backup.sh" "$T/remote/backup.sh"
check "两个 unit 装进 systemd 目录" cmp -s "$HERE/../yuanhui-backup.timer" "$T/units/yuanhui-backup.timer"
check "启用了定时器" grep -q "systemctl enable --now yuanhui-backup.timer" "$FAKE_LOG"
setup; with_prev; export FAKE_SYSTEMCTL_FAIL=1; deploy "$NEW" --execute
check "退出码 4（实际 $(rc)）" [ "$(rc)" = 4 ]
check "current-tag 已是新标签（发布成功）" [ "$(tag)" = "$NEW" ]

t "IMAGES_TAR（不用 ACR）：tar 传到 incoming/，先 docker load 再校验，不 docker pull；ACR 不填时用 local/yuanhui"
setup; with_prev; printf x > "$T/yuanhui-images-$NEW.tar.gz"
IMAGES_TAR="$T/yuanhui-images-$NEW.tar.gz" A='' deploy "$NEW" --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "scp 传了 tar" grep -q "^scp .*yuanhui-images-$NEW.tar.gz" "$FAKE_LOG"
check "docker load 了 incoming/ 里的 tar" grep -q "^docker load -i $T/remote/incoming/yuanhui-images-$NEW.tar.gz" "$FAKE_LOG"
check "load 在 caddy validate 之前" [ "$(grep -n '^docker load' "$FAKE_LOG" | cut -d: -f1)" -lt "$(grep -n 'caddy validate' "$FAKE_LOG" | cut -d: -f1)" ]
check "没有 docker pull" no grep -q "^docker pull" "$FAKE_LOG"
check "load 完删掉了 tar" [ ! -e "$T/remote/incoming/yuanhui-images-$NEW.tar.gz" ]
check ".env 指向 local/yuanhui/api:新标签（实际 $(envimg)）" [ "$(envimg)" = "local/yuanhui/api:$NEW" ]
unset A
setup; with_prev; export FAKE_IMAGE_PRESENT=1; deploy "$NEW" --execute
check "不带 tar、本机已有镜像：不 docker pull（实际 $(rc)）" [ "$(rc)" = 0 ] && no grep -q "^docker pull" "$FAKE_LOG"
unset FAKE_IMAGE_PRESENT
setup; with_prev; deploy "$NEW" --execute
check "不带 tar、本机没有镜像：照常 docker pull" grep -q "^docker pull $REG/api:$NEW" "$FAKE_LOG"
setup; with_prev; IMAGES_TAR="$T/nope.tar.gz" deploy "$NEW" --execute
check "tar 不存在：退出码 2、没有 ssh（实际 $(rc)）" [ "$(rc)" = 2 ] && [ ! -s "$FAKE_LOG" ]
setup; with_prev; printf x > "$T/a;b.tar"; IMAGES_TAR="$T/a;b.tar" deploy "$NEW" --execute
check "tar 文件名带分号：退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ] && [ ! -s "$FAKE_LOG" ]

t "发布标签（PR #27 Codex）：成功后打附注标签 release-<前 12 位> 并推到 origin；失败、门禁拒绝、dry-run 不打；重复发布幂等；推不上退出码 6"
setup; with_prev; deploy "$NEW" --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "origin 上有附注标签 release-${NEW:0:12}，指向这次的提交（实际：$(rtags)）" [ "$(rtags)" = "release-${NEW:0:12} tag $NEW" ]
check "输出里写了标签和按标签重打的命令" grep -q "gh workflow run image.yml --ref release-${NEW:0:12}" "$T/out"
deploy "$NEW" --execute
ok() { [ "$(rc)" = 0 ] && [ "$(rtags)" = "release-${NEW:0:12} tag $NEW" ]; }; check "同一个提交再发布一次：退出码 0、标签不变（实际 $(rc)）" ok
deploy "${NEW:0:7}" --execute
ok() { [ "$(rc)" = 0 ] && [ "$(rtags)" = "release-${NEW:0:12} tag $NEW" ]; }; check "用 7 位短提交号发布：同一个标签（实际 $(rc)：$(rtags)）" ok
setup; with_prev; export FAKE_BAD_IMAGE=":$BAD"; deploy "$BAD" --execute; unset FAKE_BAD_IMAGE
ok() { [ "$(rc)" = 1 ] && [ -z "$(rtags)" ] && [ -z "$(git -C "$G" tag -l 'release-*')" ]; }; check "发布失败已回滚：退出码 1、不打标签（实际 $(rc)：$(rtags)）" ok
setup; with_prev; rm "$T/remote/backup/last-success"; deploy "$NEW" --execute
ok() { [ "$(rc)" = 5 ] && [ -z "$(rtags)" ]; }; check "门禁拒绝：退出码 5、不打标签" ok
setup; with_prev; deploy "$NEW"
ok() { [ "$(rc)" = 0 ] && [ -z "$(rtags)" ] && [ -z "$(rcur)" ] && grep -q "^\[dry-run\] 发布成功后：deploy/release-tag.sh $NEW" "$T/out"; }; check "dry-run：不打标签、不动 release-current，只打印" ok
setup; with_prev; export FAKE_SYSTEMCTL_FAIL=1; deploy "$NEW" --execute; unset FAKE_SYSTEMCTL_FAIL
ok() { [ "$(rc)" = 4 ] && [ "$(rtags)" = "release-${NEW:0:12} tag $NEW" ]; }; check "定时器没装上（退出码 4，发布成功）：照样打标签，退出码仍是 4" ok
setup; with_prev; git -C "$G" remote set-url origin "$T/no-such-remote.git"; deploy "$NEW" --execute
ok() { [ "$(rc)" = 6 ] && [ "$(tag)" = "$NEW" ]; }; check "推不上 origin：退出码 6（实际 $(rc)），发布本身成功（current-tag 是新的）" ok
check "提示发布已成功、标签要补" grep -q "发布本身已成功，但发布标签没打上" "$T/out"
setup; with_prev; deploy 4444444 --execute
ok() { [ "$(rc)" = 6 ] && grep -q "先 git fetch" "$T/out"; }; check "本机仓库里没有这个提交：退出码 6（实际 $(rc)）、提示先 git fetch" ok
setup; with_prev; git -C "$G" tag -a "release-${NEW:0:12}" -m x "$OLD"; deploy "$NEW" --execute
ok() { [ "$(rc)" = 6 ] && [ "$(git -C "$G" rev-parse "release-${NEW:0:12}^{commit}")" = "$OLD" ]; }; check "同名标签已指向别的提交：不动它，退出码 6（实际 $(rc)）" ok

t "release-current（PR #27 Codex 第二轮 2）：每次发布成功都移到这次的提交，和 ECS 的 current-tag 一致；失败自动回滚不动它"
setup; with_prev; deploy "$NEW" --execute
check "发布成功：release-current = 这次的提交（实际 $(rcur)）" [ "$(rcur)" = "$NEW" ]
check "origin 上 release-current 是附注标签" [ "$(git -C "$T/origin.git" cat-file -t refs/tags/release-current)" = tag ]
export FAKE_BAD_IMAGE=":$BAD"; deploy "$BAD" --execute; unset FAKE_BAD_IMAGE
ok() { [ "$(rc)" = 1 ] && [ "$(tag)" = "$NEW" ] && [ "$(rcur)" = "$NEW" ]; }; check "发布坏镜像、自动回滚：退出码 1，current-tag 和 release-current 都还是上一个（实际 $(rc)、$(tag)、$(rcur)）" ok
# Codex 第二轮 1 的情形：origin 连得上但拒收推送（本机标签已打上），之后照 runbook 补救
setup; with_prev; printf '#!/bin/sh\nexit 1\n' > "$T/origin.git/hooks/pre-receive"; chmod +x "$T/origin.git/hooks/pre-receive"; deploy "$NEW" --execute
rm "$T/origin.git/hooks/pre-receive"
check "origin 拒收：退出码 6（实际 $(rc)）" [ "$(rc)" = 6 ]
check "推不上之后：本机已有发布标签（实际 $(git -C "$G" tag -l 'release-*' | tr '\n' ' ')）" [ -n "$(git -C "$G" tag -l "release-${NEW:0:12}")" ]
ok() { RELEASE_GIT_DIR=$G bash "$HERE/../release-tag.sh" "$(cat "$T/remote/current-tag")" > "$T/out" 2>&1; }
check "按 runbook 补救：用 ECS 的 current-tag 重跑 release-tag.sh，退出码 0" ok
ok() { [ "$(rtags)" = "release-${NEW:0:12} tag $NEW" ] && [ "$(rcur)" = "$NEW" ]; }; check "补救后 origin 上有发布标签，release-current 是这次的（实际 $(rtags)、$(rcur)）" ok

t "release-tag.sh 单独跑（runbook 的补救命令，PR #27 Codex 第二轮 1）：三种情况幂等或报错退出"
rt() { RELEASE_GIT_DIR=$G bash "$HERE/../release-tag.sh" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
setup; rt "$NEW"
ok() { [ "$(rc)" = 0 ] && [ "$(rtags)" = "release-${NEW:0:12} tag $NEW" ] && [ "$(rcur)" = "$NEW" ]; }; check "都没有：打上并推送，release-current 指向它（实际 $(rc)）" ok
before=$(git -C "$T/origin.git" rev-parse refs/tags/release-current); rt "$NEW"
ok() { [ "$(rc)" = 0 ] && [ "$(git -C "$T/origin.git" rev-parse refs/tags/release-current)" = "$before" ]; }; check "原样再跑一次：退出码 0，release-current 不重打（实际 $(rc)）" ok
setup; git -C "$G" tag -a "release-${NEW:0:12}" -m "旧脚本打的" "$NEW"; rt "$NEW"
ok() { [ "$(rc)" = 0 ] && [ "$(rtags)" = "release-${NEW:0:12} tag $NEW" ] && [ "$(git -C "$T/origin.git" cat-file tag "release-${NEW:0:12}" | tail -1)" = "旧脚本打的" ]; }
check "本机已有、指向同一提交：只推送，用的是本机那个标签（实际 $(rc)）" ok
setup; git -C "$G" tag -a "release-${NEW:0:12}" -m x "$OLD"; rt "$NEW"
ok() { [ "$(rc)" = 3 ] && [ -z "$(rtags)" ] && [ -z "$(rcur)" ] && grep -q "指向别的提交" "$T/out"; }; check "本机同名标签指向别的提交：退出码 3，什么都不推（实际 $(rc)）" ok
setup; git -C "$G" tag -a "release-${NEW:0:12}" -m x "$OLD"; git -C "$G" push -q origin "refs/tags/release-${NEW:0:12}"; git -C "$G" tag -d "release-${NEW:0:12}" > /dev/null; rt "$NEW"
ok() { [ "$(rc)" = 3 ] && [ -z "$(rcur)" ] && [ -z "$(git -C "$G" tag -l "release-${NEW:0:12}")" ]; }; check "origin 上同名标签指向别的提交：退出码 3，本机不打、不动 release-current（实际 $(rc)）" ok
setup; git -C "$G" tag -a "release-${NEW:0:12}" -m "别的机器打的" "$NEW"; git -C "$G" push -q origin "refs/tags/release-${NEW:0:12}"; git -C "$G" tag -d "release-${NEW:0:12}" > /dev/null; rt "$NEW"
ok() { [ "$(rc)" = 0 ] && [ "$(git -C "$G" rev-parse "release-${NEW:0:12}^{commit}")" = "$NEW" ] && [ "$(rcur)" = "$NEW" ]; }; check "origin 已有、本机没有：取下来，退出码 0（实际 $(rc)）" ok
setup; rt 4444444; check "找不到提交：退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]
rt "abc;x"; check "提交号格式不对：退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
rt --current; check "origin 上还没有 release-current：--current 退出码 1（实际 $(rc)）" [ "$(rc)" = 1 ]

t "发布 A → 发布 B → 手工回滚到 A（用 A 再发布一次）→ 整机恢复按 release-current 取到 A（PR #27 Codex 第二轮 2）"
setup; deploy "$OLD" --execute; a1=$(rc); sleep 1; deploy "$NEW" --execute; a2=$(rc); sleep 1; deploy "$OLD" --execute
check "三次发布都成功（实际 $a1 $a2 $(rc)）" [ "$a1$a2$(rc)" = 000 ]
check "ECS 的 current-tag 是 A" [ "$(tag)" = "$OLD" ]
check "origin 上两个发布标签都在" [ "$(rtags | wc -l | tr -d ' ')" = 2 ]
check "release-current 是 A（实际 $(rcur)）" [ "$(rcur)" = "$OLD" ]
newest=$(git -C "$T/origin.git" for-each-ref --sort=-creatordate --format='%(refname:short) %(*objectname)' 'refs/tags/release-*' | grep -v '^release-current ' | head -1 | cut -d' ' -f2)
check "（旧做法按创建时间取最新的会取到被回滚掉的 B）" [ "$newest" = "$NEW" ]
# 恢复在另一台机器上做：新克隆 origin，再在旧仓库（本机标签是旧的 release-current）各取一次
git clone -q "$T/origin.git" "$T/fresh"
ok() { [ "$(RELEASE_GIT_DIR=$T/fresh bash "$HERE/../release-tag.sh" --current 2> "$T/out")" = "$OLD release-${OLD:0:12}" ]; }
check "新克隆上 release-tag.sh --current 取到 A" ok
git -C "$G" tag -f -a release-current -m stale "$NEW" > /dev/null
ok() { [ "$(RELEASE_GIT_DIR=$G bash "$HERE/../release-tag.sh" --current 2> "$T/out")" = "$OLD release-${OLD:0:12}" ]; }
check "本机 release-current 是旧的（指向 B）：--current 强制取 origin 的，仍取到 A" ok
case "$(tag)" in "${OLD:0:${#OLD}}"*) okc=1;; *) okc=0;; esac
check "取到的提交和 ECS current-tag 一致" [ "$okc" = 1 ]

t "image.yml 能按发布标签重打（PR #27 Codex）：workflow_dispatch 触发、tar 那一步不限于 PR、标签 = 检出的提交号"
Y="$HERE/../../.github/workflows/image.yml"
check "有 workflow_dispatch" grep -q "^  workflow_dispatch:" "$Y"
check "打 tar 的条件：不是 PR 就打" grep -q "if: github.event_name != 'pull_request' ||" "$Y"
check "非 PR 时标签是 github.sha（按标签触发时就是标签指向的提交）" grep -q "TAG: \${{ github.event.pull_request.head.sha || github.sha }}" "$Y"

t "部署脚本里没有紧贴非 ASCII 字符的 \$变量（Bash 3.2 + UTF-8 下会被读成另一个变量名；一律写成 \${变量}）"
# shellcheck disable=SC2016
LC_ALL=C grep -nE '^[^#]*\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' "$HERE"/../*.sh > "$T/out" 2>&1
check "没有这种写法（见上面的行）" [ ! -s "$T/out" ]

echo "通过 ${pass}，失败 $fail"
[ "$fail" = 0 ]
