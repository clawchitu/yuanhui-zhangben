# 运维手册（S10a 初版，S10b 加备份与恢复）

## 布局
ECS 上海 2C2G Ubuntu 24.04。`/opt/yuanhui/{compose.yml,caddy/Caddyfile,.env,current-tag,prev/,incoming/,backup.sh,backup/}`，数据 `/data/{pg,img,caddy}`。
Compose（`deploy/compose.yml`）：
- 网络 `edge`（172.30.0.0/24，动态地址只在 .128/25）：`caddy`（172.30.0.2，唯一映射公网端口 80、443/tcp）、`api`（172.30.0.3，不映射端口，出网连 OSS / 快鸟走这里）。
- 网络 `db`（172.30.1.0/24，`internal: true`，不出网）：`api`、`postgres`、`migrate`（只在发布时 `run`，没有固定地址）。Caddy 不在这个网络上，连不到数据库。
- `api` 内存上限 512 MB 且 `memswap_limit` 同为 512 MB（不许靠 swap 顶，§14 S10a-7）；`caddy` 128 MB；三个服务日志轮转 20 MB × 5。
- api `TRUST_PROXY=1`、`TRUSTED_PROXY=172.30.0.2`：只有对端是 Caddy 才看 `X-Forwarded-For`，且只取最右一项（§14 S03-6）。
- Caddy 只放行 `/v1/*` 和 `/healthz`，其余 404；只开 h1、h2（§14 S10a-5）。
- 镜像不从 Docker Hub 拉（ECS 连不上）。默认（负责人 11/22 决定，不用 ACR）：GitHub Actions 的 `image.yml` 把 api、`caddy:2.10.2`、`postgres:16` 打成 `yuanhui-images-<提交号>.tar.gz`，发布时传上去 `docker load`，镜像名前缀 `local/yuanhui`（`.env` 的 `CADDY_IMAGE=local/yuanhui/caddy:2.10.2`、`POSTGRES_IMAGE=local/yuanhui/postgres:16`，`API_IMAGE` 由发布脚本写）。ACR 路径保留为可选（`cloud-manual-steps.md` 第 5 步）。
- OSS：`yuanhui-backup`（只放 `backups/`，**合规保留 35 天**）、`yuanhui-archive`（`exports/`、`deletions/`、`heartbeat/`）；商品图桶 `yuanhui-img` T9 前不建。**按负责人决定，服务器使用部署账号密钥，不使用专用子账号**（`cloud-manual-steps.md` 第 4 步）。

**备案通过前，服务器上只放假数据**（演示小店、测试店；黄总试用店先说明「账不作数」，Q8 未答复前不建），两个域名都不解析到这台 ECS（§9.2、§14 S10a-4）。

## 首次部署（顺序不能乱）
1. 云上人工步骤 `docs/cloud-manual-steps.md` 第 0–4 步做完（安全组、密钥、两个 OSS 桶和合规保留、生命周期）。第 5 步 ACR 不做。
2. 镜像 tar：`image.yml` 在 main 的 push、手动触发（`gh workflow run image.yml`）或带 `deploy-tar` 标签的 PR 上传 artifact `yuanhui-images-<提交号>`（**只留 3 天**；过期后按发布标签重打，见「整机重建」第 1 步）。本机 `gh run download <run id> -D /tmp/yh-img`，`shasum -a 256 -c *.sha256`。
3. `ECS_HOST=root@47.117.184.253 deploy/bootstrap-ecs.sh` → 看一遍 → `--execute`。
4. ECS 上填 `/opt/yuanhui/.env`（`deploy/.env.example`，`POSTGRES_PASSWORD` 用 `openssl rand -hex 24`）。密钥走管道写入、不显示：本机把 `KEY=值` 行从钥匙串拼出来，`| ssh root@47.117.184.253 'bash /root/setenv.sh'`（ECS 上一个替换同名行的小脚本，见部署实测 PR），不在命令行和终端里出现值。
5. （不用 ACR 时跳过 `docker login`。）
6. 本机发布：`IMAGES_TAR=/tmp/yh-img/…/yuanhui-images-<提交号>.tar.gz ECS_HOST=root@47.117.184.253 deploy/deploy.sh <提交号>` → 看一遍 → 加 `--execute`（tar 约 300 MB，scp 加 `docker load` 几分钟）。**`<提交号>` 填 40 位完整提交号**，和 tar 文件名里的一致：tar 里的 api 镜像标签就是它，对不上 `remote-deploy.sh` 在 `docker load` 后就停（什么都没切）。用 ACR 时不带 `IMAGES_TAR`、加 `ACR=<ACR 的 VPC 地址>/yuanhui`。首次发布时 `.env` 的 `API_IMAGE` 还是空的，脚本在切换前的 `compose config`、起 Postgres、迁移这几步临时带上新镜像，不用手填。首次发布会先起 Postgres、等健康，再跑迁移。首次发布还没有任何备份，要加 `--skip-backup-gate`（会记进 `backup/gate-skips.log`）；发布成功后备份定时器自动装上，之后的发布不再跳过。
7. 冒烟：`deploy/smoke.sh`；然后按下面「部署时验证」逐项做。

## 发布 / 回滚
- 发布：同上第 6 步（40 位完整提交号）。`deploy.sh` 在第一条 ssh 之前校验 `IMAGES_TAR`（文件存在、文件名）或 `ACR`、`ECS_HOST`、标签（7–40 位小写十六进制），不对退出码 2。
- **发布标签**（PR #27 Codex）：发布成功（退出码 0 或 4）后，`deploy.sh` 调 `ECS_HOST=… deploy/release-tag.sh <提交号>`：先核对 ECS 上的 `current-tag` 就是这个提交，再给这次的提交打附注标签 `release-<提交号前 12 位>`（说明里有发布时间和 ECS，永不移动），再把**移动标签 `release-current`** 强制移到这次的提交，都推到 origin；输出最后一行「发布标签：…」。`release-current` 每次发布成功都跟着走（手工回滚也是一次发布，见下），所以它和 ECS 上的 `current-tag` 一致；发布失败自动回滚时两者都不变。镜像 artifact 只留 3 天，ECS 丢了以后按 `release-current` 取版本、按 `release-<前 12 位>` 重打同一个提交的镜像（`workflow_dispatch` 的 `--ref` 只收分支或标签，不收提交号）。所以发布前本机仓库要有这个提交（`git fetch origin`）。
  - 标签打不上或推不上：发布本身不回滚，退出码 6。修好（网络、权限）后照 `deploy.sh` 打印的补救命令跑：`ECS_HOST=root@47.117.184.253 deploy/release-tag.sh --from-ecs`（不带提交号，脚本自己读 ECS 上的 `/opt/yuanhui/current-tag`，按当时线上那一版补）。直接带提交号跑 `ECS_HOST=… deploy/release-tag.sh <提交号>` 时，脚本先核对 ECS 的 `current-tag`，不是同一个提交就什么都不动、退出码 3（PR #27 Codex 第三轮：A 的标签没推上、B 又发布成功后，按 A 的提交号补会把 `release-current` 拨回 A，线上却是 B）；读不到 `current-tag` 退出码 1。脚本幂等：本机、origin 都没有就打上并推；本机已有且指向同一提交（上次推送失败留下的）就只推；origin 有、本机没有就取下来；同名标签在本机或 origin 指向别的提交就什么都不动、退出码 3（需人工看）。退出码 1 是找不到提交或连不上 origin / ECS，可重跑。用 `--from-ecs` 而不是自己记的提交号，是为了下一次发布之后再补也不会把 `release-current` 拨回旧版本（那时补上的是当前线上那一版；被跳过的那一版没有发布标签，它已不在线上，整机恢复用不到）。
  - 看发布历史：`git fetch --force --tags origin && git for-each-ref --sort=-creatordate --format='%(creatordate:iso) %(refname:short) %(*objectname) %(contents:subject)' 'refs/tags/release-*'`。**这是标签第一次打的时间，不是线上版本**：回滚到旧提交不新打标签，最新一行可能是被回滚掉的版本。当前线上版本只看 `deploy/release-tag.sh --current`（或 ECS 上的 `current-tag`）。
