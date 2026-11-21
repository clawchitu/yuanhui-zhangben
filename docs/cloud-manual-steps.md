# 需要人工在阿里云上做的步骤（S10a）

本 PR 不碰云资源、不用真实凭据。下面每一步由 Chitu / Haoqiang 在控制台做，做完在 PR 里勾掉。

## 0. 备案状态（先做）
- [ ] 备案控制台查 `yuanhuishop.cn` 状态（11/20 提交，审核中）。**通过前**：Caddy 只加载 `Caddyfile.ip`，不为域名签证书；api 子域 A 记录可以保留，但 80/443 带该域名的访问会被拦（§9.2）。
- [ ] 通过后按 `deploy/cutover-to-domain.md` 切换。

## 1. 安全组（ECS 47.117.184.253）
- [ ] 入方向只放：22/tcp（仅本机出口 IP）、80/tcp、443/tcp、443/udp（0.0.0.0/0）。**不放 3000、5432**。
- [ ] 出方向默认放行（要连 Let's Encrypt、ACR、OSS 内网）。

## 2. OSS 两个桶（上海，私有，§9.1）
- [ ] `yuanhui-img`：商品图，只放 `images/`。
- [ ] `yuanhui-backup`：`exports/`、`deletions/`、备份前缀；生命周期 35 天（S10b 配）。
- [ ] 两个桶都关公共读写，ECS 用内网 endpoint `oss-cn-shanghai-internal.aliyuncs.com`（填 `OSS_ENDPOINT`）。

## 3. RAM 子账号（最小权限，§14 T9 ⑤、T13）
- [ ] 新建子账号 `yuanhui-api`，只开 AccessKey，不开控制台登录。策略：
```json
{"Version":"1","Statement":[
 {"Effect":"Allow","Action":["oss:GetObject","oss:PutObject","oss:DeleteObject","oss:ListObjects","oss:ListMultipartUploads","oss:ListParts","oss:AbortMultipartUpload"],
  "Resource":["acs:oss:*:*:yuanhui-img/images/*","acs:oss:*:*:yuanhui-backup/exports/*","acs:oss:*:*:yuanhui-backup/deletions/*","acs:oss:*:*:yuanhui-backup/backups/*"]},
 {"Effect":"Allow","Action":["oss:ListObjects","oss:ListMultipartUploads"],"Resource":["acs:oss:*:*:yuanhui-img","acs:oss:*:*:yuanhui-backup"],
  "Condition":{"StringLike":{"oss:Prefix":["images/*","exports/*","deletions/*","backups/*"]}}}]}
```
- [ ] AccessKey 只写进 ECS `/opt/yuanhui/.env`（600）和 Mac 钥匙串，不进仓库、不进 CI。

## 4. ACR
- [ ] 个人版实例（上海），命名空间 `yuanhui`；跑 `deploy/mirror-base-images.sh --execute`；仓库 secrets 配 `ACR_REGISTRY / ACR_USERNAME / ACR_PASSWORD` 后 `image.yml` 才推送。

## 5. ECS 初始化
- [ ] `ECS_HOST=root@47.117.184.253 deploy/bootstrap-ecs.sh`（先 dry-run 看一遍）→ `--execute`。
- [ ] 填 `/opt/yuanhui/.env`（按 `deploy/.env.example`）；ECS 上 `docker login <ACR>`。
- [ ] 云盘自动快照（每周、留 4 份，§9.4）。
