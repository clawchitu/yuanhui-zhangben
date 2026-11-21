#!/usr/bin/env bash
# bootstrap-ecs.sh 的单元测试：fakes/ 里的 ssh 把远端命令放到本机沙盒里跑，fallocate / mkswap / swapon / ufw / sshd 等用替身。
# 用法：deploy/test/bootstrap.test.sh        退出码 0 = 全部通过
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BOOT="${BOOTSTRAP_SH:-$HERE/../bootstrap-ecs.sh}"
pass=0; fail=0; T=""
setup() {
  T=$(mktemp -d); mkdir -p "$T/root/etc" "$T/root/root/.ssh" "$T/state" "$T/root/opt/yuanhui"
  : > "$T/root/etc/fstab"; echo "ssh-ed25519 AAAA test" > "$T/root/root/.ssh/authorized_keys"
  export FAKE_ROOT="$T/root" FAKE_REMOTE="$T/root/opt/yuanhui" FAKE_STATE="$T/state" FAKE_LOG="$T/log"; : > "$FAKE_LOG"
  unset FAKE_FALLOCATE_FAIL FAKE_MKSWAP_FAIL FAKE_SSHD_FAIL
}
boot() { PATH="$HERE/fakes:$PATH" ECS_HOST=root@47.117.184.253 bash "$BOOT" "$@" > "$T/out" 2>&1; echo $? > "$T/rc"; }
rc() { cat "$T/rc"; }
fstab_lines() { grep -c swapfile "$T/root/etc/fstab"; }
check() { local d=$1; shift; if "$@"; then pass=$((pass+1)); else fail=$((fail+1)); echo "  ✗ $d"; sed 's/^/    /' "$T/out"; fi; }
t() { echo "• $1"; }

t "正常初始化：swap 起来后写一次 fstab，SSH 禁口令，ufw 只放 22 / 80 / 443/tcp"
setup; boot --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "fstab 有一行 swap（实际 $(fstab_lines)）" [ "$(fstab_lines)" = 1 ]
check "swap 已启用" grep -q swapfile "$T/state/swaps"
check "sshd 配置禁口令" grep -qx "PasswordAuthentication no" "$T/root/etc/ssh/sshd_config.d/00-yuanhui.conf"
check "sshd 配置校验过再重载" grep -q "systemctl reload ssh" "$T/log"
check "ufw 没有 443/udp" bash -c "! grep -q udp '$T/state/ufw'"
check "ufw 放了 443/tcp" grep -qx 443/tcp "$T/state/ufw"
t "再跑一次（幂等）：fstab 仍只有一行，不再重载 sshd"
: > "$FAKE_LOG"; boot --execute
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "fstab 仍是一行（实际 $(fstab_lines)）" [ "$(fstab_lines)" = 1 ]
check "没有再 fallocate" bash -c "! grep -q fallocate '$T/log'"
check "没有再重载 sshd" bash -c "! grep -q 'reload ssh' '$T/log'"

t "fallocate 失败：退出码非 0，不写 fstab，不留半个文件"
setup; export FAKE_FALLOCATE_FAIL=1; boot --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "fstab 没有 swap 行（实际 $(fstab_lines)）" [ "$(fstab_lines)" = 0 ]
check "没留下 /swapfile" [ ! -e "$T/root/swapfile" ]

t "mkswap 失败：退出码非 0，不写 fstab"
setup; export FAKE_MKSWAP_FAIL=1; boot --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "fstab 没有 swap 行（实际 $(fstab_lines)）" [ "$(fstab_lines)" = 0 ]

t "root 没有公钥：不禁口令（防止把自己锁在外面），退出码非 0"
setup; rm "$T/root/root/.ssh/authorized_keys"; boot --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "没写 sshd 配置" [ ! -e "$T/root/etc/ssh/sshd_config.d/00-yuanhui.conf" ]

t "sshd -t 不过：撤回配置、不重载，退出码非 0"
setup; export FAKE_SSHD_FAIL=1; boot --execute
check "退出码非 0（实际 $(rc)）" [ "$(rc)" != 0 ]
check "配置已撤回" [ ! -e "$T/root/etc/ssh/sshd_config.d/00-yuanhui.conf" ]
check "没有重载 sshd" bash -c "! grep -q 'reload ssh' '$T/log'"

t "--execute 缺 ECS_HOST：退出码 2，不发 ssh"
setup; PATH="$HERE/fakes:$PATH" ECS_HOST="" bash "$BOOT" --execute > "$T/out" 2>&1; echo $? > "$T/rc"
check "退出码 2（实际 $(rc)）" [ "$(rc)" = 2 ]
check "没有发出 ssh" [ ! -s "$FAKE_LOG" ]

t "默认 dry-run：不发 ssh"
setup; boot
check "退出码 0（实际 $(rc)）" [ "$(rc)" = 0 ]
check "没有发出 ssh" [ ! -s "$FAKE_LOG" ]

echo "通过 ${pass}，失败 $fail"
[ "$fail" = 0 ]