- ECS 上 `remote-deploy.sh` 的顺序：（`--load-images` 时先 `docker load`、删掉 tar、确认 tar 里有 `api:<标签>`）→ 校验新 compose 和新 Caddyfile → 拉镜像（tar 时不拉）→ 备份当前配置到 `prev/` → 起 Postgres 等健康 → `migrate` → 换 `API_IMAGE` → `up -d` → 探 `/healthz` → 镜像内缩图冒烟 → `caddy reload`。**从起 Postgres 到重载 Caddy 任何一步失败**，自动换回 `prev/` 里的配置和上一个镜像，再探一次健康、重载一次 Caddy；回滚这几步也失败则退出码 3。
- `current-tag` 只在整套成功后写；失败时它保持上一个成功的标签。退出码：0 成功；1 失败已回滚（或首次发布没有可回的）；2 参数 / `.env` 不对，什么都没动；3 回滚也失败，需人工；4 发布成功但备份定时器没装上；5 备份门禁拒绝，什么都没动；6 发布成功但发布标签没打上 / 没推上（见上）。
- 手工回滚 = 用上一个标签再跑一次 `deploy.sh`（成功后 `current-tag` 和 `release-current` 都回到这个提交）：上一个镜像还在 ECS 上时，不带 `IMAGES_TAR`、带 `ACR=local/yuanhui` 即可（`remote-deploy.sh` 本机已有镜像就不 `docker pull`，`4d18f4e`）；镜像已被清掉时带上那次的 tar（过期了按发布标签重打）。
- 旧镜像：tar 路径下 ECS 上的旧 api 镜像不会自动清，每次发布多约 300 MB。每月看一次 `docker images local/yuanhui/api`，留 `current-tag` 和最近 3 个，其余 `docker rmi local/yuanhui/api:<提交号>`（不要 `docker image prune -a`，会连回滚要用的一起删）。
- **迁移前备份门禁**（S10b，§14 T20）：`remote-deploy.sh` 动任何东西之前看 `/opt/yuanhui/backup/last-success`，营业时间（上海 8:00–22:59）超过 2 小时、其余时间超过 6 小时没有成功备份 → 退出码 5、什么都不动。先在 ECS 上 `bash /opt/yuanhui/backup.sh`，成功再发布。确需跳过（首次发布、备份本身坏了要发修复）加 `--skip-backup-gate`，每次跳过记进 `/opt/yuanhui/backup/gate-skips.log`（时间、标签、原因）。
- 发布避开整点和 02:30 之后的两三分钟：迁移的 DDL 会排在正在跑的 `pg_dump` 后面，排队期间那张表的读写都要等。
- 发布成功后会装上 `backup.sh` 和 `yuanhui-backup.{service,timer}` 并 `enable --now`；这一步失败退出码 4（发布本身已成功，不回滚）。
- 只改了 Caddyfile：用当前标签再跑一次 `deploy.sh`，会校验后 `caddy reload`。

## 备份与恢复（S10b，§9.4）
**时间表**：`yuanhui-backup.timer`，上海时间 8:00–22:00 每小时一次、02:30 一次（`systemctl list-timers yuanhui-backup.timer` 看下一次）。错过的开机补跑。
**一次备份**（`/opt/yuanhui/backup.sh`，也可手动跑）：`backup` 容器开可重复读事务、`pg_export_snapshot()`、在同一快照里算清单 → Postgres 容器里 `pg_dump -Fc --snapshot=<同一快照>` → `backup` 容器用口令加密（scrypt + AES-256-GCM）→ 传 `backups/<UTC 时间>-<随机>.dump.enc` 和 `.manifest.enc` → 写心跳 `heartbeat/backup.json` → 写 `backup/last-success`。不重叠（`backup/lock.d`，里面记 pid）：上一次还在跑就跳过，退出码 2，打 `alert=backup_skipped` 并记进 `backup/skips.log` 和 `metrics.prom` 的 `last_skip_timestamp_seconds`；持锁进程已不在（`kill -9`、OOM、强制重启）或锁超过 16 分钟（`TimeoutStartSec=900`）算残留，清掉照常跑。拿到锁后先删上一次残留的 `backup/work.*`（明文 dump）。
**清单**：每张表的行数；每家店的流水条数、`value_delta_fen` 合计、`cogs_fen` 合计、商品库存 / 货值 / 最近进价的校验和、每条流水数量 / 金额 / 成本的校验和、本月和上月月报全部数字。和 dump 同一快照，恢复后逐项比对必须全等。**不覆盖**商品名、售价、条码内容、设备和账号（这些表只比行数），它们靠 dump 的 sha256 和 `pg_restore --exit-on-error` 保证，清单不是全量校验。加密格式（scrypt + AES-256-GCM）见 `server/src/backup/crypto.ts` 开头（§14 S10b-1）。
**保留**：`yuanhui-backup` 桶开了 OSS 合规保留（WORM）35 天，保留期内任何人（含主账号、服务器上的密钥）都删不掉、覆盖不了 `backups/` 里的对象；35 天后由 OSS 生命周期删除（`cloud-manual-steps.md` 第 3 步，生命周期天数不能早于保留期）。备份键各不相同（UTC 时间 + 随机），从不覆盖同名对象；心跳要覆盖，放在存档桶 `yuanhui-archive`。每次备份顺带列一遍 `backups/`，最旧的一份超过 38 天打 `alert=backup_lifecycle_stale`（生命周期没生效；阈值是 35 天保留 + 生命周期一天一轮、不准点的余量 3 天，PR #27 Fable：36 天在合规保留下会误报）。
**可观测**（S10c 接告警）：
- `journalctl -u yuanhui-backup`：每次一行 JSON，`event=backup_ok`（`backup_id`、`dump_bytes`、`duration_s`），或 `event=backup_failed`、`alert=backup_failed`、`stage=prepare|snapshot|dump|upload`；
- `/opt/yuanhui/backup/status.json`、`metrics.prom`（`yuanhui_backup_last_success_timestamp_seconds`、`_last_attempt_timestamp_seconds`、`_last_ok`、`_consecutive_failures`、`_duration_seconds`、`_dump_bytes`）；
- OSS 上的心跳对象 `yuanhui-archive` 桶的 `heartbeat/backup.json`（`at`、`backup_id`）：§9.5 的「营业时间内超过 2 小时没更新」看它。
- 手动看桶：`docker compose -f /opt/yuanhui/compose.yml --project-directory /opt/yuanhui --env-file /opt/yuanhui/.env run --rm -T backup node scripts/backup.ts status`。

### 恢复（演练和整机重建都用这一套）
只需要：这个仓库（`cd server && npm ci`）、`pg_restore` 16 或更新、部署账号的 AccessKey、加密口令（见下面「口令保管」）。不需要 ECS。整机重建见下一节。
1. 建一个**空库**做目标（本机 `createdb yh_restore`）。脚本只写空库或「恢复中」的库，在用的库不会被覆盖。
2. 环境变量：
   ```sh
   export DATABASE_URL=postgres://<用户>:<口令>@127.0.0.1:5432/yh_restore   # 口令经 PGPASSWORD 给 pg_restore，不进命令行
   export BACKUP_PASSPHRASE="$(security find-generic-password -s yuanhui-backup-passphrase -w)"
   # BACKUP_OSS_ARCHIVE_BUCKET 必填：deletions/ 在存档桶，不设 restore.sh 拒绝（退出码 2），否则已注销的店会被恢复回来（PR #27 Fable S10r-8）
   export BACKUP_OSS_REGION=oss-cn-shanghai BACKUP_OSS_BUCKET=yuanhui-backup BACKUP_OSS_ARCHIVE_BUCKET=yuanhui-archive BACKUP_OSS_ENDPOINT=https://oss-cn-shanghai.aliyuncs.com
   export BACKUP_OSS_ACCESS_KEY_ID="$(security find-generic-password -s tomo-credential-broker -a aliyun-huang-ak-id -w)"
   export BACKUP_OSS_ACCESS_KEY_SECRET="$(security find-generic-password -s tomo-credential-broker -a aliyun-huang-ak-secret -w)"
   ```
3. `deploy/restore.sh latest`（或指定 `<备份 id>`）：dry-run，下载、解密、核对 sha256、`pg_restore --list`、检查目标库、列出删除记录，单独一行 `restore_will_delete` 列出恢复时会被删掉的店（元辉店不许在里面），目标库不写。
4. `deploy/restore.sh latest --execute`：清空目标库、打「恢复中」标记 → `pg_restore` → 按清单逐项比对（不一致就停，不换 epoch）→ 重放 `deletions/` 里的删除记录（已注销的店整家删掉，旧令牌和重传 401）→ 再比对 → 全部店换新 `epoch`、标记改「已恢复」。最后一行 `restore_ok` 带 `restore_seconds`。
5. 重跑：「恢复中」的库清空重来；「已恢复」的库同一个备份报 `already_restored`、什么都不动，换一个备份拒绝（要新建空库）。已恢复完成、接上 api 记了新账的库不会被清掉（§14 S10b-5）。

### 恢复演练（ECS 上，恢复到另建的库，在用库不动）
`restore.sh` 的整机跑法默认写在用库 `yuanhui`（整机重建用）。演练时设 `RESTORE_DB=<另建的空库>`：node 步骤在 backup 容器里把 `.env` 拼好的 `DATABASE_URL` 只换库名（口令不进命令行，不依赖镜像里脚本的版本），`pg_restore -d <那个库>`。`C` 同下一节。
1. `scp deploy/restore.sh huang-shop:/root/yh-b6/restore.sh`（ECS 上 `/opt/yuanhui/restore.sh` 可能是旧版，没有 `RESTORE_DB`）；`C exec -T postgres createdb -U yuanhui yh_b6_drill`。
2. `RESTORE_DB=yh_b6_drill RESTORE_COMPOSE_DIR=/opt/yuanhui bash /root/yh-b6/restore.sh <备份 id>`：dry-run 的 `restore_target` 必须是 `"state":"empty"`（是 `foreign` 说明连到了在用库，停）；看 `restore_will_delete`。再加 `--execute`。
3. 在恢复库上起一个临时 api（不映射端口、只接 `yuanhui_db` 网络、`OBJECT_STORE=none`）：`DATABASE_URL` 写进一个 600 的 env 文件（`(umask 077; printf 'DATABASE_URL=postgres://yuanhui:%s@postgres:5432/yh_b6_drill\nOBJECT_STORE=none\n' "$(sed -n 's/^POSTGRES_PASSWORD=//p' /opt/yuanhui/.env)" > /root/yh-b6/api.env)`——必须重定向进文件，不要让连接串打到终端或日志；临时 api **只用这个 env 文件，不许 `--env-file /opt/yuanhui/.env`**，否则会带上真实存档桶凭据、往 `deletions/` 写记录），`docker run -d --name yh-b6-api --network yuanhui_db --env-file /root/yh-b6/api.env local/yuanhui/api:$(cat /opt/yuanhui/current-tag)`；用 `docker exec yh-b6-api node …` 打 `http://127.0.0.1:3000` 模拟一台设备。
4. 收尾：`docker rm -f yh-b6-api`、`C exec -T postgres dropdb -U yuanhui --force yh_b6_drill`、删 env 文件和 `/root/yh-b6`。**不要** `clear-marker`（那是整机重建转正用的）。

