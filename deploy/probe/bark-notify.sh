#!/usr/bin/env bash
# 本机探测的 Bark 通道：PROBE_NOTIFY_CMD=<仓库绝对路径>/deploy/probe/bark-notify.sh
# 告警正文从 stdin 读：第一行当标题，其余当正文，分组 yuanhui。
# Bark key 从钥匙串读（服务名 BARK_KEYCHAIN_SERVICE，默认 chitu-bark-key），不进配置文件；
# key 经 curl -K - 从 stdin 传，不出现在命令行（ps 里看不到）。
# 退出码：0 发出；3 钥匙串里没有 key；其他 = curl 失败（探测会下一轮重发）
set -euo pipefail
svc="${BARK_KEYCHAIN_SERVICE:-chitu-bark-key}"
server="${BARK_SERVER:-https://api.day.app}"
SECURITY="${BARK_SECURITY:-security}"
CURL="${BARK_CURL:-curl}"
key=$("$SECURITY" find-generic-password -s "$svc" -w 2>/dev/null) || { echo "钥匙串里没有 $svc" >&2; exit 3; }
[[ "$key" =~ ^[A-Za-z0-9]+$ ]] || { echo "钥匙串 $svc 里的值不像 Bark key" >&2; exit 3; }
msg=$(cat)
title=${msg%%$'\n'*}
body=""
[ "$title" = "$msg" ] || body=${msg#*$'\n'}
printf 'url = "%s/%s"\n' "$server" "$key" | "$CURL" -fsS --max-time 20 -o /dev/null -K - \
  --data-urlencode "title=$title" --data-urlencode "body=$body" --data-urlencode "group=yuanhui"
