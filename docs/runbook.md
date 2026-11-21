# 运维手册（S10a 初版，S10b 加备份与恢复）

## 布局
ECS 上海 2C2G Ubuntu 24.04。`/opt/yuanhui/{compose.yml,caddy/Caddyfile,.env,current-tag,prev/,incoming/,backup.sh,backup/}`，数据 `/data/{pg,img,caddy}`。
Compose（`deploy/compose.yml`）：
- 网络 `edge`（172.30.0.0/24，动态地址只在 .128/25）：`caddy`（172.30.0.2，唯一映射公网端口 80、443/tcp）、`api`（172.30.0.3，不映射端口，出网连 OSS / 快鸟走这里）。
- 网络 `db`（172.30.1.0/24，`internal: true`，不出网）：`api`、`postgres`、`migrate`（只在发布时 `run`，没有固定地址）。Caddy 不在这个网络上，连不到数据库。
- `api` 内存上限 512 MB 且 `memswap_limit` 同为 512 MB（不许靠 swap 顶，§14 S10a-7）；`caddy` 128 MB；三个服务日志轮转 20 MB × 5。
- api `TRUST_PROXY=1`、`TRUSTED_PROXY=172.30.0.2`：只有对端是 Caddy 才看 `X-Forwarded-For`，且只取最右一项（§14 S03-6）。
- Caddy 只放行 `/v1/*` 和 `/healthz`，其余 404；只开 h1、h2（§14 S10a-5）。
- 镜像全部从 ACR 的 VPC 地址拉（`.env` 的 `CADDY_IMAGE`、`POSTGRES_IMAGE`，`API_IMAGE` 由发布脚本写）。

**备案通过前，服务器上只放假数据**（演示小店、测试店；黄总试用店先说明「账不作数」，Q8 未答复前不建），两个域名都不解析到这台 ECS（§9.2、§14 S10a-4）。

## 首次部署（顺序不能乱）
1. 云上人工步骤 `docs/cloud-manual-steps.md` 第 0–5 步做完（安全组、密钥、OSS、RAM、ACR）。
2. 镜像推 ACR：`mirror-base-images.sh --execute`（基础镜像）；`main` 上的 `image.yml` 推 `api:<提交号>` 成功（Actions 里看到「推 ACR」步骤绿）。
3. `ECS_HOST=root@47.117.184.253 deploy/bootstrap-ecs.sh` → 看一遍 → `--execute`。
4. ECS 上填 `/opt/yuanhui/.env`（`deploy/.env.example`，`POSTGRES_PASSWORD` 用 `openssl rand -hex 24`）。
5. ECS 上 `docker login <ACR 的 VPC 地址>`。
6. 本机发布：`ECS_HOST=root@47.117.184.253 ACR=<ACR 的 VPC 地址>/yuanhui deploy/deploy.sh <提交号>` → 看一遍 → 加 `--execute`。**`<提交号>` 填 40 位完整提交号**（`git rev-parse <提交>`）：`image.yml` 推的标签是 `${GITHUB_SHA}`，填 7 位短号会在拉镜像时失败（什么都没动，但白跑一趟）。首次发布时 `.env` 的 `API_IMAGE` 还是空的，脚本在切换前的 `compose config`、起 Postgres、迁移这几步临时带上新镜像，不用手填。首次发布会先起 Postgres、等健康，再跑迁移。首次发布还没有任何备份，要加 `--skip-backup-gate`（会记进 `backup/gate-skips.log`）；发布成功后备份定时器自动装上，之后的发布不再跳过。
7. 冒烟：`deploy/smoke.sh`；然后按下面「部署时验证」逐项做。