### 整机重建（新 ECS）
数据库容器不映射端口，所有库操作都在容器里做（`restore.sh` 的 `RESTORE_COMPOSE_DIR` 跑法：node 步骤 `docker compose run backup`，`pg_restore` 用 `docker compose exec postgres`）。**先恢复、后发布**：先发布会跑迁移建出表，恢复会被拒绝。下面 `C` = `docker compose -f /opt/yuanhui/compose.yml --project-directory /opt/yuanhui --env-file /opt/yuanhui/.env`。
1. 新 ECS 按 `cloud-manual-steps.md` 第 1、2、6 步准备好；填 `/opt/yuanhui/.env`，其中密钥和口令从钥匙串取，`API_IMAGE=local/yuanhui/api:<$SHA，即 release-current 指向的 40 位提交号，见下面「取镜像」第 1 步>`，`RECOVERY_MODE=0`；那个提交的镜像 tar 按下面「取镜像」拿到、传上去 `docker load -i`。
   **取镜像**（artifact 只留 3 天，ECS 丢了时多半已过期；PR #27 Codex）：
   1. 取线上版本：`out=$(deploy/release-tag.sh --current); echo "退出码 $?"; read -r SHA R <<< "$out"; echo "SHA=$SHA R=$R"`（从 origin 强制取 `release-current`，输出「<40 位提交号> release-<前 12 位>」）。**退出码不是 0、或 `SHA`、`R` 有一个是空的，就停下，不要往下跑**：脚本失败时只在 stderr 留一句提示，变量是空的，后面的命令会带着空值跑。退出码 1 是取不到（连不上 origin，或还没有带标签的发布），3 表示 `release-current` 和发布标签对不上，人工看。**不要按标签创建时间取最新的**：回滚过的话那是被回滚掉的版本。旧 ECS 还能登上时，再和它的 `/opt/yuanhui/current-tag` 对一下，应是 `$SHA`（或它的前缀）。
   2. artifact 还在就直接下：`gh run list --workflow image.yml --limit 30 --json databaseId,headSha,conclusion | jq -r --arg s "$SHA" '.[] | select(.headSha == $s and .conclusion == "success") | .databaseId' | head -1` 得到 run id，`gh run download <run id> -n yuanhui-images-$SHA -D /tmp/yh-img`。下载失败（过期）走第 3 步。
   3. 按标签重打：`gh workflow run image.yml --ref "$R"`（`workflow_dispatch` 检出标签指向的提交，`github.sha` 就是 `$SHA`，产出 `yuanhui-images-$SHA`）；等几秒，`gh run list --workflow image.yml --event workflow_dispatch --limit 3 --json databaseId,headSha,createdAt` 里挑 `headSha` 是 `$SHA`、刚创建的那一次拿 run id（刚触发时可能还列不到，列不到再等几秒），`gh run watch <run id>`，成功后同第 2 步下载。约 5 分钟。
   4. `cd /tmp/yh-img && shasum -a 256 -c yuanhui-images-$SHA.tar.gz.sha256`。重打的 tar 里 api 镜像是同一个提交构建的；`caddy:2.10.2`、`postgres:16` 是重打当天的同标签镜像（`postgres:16` 小版本可能更新，数据目录兼容；按 digest 固定见 §14 S10r-12）。
   5. `scp /tmp/yh-img/yuanhui-images-$SHA.tar.gz root@<新 IP>:/opt/yuanhui/incoming/`，ECS 上 `docker load -i /opt/yuanhui/incoming/yuanhui-images-$SHA.tar.gz`。
   注：按标签触发要求 `image.yml` 在默认分支上带 `workflow_dispatch`，本 PR 合并后才成立；本 PR 合并前的发布（首次发布 `efd4e05`）没有标签，`release-current` 也没有，合并后第一次发布起才有；在那之前整机恢复按 ECS 的 `current-tag`（ECS 也丢了就是 `efd4e05`）。
2. 本机：`scp deploy/compose.yml deploy/restore.sh root@<新 IP>:/opt/yuanhui/`
3. ECS 上只起 Postgres：`C up -d --wait postgres`
4. 恢复：`RESTORE_COMPOSE_DIR=/opt/yuanhui bash /opt/yuanhui/restore.sh latest`（dry-run，看 `restore_will_delete`）→ 加 `--execute`，最后一行 `restore_ok`。
5. 清掉恢复标记：`C run --rm -T backup node scripts/restore.ts clear-marker`（输出 `"state":"foreign"`，之后任何恢复都拒绝这个库）。
6. 本机发布同一个提交：`IMAGES_TAR=/tmp/yh-img/yuanhui-images-$SHA.tar.gz ECS_HOST=root@<新 IP> deploy/deploy.sh $SHA --execute --skip-backup-gate`（迁移是空操作；备份定时器随之装上；发布标签和 `release-current` 已在且指向它，不重打）。
7. 冒烟：`deploy/smoke.sh`，再 `bash /opt/yuanhui/backup.sh` 出 `backup_ok`。RTO 1 小时指第 1 步到这里。
8. 手机下一次同步拿到 `epoch_mismatch` → 全量拉取 → 重传保留的 op（§4.6）。备份之后才开通的设备重新开通，再开「恢复模式」补交。

### 恢复模式（平时关）
- 开：`.env` 里改 `RECOVERY_MODE=1`，`C up -d api`，`C exec -T api printenv RECOVERY_MODE` 输出 `1`。
- 关（补交完就关）：改回 `RECOVERY_MODE=0`，`C up -d api`，同一条命令输出 `0`。

### 口令保管（§9.1、§14 S10b-10）
备份口令丢了所有备份都解不开，补不回来；部署账号的 AccessKey 丢了可以用阿里云主账号重发。口令留三份，不经过聊天软件、邮件、备忘录：
1. 部署机（这台 Mac）的钥匙串：`security add-generic-password -s yuanhui-backup-passphrase -a yuanhui -w "$(openssl rand -base64 32)"`；写进 ECS 时走管道、不显示：`printf 'BACKUP_PASSPHRASE=%s\n' "$(security find-generic-password -s yuanhui-backup-passphrase -w)" | ssh root@47.117.184.253 'cat >> /opt/yuanhui/.env'`。AccessKey 在钥匙串 `-s tomo-credential-broker -a aliyun-huang-ak-id|aliyun-huang-ak-secret`（部署账号，不另建备份账号）。
2. Haoqiang 的 iPhone「密码」App：他本人在这台 Mac 的终端里 `security find-generic-password -s yuanhui-backup-passphrase -w | pbcopy`，粘贴进「密码」App 新建的「元辉账本 备份口令」（存 iCloud 钥匙串，手机上能打开），然后 `pbcopy < /dev/null`。AccessKey 同样存一项。
3. 纸质一份：只抄口令，放家里。
4. Haoqiang 确认阿里云主账号的登录密码和二次验证在他本人手里（AccessKey 丢了靠它重发）。
5. 换口令时旧口令各处再留 35 天（旧备份还要用它解）。

可选：核对各份是否一致，各算一次口令 sha256 的前 12 位，只比指纹、不报口令：
- ECS：`sed -n 's/^BACKUP_PASSPHRASE=//p' /opt/yuanhui/.env | tr -d '\n' | sha256sum | cut -c1-12`
- Mac：`security find-generic-password -s yuanhui-backup-passphrase -w | tr -d '\n' | shasum -a 256 | cut -c1-12`
- 「密码」App 或纸质：`read -rs P; printf %s "$P" | shasum -a 256 | cut -c1-12; unset P`（粘贴或照纸敲入）

