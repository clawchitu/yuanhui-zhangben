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
- [ ] 家里出口 IP 变了、SSH 连不上时：控制台 → 安全组 → 改 22 那条的来源为新 IP（不要临时改成 `0.0.0.0/0`）；改不了时用控制台的 VNC 远程连接。
- [ ] 出方向默认放行（要连 Let's Encrypt、ACR、OSS 内网）。

## 2. SSH 只许密钥（§9.1）
- [ ] 控制台给实例绑定密钥对（或把本机公钥放进 `/root/.ssh/authorized_keys`），**先确认用密钥能登录**。
- [ ] `bootstrap-ecs.sh` 会写 `/etc/ssh/sshd_config.d/00-yuanhui.conf`（`PasswordAuthentication no`、`KbdInteractiveAuthentication no`、`PermitRootLogin prohibit-password`）并 `sshd -t` 后重载；没有公钥时它拒绝执行这一步。
- [ ] 跑完后在本机验：`ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password root@47.117.184.253` 应直接 `Permission denied (publickey)`。

## 3. OSS 两个桶（上海，私有，§9.1）
- [ ] `yuanhui-img`：商品图，只放 `images/`。
- [ ] `yuanhui-backup`：`exports/`、`deletions/`、`backups/`、`heartbeat/`。生命周期规则（S10b，§14 T21），在桶的「生命周期」页配，**规则只按前缀，不选「整个桶」**：
  - `backups/`：最后修改时间 **35 天**后删除；同一条规则里「碎片」（未完成的分片上传）7 天后删除。这条是「注销后 7 + 35 天内彻底清除」的依据（§9.4），备份账号自己删不了备份。
  - `exports/`：**30 天**后删除，只作兜底（代码在到期清除和撤回时已经删导出包，这条防残留；导出包只在注销的 7 天内交给黄总用）。
  - `deletions/`：**不配生命周期，永久保留**。删除记录只有店 id 和时间、不含业务数据；它必须活得比任何可能含这家店的备份都久，不过期最简单。
  - `heartbeat/`：不配（一个对象，每次覆盖）。
  - 配好后用主账号 `ossutil lifecycle --method get oss://yuanhui-backup` 导出一份，贴进部署实测 PR。
- [ ] 两个桶都**私有**（关公共读写），**都不开版本控制**：开了的话「删除」只是加删除标记，注销后彻底清除的承诺就不成立（§14 T21）。建好后在「版本控制」页确认是「未开通」。
- [ ] 桶名全局唯一。`yuanhui-img` / `yuanhui-backup` 被别人占了就换名（如加后缀 `-yh01`），然后**同步改**：下面 RAM 策略里的桶名、`/opt/yuanhui/.env` 的 `OSS_BUCKET` / `OSS_ARCHIVE_BUCKET`、本文件和 runbook 里的桶名。
- [ ] ECS 走内网 endpoint，`.env` 里写完整地址、带 `https://`：`OSS_ENDPOINT=https://oss-cn-shanghai-internal.aliyuncs.com`（裸域名启动时会被拒绝）。

## 4. RAM 子账号（最小权限，§14 T9 ⑤、T13、S10a-6）
- [ ] 新建子账号 `yuanhui-api`，只开 AccessKey，不开控制台登录。策略（`backups/` 一律不给；`deletions/` 只给读、写，不给删——代码只写不删；api 被攻破也删不了备份和删除记录）：
```json
{"Version":"1","Statement":[
 {"Effect":"Allow","Action":["oss:GetObject","oss:PutObject","oss:DeleteObject","oss:ListMultipartUploads","oss:ListParts","oss:AbortMultipartUpload"],
  "Resource":["acs:oss:*:*:yuanhui-img/images/*","acs:oss:*:*:yuanhui-backup/exports/*"]},
 {"Effect":"Allow","Action":["oss:GetObject","oss:PutObject","oss:ListParts","oss:AbortMultipartUpload"],
  "Resource":["acs:oss:*:*:yuanhui-backup/deletions/*"]},
 {"Effect":"Allow","Action":["oss:ListObjects","oss:ListMultipartUploads"],"Resource":["acs:oss:*:*:yuanhui-img"],
  "Condition":{"StringLike":{"oss:Prefix":["images/*"]}}},
 {"Effect":"Allow","Action":["oss:ListObjects","oss:ListMultipartUploads"],"Resource":["acs:oss:*:*:yuanhui-backup"],
  "Condition":{"StringLike":{"oss:Prefix":["exports/*","deletions/*"]}}}]}
```
- [ ] 负测（用这个账号的 AccessKey，`ossutil` 在本机或 ECS 上跑，结果写进部署实测 PR）：
  - `ossutil cp x oss://yuanhui-img/other/x` → 403；`ossutil cp x oss://yuanhui-backup/backups/x` → 403；`ossutil ls oss://yuanhui-backup/backups/` → 403；
  - `ossutil cp x oss://yuanhui-backup/deletions/test.json` 成功，`ossutil rm oss://yuanhui-backup/deletions/test.json` → 403（再用主账号删掉这个测试对象）；
  - `images/`、`exports/` 下读、写、删、列举各成功一次。
