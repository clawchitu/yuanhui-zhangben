# 备案通过后切换到域名

步骤以 docs/plan-v2.md §9.3 为准，这里只记操作细节。11/26 已做到第 4 步（`api.yuanhuishop.cn`、根域名静态首页、`www` 跳转都已上线），实际配置和回滚见 `docs/runbook.md`「域名站点 api.yuanhuishop.cn」：

1. 在阿里云备案控制台确认网站备案和 App 备案**都已通过**，记下备案号；30 天内做公安备案。
2. 这时才给 `yuanhuishop.cn`、`api.yuanhuishop.cn` 加 A 记录指向 47.117.184.253（备案通过前两个域名都不解析到这台 ECS，§14 S10a-4）。
3. 把 `deploy/Caddyfile.domain` 的两个站点追加进 `deploy/Caddyfile.ip`（`(common)` 片段共用），IP 站点保留；静态页放 `/srv/site`（compose.yml 加只读挂载 `deploy/site`）。
4. `deploy/deploy.sh <当前标签> --execute`：校验新 Caddyfile 后 `caddy reload`（失败自动换回上一份配置）；`docker logs yuanhui-caddy-1 2>&1 | grep 'certificate obtained'` 看到两张证书签发成功。
5. 从本机和手机蜂窝网络验证 `https://api.yuanhuishop.cn/healthz`；NAT64 下再验一次。
6. 之后按 §9.3 第 4–8 步。

## 进度核对（11/27，S31）

按 §9.3 的八步逐条对现状（核对命令和结果见 S31 的 PR）：

| §9.3 步骤 | 状态 | 说明 |
|---|---|---|
| 1 备案号、公安备案、网站挂号 | 部分 | ICP 苏ICP备2026094233号（网站 -1、App -2A）11/26 通过；首页底部已挂 -1。**公安联网备案还没交**（30 天内，约 12/26 前，要经营者本人在 beian.mps.gov.cn 办），号码拿到后放出 `deploy/site/index.html` 底部注释那行 |
| 2 Caddy 加域名站点 | 已做 | 11/26：`api.yuanhuishop.cn`、`yuanhuishop.cn`、`www`（301），都在 `deploy/Caddyfile.ip`；IP 站点保留 |
| 3 本机、手机蜂窝、IPv6-only 验证 | 部分 | 本机（境外家庭网络）已验：证书 LE YE1、到 2027-02-24，healthz 200。**手机蜂窝没验**（要人拿手机）。**IPv6-only 没验**：见下 |
| 4 Release 配置的包（连域名）给家里手机 | 部分 | 模拟器上 Release 构建连域名跑通 S28 精简剧本（`ios/scripts/s31-release-live.sh`）。TestFlight 上传、家里手机更新没做（提审前由负责人决定什么时候传） |
| 5 试用数据怎么处理 | 没做 | 黄总定：清空试用店从头建库，还是试用店转正 |
| 6 App Store Connect 填备案号 | 没做 | 提审时填 App 备案号 苏ICP备2026094233号-2A（S32） |
| 7 观察两周后删 IP 站点、调 `min_build` | 没到时候 | 正式版上线、全部手机更新之后 |
| 8 `tools.yuanhuishop.cn` | 只预留 | 不在本计划范围，`Caddyfile.ip` 里留了注释位置，没有解析、没有站点 |

**老 Beta 包（连 IP）**：服务器 `.env` 没配 `API_BASE`，`/v1/config` 不下发 `api_base`，已装的老 Beta 包继续连 `https://47.117.184.253`，IP 站点和证书照常（S31 PR 里有 IP 地址上的登录、同步记录）。要不要配 `API_BASE=https://api.yuanhuishop.cn` 让老包自己切到域名（要重启 api，几秒中断），等黄总这轮试用结束后由负责人定；切之前先确认域名在手机蜂窝下能连。

**IPv6-only 怎么验**（这台部署机没有公网 IPv6，验不了；App 审核在 IPv6-only 的 NAT64 网络下测）：
- 已核对的：Release 包只连 `https://api.yuanhuishop.cn`（二进制里没有 IP 字面量，`release-check.sh`），全部走 `URLSession`，没有自己解析地址或开 socket，符合苹果对 NAT64 的要求；域名只有 A 记录，NAT64 下由 DNS64 合成 `64:ff9b::2f75:b8fd`，ECS 不需要 IPv6。
- 真机验证并进 S29 真机清单（§8 S29，11/27 定）：Mac 系统设置 → 通用 → 共享 → 互联网共享，按住 Option 点「互联网共享」旁的 (i)，勾「创建 NAT64 网络」，用 Wi‑Fi 共享给 iPhone；iPhone 关蜂窝、连这个 Wi‑Fi，装 Release/TestFlight 包，登录、卖一笔、看账。结果写回这里。