## SSH 连不上（安全组 22 只放部署机出口 IP，PR #27 Fable S10r-9）
家里是住宅宽带，出口 IP 会变。安全组 `sg-uf6jbhnzv9gbczcabcp3` 的 22/tcp 只放一个 `/32`（11/22 起是 `97.126.176.236/32`）。
**怎么认出来**：`ssh root@47.117.184.253` **超时**（`Operation timed out` / `Connection timed out`），不是 `Permission denied`（那是密钥问题，和安全组无关）。先对出口 IP：`curl -s https://ifconfig.me`，和安全组里那条不一样就是这个原因。`https://47.117.184.253/healthz` 照样 200（80、443 对所有来源开放）。
**连带影响**：发布和回滚做不了（`deploy.sh` 走 ssh / scp）；本机探测拉 `outbox.jsonl` 走 ssh，30 分钟后报 `outbox_unreachable`（看到它先查出口 IP）；服务器里的告警照常写进 outbox，只是转不出来。服务本身、备份定时器、证书续期都不受影响。
**用 aliyun CLI 改**（部署账号 `chitu` 有 ECS 完全权限，不用登控制台；只写不做，需要时照着做）。aliyun CLI 有默认配置时会忽略环境变量里的密钥、用另一个账号，所以每条都显式带密钥和地域，先确认账号：
```sh
A=$(security find-generic-password -s tomo-credential-broker -a aliyun-huang-ak-id -w)
S=$(security find-generic-password -s tomo-credential-broker -a aliyun-huang-ak-secret -w)
K=(--access-key-id "$A" --access-key-secret "$S" --region cn-shanghai)
aliyun sts GetCallerIdentity "${K[@]}"            # AccountId 必须是 1776699878997935，不是就停
SG=sg-uf6jbhnzv9gbczcabcp3
aliyun ecs DescribeSecurityGroupAttribute "${K[@]}" --SecurityGroupId $SG --Direction ingress \
  | jq -r '.Permissions.Permission[] | "\(.IpProtocol) \(.PortRange) \(.SourceCidrIp) \(.Policy)"'   # 看现在 22 放的是哪个 /32
NEW=$(curl -s https://ifconfig.me)/32; OLD=<上一步看到的 22 那条的来源>
# 先加新的、确认能连，再删旧的（反过来的话中间一段谁都连不上）
aliyun ecs AuthorizeSecurityGroup "${K[@]}" --SecurityGroupId $SG --IpProtocol tcp --PortRange 22/22 --SourceCidrIp "$NEW" --Policy accept --Description "deploy-mac $(date +%F)"
ssh -o ConnectTimeout=10 root@47.117.184.253 true && \
aliyun ecs RevokeSecurityGroup "${K[@]}" --SecurityGroupId $SG --IpProtocol tcp --PortRange 22/22 --SourceCidrIp "$OLD" --Policy accept
unset A S K
```
- 不要临时改成 `0.0.0.0/0`；改完 `DescribeSecurityGroupAttribute` 再看一遍，22 只剩新的一条 `/32`。改完把新 IP 和时间记进这一节下面。
- **改错的影响**：删错了 80 / 443 那条，手机全部连不上、证书续不了期；把 22 放成 `0.0.0.0/0`，SSH 暴露给全网（只许密钥，但不该放）；先删旧的再加新的，中间一段没人能连上（服务不受影响）。
- **兜底**：部署机或钥匙串都不可用时，Haoqiang 用阿里云主账号登控制台 → ECS → 安全组 → 改 22 那条的来源；连控制台改也不行时用实例的 VNC 远程连接（控制台 → 实例 → 远程连接 → VNC）。
- TestFlight 前照着真做一次演练（S10r-9）：把 22 的来源改成一个假地址、确认 ssh 超时、再用上面的命令改回来，记时间。

## 看日志、看证书
- 容器状态：`docker compose -f /opt/yuanhui/compose.yml --project-directory /opt/yuanhui --env-file /opt/yuanhui/.env ps`
- api 日志：`docker logs --since 1h yuanhui-api-1`；告警字段：`docker logs yuanhui-api-1 2>&1 | grep '"alert"'`
- 不得出现：`docker logs yuanhui-api-1 2>&1 | grep -E 'export_no_archive|purge_no_archive'` 应为空。
- Caddy 访问日志（JSON，看 `request.remote_ip`）：`docker logs --since 10m yuanhui-caddy-1 2>&1 | grep '"http.log.access' | tail`
- 证书签发 / 续期记录：`docker logs yuanhui-caddy-1 2>&1 | grep -E 'certificate obtained|renew|obtain|acme' | tail -20`
- 当前证书的签发方和到期时间（本机）：`echo | openssl s_client -connect 47.117.184.253:443 -servername 47.117.184.253 2>/dev/null | openssl x509 -noout -issuer -dates`
- 不带 SNI 时拿到的证书：同上把 `-servername …` 换成 `-noservername`。
- 证书文件（ECS 上）：`ls -l /data/caddy/data/caddy/certificates/*/`

## 域名站点 api.yuanhuishop.cn（2026-11-26 上线，§9.3）
- 备案：苏ICP备2026094233号，2026-11-26 11:51 CST 管局通过（阿里云订单 2034885592055）。公安联网备案 30 天内要交（约 12/26 前）。
- DNS（黄总阿里云账号 1776699878997935，云解析）：`api.yuanhuishop.cn` A → `47.117.184.253`，TTL 600，RecordId `2125800818518669312`（11/26 11:56 CST 加）。根域名 `yuanhuishop.cn`、`www` **没加**（还没有网站内容）；`tools` 11/21 删掉后没恢复。查：`dig +short @223.5.5.5 api.yuanhuishop.cn`、`dig +short @8.8.8.8 api.yuanhuishop.cn`。
- 反代配置：仓库 `deploy/Caddyfile.ip` 末尾的 `api.yuanhuishop.cn { … import common }` 站点（和 IP 站点共用 `(common)`：只放行 `/v1/*`、`/healthz`，其余 404）。ECS 上是 `/opt/yuanhui/caddy/Caddyfile`（容器里 `/etc/caddy/Caddyfile`，只读挂载）。**IP 站点 `https://47.117.184.253` 保留不动**，已装的 TestFlight 老包还在用它。
- 根域名首页（11/26 12:23 CST 上线，公安联网备案要网站能打开）：DNS `@` A RecordId `2125807243957436416`、`www` A RecordId `2125807249795871744`（都 → 47.117.184.253，TTL 600）。`Caddyfile.ip` 的 `yuanhuishop.cn` 站点只给 `deploy/site/` 里的 `index.html`、`favicon.svg`（其余路径 404，不反代 api，`/v1/*` 在这里 404），`www.yuanhuishop.cn` 301 到根域名。静态页在 ECS `/opt/yuanhui/caddy/site/`（容器 `/etc/caddy/site`）；`deploy.sh` 把 `deploy/site` 带上去、`remote-deploy.sh` 整目录替换，改页面不用重载 Caddy。证书同为 LE 90 天，Caddy 自动续（首张到期 2027-02-24）。公安备案号拿到后，把 `index.html` 底部注释里的那行放出来。加根域名之前的 Caddyfile 备份：`/opt/yuanhui/caddy-backup/Caddyfile.20261126T122324`（只含 api 站点）。
- 阿里云接入备案拦截：备案刚通过、阿里云还没同步时，域名会被拦（HTTPS 连接被重置，HTTP 返回 `Server: Beaver` 的「Non-compliance ICP Filing」403），ECS 本机 `curl --resolve …:127.0.0.1` 正常。11/26 api 域名被拦了约 20 分钟（12:00–12:20 CST）后自己恢复；以后新加域名遇到同样现象先等，别改配置。
- 发布时 `deploy.sh` 会用部署机那份 `deploy/Caddyfile.ip` 覆盖 ECS 上的：**从不含这个站点的旧分支部署，域名站点会被删掉**（症状：`https://api.yuanhuishop.cn` 握手失败或拿到错的证书）。补救：从 main 重新部署，或照下面「手工改」那几步再装一次。
- 证书：Let's Encrypt 正常证书（不是 IP 那种 shortlived），HTTP-01，Caddy 自己签、自己续，状态在宿主 `/data/caddy/data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/api.yuanhuishop.cn/`。首张 11/26 02:59 UTC 签发，到期 **2027-02-24 02:59 UTC**，链 `api.yuanhuishop.cn` ← YE1 ← Root YE ← ISRG Root X2 ← ISRG Root X1（`openssl s_client` 验证 0）。Caddy 在剩余约 1/3 有效期时自动续，不需要定时任务；续期要 80/tcp 对公网开（安全组 `sg-uf6jbhnzv9gbczcabcp3` 和 ufw 都已放行 80、443）。
- 看证书：`echo | openssl s_client -connect api.yuanhuishop.cn:443 -servername api.yuanhuishop.cn 2>/dev/null | openssl x509 -noout -issuer -dates`；续期记录同上 `docker logs yuanhui-caddy-1 2>&1 | grep -E 'certificate obtained|renew' | grep api.yuanhuishop`。
- 验证：`curl -sS https://api.yuanhuishop.cn/healthz` → 200 `{"ok":true}`；`curl -sI http://api.yuanhuishop.cn/healthz` → 308 到 https（Caddy 对域名站点自动跳转）；`https://47.117.184.253/healthz` 仍 200。
- 手工改（不发布 api，只换 Caddyfile；11/26 就是这么上的）：
  1. 备份：`ssh huang-shop 'mkdir -p -m 700 /opt/yuanhui/caddy-backup && cp -p /opt/yuanhui/caddy/Caddyfile /opt/yuanhui/caddy-backup/Caddyfile.$(date +%Y%m%dT%H%M%S)'`（11/26 的备份：`/opt/yuanhui/caddy-backup/Caddyfile.20261126T115744`，就是加域名之前那份）。
  2. 传新文件到 `/tmp/Caddyfile.new`，用同一个镜像校验：`cd /opt/yuanhui && set -a && . ./.env && set +a && docker run --rm -e PUBLIC_IP -e ACME_EMAIL -v /tmp/Caddyfile.new:/etc/caddy/Caddyfile:ro "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile`。
  3. `install -m 600 /tmp/Caddyfile.new /opt/yuanhui/caddy/Caddyfile && docker exec yuanhui-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`（**reload，不要 restart**；api 不动）。