## 发布 / 回滚
- 发布：同上第 6 步（40 位完整提交号）。`deploy.sh` 在第一条 ssh 之前校验 `ACR`、`ECS_HOST`、标签（7–40 位小写十六进制），不对退出码 2。
- ECS 上 `remote-deploy.sh` 的顺序：校验新 compose 和新 Caddyfile → 拉镜像 → 备份当前配置到 `prev/` → 起 Postgres 等健康 → `migrate` → 换 `API_IMAGE` → `up -d` → 探 `/healthz` → 镜像内缩图冒烟 → `caddy reload`。**从起 Postgres 到重载 Caddy 任何一步失败**，自动换回 `prev/` 里的配置和上一个镜像，再探一次健康、重载一次 Caddy；回滚这几步也失败则退出码 3。
- `current-tag` 只在整套成功后写；失败时它保持上一个成功的标签。退出码：0 成功；1 失败已回滚（或首次发布没有可回的）；2 参数 / `.env` 不对，什么都没动；3 回滚也失败，需人工；4 发布成功但备份定时器没装上；5 备份门禁拒绝，什么都没动。
- 手工回滚 = 用上一个标签再跑一次 `deploy.sh`。
- **迁移前备份门禁**（S10b，§14 T20）：`remote-deploy.sh` 动任何东西之前看 `/opt/yuanhui/backup/last-success`，营业时间（上海 8:00–22:59）超过 2 小时、其余时间超过 6 小时没有成功备份 → 退出码 5、什么都不动。先在 ECS 上 `bash /opt/yuanhui/backup.sh`，成功再发布。确需跳过（首次发布、备份本身坏了要发修复）加 `--skip-backup-gate`，每次跳过记进 `/opt/yuanhui/backup/gate-skips.log`（时间、标签、原因）。
- 发布成功后会装上 `backup.sh` 和 `yuanhui-backup.{service,timer}` 并 `enable --now`；这一步失败退出码 4（发布本身已成功，不回滚）。
- 只改了 Caddyfile：用当前标签再跑一次 `deploy.sh`，会校验后 `caddy reload`。

## 备份与恢复（S10b，§9.4）
**时间表**：`yuanhui-backup.timer`，上海时间 8:00–22:00 每小时一次、02:30 一次（`systemctl list-timers yuanhui-backup.timer` 看下一次）。错过的开机补跑。
**一次备份**（`/opt/yuanhui/backup.sh`，也可手动跑）：`backup` 容器开可重复读事务、`pg_export_snapshot()`、在同一快照里算清单 → Postgres 容器里 `pg_dump -Fc --snapshot=<同一快照>` → `backup` 容器用口令加密（scrypt + AES-256-GCM）→ 传 `backups/<UTC 时间>-<随机>.dump.enc` 和 `.manifest.enc` → 写心跳 `heartbeat/backup.json` → 写 `backup/last-success`。不重叠（`backup/lock.d`，60 分钟以上算残留）。
**清单**：每张表的行数；每家店的流水条数、`value_delta_fen` 合计、`cogs_fen` 合计、商品库存 / 货值 / 最近进价的校验和、每条流水数量 / 金额 / 成本的校验和、本月和上月月报全部数字。和 dump 同一快照，恢复后逐项比对必须全等。
**保留**：备份账号删不了任何对象；`backups/` 35 天后由 OSS 生命周期删除（`cloud-manual-steps.md` 第 3 步）。每次备份顺带列一遍 `backups/`，最旧的一份超过 36 天打 `alert=backup_lifecycle_stale`（生命周期没生效）。
**可观测**（S10c 接告警）：
- `journalctl -u yuanhui-backup`：每次一行 JSON，`event=backup_ok`（`backup_id`、`dump_bytes`、`duration_s`），或 `event=backup_failed`、`alert=backup_failed`、`stage=prepare|snapshot|dump|upload`；
- `/opt/yuanhui/backup/status.json`、`metrics.prom`（`yuanhui_backup_last_success_timestamp_seconds`、`_last_attempt_timestamp_seconds`、`_last_ok`、`_consecutive_failures`、`_duration_seconds`、`_dump_bytes`）；
- OSS 上的心跳对象 `heartbeat/backup.json`（`at`、`backup_id`）：§9.5 的「营业时间内超过 2 小时没更新」看它。
- 手动看桶：`docker compose -f /opt/yuanhui/compose.yml --project-directory /opt/yuanhui --env-file /opt/yuanhui/.env run --rm -T backup node scripts/backup.ts status`。

### 恢复（演练和整机重建都用这一套）
只需要：这个仓库（`cd server && npm ci`）、`pg_restore` 16 或更新、备份账号的 AccessKey、加密口令（钥匙串 / Haoqiang 的密码管理器）。不需要 ECS。
1. 建一个**空库**做目标（演练：本机 `createdb yh_restore`；整机重建：新 ECS 上起好 Postgres，从本机经 `ssh -L` 连过去，或者在新 ECS 上装 node 跑）。脚本拒绝写非空且没有恢复标记的库，在用的库不会被覆盖。
2. 环境变量：
   ```sh
   export DATABASE_URL=postgres://<用户>:<口令>@127.0.0.1:5432/yh_restore
   export BACKUP_PASSPHRASE="$(security find-generic-password -s yuanhui-backup-passphrase -w)"
   export BACKUP_OSS_REGION=oss-cn-shanghai BACKUP_OSS_BUCKET=yuanhui-backup BACKUP_OSS_ENDPOINT=https://oss-cn-shanghai.aliyuncs.com
   export BACKUP_OSS_ACCESS_KEY_ID=… BACKUP_OSS_ACCESS_KEY_SECRET=…   # 钥匙串 yuanhui-backup-oss
   ```
