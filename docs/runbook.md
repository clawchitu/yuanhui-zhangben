# 运维手册（S10a 初版）

## 布局
ECS 上海 2C2G Ubuntu 24.04，`/opt/yuanhui/{compose.yml,Caddyfile.ip,.env,current-tag}`，数据 `/data/{pg,img,caddy}`。
Compose：`caddy`（172.30.0.2，唯一映射公网端口）、`api`（172.30.0.3，512 MB，不映射端口）、`postgres`（172.30.0.4，不出网）。
api `TRUST_PROXY=1`、`TRUSTED_PROXY=172.30.0.2`：只有对端是 Caddy 才看 `X-Forwarded-For`，且只取最右一项（§14 S03-6）。

## 发布 / 回滚
- 发布：`ECS_HOST=root@47.117.184.253 ACR=<registry>/yuanhui deploy/deploy.sh <提交号>` 先 dry-run，再加 `--execute`。
- 失败自动回滚到 `current-tag` 里的上一个标签；手工回滚 = 用上一个标签再跑一次 `deploy.sh`。
- 发布后：`deploy/smoke.sh`；`SMOKE_XFF=1` 时测伪造 XFF（会占本机 IP 15 分钟登录额度）。
- 日志里不得出现 `export_no_archive`、`purge_no_archive`：`docker logs yuanhui-api-1 2>&1 | grep -E 'export_no_archive|purge_no_archive'` 应为空。

## 部署时实测（数字写回这里和 S10a PR）
| 项 | 方法 | 结果 |
|---|---|---|
| T4 / T2-2 | 30 个登录同时到：最慢一个响应时间、期间 `/healthz` 和一次 `/v1/sync` 耗时、0 个 500；单次 argon2 耗时 | 待测 |
| T7 | 约 40 万行流水下月报和 `/v1/entries/days` 耗时，07c > 200 ms 要改 | 待测 |
| T10 | 512 MB api 里 3 个并发登录 + 缩 5000×5000 隔行 16 位 PNG，不 OOM | 待测 |
| T9 | 快鸟 20 条码命中率 / 有图率、条款原文、计费方式、OSS 往返 | 待测 |
| T13 / T17 | 真实 OSS 上列举、删除、`putFile` 分片、`listUploads` / `abortUpload` 各一次 | 待测 |
| 证书 | 境外和本机 `curl` 验证链公开受信任；观察到一次自动续期 | 待测 |

## 关掉商品图开关时清第三方图（T12）
1. `.env` 里 `PRODUCT_IMAGES_ENABLED=0`，`deploy.sh <当前标签> --execute` 重启 api。
2. 用 RAM 账号列举并删除 `yuanhui-img` 的 `images/` 前缀（`ossutil rm -r oss://yuanhui-img/images/ -f`）。
3. `rm -rf /data/img/*`（本机缓存）。手机端开关关着时一律显示首字。