- 回滚（去掉域名站点，IP 站点不受影响；只撤根域名首页时换回 `Caddyfile.20261126T122324`，api 不受影响）。**顺序不能反**：从这个 PR 起，Beta 新包和 Release 包都默认连域名；手机只有在域名还能连上时取到 `/v1/config` 的 `api_base`，才会改用 IP，App 自己不会去试 IP。
  1. 先看有没有装着「默认连域名」的包的手机：没出过这种包（TestFlight 上全是 IP 默认的老包）→ 直接第 3 步。出过 → 第 2 步。
  2. 域名还能连的时候，先在 ECS `.env` 配 `API_BASE=https://47.117.184.253` 并重启 api（会中断几秒，要和负责人确认），等所有 Beta 手机至少打开一次 App（取到新 `api_base`；api 日志里它们的请求 host 变成 IP）。Release 包白名单里没有 IP，这一步对它无效：有 Release 包在用就**不要撤域名站点**，只修域名。
  3. 换回备份并校验、重载：`cp -p /opt/yuanhui/caddy-backup/Caddyfile.20261126T115744 /tmp/Caddyfile.new`，按上面「手工改」第 2 步 `caddy validate`，通过后 `install -m 600 /tmp/Caddyfile.new /opt/yuanhui/caddy/Caddyfile && docker exec yuanhui-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile`。
  4. 仓库里同时 revert `deploy/Caddyfile.ip` 的改动，否则下次发布又加回来。要连解析一起撤：黄总账号 `alidns DeleteDomainRecord --RecordId 2125800818518669312`（用 `projects/huang_shop/ops/ali.sh`，显式传 key）。
  - 已经失联的手机（域名连不上、又没取到 IP）：只能恢复域名，或装新包。
- App：从「App 改用 https://api.yuanhuishop.cn」这个 PR 起 Beta 包默认连域名（Release 本来就是）。没有 ATS 例外、没有证书 pin。已装的老 Beta 包默认还是 IP，要等服务器配 `API_BASE=https://api.yuanhuishop.cn`（`/v1/config` 下发 `api_base`）或装新包才切。

### 发布防护（11/26 事故后加）

11/26 12:33 发布 #52 时，`deploy.sh` 用了 main 上只有 IP 站点的 `Caddyfile.ip`，把手工装上的 api.yuanhuishop.cn / yuanhuishop.cn 覆盖掉，两个域名 TLS 握手失败约 1.5 小时（从 `prev/caddy_Caddyfile` 恢复）。现在：
- 线上站点配置只以仓库里的 `deploy/Caddyfile.ip` 为准，**不要再在 ECS 上手改 Caddyfile**；要改就提 PR 再发布。
- `deploy.sh` 在连服务器之前检查：`Caddyfile.ip` 里必须有 `api.yuanhuishop.cn`、`yuanhuishop.cn`、`www.yuanhuishop.cn` 三个站点，`deploy/site/index.html` 必须存在，否则退出 2、什么都不动（`deploy/test/deploy.test.sh` 有用例）。
- 发布后验 4 个地址：`https://yuanhuishop.cn`（200）、`https://www.yuanhuishop.cn`（301）、`https://api.yuanhuishop.cn/healthz`（200）、`http://yuanhuishop.cn`（308 到 https）。

## 证书策略（§14 S10a-3，PR #22 Fable 裁定 ①）
- 方案 A（Let's Encrypt IP 短期证书）续期不稳时**不直接换私有 CA**。备案前服务器上只有假数据，App 离线可用，证书断几天不是紧急事件。
- 「不稳」要有数字：部署后**观察 14 天**，期间出现过证书剩余有效期低于 48 小时、或过期，才算不稳；一两次续期重试不算。每次续期成功 / 失败的记录和剩余有效期告警由本机探测做（S10c，§14 T19，见「监控与告警」：`cert-renewals.jsonl`、`ip_cert_expiry`）；探测装上之前每天按上面的命令看一次并记下来。
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

## 部署实测进度（2026-11-22，S10 部署实测 PR #27）
- 负责人 11/22 04:19 决定：不建 RAM 子账号（**按负责人决定，服务器使用部署账号密钥，不使用专用子账号**）；备份桶开合规保留 35 天作补偿；不用 ACR（镜像 tar）；不开云盘快照；`ACME_EMAIL=clawchitu@gmail.com`；告警 webhook 暂留空；只用 IP、只放假数据、不加域名解析。
- 之前「403 / 没权限」是误判：aliyun CLI 有默认配置时忽略 `ALIBABA_CLOUD_ACCESS_KEY_*` 环境变量、用了另一个账号。每条命令显式带 `--access-key-id/--access-key-secret/--region` 后，`sts GetCallerIdentity` 的 AccountId 为 1776699878997935（RAM 用户 `chitu`），OSS、ECS 正常。
- 11/22 04:24 建桶：`yuanhui-backup`（私有、LRS、版本控制未开、生命周期 `backups/` 35 天 + 碎片 7 天、合规保留 35 天，04:34 验证备份写入后**已锁定**，WormId 8CAC3FA9…）、`yuanhui-archive`（私有、版本控制未开、生命周期 `exports/` 30 天 + 碎片 7 天）。`yuanhui-img` 没建（只批了两个桶，T9 前不开商品图）。
- 11/22 04:2x 安全组 `sg-uf6jbhnzv9gbczcabcp3`：删掉 22/tcp 和 ICMP 对 `0.0.0.0/0` 的规则，22 只放部署机出口 `97.126.176.236/32`；80、443/tcp 对 `0.0.0.0/0`；没有 3000、5432、443/udp。
- 11/22 04:26–04:31 首次发布 `efd4e05`（`IMAGES_TAR`，tar 309 MB，scp + load + 发布共 5 分 29 秒，`--skip-backup-gate`）：迁移 0001、0002，三容器起来，Caddy 拿到 Let's Encrypt IP 证书，备份定时器装上。
- 代码改动（本 PR）：`image.yml` 打镜像 tar；`deploy.sh` / `remote-deploy.sh` 支持 `IMAGES_TAR` / `--load-images`，本机已有镜像时不 `docker pull`；备份存储 `BACKUP_OSS_ARCHIVE_BUCKET`（心跳、`deletions/` 不进合规保留桶）。
- 11/22 07:14–07:20（上海）发布 main `65899e0`（S10 真机部署与验证 #27 合并后的 main，含迁移 0003）：先手动 `backup.sh` 出 `backup_ok`，再 `IMAGES_TAR=… ECS_HOST=huang-shop deploy/deploy.sh 65899e0c4bee8189cd356c3fec959b32f363b30b --execute`，退出码 0，共 5 分 7 秒（tar 309 MB，push 触发的 `image.yml` run 44960528538）。`执行了：0003_store_purges_backoff.sql`；缩图冒烟四种格式正常；发布标签 `release-65899e0c4bee`，`release-current` → `65899e0`；`deploy/release-tag.sh --current` 输出 `65899e0c… release-65899e0c4bee`，和 ECS `current-tag` 一致；`https://47.117.184.253/healthz` 200、`smoke.sh` 通过。
  - 注：这台 Mac 上 `ssh root@47.117.184.253` 是 `Permission denied (publickey)`（部署密钥是 `~/.ssh/huang_shop`，只在 `~/.ssh/config` 的 `Host huang-shop` 里配了 `IdentityFile`），所以 `ECS_HOST` 用 `huang-shop`（`check_host` 接受主机别名）。本手册里写 `ECS_HOST=root@47.117.184.253` 的地方，在这台 Mac 上一律换成 `ECS_HOST=huang-shop`。
- 11/22 07:2x（上海）线上建测试店（假数据，§14 S10a-4）：**`联调测试店甲`**（账号 `yh_test_a`，店 id `2510edd4-d332-42f9-aeb6-cc4a9b7c6a05`，**保留，供 S22a 联调**）、`注销演练店乙`（`yh_test_b`，`fb9c0b6e-…`，B6 用，已清除）。口令在这台 Mac 的钥匙串 `-s yuanhui-test-store -a yh_test_a`（不进仓库）。甲店里有 2 个商品、2 笔进货、5 笔卖出（10 行）。线上目前只有甲店；演示店、审核号还没建。
- **遗留**：① 商品图桶 `yuanhui-img` 不存在：注销清除（申请后 7 天）会按前缀扫 `images/<店>/`，桶不存在这一步报错，这家店的对象清理一直记不成「清完」。返修后（PR #27 Fable S10r-11）存档桶的 `exports/<店>/`、本机缓存照样删，不受影响；代码不跳过不存在的桶（配错桶名时不能记成清完），连续失败第 3 次起打 `alert=purge_objects_failed` 并退避（1、2、4……最长 24 小时一次）。**要建 `yuanhui-img` 空桶**（私有、不开版本控制、不配合规保留、不配生命周期，空桶不计费；第三个桶，**待负责人同意**，`cloud-manual-steps.md` 第 3 步，S10r-7），TestFlight 前、M10 之前建好。② 告警通道待配置（webhook 留空），本机探测没装。③ 家里出口 IP 变了要改安全组 22 那条（下面「SSH 连不上」）。④ B6 清除的 `注销演练店乙` 在 `store_purges` 里对象清理一直 `NoSuchBucket`（就是 ①：`yuanhui-img` 不存在；它的 `exports/` 导出包已删掉，`deletions/` 记录已写），第 3 次起会打 `alert=purge_objects_failed`、按退避重试，这是预期的，建了 `yuanhui-img` 后下一轮自己清完。⑤ `yuanhui-archive` 的 `exports/eb7f1094-…/1795293687128-….zip`（3 MiB，11/22 04:41，不是 B6 产生的）还在，30 天生命周期会删。