3. `deploy/restore.sh latest`（或指定 `<备份 id>`）：dry-run，下载、解密、核对 sha256、`pg_restore --list`、检查目标库、列出要重放的删除记录，目标库不写。
4. `deploy/restore.sh latest --execute`：清空并标记目标库 → `pg_restore` → 按清单逐项比对（不一致就停，不换 epoch，库留着查）→ 重放 `deletions/` 里的每条删除记录（已注销的店整家删掉，设备行没了，旧令牌和重传一律 401；`store_purges` 记上，对象清理照常再扫一遍）→ 再比对（注销的店不在，其余店和清单一致）→ 全部店换新 `epoch`。最后一行 `restore_ok` 带 `restore_seconds`。重跑同一条命令结果一样。
5. 整机重建时：把 api 指到恢复好的库，发布（`deploy.sh`，此时没有备份要加 `--skip-backup-gate`）；手机下一次同步拿到 `epoch_mismatch` → 全量拉取 → 重传保留的 op（§4.6）。备份之后才开通的设备要重新开通，再按 §4.6 临时开「恢复模式」补交。

## 看日志、看证书
- 容器状态：`docker compose -f /opt/yuanhui/compose.yml --project-directory /opt/yuanhui --env-file /opt/yuanhui/.env ps`
- api 日志：`docker logs --since 1h yuanhui-api-1`；告警字段：`docker logs yuanhui-api-1 2>&1 | grep '"alert"'`
- 不得出现：`docker logs yuanhui-api-1 2>&1 | grep -E 'export_no_archive|purge_no_archive'` 应为空。
- Caddy 访问日志（JSON，看 `request.remote_ip`）：`docker logs --since 10m yuanhui-caddy-1 2>&1 | grep '"http.log.access' | tail`
- 证书签发 / 续期记录：`docker logs yuanhui-caddy-1 2>&1 | grep -E 'certificate obtained|renew|obtain|acme' | tail -20`
- 当前证书的签发方和到期时间（本机）：`echo | openssl s_client -connect 47.117.184.253:443 -servername 47.117.184.253 2>/dev/null | openssl x509 -noout -issuer -dates`
- 不带 SNI 时拿到的证书：同上把 `-servername …` 换成 `-noservername`。
- 证书文件（ECS 上）：`ls -l /data/caddy/data/caddy/certificates/*/`

## 证书策略（§14 S10a-3，PR #22 Fable 裁定 ①）
- 方案 A（Let's Encrypt IP 短期证书）续期不稳时**不直接换私有 CA**。备案前服务器上只有假数据，App 离线可用，证书断几天不是紧急事件。
- 「不稳」要有数字：部署后**观察 14 天**，期间出现过证书剩余有效期低于 48 小时、或过期，才算不稳；一两次续期重试不算。每次续期成功 / 失败的记录和剩余有效期告警在 S10c 做（§14 T19），在那之前每天按上面的命令看一次并记下来。
- 切方案 B 的前提：S11b 已在真机 Beta 包上用 `URLSession` 实测私有 CA 可连，并写进 `docs/beta-probe.md`（§14 T22）。在那之前即使 A 不稳，也只是停同步、等 S11b；**不许为了连上去加 ATS 例外或 `curl -k`**。
- B 的约束：CA 私钥只在这台 Mac 的钥匙串；CA 带名称限制，只能签 `47.117.184.253`；服务器证书 IP 写在 SAN、有效期不超过 397 天；信任方式**只许**在 Beta 配置里把 CA 打进包做锚点固定，仍校验 IP。**不装描述文件**（家人手机上装描述文件并打开完全信任是全机信任，不采用）。Release 配置里不出现 CA 和任何例外（S30 归档检查）。
- S11b 实测 B 还需要 `NSAllowsArbitraryLoads` 之类才能连 → 不做 B，走方案 C（离线试用）。

