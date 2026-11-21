#!/usr/bin/env bash
# 部署脚本共用：默认 dry-run，只打印要执行的命令；带 --execute 才真的执行（含远程 ssh）。
DRY_RUN=1
ECS_HOST="${ECS_HOST:-}"
for a in "$@"; do [ "$a" = "--execute" ] && DRY_RUN=0; done
run() { if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] %s\n' "$*"; else "$@"; fi; }
remote() {
  if [ "$DRY_RUN" = 1 ]; then printf '[dry-run] ssh %s -- %s\n' "${ECS_HOST:-<ECS_HOST>}" "$*"; return 0; fi
  [ -n "$ECS_HOST" ] || { echo "需要 ECS_HOST（如 root@47.117.184.253）" >&2; exit 2; }
  ssh -o BatchMode=yes "$ECS_HOST" -- "$@"
}