## 部署时验证（数字写回这里和部署实测 PR；本 PR 合并不等于 S10a 通过，§14 S10a-9）
剩余条件和 TestFlight 前门槛见计划 §14 的 S10r-1 至 S10r-12（S10r-3 的 B6 已在 11/22 做完，见 B6 行）（PR #27 Fable 审核原文）：S10a、S10b、S10c 都还不算通过，每补一批开一个只改 runbook 的小 PR。

| # | 项 | 方法 | 结果 |
|---|---|---|---|
| 1 | 自动回滚 | 用一个故意坏掉的镜像（如 `/healthz` 永远 503 的分支构建）跑 `deploy.sh --execute`：退出码 1、`current-tag` 不变、api 回到上一个镜像、`smoke.sh` 通过 | **通过**（11/22 04:35）：本机用 `efd4e05` 镜像在 ECS 上构建一个 `/healthz` 永远 503 的镜像 `api:dead…b1`，`ACR=local/yuanhui deploy.sh dead…b1 --execute`：退出码 1，「已回滚到 efd4e05（current-tag 仍是 efd4e05）」，`.env` 和正在跑的容器都是 `local/yuanhui/api:efd4e05…`，`smoke.sh` 通过 |
| 2 | 端口 | 公网连不上 3000 **和 5432**（`smoke.sh` 两个都查）；`nmap -Pn -p 22,80,443,3000,5432,3389 47.117.184.253` 从家外网络跑一次 | 部分：安全组（API 读出）入方向只有 22（`97.126.176.236/32`）、80、443/tcp；`smoke.sh` 3000、5432 公网不可达；本机 `nc` 22 通。家外网络 `nmap` 一次待做（部署机本身在境外家庭网络，算一次「外网」，但没跑 nmap） |
| 3 | 客户端 IP | `SMOKE_XFF=1 deploy/smoke.sh`（伪造 XFF 换不出额度）；**另外** Caddy 访问日志里的 `remote_ip` 等于测试机的公网出口 IP（不是 `172.30.0.1` 之类的网关）；换一个出口（手机蜂窝）登录不受前一个 IP 限速影响 | 部分：`SMOKE_XFF=1 smoke.sh` 第 31 次 429（伪造 XFF 换不出额度）；Caddy 访问日志 `remote_ip` 69 条是部署机公网出口 `97.126.176.236`（另有几条境外扫描器 IP、1 条 `172.30.0.128` 是我在 ECS 本机 curl 的），不是网关地址。换手机蜂窝出口那一步没做（要人拿手机） |
| 4 | 无 SNI | `openssl s_client -connect 47.117.184.253:443 -noservername` 拿到的是公网签发的 IP 证书 | **通过**：`-noservername` 拿到 `issuer=Let's Encrypt, CN=YE1`、SAN `IP Address:47.117.184.253` |
| 5 | 证书 | 境外和本机各一次 `curl`（不加 `-k`），记签发方、有效期；观察到一次自动续期，记续期前后的到期时间；14 天观察记录（见证书策略） | 部分：本机（境外家庭网络）`curl` 不加 `-k` 成功，Let's Encrypt YE1，11/21 19:33 → 11/28 11:33 UTC（约 160 小时）。境内一次、自动续期、14 天观察待做（探测没装，见 M 节） |
| 6 | 存档桶 | 日志里没有 `export_no_archive`、`purge_no_archive` | **通过**（截至 04:50）：`docker logs yuanhui-api-1 | grep -cE 'export_no_archive|purge_no_archive'` = 0 |
| 7 | RAM 负测 | 用 api 的凭据写 `images/` 以外的前缀、读写 `backups/`、删 `deletions/`，都 403（`cloud-manual-steps.md` 第 4 步，T9 ⑤） | 不适用：按负责人决定，服务器使用部署账号密钥，不使用专用子账号，没有可负测的最小权限。代替的保护：备份桶合规保留，用这把密钥删 / 覆盖 `backups/` 对象都返回 `409 FileImmutable`（见 B3） |
| 8 | 镜像链路 | CI 推 ACR 成功一次，记耗时；ECS 从 VPC 地址拉取成功 | **通过**（改为 tar 链路）：`image.yml` 在 PR 上（`deploy-tar` 标签）产出 artifact，tar 309 MB；`gh run download` + `shasum -c` OK；scp + `docker load` + 发布 5 分 29 秒；ECS 没连 Docker Hub、没用 ACR |
| 9 | T4 / T2-2、T7 | 30 个登录同时到：最慢一个响应时间、期间 `/healthz` 和一次 `/v1/sync` 耗时、0 个 500；单次 argon2 耗时。约 40 万行流水下月报和 `/v1/entries/days` 耗时，07c > 200 ms 要改 | 未做：要一家测试店和 30 个账号 / 约 40 万行流水的造数脚本，这一轮没做到 |
| 10 | T10 | 512 MB api 里 3 个并发登录 + 缩 5000×5000 隔行 16 位 PNG：不被 OOM 杀；记 cgroup `memory.peak`（`docker exec yuanhui-api-1 cat /sys/fs/cgroup/memory.peak`）写在这里 | 部分：api 容器里造一张 5000×5000 隔行 16 位 PNG（129 MB）并缩到 200 px，2.0 秒，`memory.peak` 417 MB（512 MB 上限内），`OOMKilled=false`、重启 0 次。没有同时 3 个登录（同第 9 项，缺测试店）；造图本身也占内存，比真实上传更重 |
| 11 | T13 / T17 | 真实 OSS 上列举、删除、`putFile` 分片、`listUploads` / `abortUpload` 各一次 | **通过**：api 容器里用 `AliOssObjectStore` 对 `yuanhui-archive` 的 `exports/<随机店>/`：`putFile` 3 MiB（分片）628 ms、`list` 1 个、`get` 3145851 字节、手工开一个分片上传后 `listUploads` 看到它、`abortUpload` 后 0 个、`delete` 后 `list` 0 个 |
| 12 | T9 ①–⑥ | ① 20 个真实条码命中率 / 有图率；② 真实录制件替换手写夹具、定判别字段；③ 条款原文摘进 `docs/image-rights.md`；④ 计费是预付次数包、用完即停；⑤ 真实 OSS 往返、RAM 只能读写 `images/`；⑥ 条码格式过滤做不做 | 未做：需要快鸟 AppCode 和真实条码（T9 未开始）；⑤ 的「RAM 只能读写 `images/`」按负责人决定不适用 |
| 13 | 重启 | `reboot` 后三个容器自己起来（`restart: unless-stopped`），`swapon --show` 仍有 `/swapfile`，`smoke.sh` 通过 | **通过**（04:45 `systemctl reboot`）：三个容器自己起来（api、postgres healthy），`swapon` 有 `/swapfile` 4G，`yuanhui-backup.timer` 仍 `enabled`、下一次 08:00，`smoke.sh` 通过 |