### 切方案 B 的服务器端步骤（只写不做，满足上面前提后才执行）
1. 本机用钥匙串里的 CA 签好服务器证书，得到 `ip-cert.pem`（含中间证书链，若有）和 `ip-key.pem`。私钥文件只在传输时离开本机，传完本机删掉临时文件。
2. 先在 ECS 上建目录：`ssh root@47.117.184.253 'mkdir -p /opt/yuanhui/caddy/tls && chmod 700 /opt/yuanhui/caddy/tls'`（目录不存在时 `scp` 会把两个文件写成同一个名为 `tls` 的文件）。再传：`scp ip-cert.pem ip-key.pem root@47.117.184.253:/opt/yuanhui/caddy/tls/`。然后 ECS 上（一律完整路径）：
   ```sh
   chown root:root /opt/yuanhui/caddy/tls/ip-cert.pem /opt/yuanhui/caddy/tls/ip-key.pem
   chmod 644 /opt/yuanhui/caddy/tls/ip-cert.pem
   chmod 600 /opt/yuanhui/caddy/tls/ip-key.pem
   chmod 700 /opt/yuanhui/caddy/tls
   ```
   容器里 Caddy 以 root 运行、`./caddy` 只读挂载在 `/etc/caddy`，所以路径是 `/etc/caddy/tls/…`。`remote-deploy.sh` 校验新 Caddyfile 的临时容器在 `/opt/yuanhui/caddy/tls/` 存在时同样把它只读挂到 `/etc/caddy/tls`，所以第 4 步的校验能读到证书和私钥；这一步没做（目录不存在）第 4 步会在校验时失败，什么都不切。
3. 改 `deploy/Caddyfile.ip` 的站点：把 `tls { issuer acme { … } }` 整段换成 `tls /etc/caddy/tls/ip-cert.pem /etc/caddy/tls/ip-key.pem`。
4. 用当前标签跑 `deploy.sh --execute`（校验后 `caddy reload`）；本机 `openssl s_client` 看签发方已是自家 CA；`curl` 不加 `-k` 时**应失败**（公网不信这张证书，这是预期），真机 Beta 包按 S11b 的结果验证。
5. 方案 B 期间每年证书到期前 30 天重签（有效期 ≤ 397 天）；备案切域名后按 §9.3 第 7 步删掉 IP 站点和这两个文件。

## 部署时验证（数字写回这里和部署实测 PR；本 PR 合并不等于 S10a 通过，§14 S10a-9）
| # | 项 | 方法 | 结果 |
|---|---|---|---|
| 1 | 自动回滚 | 用一个故意坏掉的镜像（如 `/healthz` 永远 503 的分支构建）跑 `deploy.sh --execute`：退出码 1、`current-tag` 不变、api 回到上一个镜像、`smoke.sh` 通过 | 待测 |
| 2 | 端口 | 公网连不上 3000 **和 5432**（`smoke.sh` 两个都查）；`nmap -Pn -p 22,80,443,3000,5432,3389 47.117.184.253` 从家外网络跑一次 | 待测 |
| 3 | 客户端 IP | `SMOKE_XFF=1 deploy/smoke.sh`（伪造 XFF 换不出额度）；**另外** Caddy 访问日志里的 `remote_ip` 等于测试机的公网出口 IP（不是 `172.30.0.1` 之类的网关）；换一个出口（手机蜂窝）登录不受前一个 IP 限速影响 | 待测 |
| 4 | 无 SNI | `openssl s_client -connect 47.117.184.253:443 -noservername` 拿到的是公网签发的 IP 证书 | 待测 |
| 5 | 证书 | 境外和本机各一次 `curl`（不加 `-k`），记签发方、有效期；观察到一次自动续期，记续期前后的到期时间；14 天观察记录（见证书策略） | 待测 |
| 6 | 存档桶 | 日志里没有 `export_no_archive`、`purge_no_archive` | 待测 |
| 7 | RAM 负测 | 用 api 的凭据写 `images/` 以外的前缀、读写 `backups/`、删 `deletions/`，都 403（`cloud-manual-steps.md` 第 4 步，T9 ⑤） | 待测 |
| 8 | 镜像链路 | CI 推 ACR 成功一次，记耗时；ECS 从 VPC 地址拉取成功 | 待测 |
| 9 | T4 / T2-2、T7 | 30 个登录同时到：最慢一个响应时间、期间 `/healthz` 和一次 `/v1/sync` 耗时、0 个 500；单次 argon2 耗时。约 40 万行流水下月报和 `/v1/entries/days` 耗时，07c > 200 ms 要改 | 待测 |
| 10 | T10 | 512 MB api 里 3 个并发登录 + 缩 5000×5000 隔行 16 位 PNG：不被 OOM 杀；记 cgroup `memory.peak`（`docker exec yuanhui-api-1 cat /sys/fs/cgroup/memory.peak`）写在这里 | 待测 |
| 11 | T13 / T17 | 真实 OSS 上列举、删除、`putFile` 分片、`listUploads` / `abortUpload` 各一次 | 待测 |
| 12 | T9 ①–⑥ | ① 20 个真实条码命中率 / 有图率；② 真实录制件替换手写夹具、定判别字段；③ 条款原文摘进 `docs/image-rights.md`；④ 计费是预付次数包、用完即停；⑤ 真实 OSS 往返、RAM 只能读写 `images/`；⑥ 条码格式过滤做不做 | 待测 |
| 13 | 重启 | `reboot` 后三个容器自己起来（`restart: unless-stopped`），`swapon --show` 仍有 `/swapfile`，`smoke.sh` 通过 | 待测 |

