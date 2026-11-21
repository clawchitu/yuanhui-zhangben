#!/usr/bin/env bash
# 本机定时探测的入口（S10c，§9.5）：launchd 每 10 分钟跑一次（cn.yuanhuishop.probe.plist），也可以手动跑。
# 读配置文件（默认 ~/.config/yuanhui-probe/env，必须 600、属主是自己：里面可能有 webhook 令牌），
# 然后跑 server/scripts/probe.ts（只用 Node 自带模块，不用 npm ci）。
# 用法：deploy/probe/run-probe.sh [--test-alert]      --test-alert：探测完再发一条「告警通道测试」
# 退出码：0 跑完（不论有没有告警）；2 配置不对；其他 = node 的退出码
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
CONF="${PROBE_ENV_FILE:-$HOME/.config/yuanhui-probe/env}"
NODE="${PROBE_NODE:-node}"

[ -f "$CONF" ] || { echo "缺配置文件 ${CONF}（照 deploy/probe/probe.env.example 填）" >&2; exit 2; }
mode=$(stat -c %a "$CONF" 2>/dev/null || stat -f %Lp "$CONF")
owner=$(stat -c %u "$CONF" 2>/dev/null || stat -f %u "$CONF")
[ "$mode" = 600 ] || { echo "${CONF} 权限是 ${mode}，要 600（chmod 600 ${CONF}）" >&2; exit 2; }
[ "$owner" = "$(id -u)" ] || { echo "$CONF 的属主不是当前用户" >&2; exit 2; }

# 只认这几个变量，别的行忽略（配置文件不当 shell 脚本 source，里面写什么都不会被执行）
allowed=" PROBE_URL PROBE_STATE_DIR PROBE_SSH_TARGET PROBE_REMOTE_OUTBOX PROBE_NOTIFY_CMD PROBE_WEBHOOK_URL PROBE_WEBHOOK_TOKEN "
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  k=${line%%=*}; v=${line#*=}
  [ "$k" != "$line" ] || continue
  case "$allowed" in *" $k "*) export "$k=$v" ;; *) echo "忽略配置里不认识的键：$k" >&2 ;; esac
done < "$CONF"

exec "$NODE" "$REPO/server/scripts/probe.ts" "$@"
