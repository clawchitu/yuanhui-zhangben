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
- [ ] `yuanhui-backup`：`exports/`、`deletions/`、`backups/`。生命周期在 S10b 配，35 天只作用于 `backups/` 前缀，`exports/`、`deletions/` 怎么过期单独定（§14 T21）。
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
- [ ] 备份用另一个账号（S10b，§14 T21），不和 `yuanhui-api` 共用。
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