### S10b 部署时验证（真机器上才能做，数字写回这里和部署实测 PR；B1–B6、B8–B11 没做完 S10b 不算通过，§14 S10b-11）
原 B7（真手机换 epoch 后补回）和第 36 天的生命周期检查不在这里等，记在 §14 待办 T23、T24。
| # | 项 | 方法 | 结果 |
|---|---|---|---|
| B1 | 定时器在 ECS 上按时跑 | `systemctl list-timers yuanhui-backup.timer` 的下一次时间对得上（上海 8:00–22:00 整点、02:30）；跑过一个营业日后 `journalctl -u yuanhui-backup --since today` 里 15 次 `backup_ok`，桶里 `backups/` 多 15 对对象；ECS `reboot` 之后定时器仍是 `enabled`，下一次按时跑 | 部分：`list-timers` 下一次 08:00 CST（对）；重启后仍 `enabled`。跑满一个营业日 15 次 `backup_ok` 要等到 11/22 22:00 以后 |
| B2 | 跨容器快照 | 第一次 `bash /opt/yuanhui/backup.sh` 成功（`pg_dump --snapshot` 在 Postgres 容器里导入 backup 容器导出的快照）；记 `duration_s`、`dump_bytes` | **通过**：第一次 `bash /opt/yuanhui/backup.sh`：`backup_ok`、`duration_s` 7、`dump_bytes` 53057（空库只有迁移） |
| B3 | 真实 OSS 读写 | 备份账号：`backups/` 分片上传（`putFile`）、读、列举，`deletions/` 列举、读，心跳读写各成功一次；`cloud-manual-steps.md` 第 4 步的负测全部 403。`PutObject` 能覆盖已有对象是已知并接受的（§14 S10b-9），不算负测失败 | **通过**（按新布局）：`backups/` 写入（dump、清单）、读（B6 恢复下载）、列举（`backup_status`），心跳写进 `yuanhui-archive`、读（`status`），`deletions/` 列举（B6，0 条）。负测改为合规保留：用部署账号删 `backups/…manifest.enc`、覆盖同名对象都 `409 FileImmutable`。RAM 负测按负责人决定不适用 |
| B4 | 生命周期、版本控制 | `ossutil lifecycle --method get` 的输出贴进 PR：`backups/` 35 天、`exports/` 30 天、`deletions/` 无；两个桶「版本控制」未开通；第 36 天的检查见 §14 T24 | **通过**：`lifecycle --method get`：`yuanhui-backup` `backups/` 35 天、碎片 7 天；`yuanhui-archive` `exports/` 30 天、碎片 7 天，`deletions/`、`heartbeat/` 无；两桶 `bucket-versioning` 为 null（未开通）；`worm get`：`Locked`、35 天。第 36 天检查见 T24 |
| B5 | 口令三份 | 按「口令保管」：Mac 钥匙串有 `yuanhui-backup-passphrase`、`yuanhui-backup-oss`；Haoqiang 确认 iPhone「密码」App 里有两项、纸质一份已放好、主账号登录和二次验证在他手里（不贴值）。可选附三处 12 位指纹 | 部分：Mac 钥匙串有 `yuanhui-backup-passphrase`（未重新生成），ECS `.env` 有，两处指纹 11/22 00:05 已核一致；AccessKey 用部署账号那把（钥匙串 `tomo-credential-broker`）。iPhone「密码」App、纸质一份、主账号二次验证等 Haoqiang 确认 |
| B6 | 异机恢复演练 | 在 Mac 上只凭 OSS 和钥匙串按上面「恢复」做一遍：`restore_ok`、清单逐项一致、注销的店不在；再在恢复出来的库上起一个本机 api：`/healthz` 200、用新 epoch 同步一次 200；记 `restore_seconds` 和从开始到这一步的总时长（RTO 目标 1 小时以内，含下载） | **通过（带数据，ECS 上恢复到新库，11/22 07:26 上海）**：线上建甲（2 商品、2 进货、5 卖出）、乙（2 商品、2 进货、2 卖出）两家测试店，各登录一台模拟设备 → `backup.sh` 出 `20261121T232506Z-abab9da600b355d4`（`dump_bytes` 58673，`duration_s` 8）→ 乙店 `/v1/account/delete-request`，把它的 `delete_requested_at` 往前拨 8 天、重启 api 触发到期清除：`注销到期：在线数据已清除`，`yuanhui-archive` 有 `deletions/fb9c0b6e-….json` → ECS 上 `createdb yh_b6_drill`，`RESTORE_DB=yh_b6_drill RESTORE_COMPOSE_DIR=/opt/yuanhui restore.sh <该备份>`：dry-run `restore_target` `empty`、`restore_will_delete [乙]`；`--execute` 清单比对两次都过、`replayed [乙]`、`epochs_rotated 1`、`restore_ok`，`restore_seconds` 11。另行核对：甲店流水 12 行、`entries`/`products` 整行 md5 与在用库一致，epoch 已换（`95fcb77b…` → `f54b953a…`）；乙店的店、账号、设备在新库里都是 0 行；新库标记 `yuanhui-restored <备份 id>`，在用库没有标记、甲店 epoch 未变。新库上起临时 api（`yuanhui_db` 网络、不映射端口）：`/healthz` 200；甲店旧令牌 + 旧 epoch 同步 → 409 `epoch_mismatch` 带新 epoch；新 epoch → 200，再推 2 商品 + 2 进货 + 2 卖出 6 个 op 全部 `applied`；乙店旧令牌 → 401 `unauthorized`，乙店账号密码登录 → 401。从 dry-run 开始到同步完约 1.5 分钟（含 OSS 下载）。演练完删掉临时 api 和 `yh_b6_drill`。（原表述是 Mac 上本机库；ECS 上恢复用的是同一套脚本和 OSS 对象，`restore.sh` 加了 `RESTORE_DB`，见「恢复演练（ECS 上）」。Mac 上空库那一遍见 PR #27：`restore_seconds` 2） |
| B8 | 迁移前门禁 | 营业时间内停掉定时器超过 2 小时后发布 → 退出码 5；`--skip-backup-gate` 能发布且 `gate-skips.log` 有记录；恢复定时器 | **部分**：挪走 `last-success` 后发布 → 退出码 5、「没有任何成功的备份记录，拒绝在迁移前发布」；`--skip-backup-gate` 退出码 0，`gate-skips.log` 记一行；放回。「营业时间停定时器 2 小时」那个条件没在真机上等（测试里有） |
| B9 | 失败信号 | 临时把 `.env` 的 `BACKUP_OSS_ACCESS_KEY_SECRET` 改错跑一次：`backup_failed stage=upload`、`metrics.prom` 的 `last_ok 0`、`consecutive_failures` 加 1、心跳不变；改回后下一次清零 | **通过**：`.env` 的 `BACKUP_OSS_ACCESS_KEY_SECRET` 改错跑两次：`backup_failed stage=upload`，`metrics.prom` `last_ok 0`、`consecutive_failures 2`；改回后 `backup_ok`，`last_ok 1`、`consecutive_failures 0` |
| B10 | 资源影响 | S10a 压测的 3 年数据量下，压测进行中手动跑 3 次 `backup.sh`：记 `duration_s`、`backup` 容器内存峰值（cgroup `memory.peak`）、备份期间 `/v1/sync` 的 p95 和不备份时的对比、`free -m` 最低值；没有容器被 OOM 杀 | 未做：依赖第 9 项的 3 年数据量压测 |
| B11 | 云盘自动快照（§9.4） | 负责人 11/22 决定不开（备份靠合规保留的 OSS 备份） | 负责人决定不开 |

## 监控与告警（S10c，§9.5）

所有告警发给 **Chitu**，由 Chitu 转告 Haoqiang 或黄总，不直接发给黄总。两条腿：

- **服务器里的检查任务**（api 进程内，`server/src/monitor/`，每分钟一轮）：从 api 自己的日志里取带 `alert` 字段的行、数 5xx，查库、读 `/opt/yuanhui/backup/`（只读挂成 `/backup`）。告警追加到 ECS 的 `/data/monitor/outbox.jsonl`；配了 `ALERT_WEBHOOK_URL` 再直接推一份。去重状态在 `/data/monitor/state.json`，重启不会重发正在告警的、也不会漏发恢复。
- **本机探测**（这台 Mac，launchd 每 10 分钟，`deploy/probe/run-probe.sh` → `server/scripts/probe.ts`）：探 `/healthz`、读 IP 证书、用部署 ssh 拉 `outbox.jsonl` 的新行，经 `PROBE_NOTIFY_CMD` / `PROBE_WEBHOOK_URL` 发给 Chitu。api 挂了服务器那条腿也就停了，所以存活和证书放在本机。
- **阿里云云监控**（手工配，见下）：CPU、内存、磁盘 > 80%，站点监控做存活的第二来源。

去重规则（两条腿相同，`alerter.ts`）：条件类（「现在是不是坏的」）好→坏发一条，一直坏每 6 小时提醒一次，坏→好发「已恢复」；事件类（日志里的告警、门禁被跳过、恢复失败……）同一个键 30 分钟内只发第一条，之后的一条带「另有 N 次」。通道发不出去时下一轮重试，事件最多攒 100 条。告警正文只留白名单字段，像凭据的长串换成「[已隐去]」（`alert.ts`），本机转发前再洗一遍。

| §9.5 的项 | 告警键 | 哪条腿 | 阈值 |
|---|---|---|---|
| 服务存活 | `healthz_down` | 本机 + 云监控站点监控 | 连续 2 次（20 分钟）失败 |
| CPU、内存、磁盘 | 云监控规则；`disk_usage` | 云监控 + 服务器 | > 80% |
| 证书（T19） | `ip_cert_expiry` | 本机 | 剩余 < 48 小时或链不受信任；续期记进 `cert-renewals.jsonl` |
| 备份心跳、失败（T26） | `backup_heartbeat_stale`、`backup_failed`、`backup_consecutive_failures`、`backup_lifecycle_stale`、`backup_skipped`、`backup_gate_skipped`、`restore_failed` | 服务器 | 营业时间 2 小时（从 8:00 起算，不在 8:00 切换时误报）/ 任何时候 6 小时；连续失败 ≥ 2 升严重 |
| 营业时间没有同步 | `no_sync:<店>` | 服务器 | 8:00–21:00 超过 3 小时；真同步过才发「已恢复」（打烊不算恢复） |
| 接口错误率 | `http_5xx_rate` | 服务器 | 一小时 > 20 次 |
| 快鸟额度（S08-3 条件二） | `kuainiao_store_daily:<店>`、`kuainiao_quota` | 服务器 | 单店当天 ≥ 700 次；网关报额度用完 / 限流 |
| 登录异常 | `login_locked:<店>` | 服务器 | 刚锁上那一次 |
| 账号注销申请 | `account_delete_request:<店>`、`account_delete_export:<店>` | 服务器 | 申请时一条；导出包生成后再一条（带对象键） |
| 被退出的手机有待确认的账 | `held_ops:<店>` | 服务器 | > 24 小时 |
| T16 导出和清除 | `account_delete_export_failed`、`export_no_archive`、`purge_no_archive`、`object_discard_failed`、`export_discard_lost` | 服务器 | 出现即发 |
| T3 | `ops_table_size`、`ops_table_growth` | 服务器 | ops 表 > 512 MB；24 小时增长 > 64 MB。出现异常增长再提裁定 |
| 监控自己 | `outbox_unreachable`（本机连续 30 分钟拉不到）、`monitor_check_error:<段>`（服务器检查某一段出错，其余段照跑）、`alert_queue_overflow`、`log_alerts_dropped`、`monitor_state_unwritable` | 两边 | |

