# 需要人工在阿里云上做的步骤（S10a）

本 PR 不碰云资源、不用真实凭据。下面每一步由 Chitu / Haoqiang 在控制台做，做完在部署实测 PR 里勾掉（§14 S10a-9）。
首次部署的完整顺序见 `docs/runbook.md`「首次部署」。

## 0. 备案状态（先做）
- [ ] 现状：`yuanhuishop.cn` 11/20 提交的备案**未通过**。按驳回意见改好后重新提交，记下重新提交的日期和受理号。
- [ ] **备案通过前，`yuanhuishop.cn` 和 `api.yuanhuishop.cn` 都不解析到这台 ECS**（已有的 A 记录删掉或指向别处）：上面本来就不提供服务，留着只增加备案被驳回的风险（§14 S10a-4）。Caddy 只加载 `Caddyfile.ip`，不为域名签证书（§9.2）。
- [ ] 备案前 IP 站点上只放假数据：演示小店和测试店。黄总试用店要先说明「账不作数」再建（Q8 未答复前先不建）；元辉正式店等备案通过，或拿到备案客服对 Q1 的明确答复（§9.2、§14 S10a-4）。
- [ ] 通过后按 `deploy/cutover-to-domain.md` 切换（那时才加域名解析）。

## 1. 安全组（ECS 47.117.184.253）——真正的边界
主机上的 ufw 管不到 Docker 映射的端口（Docker 直接改 iptables，映射出去的端口绕过 ufw），**能挡住外网的只有安全组**。
- [ ] 先**删掉**阿里云默认安全组自带的对 `0.0.0.0/0` 的规则：22/tcp、3389/tcp、ICMP。
- [ ] 入方向只放：
  - 22/tcp：来源只填家里当前的出口 IP（`curl -s https://ifconfig.me` 查，写成 `x.x.x.x/32`）；
  - 80/tcp、443/tcp：`0.0.0.0/0`（80 给 ACME 校验和跳转）。
  - **不放 3000、5432，不放 443/udp**（不开 HTTP/3，§14 S10a-5）。
- [ ] 家里出口 IP 变了、SSH 连不上时：照 `runbook.md`「SSH 连不上」用 aliyun CLI 先加新 `/32`、再删旧的（不要临时改成 `0.0.0.0/0`）；部署机不可用时 Haoqiang 用主账号登控制台改，再不行用 VNC 远程连接。
- [ ] 出方向默认放行（要连 Let's Encrypt、OSS 内网）。

## 2. SSH 只许密钥（§9.1）
- [ ] 控制台给实例绑定密钥对（或把本机公钥放进 `/root/.ssh/authorized_keys`），**先确认用密钥能登录**。
- [ ] `bootstrap-ecs.sh` 会写 `/etc/ssh/sshd_config.d/00-yuanhui.conf`（`PasswordAuthentication no`、`KbdInteractiveAuthentication no`、`PermitRootLogin prohibit-password`）并 `sshd -t` 后重载；没有公钥时它拒绝执行这一步。
- [ ] 跑完后在本机验：`ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@47.117.184.253` 应直接 `Permission denied (publickey)`。

## 3. OSS 两个桶（上海，私有，§9.1；S10 部署实测按负责人 11/22 的决定改）
- [x] `yuanhui-backup`：**只放 `backups/`**（加密的 dump 和清单，键各不相同、只写不改）。
  - **OSS 合规保留策略（WORM）35 天**：保留期内桶里任何对象都删不掉、覆盖不了（主账号也不行）。先建成「未锁定」（InProgress，24 小时内有效），确认备份写得进去后再锁定（`aliyun oss worm complete oss://yuanhui-backup <WormId>`）；锁定后不能删除策略、不能缩短天数，只能延长。
  - 生命周期：`backups/` 最后修改 **35 天**后删除（不早于保留期）、碎片 7 天后删除。这条是「注销后 7 + 35 天内彻底清除」的依据（§9.4）。
  - 因为对象覆盖不了，要覆盖的心跳 `heartbeat/backup.json` 不放这里，放存档桶（`server/src/backup/store.ts` 的 `BACKUP_OSS_ARCHIVE_BUCKET`）。
- [x] `yuanhui-archive`（存档桶，api 的 `OSS_ARCHIVE_BUCKET`）：`exports/`、`deletions/`、`heartbeat/`。不开合规保留（导出包到期和撤回时代码要删）。
  - 生命周期只按前缀：`exports/` **30 天**后删除（兜底）、碎片 7 天；`deletions/` **不配，永久保留**（必须活得比任何含这家店的备份都久）；`heartbeat/` 不配（一个对象，每次覆盖）。