### S10b 部署时验证（真机器上才能做，数字写回这里和部署实测 PR；没做完 S10b 不算通过）
| # | 项 | 方法 | 结果 |
|---|---|---|---|
| B1 | 定时器在 ECS 上按时跑 | `systemctl list-timers yuanhui-backup.timer` 的下一次时间对得上（上海 8:00–22:00 整点、02:30）；跑过一个营业日后 `journalctl -u yuanhui-backup --since today` 里 15 次 `backup_ok`，桶里 `backups/` 多 15 对对象 | 待测 |
| B2 | 跨容器快照 | 第一次 `bash /opt/yuanhui/backup.sh` 成功（`pg_dump --snapshot` 在 Postgres 容器里导入 backup 容器导出的快照）；记 `duration_s`、`dump_bytes` | 待测 |
| B3 | 真实 OSS 读写 | 备份账号：`backups/` 分片上传（`putFile`）、读、列举，`deletions/` 列举、读，心跳读写各成功一次；`cloud-manual-steps.md` 第 4 步的负测全部 403 | 待测 |
| B4 | 生命周期、版本控制 | `ossutil lifecycle --method get` 的输出贴进 PR：`backups/` 35 天、`exports/` 30 天、`deletions/` 无；两个桶「版本控制」未开通；第 36 天起 `backup.ts status` 的 `lifecycle_stale` 一直是 false | 待测 |
| B5 | 口令另存两处 | Mac 钥匙串里有 `yuanhui-backup-passphrase`、`yuanhui-backup-oss`；Haoqiang 确认密码管理器里有同样两项（只确认有，不贴值） | 待测 |
| B6 | 异机恢复演练 | 在 Mac 上只凭 OSS 和钥匙串按上面「恢复」做一遍：`restore_ok`、清单逐项一致、注销的店不在；记 `restore_seconds`（RTO 目标 1 小时以内，含下载） | 待测 |
| B7 | 换 epoch 后补回 | 一台带保留 op 的测试手机：恢复后同步拿到 `epoch_mismatch`、全量拉取、补回备份之后的流水（需要 App 端的握手，S11b 之后做） | 待测 |
| B8 | 迁移前门禁 | 营业时间内停掉定时器超过 2 小时后发布 → 退出码 5；`--skip-backup-gate` 能发布且 `gate-skips.log` 有记录；恢复定时器 | 待测 |
| B9 | 失败信号 | 临时把 `.env` 的 `BACKUP_OSS_ACCESS_KEY_SECRET` 改错跑一次：`backup_failed stage=upload`、`metrics.prom` 的 `last_ok 0`、`consecutive_failures` 加 1、心跳不变；改回后下一次清零 | 待测 |

## 关掉商品图开关时清第三方图（T12）
1. `.env` 里 `PRODUCT_IMAGES_ENABLED=0`，用当前标签跑 `deploy.sh --execute` 重启 api。
2. 用 RAM 账号列举并删除 `yuanhui-img` 的 `images/` 前缀（`ossutil rm -r oss://yuanhui-img/images/ -f`）。
3. `rm -rf /data/img/*`（本机缓存）。
4. 清掉库里的图片状态（不然以后再开开关，库里认为有图、桶里没有）：
   ```sh
   docker exec -i yuanhui-postgres-1 psql -U yuanhui -d yuanhui -v ON_ERROR_STOP=1 <<'SQL'
   BEGIN;
   DELETE FROM image_jobs;
   UPDATE products SET image_key = NULL, image_source = NULL, image_ver = 0 WHERE image_ver <> 0 OR image_key IS NOT NULL;
   COMMIT;
   SQL
   ```
   这一步不推进 `rev`，手机上旧的 `image_ver` 要等商品下次变动才更新；开关关着时手机一律显示首字，不受影响。以后要重开开关，先提裁定处理手机端缓存。