- [ ] 备份用另一个账号 `yuanhui-backup`（S10b，§14 T21），不和 `yuanhui-api` 共用，只开 AccessKey。**没有任何 `oss:DeleteObject`**：`backups/` 只写不删（删除靠上面的生命周期），`deletions/` 只读和列举（重放删除记录用），心跳对象读写。恢复也用这组凭据（读 `backups/`、列举 `deletions/`）：
```json
{"Version":"1","Statement":[
 {"Effect":"Allow","Action":["oss:GetObject","oss:PutObject","oss:ListParts","oss:AbortMultipartUpload"],
  "Resource":["acs:oss:*:*:yuanhui-backup/backups/*"]},
 {"Effect":"Allow","Action":["oss:GetObject","oss:PutObject"],"Resource":["acs:oss:*:*:yuanhui-backup/heartbeat/backup.json"]},
 {"Effect":"Allow","Action":["oss:GetObject"],"Resource":["acs:oss:*:*:yuanhui-backup/deletions/*"]},
 {"Effect":"Allow","Action":["oss:ListObjects","oss:ListMultipartUploads"],"Resource":["acs:oss:*:*:yuanhui-backup"],
  "Condition":{"StringLike":{"oss:Prefix":["backups/*","deletions/*"]}}}]}
```
  - AccessKey 写进 ECS `/opt/yuanhui/.env` 的 `BACKUP_OSS_ACCESS_KEY_ID` / `BACKUP_OSS_ACCESS_KEY_SECRET`（compose 只把它们给 `backup` 服务，api 容器拿不到）。
  - 负测（结果写进部署实测 PR）：`ossutil rm oss://yuanhui-backup/backups/<任一>` → 403；`ossutil cp x oss://yuanhui-backup/deletions/x.json` → 403；`ossutil cp x oss://yuanhui-img/images/x` → 403；`ossutil ls oss://yuanhui-backup/exports/` → 403；`backups/` 写、读、列举和 `deletions/` 列举、读各成功一次。
  - **加密口令 `BACKUP_PASSPHRASE`（`openssl rand -base64 32`）**存在部署机（这台 Mac）的钥匙串（`security add-generic-password -s yuanhui-backup-passphrase -a yuanhui -w`，AccessKey 存 `-s yuanhui-backup-oss`），另给 Haoqiang 一份存进他 iPhone 的「密码」App（§14 S10b-10）。
- [ ] AccessKey 只写进 ECS `/opt/yuanhui/.env`（600）和 Mac 钥匙串，不进仓库、不进 CI。

## 5. ACR（个人版，上海）
- [ ] 建实例，命名空间 `yuanhui`；仓库 `api`、`node`、`postgres`、`caddy` 都设为**私有**。
- [ ] 设固定密码（「访问凭证」页），用户名是阿里云账号全名。
- [ ] 记下两个地址，**是两个不同的主机名**：
  - 公网地址（如 `<实例>.cn-shanghai.personal.cr.aliyuncs.com`）：GitHub Actions 推送、本机跑 `mirror-base-images.sh` 用；
  - VPC 地址（主机名带 `-vpc`）：ECS 上 `docker login`、`.env` 的 `CADDY_IMAGE` / `POSTGRES_IMAGE`、`deploy.sh` 的 `ACR` 用（走内网、不花流量）。
- [ ] 在能访问 Docker Hub 的机器上：`ACR=<公网地址>/yuanhui deploy/mirror-base-images.sh` 先 dry-run，再 `--execute`。
- [ ] GitHub 仓库 secrets：`ACR_REGISTRY`（**公网地址**）、`ACR_USERNAME`、`ACR_PASSWORD`。配好之前 `image.yml` 的推送步骤自动跳过（推送步骤保留，§14 S10a-8）。

## 6. ECS 初始化
- [ ] `ECS_HOST=root@47.117.184.253 deploy/bootstrap-ecs.sh`（先 dry-run 看一遍）→ `--execute`。
- [ ] 填 `/opt/yuanhui/.env`（按 `deploy/.env.example`）：`POSTGRES_PASSWORD` 用 `openssl rand -hex 24` 生成（只许字母数字，它被原样拼进连接串，`remote-deploy.sh` 会检查）。
- [ ] ECS 上 `docker login <ACR 的 VPC 地址>`。
- [ ] 云盘自动快照（每周、留 4 份，§9.4）。