- [ ] `yuanhui-img`（商品图，api 的 `OSS_BUCKET`）：**现在就建空桶**（PR #27 Fable S10r-7：私有、不开版本控制、不配合规保留、不配生命周期；空桶不计费），**待负责人同意**（当初只批了上面两个桶）。没有这个桶时注销清除扫 `images/<店>/` 一直失败、对象清理记不成清完（`exports/` 照样删，第 3 次起告警 `purge_objects_failed`）；代码不跳过不存在的桶。`.env` 里填这个名字（`loadConfig` 要求和存档桶不同）。TestFlight 前、M10 之前建好。
- [x] 两个桶都**私有**、**都不开版本控制**（开了「删除」只是加删除标记，注销后彻底清除不成立，§14 T21）。
- [x] 导出配置贴进部署实测 PR：`aliyun oss lifecycle --method get oss://<桶>`、`aliyun oss worm get oss://yuanhui-backup`、`aliyun oss bucket-versioning --method get oss://<桶>`。
- [x] ECS 走内网 endpoint，`.env` 里写完整地址、带 `https://`：`OSS_ENDPOINT=https://oss-cn-shanghai-internal.aliyuncs.com`（裸域名启动时会被拒绝）。
- aliyun CLI 有默认配置时会**忽略** `ALIBABA_CLOUD_ACCESS_KEY_ID/SECRET` 环境变量、改用默认配置里的另一个账号。每条命令都显式带 `--access-key-id "$A" --access-key-secret "$S" --region cn-shanghai`（A/S 从钥匙串 `tomo-credential-broker` / `aliyun-huang-ak-id|secret` 读进 shell 变量），先跑 `aliyun sts GetCallerIdentity` 确认 `AccountId` 是 1776699878997935。

## 4. OSS 凭据（按负责人决定，服务器使用部署账号密钥，不使用专用子账号）
- 负责人 11/22 决定不建 RAM 子账号。api 的 `OSS_ACCESS_KEY_*` 和备份的 `BACKUP_OSS_ACCESS_KEY_*` 都填部署用的这把密钥（RAM 用户 `chitu`，有 OSS、ECS 完全权限，没有 RAM 权限），以 600 权限写进 ECS `/opt/yuanhui/.env`，不进仓库、不进 CI、不打印。写入走管道（runbook「首次部署」第 4 步）。
- 这样 api 被攻破就能删存档桶里的东西；补偿是备份桶的合规保留：保留期内的备份谁都删不掉、改不了。原来按前缀的最小权限策略和负测（S10a 第 7 项、B3 负测）不再适用。
- **加密口令 `BACKUP_PASSPHRASE`**：见 `docs/runbook.md`「口令保管」（§14 S10b-10）。
- [x] 云盘自动快照：**负责人决定不开**（B11）。备份靠 OSS 上的合规保留备份。

## 5. ACR（可选，负责人决定暂不用）
- 默认不用 ACR：`image.yml` 在 GitHub Actions 里构建 api 镜像、拉 `caddy:2.10.2` 和 `postgres:16`，`docker save` 成 `yuanhui-images-<提交号>.tar.gz` 传成 artifact（main 的 push、手动触发、或 PR 带 `deploy-tar` 标签时）；本机 `gh run download` 取下，`IMAGES_TAR=… deploy/deploy.sh` 传到 ECS `docker load`（runbook「首次部署」）。
- 以后要用 ACR：建个人版实例、命名空间 `yuanhui`、仓库 `api`、`node`、`postgres`、`caddy` 都私有；GitHub secrets `ACR_REGISTRY`（公网地址）、`ACR_USERNAME`、`ACR_PASSWORD`；`mirror-base-images.sh` 推基础镜像；ECS 上 `docker login <VPC 地址>`，`deploy.sh` 不带 `IMAGES_TAR`、填 `ACR=<VPC 地址>/yuanhui`。

## 6. ECS 初始化
- [ ] `ECS_HOST=root@47.117.184.253 deploy/bootstrap-ecs.sh`（先 dry-run 看一遍）→ `--execute`。
- [ ] 填 `/opt/yuanhui/.env`（按 `deploy/.env.example`）：`POSTGRES_PASSWORD` 用 `openssl rand -hex 24` 生成（只许字母数字，它被原样拼进连接串，`remote-deploy.sh` 会检查）。
- [x] （不用 ACR，不需要 `docker login`。）
- [x] 云盘自动快照：负责人决定不开。