### 装本机探测（这台 Mac）
1. `mkdir -p ~/.config/yuanhui-probe && cp deploy/probe/probe.env.example ~/.config/yuanhui-probe/env && chmod 600 ~/.config/yuanhui-probe/env`，填 `PROBE_URL=https://47.117.184.253`、`PROBE_SSH_TARGET`（部署用的 ssh 目标）、至少一个通道。令牌只放这个文件。
2. 先手动跑一次：`deploy/probe/run-probe.sh --test-alert`，Chitu 应收到「告警通道测试」。
3. `sed -e "s#__REPO__#$PWD#" -e "s#__HOME__#$HOME#" -e "s#__NODE_DIR__#$(dirname "$(command -v node)")#" deploy/probe/cn.yuanhuishop.probe.plist > ~/Library/LaunchAgents/cn.yuanhuishop.probe.plist`，`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/cn.yuanhuishop.probe.plist`；看日志 `~/Library/Logs/yuanhui-probe.log`。停用：`launchctl bootout gui/$(id -u)/cn.yuanhuishop.probe`。
4. 状态在 `~/Library/Application Support/yuanhui-probe/`：`state.json`（去重、outbox 游标）、`cert-renewals.jsonl`（每次看到新证书 `renewed`、该续没续 `renewal_overdue`，14 天观察就看它）。

### 云监控（手工，阿里云控制台；免费额度内）
- 主机监控：给 ECS 装云监控插件；报警规则 CPU 使用率、内存使用率、磁盘使用率（`/`，有数据盘再加一条）各一条：平均值 > 80%，连续 3 个周期（每周期 5 分钟）报警，恢复也通知；报警联系人只建 Chitu 一人。
- 站点监控：HTTPS 探 `https://47.117.184.253/healthz`，期望状态码 200，频率 5 分钟，选 3 个以上境内探测点，连续 2 次失败报警，联系人 Chitu。
- 配好后截图贴进部署实测 PR。

### 平时怎么看
- 服务器上还没转出去的：`tail /data/monitor/outbox.jsonl`；状态：`cat /data/monitor/state.json`。
- 关掉服务器监控（不建议）：去掉 compose 里的 `MONITOR_DIR`，api 启动时会打一条警告。

### S10c 部署时验证（真机器上才能做，数字写回这里和部署实测 PR）
每一项都人为触发一次，记 Chitu 收到的时间和正文截图（正文里不得有口令、令牌、开通码），然后恢复、记收到「已恢复」。
| # | 项 | 怎么触发 | 结果 |
|---|---|---|---|
| M1 | 通道 | 本机 `deploy/probe/run-probe.sh --test-alert` | 待配置：告警 webhook 留空、本机探测没装，没有发给 Chitu 的通道 |
| M2 | 服务存活（本机 + 站点监控） | `docker compose stop api` 25 分钟：本机 `healthz_down`、云监控站点报警各一条；`start` 后两条恢复 | 部分：服务器端没测；本机探测和云监控站点监控都没装（待配置） |
| M3 | CPU / 内存 / 磁盘 80% | ECS 上 `stress-ng --cpu 2 --timeout 20m`；`fallocate` 一个大文件把盘顶过 80%（同时应收到服务器的 `disk_usage`），删掉恢复 | 未做：云监控没配；`disk_usage` 的 fallocate 测试没做 |
| M4 | 证书 < 48 小时、续期记录 | 正常续期下不会出现（160 小时证书，Caddy 提前续）：用临时的 `PROBE_STATE_DIR`、`PROBE_URL` 指向一个剩 1 天证书的测试站点跑一次 `run-probe.sh`；另外确认 14 天观察期里 `cert-renewals.jsonl` 至少记过一次 `renewed` | 待配置（本机探测） |
| M5 | 备份心跳 / 失败 / 连续失败 / 跳过 | S10b 的 B9（改错备份密钥跑两次）→ `backup_failed`、`backup_consecutive_failures`；停定时器 2 小时 → `backup_heartbeat_stale`；`mkdir /opt/yuanhui/backup/lock.d` 后跑 `backup.sh` → `backup_skipped` | **部分（仅到 outbox）**，时间为 UTC，通道配好后要经通道重发并记「已恢复」（S10r-4）。`backup_heartbeat_stale` 是首次发布前还没有心跳触发的，不是「停定时器 2 小时」：outbox 里 `backup_failed` fire 20:40:48、`backup_consecutive_failures` fire 20:42:49，改回后 20:43:49 两条 resolved；`lock.d` 放活 pid 1 → `backup_skipped`（20:38:48）；首次发布前 `backup_heartbeat_stale` fire 20:31:41，第一次备份后 20:33:41 resolved。正文没有密钥（`grep -c LTAI` = 0） |
| M6 | 门禁跳过、恢复失败 | B8 的 `--skip-backup-gate` → `backup_gate_skipped`；`RESTORE_COMPOSE_DIR=/opt/yuanhui deploy/restore.sh latest --execute`（目标库不空，必然被拒）→ `restore_failed` | **部分（仅到 outbox）**，时间为 UTC：`backup_gate_skipped` 20:31:41；ECS 上 `restore.sh latest --execute`（目标库非空）被拒 → `restore_failed` 20:38:48 |
| M7 | 营业时间无同步 | 测试店唯一一台在用的手机关机 3 小时（营业时间内） | 未做：要测试店和真手机 |
| M8 | 5xx | `docker compose stop postgres` 1 分钟，期间从本机打 25 次 `/healthz`（查库，失败回 503），再 `start` | **部分（仅到 outbox）**，时间为 UTC，没记「已恢复」：停 postgres 期间 25 次 `/healthz` 全 503，`http_5xx_rate` fire 20:39:48（count 25） |
| M9 | 快鸟 700 次 | T9 配上 AppCode 之后，测试店用脚本查 700 个不同条码 | 未做：T9 AppCode 未配 |
| M10 | 登录锁定、注销申请、导出包 | 测试店连输错 5 次密码；测试店申请注销 → 两条（申请、导出包位置）；然后撤回 | 未做：要测试店（建测试店是下一步） |
| M11 | 被退出手机暂存的账 | 测试手机离线记一笔、在另一台撤销它、它再联网，24 小时后 | 未做：要两台测试手机 |
| M12 | outbox 拉不到 | 本机 `PROBE_SSH_TARGET` 临时改成不存在的主机 30 分钟 | 待配置（本机探测） |

## 关掉商品图开关时清第三方图（T12）
1. `.env` 里 `PRODUCT_IMAGES_ENABLED=0`，用当前标签跑 `deploy.sh --execute` 重启 api。
2. 用部署账号列举并删除 `yuanhui-img` 的 `images/` 前缀（`ossutil rm -r oss://yuanhui-img/images/ -f`）。这一步同时清掉商品图候选 `images/_catalog/`（S22d，第三方图转存的缩图）和拍照上传的图（单开关，§14 S22d-4：关掉后自拍图也不显示）。只清候选、保留正式图时用 `ossutil rm -r oss://yuanhui-img/images/_catalog/ -f`，第 3 步跳过、第 4 步只跑 `DELETE FROM catalog_image_candidates;`（不要动 `products` 和 `image_jobs`，否则正式图在桶里、库里却当成没图）。
3. `rm -rf /data/img/*`（本机缓存）。
4. 清掉库里的图片状态（不然以后再开开关，库里认为有图、桶里没有）：
   ```sh
   docker exec -i yuanhui-postgres-1 psql -U yuanhui -d yuanhui -v ON_ERROR_STOP=1 <<'SQL'
   BEGIN;
   DELETE FROM image_jobs;
   DELETE FROM catalog_image_candidates;
   UPDATE products SET image_key = NULL, image_sha256 = NULL, image_source = NULL, image_ver = 0 WHERE image_ver <> 0 OR image_key IS NOT NULL;
   COMMIT;
   SQL
   ```
   这一步不推进 `rev`，手机上旧的 `image_ver` 要等商品下次变动才更新；开关关着时手机一律显示首字，不受影响。以后要重开开关，先提裁定处理手机端缓存。
