#!/usr/bin/env bash
# 部署脚本共用：默认 dry-run，只打印要执行的命令；带 --execute 才真的执行（含远程 ssh）。
# 远程命令一律按参数传：每个参数用 printf %q 转义后再交给 ssh，远端 shell 收到的就是原样的参数，
# 带分号、引号的值改变不了命令（Codex 1）。调用方还要先用 check_* 校验格式。
DRY_RUN=1
ECS_HOST="${ECS_HOST:-}"
for a in "$@"; do [ "$a" = "--execute" ] && DRY_RUN=0; done
die2() { echo "$*" >&2; exit 2; }
# 标签 = 提交号：7–40 位小写十六进制
check_tag() { [[ ${1:-} =~ ^[0-9a-f]{7,40}$ ]] || die2 "标签只收 7–40 位小写十六进制提交号：${1:-（空）}"; }
# 镜像仓库：<主机>[:端口]/<命名空间>，如 crpi-xxx-vpc.cn-shanghai.personal.cr.aliyuncs.com/yuanhui
check_acr() { [[ ${1:-} =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?/[a-z0-9][a-z0-9._-]*$ ]] || die2 "ACR 格式不对（<仓库主机>/<命名空间>）：${1:-（空）}"; }
# ECS_HOST：[用户@]主机，不许以 - 开头（否则会被 ssh 当成选项）
check_host() { [[ ${1:-} =~ ^([a-z_][a-z0-9_-]*@)?[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die2 "ECS_HOST 格式不对（如 root@47.117.184.253）：${1:-（空）}"; }
quote() { local out="" a; for a in "$@"; do out+="$(printf '%q' "$a") "; done; printf '%s' "${out% }"; }
run() { if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] %s\n' "$(quote "$@")"; else "$@"; fi; }
remote() {
  if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] ssh %s -- %s\n' "${ECS_HOST:-<ECS_HOST>}" "$(quote "$@")"; return 0; fi
  check_host "$ECS_HOST"
  ssh -o BatchMode=yes "$ECS_HOST" -- "$(quote "$@")"
}
