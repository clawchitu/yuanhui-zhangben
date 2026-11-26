# 元辉账本 开发计划 v2（2026-11-20）

本文件取代 `design/plan.md`（11/16 旧版，只留作历史参考）。11/20 已按 Codex 的评审意见修订，逐条处理见 §13；S01 执行者提出的 14 条疑问的裁定见 §14。决策来源按优先级：11/20 最新决定 > README「11/19 新增决策」> review-1119.md / review-1119-mockups.md / changes-1119.md > README 11/16。设计稿以 `design/png/` 下 53 张为准（总览 `overview.png`）。

## 11/21 审核规则小调整（功能范围不变）

Haoqiang 11/21 定：所有段和功能按原计划做，不砍、不推迟、不合并段；安全第一，双审不变。只调三点：

1. **非五类的小问题不拦合并**（§2.1）。必须改的五类：算错钱或库存、丢数据、扫不出、卡死或崩溃、真实可利用的安全问题。其余问题执行者能小改就当轮改掉，改不了记一行待办。
2. **后续轮次不对未改动的代码提新题**（§2.1）：第二轮起只核对上一轮的必须改项和新代码。
3. **新增需求：服务器地址可由服务器配置下发**（S21、§9.2）：备案前连 `https://47.117.184.253`，备案通过后切到 `https://api.yuanhuishop.cn`，老版本不用重装。

执行者须知（每段开工前读）：
- 每段是一个 PR，只读本段「要读」列出的章节和设计稿，不要通读全部 53 张。
- 每段约 35 次工具调用，这只是切分的参考。验收没过就是没完成；确实做不完，就把这一段拆成两个各自能独立验收的 PR，不要留半成品，也不要偷偷缩小验收。
- 验收里的每一条都要有对应的自动化测试或截图，PR 描述逐条列出证据。
- 本文件里写「规则」的地方不许自行改口径；发现规则有漏洞，在 PR 里提出，不要自己换算法。

---

## 0. 已定事项速查

| 主题 | 决定 |
|---|---|
| 产品 | 原生 iOS 扫码记账 App + 自有后端。只记账不收钱。第一版：卖出、进货、撤销、抹零、新商品登记、整件码、保质期、盘点、看账、商品管理、开通与设备管理 |
| 主体 / 名称 | 江阴市周庄元辉烟酒店（个体户）。App 名「元辉账本」，Bundle ID `cn.yuanhuishop.zhangben`，Team `C29GS8XSA6`，Apple Distribution 证书已在本机钥匙串（备案用的公钥和 MD5 在 `signing/`，**证书不能重新生成**，否则和备案对不上） |
| 分发 | App Store **公开上架**，只上中国大陆区，不开放注册。开发和试用期走 TestFlight **外部测试公开链接**（要过一次 Beta 审核） |
| 账号 | 家用号（全部权限）；收银员（只卖出、抹零、撤销本机当天的卖出；不能进货；不显示库存和进价）；审核号（登录后是独立的假数据「演示小店」）。首次账号密码登录，之后保持登录；已登录的家用号手机可「给家人 / 收银员开通」出二维码。无短信 |
| 收银员的实现 | 收银员不是带密码的账号，而是家用号名下的一类**设备**：由家用号手机出「收银员码」，扫了就是收银员手机（设计稿 17b 就是这样画的；Chitu 默认值，待 Haoqiang 确认） |
| 服务器 | 阿里云上海 ECS 2C2G Ubuntu 24.04，`47.117.184.253`，`ssh huang-shop`。域名 `yuanhuishop.cn`，`api.yuanhuishop.cn` 已解析，备案 11/20 提交，预计 1–3 周 |
| 条码库 | 阿里云云市场「快鸟」(cmapi00067757)，只在登记新商品时由服务器调用；备选聚美智数 (cmapi00049717) |
| 商品图 | 服务器下载 → 压成长边 200px → 存 OSS；App 只从自家服务器取图；没图显示名称首字。S22d 起：查码时服务器把快鸟的前 6 张转存成候选，多张时让人选；也可拍照上传换图（收银员不能，演示店不能），见 §14 S22d |
| 字体 | 「大字模式」开关，默认开，按手机保存；价格、总价、主按钮、键盘、步进器不随开关变 |
| 利润口径 | 赚了 = 实收 − 卖掉的货的进价。**不扣**盘亏和过期损耗，损耗单独列（D5） |
| 开发流程 | GitHub 私有仓库 `clawchitu/yuanhui-zhangben` + PR + CI；每个 PR 由 Chitu 触发 Codex 和 Fable 评审，意见以 PR 评论留下，两方都通过才合；执行者是 Opus 子代理 |

---

## 1. 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| iOS | Swift 6，SwiftUI，最低 iOS 17（机型 iPhone 13 / 17），Xcode 27.1 | 工程用 **XcodeGen**（`ios/project.yml`）生成，`.xcodeproj` 不进仓库，代理不手改 pbxproj |
| iOS 本地库 | SQLite + **GRDB**（唯一第三方依赖，SwiftPM） | |
| iOS 扫码 | AVFoundation `AVCaptureMetadataOutput`（EAN-13/EAN-8/UPC-E/ITF-14/Code128；登录页另加 QR）；蓝牙扫码枪走 HID 键盘事件 `pressesBegan` | 不用 VisionKit |
| iOS 图表 | Swift Charts | |
| iOS 测试 | `swift test`（ShopCore 包，不依赖 UIKit）；XCUITest + `FakeScanner`（启动参数喂条码）；截图用 `-uiFixture <名字>` 直接打开指定界面的指定状态。凡是能绕过登录、换身份或装演示数据的启动参数都只在 Debug 编译进去；只换界面状态、不涉及会话的（组件陈列页、`-uiLargeText`）不限（§14 S15-7） | |
| 服务器 | Node 24 LTS，TypeScript，**Fastify 5**，Postgres 16 | SQL 用 Kysely；迁移是 `server/migrations/*.sql` 纯 SQL 文件，按文件名顺序执行 |
| 服务器库 | argon2（密码）、sharp（缩图）、ali-oss、TypeBox（请求外壳校验）、ajv + ajv-formats（op 的 payload 直接按 `contracts/ops.schema.json` 校验，不在 TypeBox 里再抄一遍，§14 S04-9）、pino（日志） | |
| 服务器测试 | Vitest，连真实 Postgres（CI 用 service 容器；本机用 Homebrew `postgresql@16`，本机没装 Docker）；fast-check 做性质测试 | |
| 部署 | Docker Compose：`api` + `postgres` + `caddy`。镜像由 CI 构建并推到**阿里云 ACR 个人版（上海）**；基础镜像（postgres、caddy、node）也先镜像到 ACR，因为大陆拉不动 Docker Hub | |
| CI | GitHub Actions。服务器测试用 GitHub 托管的 Linux runner；iOS 构建和测试用**这台 Mac 上的自托管 runner**（Xcode 27.1 已装） | |

为什么成本算法只在服务器：手机只需要条码→名称价格、购物篮合计、临时库存数。移动平均、利润、对账只写一遍（TypeScript）。**唯一两边都要实现的算法是优惠分摊**（手机离线时 08 撤销页要显示每行退多少），用 `contracts/vectors/` 里同一份测试向量保证两边结果逐分一致。

---

## 2. 仓库结构（monorepo）

```
yuanhui-zhangben/                 GitHub 私有仓库 clawchitu/yuanhui-zhangben
├─ README.md  CLAUDE.md           给人和给代理的入口（CLAUDE.md 写执行者须知）
├─ docs/
│  ├─ plan-v2.md                  本文件的副本（以仓库内为准）
│  ├─ design/png/                 53 张设计稿（从 workspace 复制）
│  └─ runbook.md                  运维手册（S10a 起写）
├─ contracts/
│  ├─ openapi.yaml                全部接口的请求/响应
│  ├─ ops.schema.json             每种 op 的 payload
│  ├─ permissions.json            权限矩阵（§6 的机器可读版，两边测试都读它）
│  └─ vectors/                    allocation.json  cost.json  rounddiv.json  expiry.json  prefix.json
├─ server/
│  ├─ src/
│  │  ├─ app.ts  config.ts  db.ts
│  │  ├─ auth/        login  pairing  devices  account  guard(权限中间件)
│  │  ├─ sync/        push  pull  projection(按角色裁剪)  aliases
│  │  ├─ ledger/      apply  cost  rounddiv  allocation  lots  void  count  costfix  invariants
│  │  ├─ reports/     today  month  entries
│  │  ├─ lookup/      kuainiao  catalog  images  oss
│  │  ├─ demo/        seed  reset
│  │  └─ jobs/        scheduler  backup-heartbeat  account-purge  image-fetch
│  ├─ migrations/     0001_init.sql …
│  ├─ test/           *.test.ts  helpers/
│  ├─ scripts/        create-store.ts  create-account.ts  barcode-trial.ts  export-store.ts
│  └─ Dockerfile  package.json  tsconfig.json  vitest.config.ts
├─ ios/
│  ├─ project.yml                 XcodeGen；三个配置 Debug / Beta / Release
│  ├─ Config/                     Debug.xcconfig  Beta.xcconfig  Release.xcconfig  Info.plist  PrivacyInfo.xcprivacy
│  ├─ ShopCore/                   Swift 包：Models Money Basket Allocation Roles Ops Outbox SyncClient LocalDB
│  │  └─ Tests/ShopCoreTests/
│  ├─ App/
│  │  ├─ Design/       Tokens  TypeScale  组件（ModeBar BigButton Keypad Stepper PriceTag Thumb BottomSheet ConfirmPanel Banner）
│  │  ├─ Scanner/      ScannerSource  CameraScanner  HIDScanner  FakeScanner  Feedback
│  │  ├─ Features/     Home Sell Discount ManualCode NewProduct LinkPack StockIn Records Undo
│  │  │                Login Onboarding Pairing Settings Reports Products Count Expiry States
│  │  └─ AppRoot.swift  Fixtures/（-uiFixture 用的假数据）
│  ├─ UITests/
│  └─ fastlane/ 或 scripts/       build_upload.sh（xcodebuild archive + App Store Connect API 上传）
├─ deploy/
│  ├─ compose.yml  Caddyfile.ip  Caddyfile.domain  .env.example
│  ├─ bootstrap-ecs.sh            一次性：装 Docker、防火墙、swap、目录、ACR 登录
│  ├─ mirror-base-images.sh       把 postgres/caddy/node 推到 ACR
│  ├─ deploy.sh                   ssh 到 ECS：拉镜像、迁移、重启、健康检查、失败回滚
│  ├─ backup.sh  restore.sh       pg_dump → OSS；从 OSS 恢复
│  ├─ site/                       index.html  privacy.html  support.html  review-barcodes.html
│  └─ cutover-to-domain.md        备案下来后的切换步骤（§9.3）
└─ .github/
   ├─ workflows/  server.yml  ios.yml  image.yml
   └─ pull_request_template.md
```

### 2.1 PR 与评审规则

- `main` 受保护：禁止直接推送；必须通过的状态检查 = `server-ci`、`ios-ci`、`review/codex`、`review/fable`。
- **两条 CI 工作流对每个 PR 都触发**，不用工作流级别的路径过滤（被过滤跳过的必需检查会一直停在 Pending，卡死合并）。在 job 里判断改动路径：不相关就跳过重任务，但始终产出同名的最终检查并标成功。
- 评审由 Chitu 在每个 PR 上触发 Codex 和 Fable，意见以 **PR 评论**留下。两方的评论都写明「通过」后，Chitu 用 `gh api repos/:owner/:repo/statuses/:sha` 把 `review/codex`、`review/fable` 置为 success。PR 有新提交后需要重审。
- 评审要点固定四条：验收逐条有证据；没有越权（收银员数据裁剪、店铺隔离）；金额全部是整数分；界面与设计稿对照截图。
- **11/21 小调整（其余各条不变，仍是 Codex 和 Fable 双审）：**
  - **必须改（拦合并）只有五类**：① 算错钱或库存；② 丢数据；③ 扫不出（扫码、手输条码记不上账）；④ 卡死或崩溃；⑤ 真实可利用的安全问题（越权、泄漏、绕过登录、数据串店等）。「没有越权（收银员数据裁剪、店铺隔离）」照旧拦合并，属于第 ⑤ 类。
  - 验收清单逐条有证据仍是通过的前提；五类说的是验收之外评审另外提出的问题。
- **11/24 调整：第二路评审由 Fable 换成 Opus**（Codex + Opus 双审，Fable 不再做代码评审）。本计划其余地方写的「Codex 和 Fable」一律按「Codex 和 Opus」理解；已用 Fable 审过的旧 PR，`scripts/merge-pr.sh` 仍接受「Fable 审核：通过」。实际合并条件见 `docs/process-deviations.md` D-S00-1、D-1124-1。
- **五类以外的问题不拦合并**：执行者能小改就当轮改掉；改不了的在 §14 的跨段待办表记一行，评审方照样可以写「通过」。
  - **第二轮起，评审只核对上一轮的必须改项和这一轮新改的代码**，不主动重审没改动的老代码。若顺带发现老代码里的问题：属于五类的照样必须改（安全与数据正确优先于轮次规则）；不属于的记一行待办。
- 分支名 `sNN-简述`，一段一个 PR，squash 合并。

---

## 3. 数据模型（Postgres）

通用约定：金额一律整数**分**（`bigint`）；数量一律整数、以**基本单位**计；时间 `timestamptz`，业务上的「天」「月」一律按 `Asia/Shanghai`；主键除特别说明外是 UUID，流水和商品的 id 由手机生成。**凡是 id 由手机生成的表（`devices`、`products`、`ops`、`sale_batches`、`entries`、`stock_lots`），主键是 `(store_id, id)`，不做全库唯一**：一家店（尤其是对公众开放的演示店）里出现的 id 不能挡住另一家店用同一个 id；幂等查找一律按 `(store_id, id)`。表之间的引用都用带 `store_id` 的复合外键。每张业务表都有 `store_id`，**所有查询必须带 `store_id` 条件**（S03 的中间件把 `store_id` 从设备令牌里取出来，路由里拿不到别的店）。

### 3.1 账号与设备

| 表 | 字段 | 约束 / 说明 |
|---|---|---|
| `stores` | `id, name, is_demo bool, low_stock_default int=3, rev bigint=0, epoch uuid, created_at` | `rev` 是本店的变更序号计数器，店铺锁内**每改一行取一个新号**（§4.2）；`epoch` 在数据库从备份恢复后换新（§4.6）；演示店每日重置不换 `epoch`（§4.5） |
| `accounts` | `id, store_id, username, password_hash, kind 'family'\|'review', failed_logins int, locked_until, delete_requested_at, created_at` | `unique(lower(username))`；一个店一个账号；没有注册接口，账号只能用 `scripts/create-account.ts` 建 |
| `devices` | `id, account_id, store_id, role 'family'\|'cashier', label, token_hash, app_build, created_at, last_seen_at, revoked_at, revoke_reason` | `unique(token_hash)`；**`id` 由手机在每次登录或兑码时新生成，从不重复使用**（同一台手机被踢后重新开通、先进演示店再登录正式账号，都是新的设备行）；`revoke_reason ∈ kicked, revoke_others, logout, account_delete, demo_reset`，与 `revoked_at` 同有同无，`demo_reset` 就是响应里的 `discard_outbox`；令牌 256 位随机数，库里只存 sha256；被踢后**行保留**（要靠它认出被踢设备补传的流水）；同店未撤销设备的 `label` 不重名（重名时自动加序号） |
| `pairing_tokens` | `id, token_hash, account_id, store_id, role, label, created_by_device, expires_at, used_at, used_by_device` | 2 分钟过期，一次性；只有 `role='family'` 的设备能创建；出码的设备被撤销后（不论哪种原因），它出的未用的码作废，兑换返回 `410 pairing_expired`；账号申请注销时未用的码一并作废（§14 S03-1、S03-5） |

### 3.2 商品

| 表 | 字段 | 约束 / 说明 |
|---|---|---|
| `products` | `id, store_id, name, base_unit, price_fen, stock_qty int, stock_value_fen bigint, last_cost_fen null, cost_known bool, stock_ver bigint, last_count_at null, low_at int null, stock_known bool, track_expiry bool, expiry_warn_days int=7, shelf_life_months int null, needs_review bool, image_key null, image_sha256 null, image_source null, image_ver int=0, archived_at null, created_by_device, rev, updated_at` | 平均进价不存，等于 `stock_value_fen / stock_qty`；`cost_known` = 进价是否已知，用来区分「真的零成本」和「没填」（§5.2）；`stock_ver` 每次库存变动 +1，`last_count_at` 是最近一次盘点或期初的时间（§5.6）；`needs_review` = 等家用号补全（`quick` 登记不论角色一律为真，卖出引用未知商品时自动建的也是，§14 S04-5、S05-9）；`image_ver` 是单独一列，`image_key` 每变一次 +1，0 = 没图（§14 S02-1）；`image_sha256` 是当前图内容的 sha256，选图 / 拍照按它判「同一张不升版本」（S22d，迁移 0006）；`price_fen >= 0` |
| `product_barcodes` | `store_id, barcode, product_id, pack_qty int, unit_name, pack_price_fen, rev, deleted_at` | 主键 `(store_id, barcode)`；`pack_qty >= 1`；**单件码（`pack_qty=1`）的 `pack_price_fen` 必须为空，卖价一律读 `products.price_fen`**（CHECK 约束），只有整件码存自己的价，整件码的价也可以为空，表示按「单件卖价 × 换算数量」算（§14 S02-5、S12-1）；一个商品可以有多个单件码；单件码的 `unit_name` 就是商品的基本单位，只有一处口径：挂单件码时服务器写 `products.base_unit`、不看 payload 的 `unit_name`，改基本单位时该商品所有单件码的 `unit_name` 跟着改、各取一个新号，整件码不动（§14 S04-5） |
| `product_aliases` | `store_id, alias_id, product_id` | 两台手机离线时各自登记了同一个条码：先到的赢，后到的商品 id 记成别名，之后引用别名的 op 一律改写到赢家 |
| `barcode_catalog` | `barcode, found bool, name, spec, brand, image_url, image_urls text[], source, raw jsonb, fetched_at, images_refreshed_at timestamptz` | 全局缓存，不分店；查不到也缓存（7 天后可重查）。`image_urls` 是快鸟返回的全部图片地址（0004，旧行空数组），`image_url` = 第一张。`images_refreshed_at`（0007）：上一次为候选图重新问快鸟的时间，每条码每天最多一次（S22d-15） |

### 3.3 流水

| 表 | 字段 | 约束 / 说明 |
|---|---|---|
| `ops` | `id uuid, store_id, device_id, type, payload jsonb, payload_hash, occurred_at, received_at, status 'applied'\|'rejected'\|'held', reject_code, result jsonb, resolved_at null, resolved_by_device null, flags jsonb` | 主键 `(store_id, id)`（§3 通用约定，§14 S02-8），幂等靠它；`payload_hash` 的算法见 §4.2，时钟被校正的 op 把手机填的原值存在 `flags.client_occurred_at`（§14 S04-11）；`result` 存当初返回给手机的结果（含 remap、拒绝原因），重发时原样返回；被拒的、暂存待确认的（§4.5）也留档；暂存的 op 被家用手机处理后，`status` 改成 `applied`（记上）或 `rejected`（`reject_code = discarded`，不要），并写 `resolved_at / resolved_by_device` |
| `sale_batches` | `id, store_id, device_id, list_total_fen, paid_total_fen, occurred_at, received_at, rev` | 原价和实收；`paid_total_fen` 在撤销单行后不改，报表按行求和 |
| `entries` | `id, store_id, seq bigint, op_id, batch_id null, type, reverses_entry_id null, product_id, barcode, name_snapshot, unit_name, pack_qty, pack_count, qty_delta int, list_amount_fen, amount_fen, unit_cost_fen null, cogs_fen, value_delta_fen, cost_missing bool, expiry_date null, device_id, occurred_at, received_at, voided_at null, voided_by_device null, cost_fix_entry_id null, flags jsonb, rev` | `seq` 是本店内的应用顺序；`type ∈ sale, stock_in, opening, count, cost_adjust, cost_fix, expire_loss, supplier_return`；`unique(store_id, seq)`；除 `cost_fix` 外一行最多被冲销一次（`cost_fix` 可以被多次部分冲销：它补记的每一笔卖出被撤销时各冲一条） |
| `stock_lots` | `id, store_id, product_id, source_entry_id, expiry_date null, qty_in, qty_left, snoozed_until null, closed_at null, closed_reason null, handle_ver int, rev` | 只用于到期提醒，**不参与成本**；生命周期和 `handle_ver` 见 §5.4 |
| `lot_moves` | `store_id, entry_id, lot_id, qty` | 每笔卖出/损耗/盘点扣了哪个批次，撤销时原样加回 |
| `image_jobs` | `product_id, store_id, source_url, attempts, next_try_at, done_at, last_error` | 图片下载队列，失败重试 3 次 |
| `removed` | `store_id, rev, kind, row_id` | 墓碑：被删的行（解除的整件码等），让手机同步删除 |

`entries` 各类型的字段含义：

| type | qty_delta | amount_fen | list_amount_fen | cogs_fen | value_delta_fen |
|---|---|---|---|---|---|
| `sale` | −数量 | 摊完优惠的实收 | 原价 | 这行货的进价（服务器算） | −cogs |
| `stock_in` | +数量 | 进货总价 = 件数 × 单价 | 同 amount | 0 | +总价；`unit_cost_fen` 存录入的每件（条/箱）单价 |
| `opening`（期初库存） | 设为实数后的差 | 0 | 0 | 0 | 库存值的变化；填了进价时 `unit_cost_fen` 存 `b`（留档，冲销行照抄），没填存空（§14 S05-7） |
| `count`（盘点） | 实数 − 账面 | 0 | 0 | 盘亏为正、盘盈为负 | −cogs |
| `expire_loss`（过期扔掉） | −数量 | 0 | 0 | 损耗金额 | −cogs |
| `supplier_return`（退供货商） | −数量 | 0 | 0 | 0（不计盈亏） | −按平均进价算的货值 |
| `cost_adjust`（调整） | 0 | 0 | 0 | 0 | 调整额（可正可负），界面显示为「调整」 |
| `cost_fix`（成本补记） | 0 | 被补记的那些卖出行的实收合计 | 0 | 补记的进价合计 | 0（§5.2） |

**撤销的记法（规则）**：原流水打 `voided_at`（界面上划线显示）；同时新增一行**冲销流水**，`type` 与原行相同、`reverses_entry_id` 指向原行、所有数量和金额取反、`occurred_at` = 撤销发生的时间。报表对所有行（原行 + 冲销行）按各自的 `occurred_at` 求和，所以「撤销算在撤销那天」；当天撤当天的（绝大多数情况）正好抵消。列表界面不显示冲销行。`unit_cost_fen` 是单价不是金额，冲销行**照抄原行、不取反**（进货的冲销行、`cost_fix` 的冲销行都一样）。`pack_count` 随数量取反，`pack_qty` 是换算、照抄不取反；手机解码和求和要接受负的 `pack_count`（列表不显示冲销行，只在求和时用到，§14 S05-11）。好处：已经过去的月份的月初货值不会被事后改动，对账等式永远是同一张流水表的求和。

撤销的三条补充（§14 S05-12、S05-13）：
- `voided_at` 记撤销 op 的 `occurred_at`（时钟校正之后的），与冲销行的 `occurred_at` 是同一个值，「撤销算在撤销那天」只有一个口径；服务器收到的时间在冲销行的 `received_at` 上。
- 卖出的冲销行带原行的 `batch_id`（I4 和按批汇总都要用）；跟着冲销产生的 `cost_fix` 冲销行和 `cost_adjust` 不带 `batch_id`。
- 因此**凡是按 `batch_id` 取「批内的行」的查询，一律加 `reverses_entry_id IS NULL`**。现有的只有整批撤销一处；S06、S07 新写的查询照此。

服务器生成的行 id（§14 S09-2）：服务器生成的流水行（冲销行、补偿行）和批次的 id 由（店、op id、seq）和（店、来源流水 id）算出（`ledger/ids.ts` 的 `derivedId`），同一串 op 按同样顺序重放得到相同的 id；手机不许自己推算，也不许依赖它随机。派生 id 撞上已有流水 → 这个 op `rejected invalid`（和主流水 `entry_id` 被占用同样处理），不许 500。

不变式（S04–S06 的性质测试逐条断言）：
- I1 每个商品：`Σ entries.qty_delta = products.stock_qty`
- I2 每个商品：`Σ entries.value_delta_fen = products.stock_value_fen`
- I3 `cost_known` 为假时 `stock_value_fen = 0`；为真时：`stock_qty > 0` 则 `stock_value_fen >= 0`，`stock_qty <= 0` 则 `stock_value_fen = stock_qty × last_cost_fen`
- I4 每个未全撤的卖出批次：未撤销各行 `amount_fen` 之和 + 已撤销各行 `amount_fen` 之和 = `paid_total_fen`
- I5 同一个 op 重放任意次，库里结果不变
- I6 对账：对任意时间段，`期初货值 + Σ value_delta（按类型分组）= 期末货值`，逐分相等
- I7 同一店内 `rev` 不重复；用任意页大小分页拉取的结果集合 = 一次拉完的结果集合
- I8 重发同一个 op，返回与第一次相同的结果（含拒绝原因和 remap）；「相同」指库里存的那份结果不变，回给手机时仍按当前请求的角色裁剪（收银员重发拿不到 `current` 里的库存，`sync/projection.ts` 的 `resultOut`）

### 3.4 手机本地库（GRDB）

| 表 | 内容 |
|---|---|
| `product` | id、名称、基本单位、卖价、`needs_review`、`track_expiry`、`image_ver`、`archived` |
| `product_private` | 库存数、货值、最近进价、`low_at`、保质期设置。**收银员手机上这张表永远是空的**（服务器根本不下发） |
| `barcode` | 条码 → 商品、换算、单位名、整件价 |
| `entry` / `sale_batch` | 家用号：最近 35 天全店流水；收银员：仅本机最近 2 天的卖出。天数按 `occurred_at` 的上海日历日算、含今天，服务器只下发窗口内的（§4.2）；撤销流水在窗口内、它指向的原流水不在本地时要能容忍；更早的账联网查（§7 `GET /v1/entries`）（§14 S04-6） |
| `lot` | 仅家用号：未关闭的批次（首页黄条和快过期清单离线可用） |
| `outbox` | 待传的 op，每条绑定产生它时的店、设备和令牌（不可改绑），op id 店内唯一；确认后保留 14 天（§4.6）；旧会话留下的未确认 op 构成「恢复队列」（§4.5）。当前会话是收银员时，旧会话的 op 一确认就删，换成收银员时旧会话已确认的立刻删，都不留 14 天（§14 S13-1） |
| `meta` | 游标、`server_epoch`、角色、店名、设备名、待压缩标记 `compact.pending`（见表下） |

退出、被踢、换角色、换账号时清空**投影**（商品、流水、批次、游标）再同步，但**绝不清未确认的 outbox**，它们连同旧令牌进恢复队列（§4.5）。大字模式、扫码枪开关等偏好存 `UserDefaults`，不进库。设备令牌（当前的和恢复队列用的旧令牌）存钥匙串（`kSecAttrAccessibleAfterFirstUnlock`）。

**待压缩标记**（S13 的 PR #9 审核定下的做法）：换成收银员时清掉的投影、删掉的旧会话 op，旧进价还留在库文件和 `-wal` 里，要压缩（VACUUM + WAL 截断）之后才真正消失，所以「清掉」和「压缩完」之间不能断开就没人管。清投影、删旧 op 的同一个事务里往 `meta` 写 `compact.pending`；压缩确认截断做成后才清标记（查标记、压缩、清标记在同一段串行写访问里，避免把别的线程新记的标记误清）；被读事务挡住或中途崩溃时标记保留，打开库时、每次 `recordResults` 时、每次同步（`compactIfNeeded()`）时补做。没做成时两类入口的表现不同：打开库、`recordResults`（以及换身份的那几个入口）压缩受阻时保留标记、照常返回，不因此报错，也不拦打开；只有 `compactIfNeeded()` 在重试后仍没做成时抛 `compactionBusy`（标记同样保留），没做成不当成功。

### 3.5 运维表（S09，§14 S09-13）

不下发给手机、不参与同步的四张表（`migrations/0002_demo_and_deletion.sql`）：

| 表 | 字段 | 约束 / 说明 |
|---|---|---|
| `demo_stores` | `store_id, review_password_hash, seeded_at, next_reset_at` | 演示店的重置状态（§8 S09）。`review_password_hash` 是审核号的原始密码哈希，每日重置恢复成它；`seeded_at` 是上一次重置的时间（种子里的「今天」）；`next_reset_at` 是下一次该重置的时间，定时任务在锁内重查它，同一个周期只重置一次 |
| `export_jobs` | `store_id, requested_at, object_key null, done_at null, attempts, next_try_at, last_error null, cancelled_at null, stale_cleared_at null` | 非演示店申请注销时同一事务插一行。`requested_at` 是这一次申请（撤回后又申请是新的一次，同一行重置）；`next_try_at` 兼作租约；`done_at` / `object_key` 同有同无，是这一版的包生成好了；`stale_cleared_at` 是比这一版更早的旧包删完了（生成和清理分开记，清理失败单独重试）；`last_error` 只记原因代码；`cancelled_at` 是撤回，定时任务删掉包再删行 |
| `store_purges` | `store_id, purged_at, swept_at null, objects_cleared_at null, attempts, last_error null, next_try_at null`（0003，失败退避，PR #27 S10r-11） | 已清除的店，只有店 id 和时间。在线数据删掉之后继续重试对象清理（商品图、导出包、未完成的分片上传、本机图片缓存）；`swept_at` 是最近一次按前缀清理成功，清除之后满 1 小时的那一遍复扫成功了才记 `objects_cleared_at`（T17）；迟到落地的对象删不掉时 `objects_cleared_at` 被撤回成空，下一轮再清。`attempts` 是连续失败次数，第 3 次起告警、按 `next_try_at` 退避，每一遍扫成功清零。删除记录的正本在 OSS `deletions/`（§9.4） |
| `object_discards` | `object_key, upload_id, store_id, created_at, attempts, next_try_at, last_error null` | 存档桶里该删却没删掉的对象（作废的导出包、生成失败时已经写进去的包），以及分片上传失败、中止也失败留下的残片（`upload_id` 非空，重试时中止它）；没有任务行再指向它们，所以持久化一条待删标记。导出任务每轮按退避重试，删掉才删这一行；删之前确认没有已完成的导出任务指向这个键 |

---

## 4. 同步协议

### 4.1 原则

1. 每次记账先写本地库和 outbox，界面立刻完成，不等网络。
2. 手机只发**事件（op）**，从不发库存绝对值。盘点和期初发的是「数到几个」加上「数的时候账上是几个、是哪个版本」（§5.6），差额由服务器在应用时算。
3. 每个 op 带手机生成的 UUID 和 `occurred_at`。服务器按 id 幂等，重发无害，并且**重发得到的是当初的处理结果**（§4.2）。
4. 服务器在**店铺级锁**（`pg_advisory_xact_lock(store)`）内按到达顺序逐个应用 op，一个请求一个事务；库存、货值、平均进价是应用时更新的投影。
5. 离线手机晚到的卖出，按服务器应用时的平均进价算成本（小偏差，接受）；报表归属的日期按它自带的 `occurred_at`。
6. **手机本地的原子性**：记一笔账 = 写本地流水 + 写 outbox，同一个事务。处理一次同步响应 = 应用拉到的变更 + 改写 remap + 记下每个 op 的结果 + 推进游标，同一个事务。本地显示的库存 = 服务器基线（只由拉取更新）+ 本机未确认 op 的增减（按 outbox 现算），两者分开存，互不覆盖；op 被拒后它的增减自然消失。
7. outbox 里的每条 op 绑定产生它时的店、设备和令牌，**永不改绑**（§4.5）。

### 4.2 接口 `POST /v1/sync`

请求：`{ epoch, cursors: {catalog, ledger}, ops: [ {id, type, occurred_at, payload} ] (≤200), app_build }`

响应：
```
{ results: [ {id, status: applied|rejected|held, code?, remap?: {旧商品id: 赢家商品id, …}, current?: {...}, replayed?: bool} ],
  changes: { products[], barcodes[], removed[], entries[], batches[], lots[] },
  cursors: {catalog, ledger}, has_more: {catalog, ledger}, total_products,
  server_time, epoch, min_build,
  device: { role, label, revoked: bool, discard_outbox?: bool }, store: { name } }
```

- **变更序号**：店铺锁内每改动一行，就从 `stores.rev` 取一个新号写到这一行的 `rev`。同一店内 `rev` 不重复，一个 op 改了 5 行就占 5 个号，所以 `rev > cursor` 分页永远不会切在同一个号中间。所有会改到同步数据的写入（包括图片任务写 `image_key`、定时任务、设备改名之外的任何后台写）都必须先拿店铺锁、走同一个取号函数。被删的行（解除整件码等）写一条 `removed` 墓碑，也有 `rev`。
- **两条独立的流，各有游标**：`catalog`（商品、条码、墓碑）和 `ledger`（流水、批次头、保质期批次）。每页 500 行，`has_more` 为真就继续拉。
- **游标怎么走**（§14 S04-12）：页没装满时，游标直接跳到同一快照里的 `stores.rev`，只进不退（成立的前提是所有写同步数据的地方都在店铺锁内取号、提交后才放锁）。请求带 `pull: false`（恢复队列只推不拉，§4.5）或设备已被踢时，游标原样返回、`total_products = 0`，手机这时不看它。游标比 `stores.rev` 大时原样返回、不报错。
- **流水只下发最近的**（§14 S04-6）：家用 35 天、收银员 2 天，按 `occurred_at` 落在上海时区的哪一天算，含今天；窗口外的流水和批次头不下发，游标照常越过；保质期批次不受窗口限制。这就是 §3.4 本地库的范围，服务器不下发手机转头就要删的行。手机要容忍「撤销流水在窗口内、它指向的原流水不在本地」；窗口以外的账只能联网查（§7 `GET /v1/entries`）。
- **墓碑**（§14 S04-7、S05-15）：条码解除后又挂上，旧墓碑不再下发：拉取那一刻按条码当前状态过滤，墓碑本身不删；再次解除写一条新号的墓碑。手机因此不必依赖同一页里 `removed` 和 `barcodes` 的处理先后。墓碑**不套**上一条的时间窗：它是删除指令，手机上可能还留着窗口以外的旧行，套了就删不掉；多发一条手机上已经没有的行的墓碑没有害处。
- **首次同步（review 四-4）**：先把 `catalog` 拉到底就进首页、可以开始卖；`ledger` 和图片在后台继续，图片不占同步队列、不阻塞扫码。拉取期间别的手机继续记账没有关系：新改的行序号更大，排在后面，不会漏。
- **`remap` 的形状**：一个对象，键是这个 op 里引用到的、已经成为别名的商品 id，值是赢家商品的 id；可以有多对（一笔卖出的好几行可能各引用一个别名）。任何引用了别名的 op 都可能带它，不只是 `product_upsert`。手机收到后把本地所有对旧 id 的引用改写成新 id。
- **结果可重放**：服务器把每个 op 的结果（应用 / 拒绝及原因 / 暂存 / remap）存在 `ops.result`。重发同一个 id，返回当初的结果并带 `replayed: true`，不返回笼统的「重复」。同一个 id 但 payload 哈希不同 → 拒 `id_conflict`，不应用。内容哈希 = sha256(键排序的 `{type, occurred_at 换算成 UTC 毫秒, payload}`)，**不含设备**；时钟被校正的 op 按手机填的原值算（原值存 `ops.flags.client_occurred_at`）。重放不看是谁发的：同店别的设备发同 id 同内容，也拿到当初的结果（§4.6 重新开通的设备补交要靠它），回给手机时仍按当前请求的角色裁剪（I8）（§14 S04-11）。
- **epoch 握手**：请求带手机记着的 `epoch`，必填、不允许为空；手机的第一个 `epoch` 来自登录或兑码的响应（§7）。与服务器不一致时，服务器**不应用**这次请求里的任何 op，只返回 `epoch_mismatch` 和新 epoch，手机按 §4.6 处理后再发。
- **店铺锁只有一个入口**：所有拿店铺锁的写入（S04 同步、S05/S06 记账、S08 图片任务、S09 重置）都只走 `withStoreLock`，不许自己另拿锁。进程内按店排队，每家店在途上限默认 32（`STORE_QUEUE_LIMIT`），超过返回 `503 {code: unavailable, retry_after_s}`，不进队列、不取连接（§14 S04-8）。
- **请求体上限**：1 MiB。超过返回 `413 {code: invalid}`，一个 op 都不处理。手机按字节拆批（≤200 个 op 且 ≤1 MiB）；最大的合法 op（200 行的卖出、字符串写满、非 ASCII 全转义）约 0.75 MiB，单独一个总放得下。op 的内容（存不进库的字符、解析不出的时间、payload 嵌套超过 16 层或超过 1 万个节点）只让这个 op `rejected: invalid`、不留档，不会让整个请求失败（§14 S04-13）。
- **校验的先后**（§14 S04-13）：请求外壳（顶层字段、`cursors`、每个 op 的 `id / type / occurred_at`）严格校验，不成形整个请求 `400 invalid`。然后逐个 op：先判权限，违反权限条件的得到的是 `forbidden`，不是 `invalid`（例如收银员的 quick 登记带了 §4.3 允许之外的家用字段）；再按 `ops.schema.json` 校验 payload，不合 → 这个 op `rejected: invalid` 并留档（有权提交的 op，例如收银员的 `sale_batch`，带了 schema 不允许的字段，仍是 `invalid`）。任何 op 的内容都不许让整个请求 500；兜底触发时怎么办见 §4.4 最后几行。
- **注销期间**：`/v1/sync` 里的 op 一个都不应用、不留档，`results` 为空，拉取照常，响应顶层带 `delete_pending_until`；手机把 op 留在 outbox 并停止推送，撤回后自动补传（§14 S04-2）。
- **按角色裁剪**（在 `sync/projection.ts` 一处实现）：收银员拿不到 `product_private` 里的任何字段、任何进货/盘点/损耗流水、别的手机的流水、保质期批次、`cogs_fen`/`value_delta_fen`/`unit_cost_fen`。响应 JSON 里**不出现这些键**，不是置空。`results` 也过同一处（首次处理和缓存重放是同一条路，收银员重发家用的 op 拿不到 `current`，I8）。`removed` 墓碑同样按角色过滤：`barcode`、`product_alias` 墓碑照发；`entry / batch` 墓碑只把本机卖出的发给收银员，库里找不到原行的不发（宁可不删也不泄漏）；`lot` 墓碑不发给收银员（§14 S04 待办、S05-14）。
- 触发时机：每次写入后、网络恢复、回到前台、打开期间每 15 秒。右上角常驻状态「已同步 / N 笔待传」。outbox 里有超过 24 小时的 → 首页提醒条（25a）；与快过期黄条同时存在时两条都显示，没同步的在上。

### 4.3 op 类型

| type | payload 要点 | 谁能发 |
|---|---|---|
| `sale_batch` | `batch_id, paid_total_fen, lines[{entry_id, product_id, barcode, name, unit_name, pack_qty, pack_count, unit_price_fen}]`；原价由服务器按行算，优惠分摊由服务器算 | 家用、收银员 |
| `void` | `target: {batch_id}` 或 `{entry_id}` | 家用：任意；收银员：仅本机的卖出，且原卖出的日期 = 服务器收到撤销那天（§6） |
| `product_upsert` | `product_id, barcode, name, price_fen, quick: bool`；`quick=false` 时必带 `base_unit`，还可带 `track_expiry, expiry_warn_days, shelf_life_months, low_at`；`quick=true` 时**不带** `base_unit`，服务器默认「个」 | 家用；收银员只能 `quick=true`（只有名称和卖价，服务器强制 `needs_review=true`，带了别的字段就拒） |
| `product_edit` | `product_id` + 要改的字段（名称、卖价、基本单位、`low_at`、保质期设置、停用）；逐字段后写者赢 | 家用 |
| `barcode_link` / `barcode_unlink` | `barcode, product_id, pack_qty, unit_name, pack_price_fen`（单件码不带价，§3.2） | 家用 |
| `stock_in` | `entry_id, product_id, barcode, pack_qty, pack_count, unit_cost_fen, expiry_date?` | 家用 |
| `opening` | `entry_id, product_id, counted_qty, unit_cost_fen?, expiry_date?, base_ver?, base_qty?`（新商品第二步「货架上现在有几个」；`base_ver` 何时必带见 §5.6） | 家用 |
| `product_review_complete` | `entry_id, product_id, unit_cost_fen（必填，可为 0）, counted_qty, base_ver, base_qty?, 保质期设置?, expiry_date?`（22b 待确认补全；`entry_id` 是它生成的那条 `opening` 流水的 id）→ 记一条 `opening` 流水，清 `needs_review` | 家用，**只能联网提交**（§5.6） |
| `count` | `entry_id, product_id, counted_qty, base_qty, base_ver` | 家用，**只能联网提交**（§5.6） |
| `expiry_dispose` | `lot_id, handle_ver, actual_qty, action: sold_out\|discard\|return, entry_id` | 家用 |
| `lot_snooze` | `lot_id, handle_ver, actual_qty, days` | 家用 |

对上表的补充（都是 §14 的裁定）：
- `product_upsert` 的商品 id 在库里已经存在（不是别名）：不改商品的任何字段。条码已经挂在这个商品上 → `applied`，无操作；其他情况（条码空闲、解除过、挂在别的商品上）→ `rejected: invalid` 并留档，不挂码。挂码只走 `barcode_link`。不论角色、不论 `quick`（S04-10）。
- `quick` 登记不论角色，一律 `needs_review = true`（S04-5）。
- `product_edit` 的「逐字段后写者赢」，先后按**到达服务器、被应用**的顺序，不按 `occurred_at`（手机时钟不可信）；只改 payload 里带了的字段，没带的不动（S04-4）。改基本单位时，该商品所有单件码的 `unit_name` 跟着改，整件码不动（S04-5，§3.2）。
- `product_review_complete`：`track_expiry / expiry_warn_days / shelf_life_months` 随 payload 写进商品，没带的不动；清 `needs_review` 单独取一个 rev。商品不是 `needs_review` 时也照收，等于一次进价必填的期初。`expiry_date` 写进 `opening` 流水和新批次，年份 0000 拒 `invalid` 并留档（S06-1、S06-13）。
- `barcode_link`：`pack_qty = 1` 时服务器写商品的基本单位，不看 payload 的 `unit_name`（不拒）；`pack_qty > 1` 时 `pack_price_fen` 可以不带，为空表示按「单件卖价 × 换算数量」算（S04-5、S02-5、S12-1）。条码已经挂在别的商品上 → 拒，不挪（§4.4）。

（设备改名、踢人、改密码等不是 op，是在线接口，见 §7。）

### 4.4 拒绝与冲突

| 情况 | 处理 |
|---|---|
| 角色无权 | `rejected: forbidden`。手机把这条 op 标成「没记上」并在首页提示，不再重试；它对本地库存的临时增减随之消失。权限判在 schema 校验之前（§4.2） |
| 同一条码已经登记过（两台手机各登记了一次，或有人故意重复登记） | 先到的赢。后到的 `product_upsert` **不修改赢家的任何字段**（不论角色），只返回 `remap` 并写 `product_aliases`，手机改写本地引用。家用号想改名称或卖价，另发 `product_edit` |
| 收银员卖了一个还没同步到服务器的商品 | 同一请求内 op 按顺序应用，`product_upsert` 在前即可；手机 outbox 保证先后顺序 |
| 卖出引用了不存在的商品（极端） | 服务器按 payload 里的名称和卖价自动建一个 `needs_review` 商品，流水照收，绝不丢账。自动建的商品：`pack_qty = 1` 的行，卖价取行单价；整件行卖价记 0，不用「整件价 ÷ 换算」去猜（猜的价会被当真价卖出去，0 一眼看得出没填）。不挂条码（行里的条码可能属于别的商品，也可能是整件码，换算和整件价都不能从一行卖出里推）。这个商品 id 之后再来 `product_upsert` 会被拒 `invalid`（下一行），补全只走 `product_edit` + `barcode_link` + `product_review_complete`；补全页（22b）遇到 `needs_review` 且 `price_fen = 0` 要先让人填卖价（§14 S05-9） |
| `product_upsert` 的商品 id 已存在（不是别名） | 不改商品任何字段。条码已挂在这个商品上 → `applied` 无操作；其他情况 → `rejected: invalid` 并留档，不挂码（§4.3，§14 S04-10） |
| 商品类 op（`product_edit / barcode_link / barcode_unlink`）引用不存在的商品；`barcode_link` 的条码已挂在别的商品上 | `rejected: invalid` 并留档。不自动建商品、不挪条码（要挪先解除再挂，必须是人明确做的两步）。同一响应的拉取会把这个条码现在挂在哪带回手机，界面据此提示，不另设拒绝码（§14 S04-3） |
| 解除一个没挂着的条码 | 无操作，算 `applied`（§14 S04-3） |
| payload 不合 `ops.schema.json` | 这个 op `rejected: invalid` 并留档；同批其余照常处理（§14 S04-13） |
| 账号在注销申请期间 | 不是拒绝：整批 op 一个都不应用、不留档，`results` 为空，拉取照常，响应顶层带 `delete_pending_until`。不能返回 `rejected`，手机会当成终局、不再重发，撤回注销后就丢账了。手机没拿到结果的 op 本来就留在 outbox，看到 `delete_pending_until` 就停止推送，撤回后自动补传。被踢设备在注销期间的补传同样处理（§4.2，§14 S04-2） |
| 撤销两次 | 第二次无操作（重放则返回第一次的结果） |
| 盘点、期初、补全、处理快过期时，手机看到的版本已经过时 | `rejected: stale`，`current` 带回最新的账面数或批次状态，手机让人重新确认（§5.4、§5.6） |
| 同一 id 不同内容 | `rejected: id_conflict` |
| 金额、数量超出 §5.0 的上限或格式不对 | `rejected: invalid` |
| 进货 0 件（`pack_count = 0`，这批单位成本无定义） | `rejected: invalid` 并留档；卖出行 0 件不拒，照普通行记（§14 S05-3） |
| 只看 op 自己就能判定的问题，包括算出来的新库存、货值存不进列（`stock_qty` 是 `integer`，满额进货约 215 次就到） | 写库之前判，`rejected: invalid`。留不留档只看 `ops` 这一行存不存得下：`expiry_date` 年份 0000 → 留档；`occurred_at` 年份 0000 → 不留档（并入 §4.2 的存不进库检查，所有 op 类型都判）。只按存不存得下判，不按合不合理判：1970 年的 `occurred_at` 照收（§14 S05-4） |
| 记账类 op 过了上面的预检查，写库时仍报 22xxx | 只能是服务器自己错了：整个请求 500、记 error 日志（op id、类型、SQLSTATE），不单个拒收，手机会重发；记账类 op 的兜底永远不产生 `rejected`（§14 S04-14、S05-4） |
| `occurred_at` 比服务器时间晚 5 分钟以上（手机时钟错） | 改成 `received_at`，`flags.clock_adjusted=true` |
| 库存变负 | 允许，永不拦卖出 |

### 4.5 身份变化：退出、被踢、换角色（review 四-3）

**归属不可变。** 手机上分两样东西：「当前会话」（令牌、角色、店、投影）和「恢复队列」（以前的会话留下的未确认 op，连同当时的令牌，存在钥匙串和本地库里）。恢复队列里的 op 永远用**它自己的旧令牌**上传，不会用新令牌、新身份、新店去解释。

- 退出登录、被踢、换角色、换账号时：清空投影和游标；**未确认的 op 不删**，移入恢复队列。恢复队列清空后才删除对应的旧令牌。
- 换成收银员（§14 S13-1）：「收银员手机找不到进价」指投影（`product_private`、`lot`、流水成本列）和**已确认**的 op；唯一例外是旧家用会话留下的**未确认** op（不加密、不拦换角色，不丢账优先），传完即删。兑收银员码成功后、第一次拉取前先用旧令牌传一遍恢复队列，传不完不拦。收银员会话下恢复队列在界面上只显示笔数，不展示 op 内容。
- 主动退出登录：先把 outbox 传完，再调 `logout`。没网时提示「还有 N 笔没传，联网后会自动补传」，这几笔进恢复队列，`logout` 推迟到传完之后再调。
- 恢复队列的上传：用旧令牌单独调 `/v1/sync`（只推不拉），每次打开 App 和每次同步时都尝试。
- 服务器对**已被踢的令牌**：不返回任何数据，响应 `device.revoked=true`。它推上来的 op 按类型分开处理：

| op | 处理 |
|---|---|
| `sale_batch`，以及 `quick` 的 `product_upsert`（不必证明它被哪笔卖出用到：它只会新建一个待确认商品，条码已存在时什么都不改） | `occurred_at <= revoked_at` → 直接入账，打 `flags.late_from_revoked`，在「记的账」里带小标记 |
| 其他类型（非 `quick` 的登记、进货、期初、盘点、撤销、改商品、整件码、处理快过期） | `occurred_at <= revoked_at` → **不直接入账**，记为 `held`。当前的家用手机在「已登录的手机」里看到「『某手机』被退出前还有 N 笔别的账」，逐笔「记上 / 不要」（用 26 号通用确认面板）。盘点、期初这类依赖当时账面数的，确认时版本已变就只能丢弃，提示重新盘 |
| `occurred_at > revoked_at` 的任何 op | 拒收 |

- 补传窗口：被踢后 30 天。说明：`occurred_at` 是手机填的，服务器无法证明它的真假；窗口和暂存的作用是把最坏情况限制在「多出几笔带标记、看得见、可以撤的卖出」，不是可信的时间证明。
- 提示页：家用手机被踢进 25b，收银员手机进 25f（「让家里人重新出码，扫了以后会自动补传」）。有未传流水时显示笔数。
- **演示小店重置**：重置时把演示店所有设备（**含重置前已撤销的**，撤销原因一律改成 `demo_reset`，已撤销的保留原撤销时间；§14 S09-3）标记为已撤销并带 `discard_outbox=true`。手机收到后**丢弃**这家店的 outbox 和恢复队列，不重放，回到登录页。重置不换 `epoch`。

### 4.6 服务器从备份恢复之后（补救手段，不是保证）

正常的灾备靠 §9.4 的备份（营业时间内每小时一次）。手机重传只是在此之上再补回一些数据：

- 手机上已确认的 op 保留 14 天。
- 恢复后运维给店铺换新 `epoch`。手机下一次同步得到 `epoch_mismatch`：丢弃投影和游标 → 重新全量拉取 → 把保留的 op 全部重新标为待传 → 正常同步。服务器上还在的 op 按 id 幂等跳过，丢了的重新入账。
- 讲清楚的限制：① 重传的先后顺序可能与原来不同，平均进价和个别流水的成本可能与恢复前差几分钱；② 备份之后才开通的设备，令牌在恢复后的库里不存在，无法认证。这类设备要重新开通，然后由运维临时打开「恢复模式」，设备（家用或收银员）通过 `POST /v1/recovery/import` 用新令牌补交保留的 op（按原 id 幂等，打 `flags.recovered`；内容哈希不含设备，所以换了新设备补交同 id 同内容的 op 不会撞 `id_conflict`，§4.2，§14 S04-11）。恢复模式平时关闭，步骤写进 runbook。

---

## 5. 成本与金额算法（规则，不许改口径）

全部在 `server/src/ledger/`，`contracts/vectors/cost.json` 给出逐步的数值用例。

- **§5.2 只在服务器实现**：手机不实现 §5.2、不读 `cost.json`，显示的是服务器算的数（§5.1 分摊和 `rounddiv.json` 仍是两端各实现一遍）。以后如果有哪一段要在手机上算成本，那一段必须先把 `cost.json` 全部向量接进 ShopCore 的测试（§14 S06-12）。

### 5.0 整数规范与输入上限

- 金额是 64 位有符号整数（分）。服务器上凡是金额相乘的中间运算一律用 `BigInt`；手机只做两种乘法（优惠分摊、进货页的预计平均），用带溢出检查的 `Int64` 乘法，溢出按无效输入处理。JSON 里金额和数量都是整数，不带小数点、不用字符串。
- `roundDiv(a, b)`（`b > 0`）：四舍五入到整数，恰好一半时远离零；对负数对称，`roundDiv(−a, b) = −roundDiv(a, b)`。本节所有「除」都指它。
- 服务器校验的上限（超出拒 `invalid`，手机端输入框同样限制）：
  - 单价、进货的每件单价、单行金额（单价 × 件数；进货是件数 × 每件单价，即进货总价）≤ 99,999,999 分；
  - 一笔卖出的实收 `paid_total_fen` ≤ 19,999,999,800 分（= 200 行 × 单行上限；多收也不能超过它）；
  - 件数 `pack_count` ≤ 99,999；`pack_qty` ≤ 9,999；**基本单位数量**（件数 × 换算、盘点数、期初数、处理快过期时的实际数、扔掉和退货的数量）≤ 9,999,999；`base_qty`（账面数，可以为负）绝对值 ≤ 9,999,999；
  - 一笔卖出 ≤ 200 行；除 `base_qty` 外数量和金额不为负。
  - 进货件数 `pack_count` ≥ 1（0 件时 `b = roundDiv(T, 0)` 无定义）：`ops.schema.json` 不改，服务器在应用时判，拒 `invalid` 并留档；`limits.json` 有对应的一组，手机同样拦。卖出行 0 件不拒（§14 S05-3）。
  - 算出来的结果也要存得进列：新的 `stock_qty`（`integer`）和 `stock_value_fen`、各行金额（`bigint`）用 `BigInt` 算完再比；金额、货值、成本还要能按契约 `SignedFen` 下发（JSON 安全整数 ±(2^53−1)），与 `bigint` 取两者更严。超出拒 `invalid` 并留档，在写库之前判；过了这一层写库时再出 22xxx 的记账 op 整个请求 500（§14 S05-4）。
  - 在这些上限内，JSON 数字不超过 2^53，分摊的中间乘积 `2 × L_i × P + L` 不超过 2^63。「件数 × 换算」「件数 × 单价」这类乘积上限 JSON schema 表达不了，由服务器在应用 op 时校验。
- S01 的向量要覆盖：负数的 `roundDiv`、恰好一半、上限值、全零购物篮、接近溢出的中间乘积。

### 5.1 优惠分摊（服务器 + 手机各实现一遍，向量一致）

设各行原价 `L_i`（= 单价 × 件数），合计 `L`，实收 `P`。
0. `L = 0`（全是零价商品）：`P` 必须为 0，各行都是 0，不进入下面的公式；界面上改价按钮不可用。
1. `a_i = roundDiv(L_i × P, L)`。
2. `d = P − Σa_i`，把 `d` 加到原价最大的那一行（并列取最前一行）。
3. 若该行因此小于 0（只在极端输入下出现），把不足部分依次摊给下一大的行。

结果：`Σa_i = P`，逐分相等。必过向量：原价 25.00 / 24.00 / 4.50（合计 53.50），实收 53.00 → **24.76 / 23.78 / 4.46**（设计稿 08）。多收（`P > L`）用同一公式。
- 抹零面板规则（18、28）：实收低于原价七折，或高于原价，弹二次确认；快捷键「抹到整元」「抹到整十」。
- 利润按实收算。撤销单行退的是该行的 `amount_fen`（摊后）和当时记下的 `cogs_fen`。

### 5.2 移动加权平均

每个商品四个量：`q = stock_qty`，`v = stock_value_fen`，`c = last_cost_fen`，`k = cost_known`（进价是否已知）。**「没填进价」和「进价就是 0」是两回事，只看 `k`，不从 `q` 的正负或 `v` 是否为 0 去猜。** `k` 为假时 `v` 恒为 0。记当前单位成本 `u = roundDiv(v, q)`（`k` 为真且 `q > 0` 时），否则用 `c`。

- **进货** `n` 个基本单位、总价 `T`（整件码先换算：5 箱 × 24 = 120 罐），这批单位成本 `b = roundDiv(T, n)`：
  - `k` 为真且 `q > 0`：`q += n; v += T; c = b`。
  - 否则（`q <= 0`，或进价一直没填）：`q += n`；目标货值 = `q > 0 ? roundDiv(T × q, n) : q × b`；进货行照记 `value_delta = T`，再记一条 `cost_adjust` = 目标货值 − (`v + T`)；`v` = 目标货值，`c = b`，`k = 真`。**差额为 0 时不记这一条**（通则：金额为 0 的 `cost_adjust` 一律不记；没有可补记行的 `cost_fix` 也不记）。
  - `n = 0`（进货 0 件）：拒 `invalid` 并留档，什么都不记（§14 S05-3）。
- **卖出** `n` 个：
  - `k` 为假：`cogs = 0`，`cost_missing = true`，`value_delta = 0`，只减数量。这行不进「赚了」，报表写「有 N 样进价没填」。**库存是正的也一样。**
  - `k` 为真且 `q > 0`：`take = min(n, q)`；`cogs = (take = q ? v : roundDiv(v × take, q)) + (n − take) × u`；若 `n >= q` 则 `c = u`。然后 `q −= n; v −= cogs`。
  - `k` 为真且 `q <= 0`：`cogs = n × c`；`q −= n; v −= cogs`。
- **整件卖**：卖价用整件码自己的价，成本 = 换算后的基本单位数按上面算。
- **期初库存 / 待确认补全**（数到 `N`；`opening` 的进价 `b` 可不填，`product_review_complete` 的进价**必须填**，可以填 0）。**按期初记，不算进货**（review 四-2）：
  - 填了进价（包括明确填 0）：`k = 真，c = b`，货值设为 `N × b`，数量设为 `N`；差额写在 `opening` 流水的 `qty_delta / value_delta_fen`。
  - 没填进价：若 `k` 已经为真，这一条就是一次盘点：流水类型记 **`count`**（不是 `opening`），金额按盘点规则算，月报算在「盘点少了的」里；否则只把数量设为 `N`，`v` 保持 0，`k` 保持假，界面黄字提醒。
- **成本补记**（进价从「没填」变成「已知」的那一刻，`b` 为这次得到的单位成本）：把这个商品此前所有 `cost_missing`、未撤销、未补记过的卖出行找出来，记**一条** `cost_fix` 流水：`amount_fen` = 这些行的实收合计，`cogs_fen` = 这些行的数量合计 × `b`，`qty_delta = 0`，`value_delta_fen = 0`，`occurred_at` = 现在；`unit_cost_fen` 存 `b`；原行写上 `cost_fix_entry_id`，原行本身的 `cogs_fen / value_delta_fen` **不改**。不做「回填原行」。
  - 这些货从来没进过货值（当时 `v = 0`），所以对账不受影响；利润在补记那天一次性计入（与「撤销算在撤销那天」同一原则，过去月份的数字不变）。
  - 补记过的卖出之后被撤销，共三条流水：正常的冲销行（只加回数量）；一条冲销的 `cost_fix`（该行的 −实收、−数量 × `b`，`b` 取自当初那条 `cost_fix` 的 `unit_cost_fen`）；一条 `cost_adjust`（+数量 × `b`）。最后这条是让回到货架的货按补记的进价计入货值，否则货值不变、数量变多，平均进价被拉低，以后的卖出会少记成本。先撤销、后补进价：已撤销的行不参与补记。
  - **`k` 只增不减**：撤销那次让进价变成已知的进货或期初，`k` 不回到假，`c` 保留，已经记的 `cost_fix` 不冲；撤销后按下面「撤销」一条的归位规则处理。
- **盘点** 数到 `N`（`N >= 0`），`d = N − q`（并发规则见 §5.6）。**`d = 0`（点「没错」）也要记一条 `count` 流水**，数量和金额都是 0、不标 `cost_missing`（不论进价是否已知）：盘点进度「已数 N 种」和 `last_count_at` 都靠它。这是「金额为 0 不记」通则之外的，那条通则只管 `cost_adjust` 和 `cost_fix`。`d ≠ 0` 时：
  - `k` 为真且 `q > 0`：盘亏金额 = `N = 0 ? v : roundDiv(v × |d|, q)`；盘盈金额 = `d × u`。
  - `k` 为真且 `q <= 0`：货值设为 `N × c`，差额即盘盈金额。
  - `k` 为假：只改数量，金额为 0。
- **过期扔掉、退给供货商** `n` 个：成本取法与卖出相同。扔掉记损耗，**不减「赚了」**，在报表「过期损耗」单列；退货不计盈亏。
- **进价未知（`k` 为假）时的非卖出流水**：过期扔掉、退货、数量有变化的盘点，金额都记 0 并标 `cost_missing = true`（数量没变的盘点不标）；它们**不参加成本补记**（补记只针对卖出），报表在对应的损耗行旁注明「有 N 笔没算进价」。没填进价的 `opening` 不标。
- **撤销**：卖出 → 加回数量和当时记下的 `cogs`；进货 → 减去数量和总价；其余类型同理取反。撤销后若违反 I3，用一条 `cost_adjust` 归位，**归位目标统一是 `v = q × c`**：`k` 为真，且（`q <= 0` 而 `v ≠ q × c`，或 `q > 0` 而 `v < 0`）时触发。`q > 0` 且 `v >= 0` 时不动。
- 必过向量：
  - 库存 6 包、货值 ¥242.80，进 5 条 × ¥400（1 条 = 10 包）→ 56 包，这批每包 ¥40.00，平均 **¥40.05**。
  - 可乐 5 箱 × ¥48（1 箱 = 24 罐）→ 一共 ¥240.00，入账 120 罐，每罐 ¥2.00（设计稿 06a）。
  - 库存 −1（已知进价）、进 3 个共 100 分 → 新库存 2，货值 `roundDiv(100 × 2, 3)` = 67 分，差额进 `cost_adjust`。
  - 期初 10 个没填进价，卖 1 个 → `cogs = 0`、`cost_missing`、不进「赚了」；随后补进价 ¥2.00 → 一条 `cost_fix`，货值 = 9 × 2.00。
  - 明确填进价 0 的赠品：卖出 `cogs = 0`、**不**标 `cost_missing`。
  - 库存为 0、已知进价 ¥3.00，盘点数到 2 → 货值 ¥6.00。
  - 撤销归位（库存为正、货值为负）：进 10 个共 1000 分，再进 10 个共 100 分，卖 5 个（`cogs` 275），撤销第一次进货 → `q = 5`，`v = −175`，`c = 10` → 归位到 `v = 50`，`cost_adjust` +225。
  - 补记后撤销：期初 10 个没填进价，卖 1 个、再卖 2 个，补进价 ¥2.00（货值 1400），撤销卖 2 个的那笔 → 冲销 `cost_fix`（−400）加 `cost_adjust` +400，货值 1800，9 个，平均仍是 ¥2.00。

### 5.3 对账与报表口径

- 本月对账（设计稿 10）：`月初货值 + 本月进货 − 卖掉的货的进价 − 盘点少了的 − 过期扔掉的 − 退给供货商的 (± 期初登记和调整，非零才显示这一行) = 月末货值`（设计稿上写「现在店里货值」，口径见下面 S07-4 一条）。**每一项都是 `entries.value_delta_fen` 按类型的分组求和**（「卖掉的货的进价」= 卖出行 `value_delta_fen` 之和取负，不是 `cogs_fen` 之和），所以等式恒成立。
- 赚了 = Σ 进价已知的卖出行 `(amount_fen − cogs_fen)` + Σ `cost_fix` 行 `(amount_fen − cogs_fen)`。尚未补记的 `cost_missing` 卖出行不计入，并在报表上计数；标了 `cost_missing` 的损耗行另行计数（§5.2）。卡片下写「赚了 = 卖出 − 进价，损耗和盘点少的另算」。
- 卖了 = Σ 卖出行 `amount_fen`（`cost_fix` 行的 `amount_fen` 不算进「卖了」，否则重复）。
- 优惠 = Σ 卖出行（含冲销行）`(list_amount_fen − amount_fen)`。只对卖出行求和：`cost_fix` 行的 `list_amount_fen` 是 0，算进去是负优惠（§14 S07-2）。
- `cost_missing` 计数只算未撤销的原行，卖出还要 `cost_fix_entry_id` 为空；顶层 `cost_missing_count` 是商品种数，对账各行是笔数。卖出事后被撤销或补记，过去那天的计数跟着减少；计数只是提醒，金额不受影响（§14 S07-3）。
- 月末货值一律是「下月第一刻之前全部流水的 `value_delta` 之和」，本月也一样，不说「本月 = 现在」：时钟超前 5 分钟以内又跨月的流水算在下个月，这几分钟里本月月末比商品投影少这一笔，本月月末 = 下月月初照样成立。`opening_and_adjust` 非零才出现，`cost_fix` 不单列并断言为 0（§14 S07-4）。
- 「记了 N 笔」：一次记账算一笔 = 当天原行（非冲销行）的不同 op 个数，不算 `cost_adjust`。卖出、进货、盘点、期初、扔掉 / 退货、补全都算；撤销本身不算；记了又撤销的那笔仍算；迟到补偿行、当场写的 `cost_fix` 和主流水同一个 op，算同一笔。09 和 07c 用同一个口径（§14 S07-1）。
- 「快没货」：没停用、不是待确认（`NOT needs_review`）、`stock_ver > 0`、`stock_qty ≤ COALESCE(low_at, low_stock_default)`。待确认商品的库存没人数过，只在「待确认」里提醒；库存 ≤ 0 的正式商品照列，手机显示「没货了」。「快没货 / 快过期」是现在的状态，与所选日期无关（§14 S07-6）。
- 日和月的界线按 `occurred_at` 的上海时间（Postgres 的 `Asia/Shanghai`，日界线和归日用同一份时区数据，1986–1991 年夏令时也一致）。查询日期接受 0001–9999 年的合法日历日，覆盖全部能入账的日子（§14 S07-8）。

### 5.4 保质期批次（只管提醒）

- 管保质期的商品，每次进货 / 期初生成一个批次；没填到期日也生成（`expiry_date = null`，不提醒）。到期日两种填法：直接填；或生产日期 + 保质期月数（按日历月加，月末对齐：1/31 + 1 个月 = 2/28 或 2/29）。必过向量：2026-11-12 + 6 个月 = 2027-05-12；2026-11-19 + 12 个月 = 2027-11-19。
- 卖出、盘亏按到期日从早到晚扣批次（空日期排最后），写 `lot_moves`。到期日相同（或都为空）的批次，先扣先建的（来源流水 `seq` 小的在前）。
- 期初 / 待确认补全新建一个批次，数量 = 数到的数，不扣也不改已有批次。旧批次可能多提醒，这是安全的方向，处理时以人数的为准（§14 S06-3）。
- 迟到补偿（§5.6 第 4 条）：被补偿的迟到卖出不扣批次、不写 `lot_moves`（盘点的盘亏已经扣过一次，再扣会让提醒提前消失）。迟到的进货照常建批次，迟到的扔掉 / 退货照常关批次，迟到的撤销照常按 `lot_moves` 加回。补偿行本身不动批次（§14 S06-10）。
- 提醒：`今天 >= expiry_date − expiry_warn_days`，批次未关闭、`qty_left > 0`、不在「过几天再提醒」期内。`今天 < snoozed_until` 才算在期内，**到 `snoozed_until` 当天就恢复提醒**。首页黄条数的是**商品种数**。
- **处理时一律以人数的为准**（20、20b）：先填「货架上这批实际还有几个」，再选：卖完了（关批次，不动库存）/ 下架扔掉（记 `expire_loss`，数量 = 实际数）/ 退给供货商（记 `supplier_return`）/ 还在卖过几天再提醒（批次数量改成实际数，`snoozed_until = 今天 + 天数`）。批次数量之和**不强求**等于库存，批次不准不会把账带歪。
- **防两台手机各处理一次**：每个批次有 `handle_ver`，只在「处理」和「过几天再提醒」时 +1（普通卖出扣批次不改它）。`expiry_dispose / lot_snooze` 带手机看到的 `handle_ver`；批次已关闭或版本不一致 → 拒 `stale`，手机刷新后让人重新确认。重开批次不改 `handle_ver`；`lot_snooze` 的「今天」= op 的 `occurred_at`（时钟校正后）所在的上海日期（§14 S06-5）。
- 处理时的记法：三种处理关批次时都不改 `qty_left`；扔掉 / 退货不写 `lot_moves`，`lot_id` 和处理前的 `qty_left` 存在流水 `flags`；卖完了不记流水，不占 `entry_id`（所以不能撤销）（§14 S06-4）。
- **批次的生命周期**（`closed_at` 只由下面两种情况设置；卖到 `qty_left = 0` 不算关闭，只是不再提醒）：

| 事件 | 对批次的影响 |
|---|---|
| 处理为卖完了 / 扔掉 / 退货 | 关闭，`closed_reason = disposed`；处理前的 `qty_left` 记在流水的 `flags` 里 |
| 撤销「扔掉」或「退货」 | 库存加回；批次重新打开，`qty_left` 恢复为处理前的值，重新参与提醒 |
| 撤销卖出 | 按 `lot_moves` 原样加回；若对应批次已关闭，则这部分不加回、也不重开（批次只管提醒） |
| 撤销来源进货 | 这次进货生成的批次关闭，`closed_reason = voided`；已经从这批扣过的 `lot_moves` 保留不动。按 `source_entry_id` 找批次，不看流水类型（没填进价的期初可能记成 `count`，§14 S06-6） |
| 扔掉 / 退货之后来源进货被撤销，再撤销扔掉 / 退货 | 库存照常加回；批次不重开，`closed_reason` 改成 `voided`，`qty_left` 恢复为处理前的值（§14 S06-7） |

### 5.5 手输条码匹配（review 四-1）

本地前缀匹配：输入满 8 位起，列出**所有**条码以输入为前缀的候选；只剩一个候选时才自动选中；未选中时主按钮置灰。绝不自动选第一个。

- 候选按「商品 + 换算数量 + 这一件的卖价 + 单位名」去重（与购物篮合并键相同，§14 S12-2 / S13-2；前缀匹配、名称搜索、购物篮都用它）：同一商品的两个单件码算一个候选；同一商品的单件码和整箱码是**两个**候选（卖的数量和价钱不同，行上要写明「罐」还是「箱（24 罐）」）。
- 一个候选有多个条码都匹配时（同一商品的两个单件码），取一个**代表条码**用来排序、显示和加入购物篮：有与输入完全相等的就取它，否则取匹配条码里字符串最小的。
- 排序：按代表条码，与输入完全相等的排第一，其余按字符串升序。最多显示前 4 行，超过时提示「还有 N 个，接着输」。
- 输入正好等于一个 8 位码、同时又是更长条码的前缀时：两个都列出，不自动选（完全相等的排第一）。

其他：收银员看到的候选行不带库存。`contracts/vectors/prefix.json`：同厂商两个商品（6902514300011、6902514300028），输入 `69025143` 时两个都列出。

### 5.6 盘点、期初与别的手机同时记账

问题：A 数到 10 个，这期间 B 卖了 2 个；如果 A 的盘点晚到并把库存设回 10，就吞掉了 B 的两个。反过来，一笔盘点前发生、盘点后才传上来的卖出，会被多扣一次。规则：

1. **盘点、待确认补全、对已有商品的期初，只能联网提交，不进离线队列。** 手机先把自己的 outbox 传完，再发这一条。没网时这些页面提示「要联网才能盘点」。
2. op 带 `base_ver`（当时的 `products.stock_ver`；每次库存变动 +1）和 `base_qty`（数的时候账上显示几个）。**服务器只比对 `base_ver`**，`base_qty` 只用来留档和排查，不参与判断：`count` 两个都必带；`product_review_complete` 必带 `base_ver`，`base_qty` 可选；`opening` 两个都可选，但受第 3 条约束。服务器发现 `stock_ver` 已经变了 → 拒 `stale`，带回最新账面数。手机显示「刚才别的手机又记了账，账上现在是 8 个。你数的 10 个还对吗？」，确认或改数后带新版本重发。
3. **新商品登记第二步的期初**可以离线（商品是新的，没有可冲突的账面数），随 `product_upsert` 一起排队，不带 `base_ver`。服务器的判断办法（schema 判断不了商品新旧）：**不带 `base_ver` 的 `opening` 只在这个商品的 `stock_ver = 0`（还没有过任何库存变动）时接受**，否则拒 `stale` 并带回最新账面数，提示重新数；带了 `base_ver` 的按第 2 条比对。条码其实已被别的手机登记（发生别名合并）时，赢家商品通常已有库存变动，自然落入被拒这一支。
   因此**每次库存变动**（卖出、进货、期初、撤销等任何改 `stock_qty` 的流水）`stock_ver + 1`，期初和盘点写 `last_count_at`。`last_count_at` 只往后走：`occurred_at` 更早的期初 / 盘点（版本对得上才会进来）不把它拉回去（§14 S06-11）。`opening` 的第 2、3 条由 S05b 实现；第 4 条、`count / product_review_complete` 的校验和批次在 S06（§14 S05-2）。
4. **迟到的流水**：任何影响库存的 op 入账时，如果它的 `occurred_at` 早于这个商品最近一次盘点 / 期初的时间（`products.last_count_at`），说明数的时候这些货已经不在货架上了。处理：流水照常入账（收入、成本照记），同时自动追加一条 `count` 类型的补偿流水（数量和货值正好抵消这笔流水对库存的影响，`flags.late_before_count`），库存保持为盘点得到的数。效果：原先被算成盘亏的那几个，改由这笔卖出解释。
   - 口径（§14 S06-8）：补偿行 = −（这一步全部流水的数量合计、货值合计，含 `cost_adjust`），`cogs = −value_delta`；`k` 为假且数量有变化时标 `cost_missing`；`q` 回到这一步之前，`c、k` 用之后的值；违反 I3 时补一条 `cost_adjust` 归位到 `q × c`，也标 `late_before_count`；这一步让 `k` 由假变真时，不论库存正负，补偿后的货值都归位到 `q × c`；收入、成本、`cost_fix` 照记。范围检查（§5.0、§14 S05-4）针对补偿后的最终状态和全部流水，不针对补偿前的中间状态。
   - 适用范围（§14 S06-9）：卖出、进货、撤销、扔掉 / 退货；`count / opening / product_review_complete` 本身不补偿。严格早于才算迟到，相等不算。补偿行与主流水同一个 op、同一台设备、同一个 `occurred_at`，`seq` 相邻。撤销发生在盘点之后的不补偿，库存 = 盘点数 + 退回的数（§14 S06-11）。
   - 批次（§14 S06-10，§5.4）：被补偿的迟到卖出不扣批次、不写 `lot_moves`；补偿行不动批次；家用可以撤补偿行，收银员不能。
5. 不做「盘点期间暂停其他手机记账」，店里不能因为有人在盘点就卖不了东西。

---

## 6. 权限矩阵

三种身份：**家用**（家用号登录或扫家人码的设备）、**收银员**（扫收银员码的设备）、**审核**（审核号登录的设备；权限同家用，但只在演示小店内，演示小店里也能开通演示用的收银员设备）。机器可读版在 `contracts/permissions.json`，服务器的 `guard` 中间件和两边的测试都读它。

三条实现原则：① 权限在服务器上判，界面隐藏只是体验；② 进价、货值、库存不下发到收银员手机；③ 收银员撤销「自己当天」的判断不信手机填的时间：必须是同一设备记的卖出，且这笔卖出的日期（上海时区）等于**服务器收到撤销请求那天**。离线撤销当天传上来照常生效；隔天才传上来的被拒，提示让家里人撤（这一条取代 review-1119 §5.1 第 3 点「按手机上记录的时间算」）。

库存和进价「看不看得到」不在下表单列一行：它由 `sync:pull` 那一格的 `scope`（全店 / 裁剪版）推出，ShopCore 给一个单独的判断（`DataVisibility`），界面和本地库都用它，不借用「能不能进货」这类能力来猜（§14 S12-3）。

### 6.1 接口

| 接口 / op | 家用 | 收银员 | 审核（演示店内） | 被踢设备 |
|---|---|---|---|---|
| `POST /v1/auth/login`、`/pair/redeem`、`GET /v1/config` | 不需登录 | 不需登录 | 不需登录 | — |
| `POST /v1/sync` 推 `sale_batch` | 能 | 能 | 能 | 只收被踢前的 |
| 推 `void` | 任意一天、任意手机 | 只能本机的卖出，且卖出日期 = 服务器收到撤销那天 | 同家用 | 暂存，等家用确认 |
| 推 `product_upsert` | 完整；条码已存在时不改原商品 | 只能 `quick`（名称 + 卖价）；条码已存在时不改原商品 | 同家用 | 被踢前的：`quick` 直接收，非 `quick` 暂存等家用确认 |
| 推 `product_edit / barcode_link / barcode_unlink / stock_in / opening / product_review_complete / count / expiry_dispose / lot_snooze` | 能 | **拒** | 能 | 暂存，等家用确认（§4.5） |
| `POST /v1/sync` 拉 | 全店 | 裁剪版（§4.2） | 演示店全店 | 不返回数据 |
| `GET /v1/barcode-lookup/:code` | 能 | 能（只返回名称、规格、有没有图） | 能（演示店返回内置假数据，**不调付费接口**） | 拒 |
| `GET /v1/images/:product_id` | 能 | 能 | 能 | 拒 |
| `GET /v1/barcode-lookup/:code/images`、`/images/:cid`（候选，S22d） | 能 | **拒** | 能（演示店恒为空 / 404） | 拒 |
| `POST /v1/images/:product_id/select`、`PUT /v1/images/:product_id`（选图、拍照，S22d） | 能 | **拒** | 演示店 403 | 拒 |
| `GET /v1/reports/*`、`GET /v1/entries*` | 能 | **拒** | 能 | 拒 |
| `POST /v1/pairing-tokens`、`GET /v1/pairing-tokens/:id` | 能 | 拒 | 能 | 拒 |
| `GET /v1/devices`、`POST /v1/devices/:id/revoke`、`/revoke-others` | 能 | 拒 | 能 | 拒 |
| `GET /v1/held-ops`、`POST /v1/held-ops/:id/resolve` | 能 | 拒 | 能 | 拒 |
| `PATCH /v1/devices/me`（改手机名） | 能 | 拒（称呼由家里人定） | 能 | 拒 |
| `POST /v1/account/password` | 能 | 拒 | 能（每天重置时恢复） | 拒 |
| `POST /v1/account/delete-request` / `delete-cancel` | 能 | 拒 | 能（每天重置时恢复） | 拒 |
| `POST /v1/auth/logout` | 能 | 能 | 能 | — |
| `GET /v1/me` | 能 | 能 | 能 | 拒（返回 `revoked`） |
| `POST /v1/recovery/import` | 仅恢复模式打开时能 | 仅恢复模式打开时能 | 拒 | 拒 |
| `GET /healthz`、`POST /v1/auth/demo`（开关打开时） | 不需登录 | 不需登录 | 不需登录 | — |

`/v1/recovery/import` 里的每个 op 仍按提交设备的角色过上面的 op 权限。权限表里不允许留「待定」的格子。

状态码（§14 S03-2）：身份无权 → `403 {code: forbidden}`；没带令牌或令牌不认识 → `401 {code: unauthorized}`；被踢设备调任何 HTTP 接口 → 统一 `401 {code: revoked}`。唯一的例外是 `/v1/sync`：照 §4.5 正常响应并带 `device.revoked=true`，`discard_outbox` 也只由它下发。表里「—」的格子按拒处理，所以被踢设备调 `logout` 也是 `401 revoked`，手机把它当作退出成功。

跨店隔离：任何接口都只能碰令牌所属的店。S09 有专门测试：用审核号令牌把元辉店的每一种 id 都试一遍，全部 404 / 拒绝。id 的命名空间是按店的（§14 S02-8）：引用元辉店 id 的「新建」类 op（同一个 id 在演示店里还没有）在演示店里按新行 `applied`，只在演示店里落行，元辉店逐行不变，这是设计如此，不算越权（§14 S09-14）。

### 6.2 页面（设计稿编号）

| 页面 | 家用 / 审核 | 收银员 |
|---|---|---|
| 13 登录、14 扫码登录、27b、25c、25d | 有 | 有（只会用到 14） |
| 16 选字号 + 起名 | 16 | 16b（不起名） |
| 29 首次同步 | 有 | 有 |
| 首页 | 01（卖出、进货、看账/商品/更多、黄条、刚记的） | 02（只有卖出、我刚记的、齿轮） |
| 03 系列卖出、15/15b 手输、18/28 抹零、27a | 有 | 有（候选行和价签不带库存） |
| 新商品登记 | 04a → 04b，05 整件码 | 04c（只填名称和卖价） |
| 06 系列进货 | 有 | **没有入口** |
| 记的账 | 07a、07c（任意一天） | 07b（本机当天的卖出） |
| 08 撤销 | 有 | 有（限本机当天） |
| 09 / 10 看账，11 / 22 / 22b 商品，12 盘点，19 / 20 快过期 | 有 | **没有入口** |
| 17a / 17b 开通，已登录的手机，账号与密码，23 注销 | 有 | 没有 |
| 设置 | 21a | 21b（大字模式、扫码枪、隐私政策、退出登录、版本） |
| 25b / 25f 被踢 | 25b | 25f |

---

## 7. API 列表（前缀 `/v1`，JSON，`Authorization: Bearer <设备令牌>`）

| 方法 路径 | 用途 | 备注 |
|---|---|---|
| `GET /healthz` | 存活检查（查一次数据库） | 无鉴权，监控用。路径不带 `/v1`（不随接口版本变）；S00 骨架里的 `/v1/health` 在 S02 改成它 |
| `GET /v1/config` | `min_build, demo_login_enabled, privacy_url, support_url, product_images_enabled`（T11，S22d 落地）；S21 起加可选的 `api_base`（服务器地址下发，11/21） | 无鉴权 | App 只采用白名单内的主机，见 S21。
| `POST /v1/auth/login` | `{username, password, device_id, label?}` → `{token, role, store, label, epoch, delete_pending_until?}` | 连错 5 次锁 15 分钟（25c）：第 5 次输错本身就返回 `423 locked`（带 `locked_until`）；锁定期内再输错不计数、不延长；上锁时计数清零，成功登录清零；并发也要守住（验对密码后在事务里重查锁，已锁返回 423 且不清锁）。按 IP 限速：每 IP 15 分钟 30 次，超了 `429 rate_limited` 带 `retry_after_s`（§14 S03-3）。错误信息不区分「账号不存在」和「密码错」 |
| `POST /v1/auth/pair/redeem` | `{code, device_id}` → 同上 | 码用过 → `410 pairing_used`；过期、或出码的手机已被撤销 → `410 pairing_expired`（25d）；账号在注销申请期间 → `403 delete_pending`（先判 410 再判 403；申请注销时未用的码已作废，403 只是兜底）。按 IP 限速同登录，单独计数（§14 S03-1、S03-3、S03-5） |
| `POST /v1/auth/demo` | 一键进演示小店（「看看演示」，受 `demo_login_enabled` 开关控制，**默认关**，被打回再开） | 发的是演示店的家用设备令牌，响应同登录（带 `epoch`）。进最早建的演示店的审核号；没有演示店 → `404 demo_disabled`。每次新建一行设备，由 S09 每日重置清理。按 IP 限速同登录，单独计数（§14 S03-3、S03-9）。审核号在注销申请中时：照样建设备，响应带 `delete_pending_until`，写账整批不应用，每日重置撤回申请（§14 S09-16） |
| `POST /v1/auth/logout` | 作废本机令牌 | 手机先尽量把 outbox 传完 |
| `GET /v1/me` | 角色、店名、设备名、注销状态 | |
| `POST /v1/sync` | 推 op + 拉变更（§4） | 平时唯一的写账入口。请求体超过 1 MiB → `413 invalid`；本店排队超过上限 → `503 unavailable` 带 `retry_after_s`；`epoch` 不一致 → `409 epoch_mismatch`；账号注销申请期间 op 不应用、`results` 为空、响应带 `delete_pending_until`（§4.2） |
| `GET /v1/barcode-lookup/:barcode` | 查名称（先查 `barcode_catalog`，没有再调快鸟，2 秒超时） | 每设备每分钟 20 次；每店每天 1000 次上限（11/23 由 300 改为 1000），防止刷掉付费额度 |
| `GET /v1/images/:product_id?v=` | 200px 小图 | 强缓存；本地磁盘缓存，缺了回源 OSS |
| `GET /v1/barcode-lookup/:barcode/images` | 商品图候选 `{state: none\|pending\|ready, ids}`（S22d） | 供轮询；每设备每分钟 60 次。平时只读库、不调快鸟；一张能用的候选都没有、条码库地址已过期（取到超过 2 小时）时重新问一次快鸟再登记（每条码每天一次、占本店查码额度，S22d-15）。查码响应（家用 / 审核）同样带 `image_candidates`，`has_image = state != none` |
| `GET /v1/barcode-lookup/:barcode/images/:cid` | 一张候选缩图 | 强缓存一年，`nosniff` + CSP |
| `POST /v1/images/:product_id/select` | `{barcode, candidate_id}` → `{image_ver}` | 条码须在本店挂在这个商品上、候选 ready；复制成正式图，`image_ver`+1、取新 `rev`；内容相同不升版本 |
| `PUT /v1/images/:product_id` | JPEG 裸体（≤ 1 MB）→ `{image_ver}` | 只收 JPEG，按 EXIF 转正、去全部元数据，存 200px；超 1 MB 413、格式不对 400 |
| `GET /v1/reports/today?date=` | 09：卖了、赚了、优惠、卖得最好、快没货、快过期 | 在线才能看 |
| `GET /v1/reports/month?month=` | 10：三张卡、优惠和过期损耗、每日柱状图、对账各行 | |
| `GET /v1/entries?date=` | 07a 某一天的流水（超出手机本地 35 天时用） | |
| `GET /v1/entries/days?before=&limit=7` | 07c 每天一行：日期、笔数、金额 | |
| `POST /v1/pairing-tokens` | `{role, label?}` → `{id, code, expires_at}` | 二维码内容 = `YHZB1:<code>`；收银员码必须带称呼 |
| `GET /v1/pairing-tokens/:id` | 出码手机轮询「对方扫了没有」 | |
| `GET /v1/devices` | 已登录的手机：名字、身份、最近使用 | |
| `POST /v1/devices/:id/revoke` | 让它退出 | 不能踢自己（自己用退出登录） |
| `POST /v1/devices/revoke-others` | 让其他手机全部退出 | |
| `GET /v1/held-ops` | 被退出的手机补传上来、等确认的账（进货、盘点、撤销等，§4.5） | 只有家用 |
| `POST /v1/held-ops/:id/resolve` | `{action: accept\|discard}` | 盘点、期初类版本已变的只能丢弃 |
| `POST /v1/recovery/import` | 服务器恢复模式下，重新开通的家用或收银员设备补交保留的 op（§4.6） | 平时关闭；每个 op 仍按该设备的角色判权限 |
| `PATCH /v1/devices/me` | 改这台手机的名字 | |
| `POST /v1/account/password` | `{old, new}` | 不强制其他手机退出。原密码输错不计入登录锁定（否则一台家用手机能把登录锁死），但按账号限速：15 分钟内错 5 次后 `429 rate_limited` 带 `retry_after_s`，与 `delete-request` 共用一个计数；限速期内正确密码也是 429（§14 S03-8） |
| `POST /v1/account/delete-request` | `{password}` → 记 `delete_requested_at`，全部设备退出 | 原密码输错的限速同上一行，共用计数（§14 S03-8）。注销期间禁止写账和开通设备；非演示店先生成导出包交给黄总；7 天后删除在线数据和 OSS 图片，备份在此后 35 天内滚动清除（§9.4） |
| `POST /v1/account/delete-cancel` | 7 天内用账号密码登录后撤回 | 恰好第 7 天整仍可撤回；过了 7 天、还没真正删除的这段空档里不能撤回，返回 `409 not_delete_pending`。手机看到 `delete_pending_until` 已过就显示「正在删除」，不给撤回按钮（§14 S03-4） |

静态页（Caddy 直接出，备案后才上线）：`yuanhuishop.cn/`（本店简介）、`/privacy`、`/support`、`/review-barcodes`（审核用条码图页）。

---

## 8. 分段开发计划

共 **39 段**，分五个阶段。A 是地基；B（服务器）和 C（iOS 离线界面）互不依赖，可以两条线同时开；D 把两边接起来；E 是发布。C 阶段全部用假数据和本地库，不需要服务器和域名，随时可以装到手机上给黄总看。

每段只承诺一个能独立验收的完整结果。35 次工具调用是切分的参考，不是完成标准：验收没过就是没完成，不能把下游依赖的东西以「剩余写进 PR」的方式留成半成品；确实做不完时，把这一段再拆成两个都能独立验收的 PR。

依赖总览（箭头左边先做）：
```
S00 → S01 ─┬→ S02 → S03 → S04 → S05 → S06 → S07
           │        S03 → S10a → S10b → S10c
           │        S04 → S08          S06 → S09
           └→ S11 → S12 → S13 → S15 → S16 → S17 → S18 → S19 → S20
                    S11 → S14 ───────┘
S10a + S11 → S11b（空壳 Beta 探针，越早越好）
S03 + S13 + S15 → S21
S21 + S06 + S20 → S22a → S22b → S22c（S22c 另需 S08）
S22b → S23a → S23b（S23b 另需 S09）
S22a + S07 → S24      S22a + S18 → S25      S22a + S17 → S26      S22a + S19 → S27
S23a + S24…S27 → S28
S10c + S11b + S23a + S28 → S29
S09 + S23b + S29 → S30 → S31（等备案）→ S32
```

每段的「设计稿」列的是 `docs/design/png/` 里的文件名前缀。

### 阶段 A：地基

**S00 仓库、CI、评审流程**
- 目标：在 `clawchitu/yuanhui-zhangben` 建好骨架，两条 CI 能跑，评审状态检查生效。
- 产出：仓库根目录文件、`CLAUDE.md`、`docs/`（复制本计划和 53 张图）、`.github/workflows/server.yml`（GitHub 托管 Linux runner，起 Postgres 服务容器跑 `npm test`）、`ios.yml`（这台 Mac 上的自托管 runner：`xcodegen` + `xcodebuild test`）、PR 模板、`server/` 和 `ios/` 各一个能通过的空测试、分支保护设置脚本 `scripts/protect-main.sh`。两条工作流对每个 PR 都触发，在 job 内按改动路径决定是否跑重任务，始终产出固定名称的最终检查（§2.1）。
- 验收：开三个示例 PR（只改文档、只改 `server/`、只改 `ios/`），每个都能在两条必需检查都变绿后合并，没有检查停在 Pending；没有 `review/codex`、`review/fable` 状态时不能合并；直接推 `main` 被拒。
- 前置：Chitu 建好私有仓库、在本机注册自托管 runner。

**S01 契约与测试向量**
- 目标：把 §3–§7 落成两边都能读的文件，之后服务器和 iOS 才能并行。
- 产出：`contracts/openapi.yaml`（§7 全部接口）、`ops.schema.json`（§4.3）、`permissions.json`（§6.1，含被踢设备一列）、`vectors/allocation.json`（≥12 组，含 53.50→53.00、多收、单行、并列最大、1 分钱、**全零购物篮**、上限值）、`cost.json`（§5.2 每条规则至少一组逐步用例，含全部必过向量、负库存、进价未知的正库存、真实零成本、成本补记前后撤销）、`rounddiv.json`（负数、恰好一半、接近 2^63 的中间乘积）、`expiry.json`、`prefix.json`。
- 验收：CI 里校验 openapi 和 schema 语法；每个向量文件有 README 说明字段；两位评审逐条对照 §5 核过数字（这一段的评审比代码重要）。

### 阶段 B：服务器

**S02 服务器骨架与全部表结构**
- 产出：`app.ts / config.ts / db.ts`、`migrations/0001_init.sql`（§3 全部表、约束、索引）、`scripts/create-store.ts`、`create-account.ts`、`/healthz`（替换 S00 骨架里的 `/v1/health`）、`/v1/config`、测试辅助（每个测试文件一个独立 schema 或事务回滚）、`Dockerfile`。
- 验收：迁移在空库上跑通且可重复执行；约束测试：重复 `(store_id, barcode)` 失败、`pack_qty=0` 失败、单件码带 `pack_price_fen` 失败、重复用户名（大小写不同）失败、同店重复 `rev` 失败；`/healthz` 在数据库断开时返回 503。

**S03 登录、设备、开通、权限中间件**
- 产出：`auth/*`、§7 中 auth / pairing-tokens / devices / account 全部接口（注销只做申请、撤回和「注销期间禁止写账与开通」，真正删除和导出在 S09）、`guard` 读 `permissions.json`。
- 验收（Vitest）：密码错 5 次锁 15 分钟，锁定期内正确密码也拒；开通码 2 分钟后失效、第二次使用失败、码里的角色决定设备角色；**`guard` 的契约级测试**：对 `permissions.json` 里的每一格（身份 × 接口或 op 类型）断言判定结果，不依赖业务路由是否已经实现；本段已实现的接口再各有一条真实请求的 403 测试（后面每一段新增接口时，各自补上真实请求的越权测试）；踢掉的设备下一次请求得到 `revoked`；A 店令牌访问 B 店任何资源 404；令牌在库里只有哈希；注销申请中的账号开通设备被拒。
- 验收补充（§14 S03-2、S03-3、S03-5、S03-8，已在 PR #8 实现）：并发登录守得住锁定（N 个错密码 + 1 个对密码同时发，结束后账号是锁定的，锁没有被清掉）；改密码、申请注销的原密码输错按账号限速（15 分钟 5 次后 429，两个接口共用计数），不计入登录锁定；被踢设备调 HTTP 接口得到 `401 revoked`；出码设备被撤销后它出的码兑换得 `410 pairing_expired`。

**S04 同步核心：幂等、变更序号、商品类 op、按角色裁剪**
- 产出：`sync/push.ts pull.ts projection.ts aliases.ts`、统一的取号函数，op：`product_upsert / product_edit / barcode_link / barcode_unlink`。
- 验收：
  - 幂等与重放：同一批 op 发 3 次，库里各一条，三次响应内容相同（含 `remap` 和拒绝原因）；同 id 不同 payload → `id_conflict`。
  - 分页：**一个 op 同时改多行，页大小设为 2，逐页拉取的结果集合等于一次拉完的结果**（I7 性质测试，随机页大小）；拉取进行到一半时插入新的写入，最终不漏不重；解除整件码后别的设备收到墓碑。
  - 两条流各自游标：只拉 `catalog` 不影响 `ledger` 游标。
  - 条码冲突：两台设备各自登记同一条码 → 一个商品 + 一条别名 + 返回 `remap`，**赢家的名称和卖价不变**；收银员对已有条码提交不同名称和卖价的 `quick` 登记 → 原值不变。
  - 裁剪：收银员的拉取响应里用递归遍历断言不存在 `cost / value / stock / low_at` 等键；收银员发带进价的 `product_upsert` 被拒，发 `quick` 的成功且 `needs_review=true`。
  - 单件卖价只有一处：改商品卖价后，该商品所有单件码、名称搜索得到的都是新价，整件码的价不变。
  - epoch 不一致的请求：一个 op 都不应用。
  - 验收补充（§14，已在 PR #10 实现）：服务器的分摊实现跑 `allocation.json`、`rounddiv.json` 同一份向量（S12-4）；注销期间推 op → `stores.rev` 和 `ops` 表不变、`results` 为空、带 `delete_pending_until`、同一请求的拉取照常，撤回后原样重发全部 `applied`（S04-2）；一家店并发超过排队上限时多出来的拿到 503，别的店不受影响，重发后幂等入账（S04-8）；`product_upsert` 用已有商品 id 挂不上码（S04-10）；存不进库或算不了哈希的 op、嵌套过深的 payload 只让自己被拒，同批其余照常，没有 500（S04-13）；请求体超过 1 MiB → 413。
  - 过渡分支（S04-1）：本段没实现的 op 类型返回 `rejected: invalid`、不留档。S05b 已对卖出、进货、期初、撤销去掉；其余在 S06 合并时删掉。**已删（PR #16）**：`push.ts` 的 `HANDLERS` 是完整的 `Record<OpType, Handler>`，测试「`ops.schema.json` 每个 type 都有处理函数」在 `test/sync.protocol.test.ts`。

**S05 记账引擎一：卖出、抹零、进货、期初、撤销**
- 产出：`ledger/apply.ts cost.ts allocation.ts void.ts invariants.ts rounddiv.ts`。
- 验收：`allocation.json`、`cost.json`、`rounddiv.json` 全部向量通过；fast-check 性质测试（随机 op 序列 ≥ 500 组，含乱序重放）断言 I1–I8；正库存但进价没填时卖出 → `cost_missing`、不进利润；明确零成本的商品不标 `cost_missing`；超出 §5.0 上限的输入被拒；收银员撤销别的设备的卖出、撤销进货被拒；收银员撤销本机**昨天**的卖出被拒，把撤销的 `occurred_at` 伪造成昨天也一样被拒（按服务器收到的日期判）；收银员当天撤本机的成功；引用未知商品的卖出自动建待确认商品，不丢账；手机时钟超前 1 天的 op 被校正并打标记。
- 拆分（§14 S05-6）：S05a 只做纯算法（`cost.ts`、`invariants.ts`，PR #11），S05b 做写库与同步接入（`apply.ts`、`void.ts`）。两个 PR 各自过审，S05 段在 S05b 合并后才算完成，依赖 S05 的段等 S05b。
  - S05a 已做：§5.2 全部纯算法与 `cost.json` 全部向量；返回前统一检查新状态和每条流水都存得进对应列（`stock_qty`、`qty_delta` 是 `integer`，金额、货值、成本是 `bigint`），越界整步拒 `invalid`（S05-4 第二层）；`assertLedger` 加了列范围、补记不含当时已撤销的行、`cost_fix` 冲销行逐分（用原补记的 b、跟 +数量 × b 的 `cost_adjust`、净额 = 仍有效的被补记卖出合计）；性质测试加了贴着列上限的生成器、「补记 → 改变当前进价 → 撤销」定向生成器（同一条 `cost_fix` 多次部分冲销）、u ≠ c 的盘盈。
  - S05b 验收 = 本段验收里的写库与同步部分，加 §14 S05-6 列的 ①–⑩。另外（Codex 对 #11 的意见）：S05a 里「同一序列跑两遍」只证明确定性，不证明 I5 幂等；I4–I8 和乱序重放必须在 S05b 经 `/v1/sync` 写库完整验收。S05-4 第二层在 S05b 要经同步接口各测一次（含 `stock_qty` 溢出、`Int64` 货值溢出，拒 `invalid` 并留档，不产生 500）。`assertLedger` 的 `cost_fix` 冲销断言依赖「同一次撤销产生的流水相邻（id 递增）」，S05b 写库时要保持这个顺序。

**S06 记账引擎二：盘点、保质期批次、损耗、退货、待确认补全、成本补记**
- 产出：`ledger/count.ts lots.ts costfix.ts`，op：`count / expiry_dispose / lot_snooze / product_review_complete`，§5.6 的版本校验和迟到流水补偿。
- 与 S05 的分工（§14）：成本补记已由 S05b 在 `stock_in / opening / void` 里当场写库，`costfix.ts` 只剩 `product_review_complete` 的接入，不许另写一套补记逻辑（S05-1）；`opening` 的版本校验、`stock_ver + 1`、`last_count_at` 已在 S05b，本段做 §5.6 第 4 条迟到补偿、`count / product_review_complete` 的版本校验，并把进货、期初、卖出、撤销的批次动作（`stock_lots / lot_moves`）一并补上（S05b 只在流水上存 `expiry_date`，S05-2）；给 `cost.json` 加一组 u ≠ c 的盘盈（例如库存 6、货值 24280、c = 4000，数到 8 → 盘盈 2 × 4047），服务器纯函数和经 `/v1/sync` 写库两条都要过（S05-8；§5.2 只在服务器实现，见 §5 开头、§14 S06-12）。
- 验收：
  - `expiry.json` 向量通过；账面 2 实数 1 → 盘亏 1 个，按平均进价。
  - 并发盘点：A 看到 10（版本 n）→ B 卖 2 → A 提交盘点 10 被拒 `stale` 并带回 8 → A 带新版本确认后成功，库存 10、盘盈 2。
  - 迟到流水：B 在盘点前离线卖了 2 个，盘点（数到 8）之后才传上来 → 卖出入账、自动补偿，库存仍是 8，盘亏相应减少 2 个。
  - 批次：卖出按到期日从早到晚扣，撤销后各批次数量与卖出前逐一相等；两台设备带同一个 `handle_ver` 各提交一次「扔掉 2 个」→ 只成功一次，另一次 `stale`；处理（关闭）后再撤销此前的卖出 → 批次不重开；撤销「扔掉」→ 批次重开且数量恢复；已有销售后撤销来源进货 → 批次关闭、`lot_moves` 保留、I1–I3 成立。
  - 处理快过期四个动作各一条测试（扔掉减库存减货值记损耗且**不改变「赚了」**；退货不计盈亏；卖完了不动库存；过几天再提醒到期后重新出现）。
  - 待确认补全：记的是 `opening` 不是 `stock_in`、清 `needs_review`、生成一条 `cost_fix`，原卖出行的 `cogs_fen` 不变。
  - 两组逐分用例：「先卖出 → 撤销 → 补进价」（已撤销的不参与补记）；「先卖出 → 补进价 → 跨月撤销」（撤销月出现冲销的 `cost_fix`，上月数字不变，对账等式两个月都成立）。
  - 性质测试加入新 op 后 I1–I8 仍成立。
  - §14 带过来的（开工前逐条看）：
    - S04-1：本段合并时删掉「没实现的 op 类型 → `rejected: invalid` 不留档」的过渡分支，并加测试「`ops.schema.json` 里每个 type 都有处理函数」。
    - S04-14 / S05-4：本段的四种 op 都是记账类，预检查没拦住的 22xxx 整个请求 500、记 error 日志，不单个拒收；算出来的新库存、货值、各行金额照 §5.0 在写库前检查（走 `cost.ts` 现有的列范围检查，不另写）。
    - S05-9：自动建的待确认商品（卖价可能是 0、没有条码）补全时，`product_review_complete` 照常接受；卖价和条码由手机另发 `product_edit`、`barcode_link`，本段不在补全里代填。加一条测试：对自动建的商品走完 `product_edit` + `barcode_link` + `product_review_complete`。
    - S05-12：本段新写的、按 `batch_id` 取批内行的查询一律加 `reverses_entry_id IS NULL`（§3.3）。
    - S05-14：本段如果成为第一个真正删流水行的段，不能指望拉取时回查原行（原行已经没了，收银员手机上的行就永远删不掉）：要么在 `removed` 上存归属（设备、是否卖出），要么不物理删行；PR 必须带「收银员收到本机卖出墓碑」的测试。
    - 迟到补偿产生的 `count` 行会挂在发那笔流水的设备名下（可能是收银员）。收银员撤它必须被拒 `forbidden`：`void.ts` 里「只能撤本机的原始卖出行」是唯一的拦截，本段加测试（PR #13 Fable 第一轮）。
  - 已做（PR #16，分三轮提交）：
    - 盘点、待确认补全写库与版本校验（`count.ts`、`costfix.ts`，补记走 `cost.ts` 的 `opening`）；保质期批次（`lots.ts`：进货 / 期初 / 补全建批次，卖出、盘亏扣批次写 `lot_moves`，撤销按 §5.4 生命周期表）；`expiry_dispose / lot_snooze`；`expiry.json` 全部向量；收银员裁剪。
    - §5.6 第 4 条迟到补偿：`writeStep` 统一判 `occurred_at < last_count_at`（盘点 / 期初本身除外），算法在 `cost.ts` 的 `lateCompensateRaw`，经 `settle` 组合后统一做范围检查；`last_count_at` 只往后走。测试 `test/ledger.late.test.ts`（含收银员撤补偿行被拒）。
    - S04-1 过渡分支已删；S05-8 的 `cost.json` 向量 cost-27 已加，服务器纯函数与经 `/v1/sync` 写库两条都跑（同步向量跑法加入 `count`）。
    - 两组逐分用例：`test/ledger.costfix.months.test.ts`。
    - 性质测试（`test/ledger.property.test.ts`）加入四种新 op、带到期日的进货 / 期初和迟到流水，乱序与重放，≥ 500 组，断言 I1–I8 与批次一致性 L1–L6；固定带一组 examples 保证覆盖扔掉 / 退货的撤销。
    - S05-14：本段不物理删流水行，不写 `entry / batch / lot` 墓碑，所以不需要「收银员收到本机卖出墓碑」的测试。
    - 返修（Codex、Fable 第一轮）：迟到补偿先组合再做范围检查，库存在 INT32 上下界时迟到的卖出 / 进货不再被拒（Codex 1）；撤销加回批次前预检查 `qty_left` 溢出，超界拒 `invalid` 留档（Codex 2，S05-4）；迟到进货让进价从没填变已知时补偿后货值一律归位到 `q × c`（S06-8）；被补偿的迟到卖出不扣批次（S06-10）；`last_count_at` 只往后走补了测试（S06-11）；性质测试加 `assertLate`（LT1、LT2）和固定组 `LATE_EXAMPLE`。§14 加 S06-1 至 S06-15 和跨段待办 T5。

**S07 报表与查询接口**
- 产出：`reports/today.ts month.ts entries.ts`。
- 验收：用一份固定夹具复现设计稿 10 的数字：卖了 23,474、赚了 5,487、月初货值 + 本月进货 41,595、卖掉的货的进价 17,987、盘点少了 128、过期扔掉 58、退供货商 160、现在货值 23,262，等式逐分成立；随机序列上「对账等式成立」作为性质测试；跨月撤销不改变上月的月初货值；未补记的 `cost_missing` 行不进「赚了」并计数，`cost_fix` 进「赚了」但不进「卖了」；收银员访问全部 403（真实请求）；一个月 1 万条流水时月报 < 300 ms。
- §14 带过来的：按 `batch_id` 取批内行、按批汇总时一律加 `reverses_entry_id IS NULL`，卖出的冲销行带原 `batch_id`，不加会把冲销行算进批里（S05-12）；`voided_at` 是撤销 op 的 `occurred_at`，和冲销行的 `occurred_at` 是同一个值，报表和 07a / 07c 的「撤销算在哪天」只用这一个口径（S05-13）；冲销行的 `pack_count` 是负数（S05-11）。验收加一条：含「撤一行」「整批撤」「补记后撤销」的批次，按批汇总 = `paid_total_fen`，跨天撤销的冲销行落在撤销那天。
- 返修（Codex、Fable 第一轮，§14 S07-1 至 S07-8）：查询日期放宽到 0001–9999 年，日界线改由 Postgres 按 `Asia/Shanghai` 换算，1970 年等历史流水能按日期查询、翻页（Codex 1）；月报柱状图与月合计同一归日口径，跨零点的流水画到它那一天（Codex 2）；月末货值的说法按 S07-4 改准确（Codex 3）；快没货排除待确认商品（S07-6）；07c 不列 0 笔 ¥0.00 的日子（S07-7）；契约 `ReportToday.count` 必填（S07-1）。跨段待办加 T7、T8。

**S08 条码查询与商品图**
- 产出：`lookup/kuainiao.ts catalog.ts images.ts oss.ts`、`jobs/image-fetch.ts`、`scripts/barcode-trial.ts`、`docs/image-rights.md`。
- 验收：快鸟客户端用样例响应做测试（S08 的样例是手写的，标明非录制；真实录制件由 T9 补）（密钥只从环境变量读，不进仓库、不进日志）；查到的结果写缓存，第二次不再调外部；外部超时 2 秒时接口仍在 2.5 秒内返回「没查到」；图片下载 → 长边 200px JPEG → 写 OSS → 写回 `image_key`（走店铺锁和取号函数）；图片下载失败不影响商品保存；只允许 http/https 且解析后不是内网地址的图片 URL（防 SSRF），单图 ≤ 5 MB；每店每天 1000 次上限生效（原 300，11/23 改）；演示店不调外部；图片功能有一个服务器开关 `product_images_enabled`，关掉后所有商品显示首字。
- 人工项一、人工项二已挪到 S10a（§14 T9，PR #19 Fable 审核）：两项都要真实 AppCode 或登录阿里云，S08 不碰真实凭据。
- 返修（Codex、Fable 第一轮，§14 S08-1 至 S08-10）：网关报错头 `X-Ca-Error-Message` 不再拼进错误信息，只记状态码和固定分类（auth / quota / other），AppCode 回显时日志里找不到（Codex 1、Fable 1）；快鸟响应的业务状态不是明确的成功、或认不出名称一律抛 `format`、不写缓存，`{code:"500"}`、`{code:403,name:"QuotaExhausted"}` 不再被当成「没查到」或商品（Codex 2、Fable 2，S08-6）；每日额度按 S08-3 保留内存计数，注释改为「每重启一次可能多用一份额度」，两个条件写进 T9 ④ 和 S10c（Codex 3、Fable 3）；图片任务一次领一个、做完再领下一个（Codex 4、Fable 4，S08-8）；两项人工验收按本段上一条延期到 S10a（Codex 5）。跨段待办加 T9 至 T12。

**S09 演示小店、每日重置、账号注销与导出**
- 产出：`demo/seed.ts reset.ts`、`jobs/account-purge.ts`、`jobs/scheduler.ts`、`scripts/export-store.ts`。
- 演示数据：店名「演示小店」；约 30 个商品，**全部是饮料、零食、日用品，没有烟和酒**，图片只用首字或自绘通用图；最近 7 天的流水（日期相对「今天」生成，含一笔抹零、一笔撤销、一次进货）；一个 3 天后到期和一个已过期的批次；一个待确认商品；一个整箱码（可乐 1 箱 = 24 罐）。
- 重置：每天北京时间 16:00（美国西岸半夜）；如果演示店最近 60 分钟有请求就顺延 1 小时再试。重置恢复审核号密码、撤回注销申请、把演示店全部设备标为已撤销并带 `discard_outbox`（§4.5），不换 `epoch`。
- 注销：申请时为非演示店生成一份导出包（ZIP，内含 `说明.txt`、`商品.csv`、`条码.csv`、`流水.csv`、`月报.csv`；CSV 带 BOM、CRLF，金额是元的两位小数，店主填的文本防公式注入，纯数字条码写成 `="…"` 防 Excel 科学计数法，时间按 `Asia/Shanghai` 历史时区；§14 S09-4）放到 OSS 的 `exports/`（存档桶，生产不和商品图共用，§14 S09-11、T13），告警通知 Chitu 转交黄总；满 7 天后删除店铺全部在线数据、OSS 图片和导出包，并往 OSS 的 `deletions/` 写一条删除记录（不在数据库里，不随备份回滚）。`restore.sh` 恢复后必须重放删除记录（S10b）。
- 验收：重置后数据与种子逐表一致；有活动时不重置；**一台在重置前登录、带着未传 op 的手机跨过重置**：得到 `revoked + discard_outbox`，重新登录后看到的是干净的种子数据，旧 op 没有进库；重置前改了审核号密码或申请了注销，重置后用原密码能登录；审核号令牌遍历元辉店的商品、流水、设备、报表 id 全部拿不到（隔离测试）；注销申请中写账和开通被拒；满 7 天后在线数据清空、删除记录存在、7 天内撤回则无事发生；导出包内的合计与月报一致。
- §14 带过来的：
  - S03-4：删除任务（`account-purge`）至少每天跑一次，把「满 7 天到真正删除」的空档压在 24 小时内；这段空档里撤回返回 `409 not_delete_pending`（S03 已实现）。
  - S03-9：每次演示登录新建的设备行由每日重置清理（重置后不留已撤销的旧演示设备越积越多）；审核号在注销申请中时 `/v1/auth/demo` 怎么响应在本段定下并测试：照样建设备，响应带 `delete_pending_until`，写账整批不应用，每日重置撤回（§14 S09-16）。
  - `createDevice` 加固（§14 跨段待办 T1）在本段动演示登录时一并做。
  - ~~`server-ci` 并发登录测试偶发 500 的排查（§14 跨段待办 T2）~~：已由 PR #15 完成，本段不用再做。本段新增的验密码路径照 T2-1 走 `src/auth/password.ts`。
- 返修（Codex、Fable 第一轮，§14 S09-1 至 S09-16）：删除记录 `deletions/<店>.json` 在锁内确认撤回不了之后、删在线数据之前写好，没配存档桶或写失败就不删、告警 `purge_no_archive`（Codex 1）；在途的图片任务上传前复查店还在、传完在店铺锁里再查，店没了就删掉刚传的图，GET /v1/images 回填本机缓存后同样复查，删不掉把 `store_purges.objects_cleared_at` 撤回成空、下一轮再清（Codex 2）；旧导出包清理在任务行锁里复查申请版本、只删键里申请时间更早的包，生成和清理分开记（`export_jobs.stale_cleared_at`），清理失败不碰已完成的新包、下一轮单独重试，完成告警不等清理（Codex 3、4）；导出包从文件流式上传（`ObjectStore.putFile`，阿里云分片上传）（Codex 5）；每日重置在锁内重查 `next_reset_at`，多进程同一周期只重置一次（Codex 6）；导出流水时间由 Postgres 按 `Asia/Shanghai` 换算，和月报归月一致（Codex 7）；派生流水 id 撞上已有流水 → `rejected invalid`（Fable 1，S09-2）；没配存档桶时有未完成的导出任务每轮 error 级告警 `export_no_archive`，阿里云的存档桶在 S10a 配第二个桶之前按没配处理（Fable 2，S09-6、S09-11）；密码登录、改密码、申请注销撞上到期清除回 401（Fable 3，S09-10）。跨段待办加 T13 至 T16。
- 返修（Codex、Fable 第二轮）：T17 在本段实现：对象清理在清除后满 1 小时按前缀复扫一遍（含本机缓存、未完成的分片上传）才记完成，盖住图片上传报错、上传后拿锁失败、进程退出留下的迟到对象（Codex 1、Fable 裁定 ②）；作废、失败的导出包删不掉记 `object_discards` 待删标记，每轮按退避重试（Codex 2）；阿里云分片上传失败时中止那次上传，中止失败记下 uploadId 重试，复扫按前缀中止残片（Codex 3）。
- 返修（Codex、Fable 第三轮）：`store_purges.purged_at` 改取在线数据删完、提交前那一刻的钟，不再用整轮开始的时间，复扫的「满 1 小时」从实际清除完成起算（Codex 1）；复扫每一遍先中止未完成的分片上传、再列举删除对象，来回到某一次两边都空才算扫干净，最多 3 次，还不干净记 `sweep_not_quiet` 下一轮重来（Codex 2）；`image-fetch` 撤回清完标记那条路补回测试（Fable）。跨段待办加 T18。

**S10a 部署：ECS、镜像链路、Compose、TLS**
- 要读：§9.1、§9.2。
- 产出：`deploy/bootstrap-ecs.sh mirror-base-images.sh compose.yml Caddyfile.ip deploy.sh`、`.github/workflows/image.yml`（构建并推 ACR）、`docs/runbook.md` 初版。
- 验收：`deploy.sh` 一条命令完成发布，健康检查失败自动回到上一个镜像（用一个故意坏掉的镜像演示一次）；Caddy 版本锁定，IP 站点**显式配置**公网 ACME 签发方和短期证书 profile，证书状态持久化在数据卷；`curl` 从境外和本机验证证书链为公开受信任；观察到至少一次自动续期成功后才算通过（不通则按 §9.2 切方案 B，并在 PR 写明）。App 端的验证在 S11b，不以 Safari 无警告代替。
- 客户端 IP（§14 S03-6，§9.1）：`TRUST_PROXY` 打开且只信一跳（把 S03 的「信整条 `X-Forwarded-For`」改掉，可以是 `trustProxy: 1` 或只信 Caddy 的地址）；`api` 端口只绑本机或 Compose 内部网络，不对公网开。验收加两条：① 从公网直接连 `api` 的端口连不上；② 从公网带伪造的 `X-Forwarded-For` 请求登录，按 IP 限速仍按真实 IP 生效（用伪造的头换不出新的限速额度），服务器端有对应的自动化测试，ECS 上再实测一次。
- 待查，不算验收（PR #10 Fable 第三轮）：上限以内但不合 schema 的 payload 会留档，持有效令牌的设备一个请求最多能往 `ops` 里写近 1 MiB 垃圾。本段配 Caddy 时看要不要在反代层按 IP / 按连接限制 `/v1/sync` 的请求速率，结论（做了什么，或为什么不做）写进 PR；应用层按设备限速若要做，另提裁定。
  - 结论（PR #22，§14 S10a-2）：反代层和应用层都不限速，不为此自编 Caddy 镜像；`/v1/sync` 靠有效令牌、请求体上限（api 1 MiB、Caddy 2 MB）、每店在途写入上限 32（S04-8）。改成监控：S10c 加 `ops` 表体积、磁盘用量告警（T3）。
- 报表耗时（§14 T7）：按 3 年的量（约 40 万行）再量一次月报和 `/v1/entries/days`，07c 超过 200 ms 就改成按天往前走索引，或存每月月末货值。
- 登录时的线程池和排队（§14 T2-2、T2-3，跨段待办 T4）：`api` 不设 `UV_THREADPOOL_SIZE`；数据库用口令认证。在 ECS 上实测并把数字写进 PR 和 runbook：单次 argon2 耗时；30 个登录同时到时最慢一个的响应时间，期间 `/healthz` 和一次 `/v1/sync` 的耗时，全程 0 个 500。最慢的登录超过 10 秒就按 T4 加排队上限（改契约），否则写明不加。
- 人工项一（来自 S08，§14 T9）：用免费额度跑 `barcode-trial.ts` 测 20 个真实条码（含 5 条香烟、5 个本地品牌），把命中率和有图率写进 PR。有图率 < 50% → 商品图降级到第二版；香烟命中率低 → 记入风险，登记时手输名称。
- 人工项二（来自 S08，§14 T9；图片使用授权）：读快鸟在云市场的服务协议和接口说明，把关于返回图片能否缓存、缩图、在自己的 App 里展示的原文摘进 `docs/image-rights.md`。**条款明确禁止 → 开关保持关闭，全部用首字。条款没有提及 → 开关是否打开交 Haoqiang 决定（§12），在他决定前保持关闭。** 演示店和商店截图无论如何不用第三方图。
- T9 做完之前不许在生产配 `KUAINIAO_APPCODE`（试跑脚本除外），不许打开 `PRODUCT_IMAGES_ENABLED`。T9 的其余各项（真实录制件替换手写夹具、计费方式确认、真实 OSS 往返、条码格式过滤）见 §14 T9。
- sharp 对镜像的要求（§14 T10，PR #19 Fable 审核）：
  `sharp` 0.35.5 靠 `@img/sharp-linux-x64` 和 `@img/sharp-libvips-linux-x64` 这两个预编译的可选依赖运行，锁文件里都有。现在的 `server/Dockerfile` 能直接用，不需要装编译工具。S10a 要守住：

  1. 基础镜像保持 glibc 的 `node:24-bookworm-slim`，镜像到 ACR 的那份也必须是 `linux/amd64`。换成 alpine 会改走 musl 包，要重新验证。
  2. `npm ci --omit=dev` 不能再加 `--omit=optional`，否则预编译包不会装。
  3. 在 Apple 芯片的 Mac 上手工构建要带 `--platform linux/amd64`，不然装进去的是 arm64 的包，到 ECS 上起不来。CI 的 x64 机器没有这个问题。
  4. 换 npm 镜像源时确认 `@img/*` 能拉到，不要触发从源码编译（镜像里没有工具链，会失败）。
  5. `routes/lookup.ts` 在启动时就加载 `sharp`，加载失败整个 API 起不来。这样现有的「镜像启动 + `/healthz`」冒烟能拦住；冒烟里再加一步在镜像内真缩一张图（确认 libvips 的 JPEG / PNG / WebP / GIF 解码器都在）。
  6. 内存见 T10。`IMAGE_CACHE_DIR` 挂 `/data/img` 数据卷，容器内 `node` 用户可写。

  `ali-oss` 是纯 JS、按需加载，对镜像没有要求，但没用真实 OSS 测过（T9 ⑤）。
  - 内存实测（T10）：在 512 MB 的 `api` 容器里，一边跑 3 个并发登录一边缩一张 5000×5000 隔行 16 位 PNG，不被 OOM 杀掉才算过，否则把上限降到单边 4096。
- 存档桶分开（§14 S09-11、T13）：加第二个桶的配置，`server.ts` 的 `archive` 接 `yuanhui-backup`（现在 `archiveStoreFromConfig` 对阿里云一律返回空，导出和清除按没配存档桶告警、不执行）；RAM 子账号对商品图桶只有 `images/`，对备份桶只有 `exports/`、`deletions/` 和备份前缀；配了商品图桶没配存档桶时不许把导出包写进商品图桶。真实 OSS 上把列举、删除、分片上传（`putFile`）各实测一次。
- 存档桶必须同时配好（PR #20 Fable 第二轮裁定 ①）：配了阿里云商品图桶就必须同时配好存档桶，部署后日志里没有 `export_no_archive`、`purge_no_archive`，否则 S10a 不算过。
- 孤儿对象（§14 T17，已在 S09 实现）：真实 OSS 上把分片上传失败后的中止、按前缀列举未完成的分片上传（`listUploads`、`abortUpload`）各实测一次。
- 导出任务失败分支删包前复查（§14 T18，PR #20 Fable 第三轮）：当场删包之前先确认没有已完成的任务指向这个键，和 `retryObjectDiscards` 一样，补一个测试（写回已提交、应答前连接断开）。
- 返修（PR #22 Codex、Fable 第一轮，§14 S03-6（补）、S10a-1 至 S10a-9）：`deploy.sh` 只在本机校验参数（`--execute` 时 `ACR`、`ECS_HOST` 必填，标签只收 7–40 位小写十六进制，第一条 ssh 之前退出码 2）、远端参数逐个转义，步骤放进 ECS 上的 `remote-deploy.sh`：先起 Postgres 等健康、用不带固定地址的 `migrate` 服务迁移，从起库到 `caddy reload` 整段失败自动换回上一份配置和镜像，`current-tag` 只在全部成功后写；Compose 拆成 `edge` 和 `internal` 的 `db` 两个网络、动态地址用 `ip_range` 隔开，镜像只从 ACR 拉，日志轮转，`api` 加 `memswap_limit: 512m`，不开 443/udp；Caddy 只放行 `/v1/*`、`/healthz`；`bootstrap-ecs.sh` 远端严格模式、swap 建失败不写 fstab、SSH 只许密钥；`TRUSTED_PROXY` 拒绝 `/0`；`deploy/test/` 下的单元测试模拟 ssh / docker 验证回滚路径、`current-tag` 写入时机和校验失败退出码。云上人工步骤和 runbook 按 Fable 审核补齐。
- **本段代码 PR（#22）合并不等于 S10a 通过**（§14 S10a-9）：部署实测另开一个 PR，只填 runbook「部署时验证」13 项的数字和必要修正，齐了、经审核后 S10a 才算过；在那之前 S10b 可以开工，S11b 的探针可以先连。

**S10b 备份与恢复**
- 要读：§9.4。
- 产出：`deploy/backup.sh restore.sh`、定时任务、备份清单文件格式。
- 验收：备份按 §9.4 的时间表产生并加密上传，OSS 生命周期规则生效；加密口令确认已另存两处（§9.1）；**恢复演练在另一台机器上做**（本机的 Postgres 即可）：只凭 OSS 上的备份和另存的口令恢复，然后逐项比对备份清单：每个商品的库存和货值、每条流水的成本、月报各数字，全部一致（不是只对行数）；恢复后重放删除记录（已注销的店不会复活）；恢复后换 `epoch`，一台带保留 op 的测试手机完成握手并补回备份之后的流水；过程写进 runbook。

- 迁移前备份门禁（§14 T20，PR #22 Codex 4、S10a-8）：`deploy.sh` 跑迁移前检查最近一次备份心跳，营业时间内超过 2 小时没更新就拒绝，带一个明确的跳过开关。
- 备份的 RAM 账号（§14 T21、S10a-6）：备份单独用一个账号，`backups/` 只写不删，删除靠生命周期；35 天生命周期只作用于 `backups/` 前缀，`exports/`、`deletions/` 怎么过期单独定；确认两个桶没开版本控制。
- 重放删除记录（§14 T14）：`restore.sh` 重放删除记录要列举 `deletions/`，现在 `ObjectStore.list` 只认 `images/<店>/`、`exports/<店>/` 两种前缀，要加；重放后这些店的旧令牌和重传按 401 处理。
- 返修（PR #23 Codex、Fable 第一轮，§14 S10b-1 至 S10b-11）：恢复标记分「恢复中」「已恢复」，已恢复的库不再被清空；compose 把 `RECOVERY_MODE`（默认 0）传给 api；`backup` 加 `memswap_limit: 256m`；整机重建改成在容器里恢复（`restore.sh` 的 `RESTORE_COMPOSE_DIR`）；目标库有大对象拒绝，`pg_restore` 口令走 `PGPASSWORD`；换 epoch 用例补真实 op 重传；残留锁改 pid + 16 分钟并清残留 `work.*`；runbook 加 B10、B11，B7 和第 36 天检查移为 T23、T24。

**S10c 监控与告警**
- 要读：§9.5。
- 产出：本机定时探测、云监控规则、服务器内的检查任务（备份心跳、证书有效期、营业时间无同步、错误率、快鸟余量）。
- 验收：§9.5 表里的每一项都人为触发一次，Chitu 收到告警；告警内容不含密码、令牌、开通码。
- `ops` 表体积和磁盘用量告警（§14 T3、S10a-2）：出现异常增长再提裁定（`/v1/sync` 反代层和应用层都不限速）。
- IP 证书（§14 T19、S10a-3）：剩余有效期低于 48 小时告警；每次续期成功 / 失败留记录，供判定方案 A 是否稳定。
- 快鸟余量（§14 S08-3 的条件二）：告警接 `app.catalog.quota`，单店当天用到 700 次就告警（原 200，11/23 随上限 300→1000 改）。每日额度计数在内存里、每重启一次可能多用一份额度，这条告警是它的兜底之一。
- 注销导出和清除的告警（§14 T16）：现在只是带 `alert` 字段的日志（`account_delete_export`、`account_delete_export_failed`、`export_no_archive`、`purge_no_archive`，以及 T17 带来的 `object_discard_failed`、`export_discard_lost`），接到通知渠道。
- **本段分两个 PR**（同 S10a、S10b）：代码与配置 PR 只改仓库，告警通道是可注入接口、测试用假实现；人为触发每一项、Chitu 收到告警的验收在部署实测 PR 里做，项目列在 `docs/runbook.md`「S10c 部署时验证」M1–M12。

### 阶段 C：iOS 离线界面（不需要服务器）

**S11 工程骨架、设计令牌、字号系统、共用组件**
- 设计稿：01、03、24a、26（只为取颜色、字号、组件样子）。
- 产出：`ios/project.yml`、三个 xcconfig、`App/Design/*`（颜色令牌：米纸 `#F3EFE3`、白卡 `#FFFDF8`、墨 `#1F1A17`、朱红 `#C4321C` = 卖出、靛青 `#1E5A7A` = 进货、价签黄 `#F5C83A` = 刚扫到和提醒、已过期 = 墨底白字；数字用 DIN Alternate Bold 等宽）、`TypeScale`（大字模式 = 把动态字号下限抬到 `xxxLarge`，上限封在 `accessibility2`；关 = 跟随系统，但**上限同样封在 `accessibility2`**；正文和次要用系统的 body / subheadline 文字样式，不自定义基准字号；价格、总价、主按钮、键盘、步进器是固定尺寸，不走这套；固定尺寸的控件点按区域不小于 56pt）、组件库和一个组件陈列页、`-uiFixture` 机制和 `make shots` 截图脚本。
- 验收：模拟器（iPhone 13 尺寸 390×844）构建通过；组件陈列页在 大字 / 标准 / 系统最大辅助字号 三种情况下各截一张图附在 PR；单元测试：大字模式下正文 ≥ 22pt、次要 ≥ 18pt；主按钮高度 ≥ 60pt。

**S11b 空壳 Beta 探针（尽早做）**
- 目标：在写大量业务代码之前，验证三件最可能翻车的事：TestFlight 外部测试公开链接在大陆能不能装；Beta 配置的包用 `URLSession` 能不能连上 `https://47.117.184.253`；签名和上传链路通不通。
- 要读：§9.2。
- 产出：`ios/scripts/build_upload.sh`（Beta 配置归档、用 App Store Connect API Key 上传）、一个只有「连接测试」页面的 Beta 包（显示 `/healthz` 的结果、证书链信息、错误原文）、`docs/beta-probe.md`（结果记录）。
- 验收：包通过 Beta 审核并出现在 TestFlight，用公开链接在一台大陆 Apple ID 的真机上装上（没有备案号时装不了 → 立刻记入风险并告知 Chitu）；连接测试在真机上逐项记录：iOS 17 和当前最新系统各一台、Wi-Fi 和蜂窝、NAT64 网络（Mac 共享）、**以及三个必须失败的场景**（换成别的 CA 签的证书、证书主机不匹配、过期证书）；Beta 包需要的任何 ATS 相关键值以 Apple 当前文档和实测为准，只写在 Beta 配置里，并记录在 `docs/beta-probe.md`；方案 A 不行就在这一段里把方案 B 试完，都不行则按 §9.2 走方案 C。
- 方案 B 一并实测（§14 T22、S10a-3）：探针把方案 B（包内 CA 锚点固定）也实测一遍，写明需要的 Info.plist 键值，不等 A 出问题再测。

**S12 ShopCore：模型与纯逻辑**
- 产出：`Models Money Basket PackConversion Allocation Roles Ops`。
- 验收（`swift test`）：`allocation.json`、`rounddiv.json` 全部向量与服务器结果一致；设计稿 03 的购物篮合计 ¥53.50；扫整箱码换算成 24 个基本单位；`Roles` 从 `permissions.json` 生成能力表，收银员没有进货、看账、商品等能力；每种 op 编码出的 JSON 通过 `ops.schema.json` 校验；金额类型没有任何浮点运算，乘法带溢出检查；超出 §5.0 上限的输入在模型层被拒。

**S13 本地库与 outbox**
- 产出：`ShopCore/LocalDB/*`（§3.4 的表、迁移、各仓库）、前缀匹配和名称搜索、临时库存（服务器基线与本机未确认增减分开存）、恢复队列的存储、演示用种子数据。
- 验收：1,000 个商品时条码查找 < 5 ms（口径见 §14 S13-3，另有合并 5,000 个样本 p99 < 20 ms 的护栏，`lookup` 和 `prefixMatch` 的查询计划断言走条码主键的 `SEARCH`、不出现 `SCAN`）；`prefix.json` 向量通过；**记账的原子性**：在「写流水」和「写 outbox」之间注入崩溃（在注入点拷走库文件含 -wal / -shm 当作断电时的磁盘，另加抛错回滚，§14 S13-4），重启后两者要么都在要么都不在；outbox 在 App 重启后仍在且顺序不变；以收银员形态建库后 `product_private` 为空，并且对库文件做字符串扫描找不到进价数值（测试写入一个特征值来验证）；**清投影不清未确认的 outbox**：有 3 条未确认 op 时切换角色，投影被清空，3 条 op 进入恢复队列且仍绑定原来的店和设备；换成收银员后旧会话已确认的 op 立刻删、未确认的确认后立刻删，压缩中途崩溃或被读事务挡住时重开 / 重试后库文件里仍找不到进价（§14 S13-1）；一个商品有两个单件码时，扫任一个或按名称找，得到同一个卖价。

**S14 扫码层**
- 设计稿：27a、27b。
- 产出：`Scanner/*`、提示音与触感（`.playback` 音频会话，静音开关下也响；没登记过的码用另一种低音）、相机权限三态。
- 验收：单元测试：一串数字 + 回车 = 恰好一次扫码；慢速逐个按键不算扫码；相机同码 1.5 秒内忽略，扫码枪每次扣扳机都算；`FakeScanner` 能由启动参数喂码。相机被拒时显示「没打开相机，扫不了码」+「去打开」，手输条码和扫码枪照常可用（XCUITest 用启动参数模拟被拒）。真机项留到 S29。

**S15 两种首页、首次进入、设置壳**
- 设计稿：01、02、24a、25a、16、16b、21a、21b。
- 产出：`Features/Home Onboarding Settings`、导航骨架（按角色决定有哪些入口）。
- 验收：XCUITest：收银员形态下遍历所有可点元素，**到不了**进货、看账、商品、盘点、快过期、开通；家用形态下都能到；16 默认选中大字，选择保存在本机，重启后保持；标准模式下系统字号调到最大时也封顶在 `accessibility2`（S11 留下的改动，连同单元测试）；小号步进器（46pt 圆钮）的点按区域不小于 56pt；16b 不出现起名；21b 恰好五项；「没同步」和「快过期」两条提醒同时出现时没同步的在上；系统最大辅助字号下首页两个大按钮不被截断；截图与 01、02、16、21a 对照附 PR。
- §14 S15 的裁定（已在 PR #12 实现）：正常启动时没有真数据的项一律不显示，不出假数（S15-1）；16 预选的是当前本机设置，「首次进入做完」按设备 id 记，重新登录会再出 16（S15-3）；未登录自动建演示会话只在 Debug，Beta / Release 出「还没登录」占位页，CI 有 Release 构建检查（S15-4、S15-7）；大字下多换一行不截断即可（S15-5）；库存和进价可见性由 `sync:pull` 的 scope 推出（S12-3）。

**S16 卖出**
- 设计稿：03、03b、03c、03d、24b、27a。
- 产出：`Features/Sell`。相机条常开、连续扫码、屏幕常亮（`isIdleTimerDisabled`）、手电筒、价签（64pt 小图或首字 + 单价）、购物篮两行式、步进器减到 0 删除、「收好钱了，记账」后显示「记好了 ¥53.00」再清空并停在卖出页。
- 验收：XCUITest：喂三个码后记账 → 本地一笔批次三行，合计正确，outbox 多一条 `sale_batch`；同码扫两次数量为 2；从首页卖一样东西共两次点击；连点两次记账只产生一笔；空篮时记账按钮置灰；商品名很长时换行不截断、金额不出右边距；系统最大辅助字号下总价和记账按钮完整可见。
- §14 带过来的：抹零后改购物篮，即清掉已填的实收（S12 的 PR #7 裁定，记在 S12 表后；S12 只记录、没实现）；设置页和首页的扫码枪连接状态接 S14 的真实状态（S15-1）。各加一条测试。
- §14 带过来的（S14，PR #17）：S14-3 ⑨–⑫——相机生命周期归页面管：压到下一页、被面板盖住、退到后台时停相机，回来再开（用 `CameraViewfinder(paused:)` / `CameraController`，返回 `.ignored` 只是不出声，不代替停相机）；页面回前台时 `permission.refresh()`（`ScannerLab` 和 `CameraController` 两处留一处），`isIdleTimerDisabled` 保留在卖出页；全 App 共用一个 `ScanFeedback`（`ScanFeedback.shared`），各页的 hub 都用它；`UIFixture.swift`、`AppRoot.swift`、`Makefile`、`ReleaseBuildUITests` 两边都改了，rebase 时手工合，`-uiScan` 走 `FakeScanner` 后 `shots-s16.sh` 和 UI 测试的等待时间按「开页等 1 秒 + 每码 0.3 秒」放宽，测相机去重的用例间隔要大于 1.5 秒。S14-5 ⑭——在 `ScanHub.receive` 用 `HIDScanParser.isCodeCharacter` 给三个入口（相机、扫码枪、手输）统一把关：只收数字和 ASCII 大小写字母，含其他字符的码整串不收、不截断，相机和扫码枪不出声、不交给页面，大小写原样保留，加测试。另：`runtimeErrorNotification` 后的重启加上限（例如 1 秒内最多一次），或 S29 真机上看日志确认不会转圈。

**S17 抹零与手输条码**
- 设计稿：18、28、15、15b。
- 产出：`Features/Discount ManualCode`（卖出、进货、盘点共用）。
- 验收：¥53.50 抹到 ¥53 → 三行实收 24.76 / 23.78 / 4.46；低于七折（53 输成 5）弹 28「输错了，重填 / 没错，就收 ¥5.00」，多收弹同一面板的另一套文案；「不抹了」恢复原价；购物篮全是零价商品时改价按钮不可用；手输条码前缀命中两个时列出两个且主按钮灰，点一行后可加入；按名称找用系统键盘，结果行在收银员形态下没有库存字样。
- §14 带过来的（S14，PR #17）：S14-4——扫码枪连着时系统软键盘不弹，手输条码还要能用；手输面板 / 弹窗关掉后不点屏幕直接扣扳机，码照常进：关面板的那一刻主动调一次 `HIDKeyCaptureView` 的 `reclaim`，别只靠键盘收起的通知（模拟器上 XCUITest 发不出不经文本框的硬件按键，真机在 S29 按 S14-4 验，两样有一样不行就在本段给出办法）。S14-5——手输的码含数字、字母以外的字符时不收，面板里提示「条码只能是数字和字母」，加测试。

**S18 新商品登记与整件码**
- 设计稿：04a、04b、04c、05、25e。
- 产出：`Features/NewProduct LinkPack`、查名称客户端（协议 + 桩实现，真实网络在 S21 接）。
- 验收：卖出中扫到新码 → 04a，填卖价后「存好，接着卖」回到卖出且该商品已在篮里；「再填进价和库存」进 04b，填了库存没填进价出现黄字提醒；打开「要管保质期」才出现到期日和提前天数，「不知道，先不填」可用；04a 的「这是整箱、整条的码」进 05，关联后扫该码按 24 个算；收银员形态只有 04c，存好后提示「已记下，回头让家里人补全」，产生的是 `quick` 的 `product_upsert`；断网时（25e）名称为空也能登记并卖出；从卖出进来两步都是红色标题栏，从进货进来都是蓝色。

**S19 进货**
- 设计稿：06a、06b、06c。
- 产出：`Features/StockIn`。
- 说明：本段只验收手机自己能确定的东西：数量换算、入账总价、这批的单位成本、临时库存。蓝卡第三行「加上原来的，平均进价」是**仅供显示的预计值**（本地基线货值 + 这批总价，除以新数量；进价未知或库存不为正时不显示这一行），不写入任何流水；权威的平均进价由服务器算，在 S22a 和 S28 对账。
- 验收：可乐整箱码，5 箱 × ¥48 → 蓝卡显示「一共 ¥240.00 / 入账 120 罐，每罐 ¥2.00」，标签随单位变（每箱 / 每条 / 每瓶）；5 条 × ¥400、原有 6 包 → 临时库存 56 包，outbox 里的 `stock_in` 带的是件数和每条单价；管保质期的商品出现到期日区，两种填法可切换，生产日期 2026-11-12 + 6 个月 = 2027-05-12，年月日三格用自家键盘、填满自动跳格（06c），保质期月数记住上次的值；「记进货」始终固定在底部可见；进货中遇到新商品必须走完 04b；数量键盘没有小数点。
- 返修（Codex、Fable 第一轮，§14 S19-1 至 S19-9）：本机有待传库存变动时蓝卡不显示预计平均（Fable 1，S19-1）；04b 没填数量或填 0 时不说「库存已记上」，接着在进货页填这一批（Fable 2、Codex 特别评估，S19-3）；名称框回车不再自动删末尾数字，只在名称框下提示，人点「是条码，去掉这串数字」才去（Codex 1，S19-9）；06b 收起键盘、填完日期后各字号「记进货」在屏幕内的界面测试（Codex 2）；大字和最大辅助字号下蓝卡顶上带商品名（Fable 建议 1）。跨段待办加 T30 至 T33。

**S20 记的账与撤销**
- 设计稿：07a、07b、07c、08。
- 产出：`Features/Records Undo`、首页「刚记的」条接真数据。
- 验收：撤销后临时库存恢复、原流水划线仍可见；撤两次第二次无操作；有优惠的批次在 08 显示「这笔抹了 ¥0.50，撤一样按比例退」和每行摊后金额；「只撤这样」和「整笔都撤销」各一条测试；收银员形态只列本机当天的卖出、没有日期切换、昨天的流水没有撤销按钮；家用形态「更早」列出每天一行（离线时只到本地 35 天）；流水上显示的是手机名，不是人名。
- §14 带过来的：首页「刚记的」条的数来自真数据（S15-1）；家用首页「刚记的」整条可点进 07a（和收银员 02 的「点开看」同一个做法，家用不加「点开看」字样），还没有任何流水、条不显示时从「看账」页进；验收加「家用首页没有提醒条时也能进记的账」，并把 S15 家用遍历的必达集合加回 `page.records`（S15-6）；07a 的卡片按 `op_id` 归并（`cost_fix` 行、带 `flags.late_before_count` 的补偿行不单独成卡），卡片数 = 09 的笔数，07c 只列笔数 > 0 或金额非零的日子（S07-1、S07-7）。

### 阶段 D：联网

**S21 网络层、凭据、登录、扫码登录**
- 设计稿：13、25c、14、27b。
- 产出：`ShopCore/SyncClient/APIClient`（基址来自 xcconfig；Beta 配置的证书处理沿用 S11b 定下的做法）、`Features/Login`、钥匙串里的当前令牌和恢复用旧令牌、`/v1/config` 最低版本检查、「看看演示」入口（`demo_login_enabled` 为假时不显示，默认假）。
- 验收：XCUITest 连本机起的服务器：账号密码登录成功进 16；密码错 5 次显示锁定到几点；登录页没有「注册」字样、没有店名（副标题「小店扫码记账」）、有隐私政策链接、密码可显示；扫码登录解析 `YHZB1:` 码，过期码给出 25d 的提示；杀掉 App 重开仍是登录状态；`min_build` 高于本包时显示「请更新」；开关打开时「看看演示」能进演示小店，关闭时界面上找不到它。（本段**不做**同步，登录后进的是空首页。）
- **服务器地址由服务器配置下发（11/21 新增需求）**：`GET /v1/config` 加一个可选字段 `api_base`（契约、服务器、手机在本段一起改；服务器端的值来自环境变量，没配就不返回）。App 包内带默认地址（来自 xcconfig；Beta 配置是 `https://47.117.184.253`）；启动和每次回到前台时取一次 `/v1/config`，返回了 `api_base` 且和当前用的不一样，就存下来，之后的请求都走新地址。下发的地址必须通过白名单才采用：用 `URLComponents` 解析后，协议是 `https`，主机**完全等于** `47.117.184.253` 或 `api.yuanhuishop.cn`（整串比较，不做前缀、后缀或包含匹配），没有用户名密码部分，端口为空或 443，路径为空或 `/`。白名单写死在包里，不从服务器取：Beta 配置两个主机都允许，Release 配置只允许 `api.yuanhuishop.cn`（提审的包里不许出现 IP 字面量，S30 的归档检查不变）。不在白名单里的值直接丢掉、继续用当前地址，并记一条本地日志。启动时从本机读出已存的地址也要过一遍同样的检查，不通过就删掉、退回包内默认地址。服务器端启动时同样校验环境变量，不在这两个主机之内就拒绝启动。Debug 配置额外放行 `http://localhost` 和 `http://127.0.0.1` 的任意端口，只供测试。 新地址连不上时退回包内默认地址，下次再试。备案通过后在服务器上把它配成 `https://api.yuanhuishop.cn`，装着老版本的手机自己切过去，不用重装（域名用公开证书，不需要 ATS 例外）。验收加一条：XCUITest 里服务器下发另一个本机端口的地址，App 之后的登录请求打到新端口；杀掉重开仍用新地址；新地址不通时退回默认地址能登录（测试用的 `http://localhost` 地址只在 Debug 配置下放行）。S30 的 Release 归档检查不变：提审的包里仍不许出现 IP 字面量。 验收：服务器下发白名单之外的地址（例如 `https://evil.example`、`https://api.yuanhuishop.cn.evil.example`、`https://api.yuanhuishop.cn@evil.example`、`https://evil.api.yuanhuishop.cn`、`https://evil.example@api.yuanhuishop.cn`（带用户信息，主机虽对也必须拒绝）），App 不采用，之后的登录请求仍打到原地址；本机预置一条白名单之外的已存地址，启动后被删掉并用默认地址。 若 Beta 走方案 B（包内私有 CA 锚点固定），固定只对 IP 主机生效，`api.yuanhuishop.cn` 走系统信任链。
- §14 带过来的：
  - S15-4：用登录页替换「还没登录」占位页；`tokenRef` 为 `demo-local` 的遗留会话不当作已登录，启动时清掉（开发机上装过早期 Debug 包的，正式库 `zhangben.sqlite` 里还留着这种会话）。加测试：库里预置一条 `demo-local` 会话，启动后进登录页、会话已删。
  - S15-2：接 `PATCH /v1/devices/me`；登录前（S15–S20 期间）本机改过的名字，第一次登录后补报；名字长度的计数口径与契约 `DeviceLabel` 核对一致（本地现在按 unicode scalar 计）。收银员本机拒改不变。
  - Release 检查补 Beta（PR #12 Fable 第二轮）：现有的 Release 构建检查（`release-check.sh` + `ReleaseBuildUITests`）只构建 `Release` 配置。本段给 Beta 配置加基址和证书处理，要对 **Beta 配置单独跑一遍同样的检查**（带夹具参数启动只出登录页、二进制里没有演示会话的符号），防止有人用 `#if BETA` 开夹具而检查抓不到。
  - S14-3 ⑬（S14，PR #17）：扫码登录页用 `NoCameraCard` 时状态栏设浅色。

**S22a 同步引擎一：正常同步、首次同步、本地原子提交**
- 设计稿：29、25a。
- 产出：`SyncClient/SyncEngine`（outbox 推送、两条流的分页拉取、`remap` 改写、每个 op 的结果处理、同步状态指示）。
- 验收（XCUITest + 本机服务器）：首次同步显示「194 / 312 样」式进度，**商品拉完即可进首页开卖**，流水在后台继续；断网卖三笔 → 联网 → 服务器上每条流水恰好一条；第二台模拟器 20 秒内看到这笔；**崩溃注入**：在「请求发出后、响应到达前」「响应到达后、本地提交前」「本地提交中途」三处强杀 App，重启后不漏拉、不重复扣临时库存、服务器上不重复记账；服务器已拒绝但响应丢失 → 重试拿到的仍是拒绝，本地把这条标为没记上，临时库存被纠正；`remap` 响应丢失后重试仍得到 `remap`；进货后服务器给出的平均进价与 `cost.json` 一致（5 条 × ¥400、原 6 包货值 ¥242.80 → ¥40.05），手机显示的是服务器的数。
- §14 和审核带过来的验收：
  - 按字节拆批（S04-13，PR #10）：取一批 op 时按 `op_json` 的字节累加，到 200 个或快到 1 MiB 就截断；outbox 里积了超过 1 MiB 的 op 时分几批传完，全程不出现 413。
  - 注销期间（S04-2）：响应带 `delete_pending_until` 时停止推送，op 留在 outbox，提示「账号正在注销，N 笔还没记上，撤回后会自动补传」；撤回后自动补传、全部入账。文案注意：真实的申请注销会让全部设备退出，注销期间还在推的只有重新登录的设备。
  - 拉取窗口（S04-6）：撤销流水指向的原流水不在本地时不报错、不崩。
  - 首页和设置页的同步状态、「超过一天没传」提醒条的数来自真数据（S15-1）。
- 本地库接口的三点约束（PR #9 Fable 第二、三轮）：
  - `beginSession` / `recordResults` / `compactIfNeeded()` **不许在主线程上调**：压缩被读事务挡住时调用线程会多停：最多尝试 5 次，重试间隔合计约 0.3 秒（30+60+90+120 ms），加上每次重做 VACUUM，PR #9 实测总停顿约 0.6 秒；读事务一直不结束就每次都停。
  - §4.1 第 6 条要求处理一次同步响应在同一个事务里，而 `recordResults` 现在自己开事务、提交后再压缩。本段给它加一个**能并进外层事务的入口**（应用变更 + 改写 remap + 记结果 + 推进游标一起提交），压缩留在提交之后。崩溃注入的「本地提交中途」就是验这一条。
  - `recordResults` 必须带发送那批 op 的会话的店（op id 只在店内唯一）。

**S22b 同步引擎二：被踢、恢复队列、换身份、epoch**
- 设计稿：25b、25f。
- 产出：恢复队列的上传、被踢处理、退出登录的排空流程、epoch 握手与重传。
- 验收（XCUITest + 本机服务器）：
  - 被踢的手机下一次同步后进 25b（收银员进 25f），有未传流水时显示笔数；其中的卖出最终出现在服务器上并带补传标记；其中的进货变成「待确认」，家用设备确认后才入账。
  - 断网时退出登录：提示有 N 笔没传；联网后用旧令牌补传成功，然后才真正注销旧令牌。
  - 家用手机改扫收银员码：投影被清空，原来未传的 op 仍以**原设备**的名义入账，不会变成收银员的流水；兑码成功后、第一次拉取前先用旧令牌传一遍恢复队列，传不完不拦，照常进首页，之后每次同步继续传；恢复队列只显示笔数（§14 S13-1）。
  - 收银员被踢后重新扫码：旧 op 归在旧设备名下（已撤销），新会话是新设备。
  - 换登另一家店（审核号）：原店未传的 op 不会进演示店。
  - 服务器换 `epoch`：手机握手、重建投影、重传保留的 op，服务器上不重复。
  - 演示店重置：手机丢弃 outbox，不重放。
  - 被拒的 op 在首页提示且不再重试。
- 本地库接口的约束（PR #9 Fable 第二、三轮，§3.4）：
  - 每次同步调一次 `compactIfNeeded()`（补做没做成的压缩）；没做成（`compactionBusy`）就下次同步再试。同 S22a，这几个接口不在主线程调。
  - 恢复队列用旧令牌上传后，`recordResults` 带的是**发送那批 op 的旧会话的店**，不是当前会话的店。
  - 收银员会话下，旧会话的 op 一拿到结果就删（被拒和 `held` 的也一样），之后从 outbox **读不回结果**。要提示这类结果时，用手上这次的服务器响应，不能事后去查 outbox。

**S22c 商品图的后台下载与缓存**
- 产出：图片下载器、磁盘缓存、`Thumb` 组件接真数据。
- 验收：图片在后台低优先级下载，不占同步请求；下载失败或很慢时扫码卖出不受任何影响（注入 10 秒延迟，连扫 50 次无卡顿）；`image_ver` 变化后刷新；没图或开关关闭时显示首字；图片请求的主机是自家服务器；收银员形态同样能看到图。

**S23a 开通与设备管理**
- 设计稿：17a、17b、25d、26。
- 产出：`Features/Pairing`、已登录的手机列表、被退出手机补传的「待确认的账」列表（用 26 号通用确认面板）、通用确认面板接入（让它退出、退出登录）。
- 验收：A 出家人码，B 扫后 20 秒内看到 A 的流水；同一个码第二台扫失败；倒计时到 0 显示「这个码过期了 / 换一个新码」；收银员码未填称呼时「出码」置灰、称呼重名有提示；B 扫收银员码后是 02 首页；「让它退出」先弹确认；待确认的账逐笔「记上 / 不要」，记上后出现在记的账里；退出登录先弹确认并走 S22b 的排空流程。
- §14 带过来的：设置页「已登录的手机」右侧的数来自真数据（S15-1）。

**S23b 账号与密码、注销**
- 设计稿：23、21a（下级页）。
- 产出：设置里的「账号与密码」下级页、改密码、注销账号。
- 验收：改密码后其他手机不被强制退出，「让其他手机全部退出」可用；注销页「不注销了」是实心主按钮、「确认注销」是描边，需重输密码，页面文字与 §9.4 的真实删除期限一致（在线数据 7 天后删除，备份 35 天内清除）；提交后回到登录页，7 天内登录可撤回；注销申请期间其他手机不能记账；收银员手机上没有这些入口。

**S24 看账**
- 设计稿：09、10。
- 产出：`Features/Reports`（Swift Charts：单色，今天用朱红，其余灰；点柱子显示数值）。
- 验收：对着 S07 的夹具服务器，页面上每个数字与接口一致，对账各行相加等于最后一行；没有优惠时优惠卡不显示；口径小字「赚了 = 卖出 − 进价，损耗和盘点少的另算」；离线时显示「要联网才能看账」而不是空白或旧数；坐标轴字号 ≥ 18pt；截图对照 09、10。
- §14 带过来的（S07-1、S07-4、S07-6）：09「记了 N 笔」用 `ReportToday.count`（一次记账算一笔，与 07a 卡片数一致）；「快没货 / 快过期」只在看今天时显示；快没货里库存 ≤ 0 的显示「没货了」，待确认商品不出现（服务器已排除）；10 的「现在店里货值」取 `stock_value_end_fen`，时钟偏差跨月的那几分钟可能比商品合计少一笔，不当错误。

**S25 商品列表、改商品、待确认补全**
- 设计稿：11、22、22b、24c。
- 产出：`Features/Products`、通用确认面板接入（不卖了、删整箱码）。
- 验收：筛选「全部 / 快没货 / 快过期 / 待确认」数量正确；改卖价后，**扫任一单件码、按名称找、另一台离线后再联网的手机**都用新价，整箱码的价不变，旧流水保持原名称原价；平均进价只读；22b：待确认商品可填进价和「货架上现在有几个」，必须联网，遇到 `stale` 时提示账面数变了并重新确认；确认后「待确认」数减一，服务器上记的是 `opening`；「不卖了」单独一行在页面最下面，点了先确认，停用后扫码提示已停用但仍可卖。
- §14 带过来的（S05-9）：卖出引用未知商品时服务器自动建的待确认商品，整件行建出来的卖价是 0、没有条码。22b 遇到 `needs_review` 且 `price_fen = 0` 要先让人填卖价（发 `product_edit`），条码要挂的发 `barcode_link`，再发 `product_review_complete`；不能对这个商品 id 再发 `product_upsert`（会被拒 `invalid`）。验收加一条对应的测试。
- §14 带过来的（S07-6）：11「快没货」筛选与 09 同一条件：没停用、不是待确认、`stock_ver > 0`、`stock_qty ≤ COALESCE(low_at, low_stock_default)`。

**S26 盘点**
- 设计稿：12a、12b。
- 验收：扫码 → 显示账上数 → 填实数或点「没错」→ 下一个；账面 2 填 1 → 服务器记盘亏 1 个；**必须联网**，没网时提示「要联网才能盘点」；提交前先传完本机 outbox；另一台手机在这期间卖了一个 → 出现「账上现在是 N 个，你数的还对吗」并可确认；进度「已数 86 种 / 还有 226 种」按本月已有盘点流水的商品数算；12b 列出没数的，「去数」可直接填；没扫的商品不变；键盘无小数点。

**S27 保质期**
- 设计稿：19、20、20b、01（黄条）。
- 产出：`Features/Expiry`、首页黄条和 09 的「快过期了」接真数据。
- 验收：清单分「已过期 / 快过期 / 过几天再提醒的」；处理面板先问实际数量；已过期的默认突出「下架扔掉」，没过期的默认突出「还在卖，过几天再提醒」；数量减到 0 时突出「卖完了」并把扔掉、退货置灰；有「先不处理」按钮；扔掉后首页黄条数量减一、月报过期损耗增加、「赚了」不变；另一台手机已经处理过同一批 → 提示「这批已经处理过了」并刷新；收银员手机上没有黄条。
- §14 带过来的：首页黄条和 09「快过期了」的数来自真数据，夹具以外不出稿子上的假数（S15-1）。 批次比货架少的两种情况怎么处理，见 T6。

**S28 端到端回归与权限扫尾**
- 产出：`UITests/E2E/*`、`docs/test-matrix.md`。
- 验收：一条完整剧本在两个模拟器 + 本机服务器上自动跑通：登录 → 登记商品 → 进货 → 卖出抹零 → 撤一行 → 给收银员开通 → 收银员卖出 → 踢掉收银员 → 月报对账成立，且手机上看到的平均进价、货值与服务器逐分一致；收银员手机：界面遍历到不了任何家用页面，本地库文件里没有进价，记录下来的全部响应里没有成本字段；大字 / 标准 / 最大辅助字号各跑一遍首页和卖出页截图；连续 200 次假扫码无丢失无卡顿（主线程单帧 < 100 ms）；冷启动到可扫码 < 2 秒（模拟器上记录数值即可）。

### 阶段 E：发布

**S29 TestFlight 完整包与真机验收**
- 要读：§9.2。
- 产出：完整功能的 Beta 包、`docs/device-checklist.md`、App 图标（不含烟酒元素）。
- 验收：完整包通过 Beta 审核，家里人用外部测试公开链接装上；真机清单（iPhone 13 和 iPhone 17 各一遍）：相机连扫 20 个店里的条码一次过、静音开关打开时仍有提示音、蓝牙扫码枪 HID 模式（扫码层逐项按 §14 S14-4；扫码枪后缀必须设成回车、Tab 后缀不出码，写进 `docs/device-checklist.md` 和店里的扫码枪设置说明）、飞行模式下卖出再联网补传、连扫 50 次无漏无卡、强光和弱光各试、开通码两台真机互扫、给收银员开通再踢掉。服务器上放什么数据按 §9.2 的前置条件执行。

**S30 上架材料**
- 要读：§10。
- 演示店的「今天」（§14 T15）：16:00 重置后，过北京时间 0 点「今天」页没有卖出。上架演练时在美国西岸白天的时段看一遍，决定要不要改重置时间或种子的日期。
- 产出：`deploy/site/` 四个页面的最终内容、演示店截图脚本（`make store-shots`，用审核号登录演示小店截 6.9 寸和 6.5 寸两套）、`docs/appstore/`（名称、副标题、描述、关键词、Review Notes、隐私标签答案、Unlisted 申请说明草稿）、`PrivacyInfo.xcprivacy`、Release 归档检查脚本。
- 验收：检查脚本对**完整的 Release 归档包**（解开 `.xcarchive` / `.ipa` 后的全部文件，不只是 Info.plist）断言：最终 Info.plist 没有 ATS 例外；二进制和资源里搜不到 IP 字面量 `47.117.184.253`；没有私有 CA 证书文件；没有 Beta 专用的证书处理代码符号。截图里没有烟、酒、「烟酒店」字样和真实包装图（人工逐张看）；在一台从未登录过的手机上只用审核号、不借助第二台设备，走通卖出（手输条码）、进货、撤销、看账、注销入口；条码图页用屏幕对屏幕能被 App 扫出来；隐私政策里写的数据保留和删除期限与 §9.4 一致。

**S31 备案后切换到域名**（备案下来才能做）
- 按 `deploy/cutover-to-domain.md`（§9.3）执行。
- 验收：`https://api.yuanhuishop.cn/healthz` 证书有效；Release 包连域名走通 S28 剧本的精简版；IPv6-only 网络下可用；旧的 Beta 包（连 IP）仍然可用；四个静态页可访问。

**S32 提审与上线**
- 产出：App Store Connect 填好全部信息（销售范围只选中国大陆）并提交；`docs/runbook.md` 定稿（续费日历：开发者会员、域名、ECS、OSS、快鸟额度、证书）。
- 验收：§10 清单逐项打勾并有截图；提审期间服务器不做任何变更；过审后家里每台手机从 App Store 安装并保持登录（同一 Bundle ID，钥匙串里的令牌继续有效），TestFlight 版本下线。
- 被打回时的顺序（每一步都是一次重新提交或一次向苹果的申请，各留约一周）：① 以「公众无法使用」打回 → 打开 `demo_login_enabled`，在回复里说明并重新提交。② 仍不过 → 走 Unlisted：在 Review Notes 写明打算走不公开链接分发，重新提交审核；审核通过后在苹果的 Unlisted 申请表单提交申请，**等苹果批准**后拿到链接才算完成。它是一次正式申请，不是改一个配置。③ 审核员要求证明有权代为提交 → 这时再补授权书（§12）。

---

## 9. 部署、备份、监控

### 9.1 服务器布局

- ECS 上只开 22（仅密钥登录，安全组限制来源）、80、443（只开 tcp，不开 443/udp 即 HTTP/3，§14 S10a-5）。Postgres 不对外。开 2 GB swap。主机 ufw 管不到 Docker 映射的端口，真正的边界是安全组（默认安全组自带的 22 / 3389 / ICMP 对 `0.0.0.0/0` 规则要删）。
- **客户端 IP 与限速**（§14 S03-6）：`api` 的端口只允许 Caddy 访问（只绑本机或 Compose 内部网络，不映射到公网，安全组也不放行）。接 Caddy 时打开 `TRUST_PROXY`，并且**只信一跳**（只信 Caddy 这一层给的地址，不信请求自带的整条 `X-Forwarded-For`）；默认关。S03 合并时的实现是打开后信整条头，S10a 要改成只信一跳，改完之前 `api` 端口不许对公网开。S10a 的实现按地址（§14 S03-6（补）、S10a-1）：`TRUST_PROXY=1` 必须同时配 `TRUSTED_PROXY`（Caddy 的固定地址 `172.30.0.2`，不许 `/0`），只有 TCP 对端在名单里才取 `X-Forwarded-For` 最右一项；部署时还要确认 Caddy 看到的是真实客户端 IP。
- Compose 三个服务：`caddy`（TLS、静态页、反代；**版本锁定**，证书状态放在持久化数据卷）、`api`（Node，内存上限 512 MB 且 `memswap_limit` 同为 512 MB（§14 S10a-7），不设 `UV_THREADPOOL_SIZE`（§14 T2-3））、`postgres`（`shared_buffers=256MB`，数据卷 `/data/pg`）。图片缓存 `/data/img`。
- 配置和密钥在 ECS 的 `/opt/yuanhui/.env`（权限 600）：数据库密码、OSS 密钥（给 RAM 子账号最小权限：api 的账号不碰 `backups/`、不能删 `deletions/`，备份另用一个账号，§14 S10a-6、T21）、快鸟 AppCode、审核号密码、备份加密口令。**任何密钥不进仓库、不进 CI 日志。**
- **备份加密口令另存**：部署机（这台 Mac）的钥匙串，Haoqiang 的 iPhone「密码」App、纸质一份（§14 S10b-10）。整台 ECS 丢了也要能解开备份。S10b 验收时确认。
- OSS 两个 bucket（上海，私有）：`yuanhui-img`（商品图）、`yuanhui-backup`（备份、`exports/` 导出包、`deletions/` 删除记录）。ECS 走内网 endpoint，不花流量费。
- 发布：合并到 `main` → CI 构建镜像推 ACR（标签 = 提交号）→ 在本机跑 `deploy/deploy.sh <提交号>` → ECS 拉镜像、跑迁移、重启 `api`、探 `/healthz`，失败自动换回上一个标签。迁移必须向后兼容一个版本（先加列后用）。

### 9.2 备案下来之前怎么连后端

**先分清两件事：连得通，不等于可以对外提供服务。**

- 连通性：未备案的域名解析到大陆服务器，阿里云会按请求里的域名（HTTP Host / TLS SNI）拦截；直接用 IP 访问在网络上不会被拦。备案审核期间，`yuanhuishop.cn` 和 `api.yuanhuishop.cn` 上不提供任何 HTTP 服务（Caddy 里先不配这两个站点，也不要为它们申请证书）。
- 合规性：阿里云的备案说明里，只通过 IP 访问的网站或 App 同样有备案路径，**IP 访问不是天然豁免**。所以「IP 能连上」只解决开发联调，不能当作「备案前就可以承载真实经营数据」的依据。

由此定下的做法：

| 阶段 | 服务器上放什么 | 条件 |
|---|---|---|
| 开发联调、S11b 探针、S29 真机验收 | 只有演示小店和测试店的**假数据** | 现在就可以做 |
| 黄总一家试用（备案通过前） | 试用店的数据，明确告诉黄总「这段时间是试着用，账不作数」；或者用方案 C 的离线试用 | 现在就可以做 |
| 正式建库、记真实经营账 | 元辉店的真实数据 | **备案通过之后**；或者 Chitu / 黄总先向阿里云备案客服问清楚「备案审核期间，只有自家几台手机、需要登录的封闭测试通过 IP 访问」是否允许，得到明确答复后才提前（§12） |

各环境连哪里：

| 环境 | 构建配置 | 连哪里 |
|---|---|---|
| 日常开发、CI、XCUITest | Debug | 本机 `http://localhost:8787`（Info.plist 里只开 `NSAllowsLocalNetworking`） |
| 真机联调、TestFlight（备案前） | **Beta** | `https://47.117.184.253`（见下） |
| 提审和正式版 | Release | `https://api.yuanhuishop.cn`，无任何 ATS 例外 |

Beta 的 HTTPS 按顺序尝试，在 S10a（服务器端）和 S11b（App 端）定下来。**哪个方案可行，以真机上 Beta 包的 `URLSession` 实测为准，Safari 没有警告不算数。**

- **方案 A（首选）：给 IP 签公开受信任的证书。** Let's Encrypt 已正式支持 IP 地址证书，属于短期证书（有效期约 160 小时）。注意 Caddy 对 IP 站点默认用自己的本地 CA，**只写一个 IP 站点不会自动拿到公网证书**：必须锁定一个验证过的 Caddy 版本，显式配置公网 ACME 签发方和短期证书 profile，把证书状态持久化，并且真正观察到自动续期成功。风险：从上海 ECS 连 Let's Encrypt 偶尔不稳，160 小时的有效期意味着续期连续失败两三天就会断。
- **方案 B（A 不通或不稳时）：自建私有 CA。** 在本机生成 CA（私钥只留本机钥匙串），签一张 `IP SAN = 47.117.184.253` 的服务器证书给 Caddy；CA 证书只打进 Beta 配置的包。
- **关于 ATS，不预先保证任何一种方案免配置。** Apple 现行文档对 iOS 17 起连接 IP 地址有专门的规定，私有 CA 也不能只靠在 `URLSessionDelegate` 里放宽信任来绕过 ATS。Beta 包到底需要哪些 Info.plist 键值、私有 CA 是否可行，由 S11b 对照 Apple 当前文档逐项实测后写进 `docs/beta-probe.md`；任何例外只出现在 Beta 配置里。
- **方案 C（A、B 都不行）：备案前不联网。** TestFlight 包以「离线试用」方式运行：本地库加一份假数据或家里自己录的数据，不同步；联网功能等备案下来用域名。C 阶段的全部界面本来就不依赖服务器，这条退路始终存在。
- **不采用**：`NSAllowsArbitraryLoads` + 明文 HTTP（密码和账本明文过公网）；境外中转服务器或隧道（多一台机器、多一段不稳定的跨境链路）。

其他注意事项：
- TestFlight 用**外部测试公开链接**（Chitu 默认值）：要过一次 Beta 审核，Beta 审核同样用审核号和演示小店；家里人点链接安装，不需要 App Store Connect 账号。没有备案号时大陆能否安装，由 S11b 尽早验证。
- Beta 和 Release 是**同一个 Bundle ID**、同一个数据库，从 TestFlight 版换到正式版后钥匙串里的令牌继续有效，不用重新登录。
- IP 字面量在纯 IPv6 网络（NAT64）下依赖系统合成地址，S11b 实测；**提审的包绝不能用 IP**。
- 备份和监控从 S10b、S10c 起就生效，不等真实数据。
- **服务器地址下发（11/21）**：备案通过、域名站点起来之后，服务器在 `GET /v1/config` 下发 `api_base = https://api.yuanhuishop.cn`（S21），装着连 IP 的老版本的手机自己切到域名，不用重装；§9.3 的切换步骤照做，这一条只是省掉「每台手机先更新」的等待。 App 只采用白名单内的主机，见 S21。
- 备案通过前 `yuanhuishop.cn`、`api.yuanhuishop.cn` 都不解析到这台 ECS（§14 S10a-4）：上面不提供服务，留着只增加备案被驳回的风险。
- 方案 A 续期不稳时**不直接换方案 B**（§14 S10a-3）：部署后观察 14 天，出现过证书剩余有效期低于 48 小时或过期才算不稳；切 B 的前提是 S11b 已在真机 Beta 包上实测私有 CA 可连（T22）。在那之前只停同步、等 S11b，不许加 ATS 例外或 `-k`。B 只许 Beta 配置里把 CA 打进包做锚点固定（CA 带名称限制、只签这个 IP，服务器证书 ≤ 397 天），不在家人手机上装描述文件；S11b 实测 B 还需要 `NSAllowsArbitraryLoads` 之类才能连 → 走方案 C。服务器端切换步骤见 `docs/runbook.md`。

### 9.3 备案下来后的切换步骤（`deploy/cutover-to-domain.md`）

1. 确认网站备案和 App 备案都已通过，记下备案号；按要求在 30 天内做公安备案；网站底部挂备案号。
2. Caddy 增加站点 `api.yuanhuishop.cn`（反代 API）和 `yuanhuishop.cn`（静态页），自动签发证书。**IP 站点保留不动。**
3. 从本机和一台手机的蜂窝网络验证 `https://api.yuanhuishop.cn/healthz`；验证 IPv6-only 网络（Mac 开 NAT64 共享给手机）。
4. 用 Release 配置出一个 TestFlight 包（连域名），家里手机更新；逐台确认仍是登录状态、能同步。
5. 试用期的数据怎么处理由黄总定：清空试用店、从头正式建库，或者把试用店直接转正。然后开始记真实的账。
6. 在 App Store Connect 填备案号，按 §10 提审。
7. 正式版上线、所有手机都更新后观察两周，日志里确认没有任何请求再走 IP 站点，然后删掉 IP 站点和（方案 B 的话）私有 CA；`min_build` 调到第一个域名版本。
8. `tools.yuanhuishop.cn`（黄总的发票工具）不在本计划范围，只在 Caddy 里预留位置。

### 9.4 备份

- **目标**：营业时间内最多丢 1 小时的数据（RPO），1 小时内恢复到可用（RTO）。手机重传（§4.6）是在这之上的补救，不计入保证。
- 时间表：每天 8:00–22:00 **每小时一次**，另加 02:30 一次。`pg_dump`（自定义格式，库很小，一次不到 1 秒）→ 用口令加密 → 传 `yuanhui-backup`。
- 每次备份同时写一份**清单**：每张表的行数、每个店的流水 `value_delta_fen` 合计、`cogs_fen` 合计、各商品库存与货值的校验和、最近一个月的月报数字。恢复演练按清单逐项比对。
- 保留：所有备份 **35 天**后由 OSS 生命周期规则删除，不留更长的归档。这样「注销后数据在 7 + 35 天内彻底清除」这句话是真的，隐私政策和注销页都按这个写。
- 删除记录：账号注销到期清除时，在删在线数据**之前**往 OSS `deletions/` 写一条记录（店 id、时间）；写不成就不删，下一轮重来（PR #20 Codex 1）。它不在数据库里，不会随备份回滚。`restore.sh` 恢复完任何备份后**必须重放删除记录**，把已注销的店再删一遍，并拒绝这些店的旧令牌和重传。
- 停用或注销时先导出：非演示店在注销申请时自动生成导出包（S09），由 Chitu 转交黄总；到期清除时一并删掉服务器上的导出包。
- 每次备份成功后写一个心跳对象；监控发现营业时间内心跳超过 2 小时没更新就告警。
- ECS 云盘开自动快照（每周一次，留 4 份），防整机误操作。
- 恢复演练：S10b 在另一台机器上做一次，上线前（S32）再做一次，步骤写在 runbook。

### 9.5 监控与告警

所有告警发给 **Chitu**，由 Chitu 转告 Haoqiang 或黄总；不直接发给黄总。

| 监控什么 | 怎么做 |
|---|---|
| 服务存活 | 本机定时任务每 10 分钟探 `/healthz`，连续 2 次失败告警；再加阿里云云监控的站点监控做第二来源 |
| CPU、内存、磁盘 > 80% | 阿里云云监控（免费） |
| 证书 | 方案 A 下每 6 小时检查 IP 证书剩余有效期，< 48 小时告警 |
| 备份心跳 | 见 9.4 |
| 营业时间内没有同步 | 元辉店在 8:00–21:00 之间超过 3 小时没有任何设备同步成功 → 告警（可能是店里断网或 App 出问题） |
| 接口错误率 | pino 日志；5xx 每小时超过 20 次告警 |
| 快鸟额度 | 每次调用后记余量，< 50 次告警 |
| 登录异常 | 账号被锁定时记日志并告警 |
| 账号注销申请 | 有人申请注销 → 立刻告警（附导出包位置） |
| 被退出的手机有待确认的账 | 超过 24 小时没人处理 → 告警 |

日志不记密码、令牌、开通码；保留 30 天。

---

## 10. 上架前清单

**账号与演示**
- [ ] 审核号（用户名、密码写进 Review Notes）登录后是「演示小店」，数据见 S09；每天自动重置且不打断正在使用的人。
- [ ] 审核员不需要第二台手机：登录页永远有账号密码入口；卖出、进货、盘点都能手输条码或按名称找。
- [ ] `yuanhuishop.cn/review-barcodes`：演示店商品的条码图一页，可以直接用手机扫电脑屏幕。
- [ ] 真机录屏一段：扫码卖出、抹零、扫码枪、离线记账后补传、给家人开通的扫码登录、收银员界面。
- [ ] Review Notes 写明：门店自用的进销存记账工具；账号由门店开通所以没有注册；不涉及支付；收银员界面是家用号功能的子集。
- [ ] 提审期间服务器不维护，演示店可用。

**公开上架又不开放注册的应对**（最容易被拒的一点，见 §11 风险 1；处理顺序见 S32）
- [ ] 描述第一段写清楚「门店自用，账号由门店开通」。
- [ ] 「看看演示」已经做好，开关 `demo_login_enabled` **默认关**；被以「公众无法使用」打回时打开并重新提交。
- [ ] Unlisted 退路的材料备好（S30 的申请说明草稿）。它需要：一个提交审核的版本、Review Notes 里说明意图、另行向苹果提交申请、**苹果批准**。为它预留至少一到两周。「看看演示」只能改善陌生人的第一印象，不能代替分发方式获批。

**隐私与账号**
- [ ] 隐私政策 `yuanhuishop.cn/privacy`，运营者写江阴市周庄元辉烟酒店；登录页和设置里都有入口；支持页 `/support` 有联系方式。
- [ ] 隐私政策和注销页写明真实的保留与删除期限：申请注销后 7 天内可撤回；到期删除在线数据和商品图；备份在此后 35 天内滚动清除；注销期间不能记账。
- [ ] App 隐私标签如实填：账号标识、店铺经营数据（与用户身份关联，用于 App 功能），不追踪、无第三方 SDK。
- [ ] `PrivacyInfo.xcprivacy`：声明用到的系统 API 原因（UserDefaults 等）。
- [ ] 相机权限说明：「用来扫商品条码和登录二维码，不保存照片」。拒绝权限后 App 仍可用（27a、27b）。
- [ ] App 内可注销账号（23）：家用号和审核号可见，重输密码。
- [ ] 加密出口合规：只用系统 HTTPS，`ITSAppUsesNonExemptEncryption = NO`。

**内容**
- [ ] 截图用审核号在演示小店里截：没有烟、没有酒、没有「烟酒店」字样；商品图只用首字或自绘通用图，**不用真实包装图**。
- [ ] 登录页不出现店名，副标题「小店扫码记账」。
- [ ] App 名、副标题、描述、关键词里不出现「烟」「酒」。
- [ ] 图标不含烟酒元素。
- [ ] 商品图的使用授权已核对（`docs/image-rights.md`），开关状态与结论一致。

**备案与主体**
- [ ] App Store Connect 填 App 备案号；App 名「元辉账本」、Bundle ID、证书公钥和 MD5 与备案**逐字一致**（`signing/beian_md5.txt`、`beian_pubkey.txt`）。证书到期换新时要同步变更备案。
- [ ] 授权书：**暂不准备**（Chitu 默认值）。审核员依据 5.2.1 要求证明时再补：元辉烟酒店授权 Haoqiang 用其个人开发者账号发布「元辉账本」，经营者签字，附营业执照。
- [ ] 销售范围**只选中国大陆**；价格免费；年龄分级、分类（商务或财务）填好。

**技术**
- [ ] Release 归档包检查通过（S30）：只用域名，无 ATS 例外，包里没有 IP 和私有 CA；IPv6-only 网络验证通过。
- [ ] 最低版本检查 `min_build` 可用，将来能强制升级。
- [ ] 备份恢复演练做过第二次；监控告警都验证过。
- [ ] 真机清单（S29）在两台机型上全部通过。

---

## 11. 风险

| # | 风险 | 可能性 / 后果 | 应对 |
|---|---|---|---|
| 1 | **公开上架但陌生人下载后只有登录框**，审核以「面向特定商户、公众无法使用」（3.2 / 4.2 类理由）打回。黄总上一个 App 被 2.1 打回过 | 高 / 拖延 1–3 轮 | Review Notes + 演示号 + 录屏先交齐；「看看演示」开关；最后退路 Unlisted（要苹果另行批准）。计划里留出两到三轮的时间 |
| 2 | **备案时间和证书绑定**：备案 1–3 周（可能被退回补材料）；提审卡在备案号上；真实经营数据也要等备案（§9.2）；备案登记了当前证书的公钥和 MD5，证书一年到期换新要变更备案 | 中 / 上线推迟 | C、D 阶段不依赖备案；备案前用假数据和试用数据；证书到期日写进续费日历，提前一个月处理 |
| 3 | **成本和同步算错账**（负库存、进价没填、离线晚到、并发盘点、撤销、抹零分摊、跨月），黄总一眼能看出对不上 | 中 / 失去信任 | 规则在 §5 写死；共享向量；I1–I8 性质测试；对账等式由同一张流水求和天然成立；试用期每周人工对一次账 |
| 4 | 备案前 Beta 包连 IP 的方案走不通（Let's Encrypt 续期不稳、ATS 对 IP 和私有 CA 的限制） | 中 / 备案前无法联网试用 | S11b 尽早实测；方案 B；方案 C 离线试用兜底 |
| 5 | 没有备案号时 TestFlight 外部测试在大陆装不了，或 Beta 审核不过 | 中 / 试用推迟到备案后 | S11b 用空壳包尽早验证；退路是内部测试（家里人加为 App Store Connect 用户）或等备案 |
| 6 | 快鸟条码库对香烟、本地品牌命中率低，有图率低；图片使用授权不明确 | 中 / 建库多打字、没有商品图 | S08 实测 20 个并核对条款；名称永远可手输；图片有总开关，关掉就是首字；备选聚美智数 |
| 7 | 烟草相关内容招来 1.4.3 追问 | 低到中 | 演示店、截图、描述、图标、登录页全部不出现烟酒；真实店铺数据不受影响 |
| 8 | 开发者账号主体（Haoqiang 个人）与备案主体（元辉）不一致；授权书暂不准备 | 低到中 / 多一轮来回 | 信息逐字一致；被要求时再补授权书（需要经营者本人签字，届时至少要几天）；长期方案是元辉自己注册组织账号 |
| 9 | 运维只有一个人、在境外 | 持续 | runbook、续费日历、告警经 Chitu 转达、发布一条命令且可回滚、手机离线可用 |
| 10 | 2C2G 单机，数据库和 API 同机；没有做连续归档，最坏丢 1 小时 | 低 | 每小时备份 + 云盘快照 + 手机 14 天重传作补救；异机恢复演练 |
| 11 | 家用号密码全家共用，登录口在公网 | 中 / 账本泄露 | 强密码、失败锁定、按 IP 限速、设备列表可逐台踢、「让其他手机全部退出」 |
| 12 | 被踢的设备在 30 天内仍可补交卖出，时间由手机自己填，无法证明真假 | 低 | 只有卖出直接入账且带标记、可见可撤；其他类型要家用手机确认；30 天后关闭 |
| 13 | 盘点必须联网，店里网不好时盘不了 | 低 | 卖出和进货不受影响；盘点本来就是每月一次、可以挑时间 |
| 14 | 老人不会用 / 字太小 / 误触 | 中 | 大字默认开；破坏性操作都有确认面板；试用期收集反馈再改 |
| 15 | 执行者一段做不完，或自行改口径 | 中 | 段已经切小且各自可独立验收；验收可机器检查；两方评审；规则类内容集中在 §3–§6 |

---

## 12. 待定项

**已按 Chitu 的默认值写进计划，等 Haoqiang 确认（有变再改）：**

| 事项 | 默认值 | 改动时影响哪里 |
|---|---|---|
| 「看看演示」入口 | 做，默认关，被打回再开 | S21、S32、设计稿 13 要补一个入口的样子 |
| TestFlight | 外部测试公开链接 | S11b、S29、§9.2 |
| 上架地区 | 只上中国大陆 | S32 |
| 收银员 | 按 17b，扫码开通的无密码设备 | S03、S21、S23a |
| 仓库与 CI | `clawchitu/yuanhui-zhangben` 私有仓库；服务器测试用 GitHub 托管 Linux runner；iOS 用这台 Mac 的自托管 runner；Codex 和 Fable 评审由 Chitu 在每个 PR 上触发，意见写在 PR 评论里 | S00、§2.1 |
| 告警 | 发给 Chitu，由 Chitu 转告 | S10c、§9.5 |
| 停用账号 | 先导出一份数据给黄总 | S09、§9.4 |
| 授权书 | 暂不做，被苹果打回再说 | §10、S32 |

**还要问 Haoqiang：**
- **Q1** 备案通过前，要不要去问阿里云备案客服「审核期间自家几台手机通过 IP 做封闭测试」是否允许？没有明确答复前，计划按「备案前只放假数据和试用数据」执行（§9.2）。
- **Q2** 商品图：如果快鸟的条款对缓存和展示图片没有明确说法，开不开？（S08 会把条款原文摘出来。在决定前保持关闭，显示首字。）
- **Q3** 备份只保留 35 天、不留更长的归档，是为了让「注销后彻底删除」的说法成立。可以吗？如果想留年度归档，隐私政策里的期限要相应改长。

**要问黄总：**
- **Q4** 扫码枪买不买、买哪款（必须支持 HID 键盘模式 + 回车后缀）。真机验收需要它。
- **Q5** 旧收银机能不能导出商品表（能的话写一个一次性导入脚本，省一晚上扫码）。
- **Q6** 建库方式：一晚上扫全店，还是边卖边建。
- **Q7** 家用号的用户名和初始密码怎么定、谁保管。
- **Q8** 备案下来之前先「试着用」（账不作数，备案后重新建库或转正），可以接受吗？先给谁的手机装？
- **Q9** 撤销以前日子的账，算在撤销那天（本计划的做法，已过去的月份数字不会变）可以吗？
- **Q10** 盘点时手机必须有网，可以吗？
- **Q11** 收银员隔天才想起来要撤昨天的账，只能让家里人撤，可以吗？

**技术上待验证（各段内解决，不用问人）：**
- Caddy 上 Let's Encrypt IP 短期证书的配置和从上海 ECS 续期的稳定性（S10a）。
- Beta 包连 IP 所需的 ATS 配置、私有 CA 是否可行、NAT64（S11b）。
- 无备案号时 TestFlight 外部测试在大陆能否安装（S11b）。
- 快鸟的香烟命中率、有图率、图片条款（S08）。
- GitHub Actions 推阿里云 ACR 的稳定性（S10a）。

第二版候选（不在本计划内）：拍进货单识别批量入库、拍价签填售价、拍照换商品图、朗读总价、打印「结账」条码代替点击、网页后台、`tools.yuanhuishop.cn`、数据库连续归档（按时间点恢复）。

---

## 13. 对 Codex 意见的处理（2026-11-20）

意见原文在 `design/review-plan-v2-codex.md`，共 22 条。**17 条全部采纳，5 条采纳了主体、其中一部分没有照做**，没有整条驳回的。

全部采纳并已改进正文的：

| # | 意见 | 改在哪里 |
|---|---|---|
| 2 | 分页会漏数据 | 每行唯一序号、墓碑、两条流各自游标（§3、§4.2、S04） |
| 3 | 换角色清库与补传冲突 | outbox 归属不可变、恢复队列用旧令牌（§3.4、§4.5、S13、S22b） |
| 5 | 正库存没填进价被算成零成本 | `cost_known` 独立状态（§3.2、§5.2） |
| 6 | 回填 `cogs` 破坏一致性 | 取消回填，改为 `cost_fix` 补记流水（§3.3、§5.2、§5.3、S06） |
| 7 | 收银员借重复登记改商品 | 冲突时不改赢家任何字段（§4.4、S04） |
| 9 | 整数规范和边界 | §5.0、`rounddiv.json`、全零购物篮 |
| 10 | 结果重放与本地原子提交 | §4.1 第 6 条、§4.2、S13、S22a 的崩溃注入 |
| 11 | 批次并发与撤销生命周期 | `handle_ver`、生命周期表（§5.4、S06） |
| 12 | 单件卖价两处存储 | 单件码不存价（§3.2、S04、S25） |
| 13 | Caddy 与 ATS 的假设不足 | §9.2 重写，去掉「不需要 ATS 例外」的保证，S10a、S11b、S30 归档包检查 |
| 15 | 演示店重置缺客户端失效协议 | `discard_outbox`，不换 epoch（§4.5、S09） |
| 16 | 「全部删除」与备份保留冲突 | 备份统一 35 天、删除记录、恢复后重放（§9.4、S09、S10b、§10） |
| 17 | 依赖图缺边和倒置 | 依赖图重画；S21 不做同步；S03 改契约级测试；S19 不验收权威平均进价 |
| 18 | S10、S22 太大 | 拆成 S10a/b/c、S22a/b/c，顺带把 S23 拆成 a/b |
| 19 | TestFlight 验证太晚 | 新增 S11b |
| 20 | 路径过滤卡死必需检查 | §2.1、S00 三类 PR 验收 |
| 21 | Unlisted 缺申请与批准节点 | §10、S32 |

采纳了主体、其中一部分没有照做的（每条一句理由）：

| # | 采纳的部分 | 没照做的部分和理由 |
|---|---|---|
| 1 | 盘点、期初、补全带账面版本，冲突时重新确认；迟到流水自动补偿；两个验收场景都加了（§5.6、S06、S26） | 没做「盘点期间暂停其他手机对该商品记账」：店里不能因为有人盘点就卖不了东西，而且离线的手机本来也暂停不了；版本校验加迟到补偿已经覆盖这两种丢账。 |
| 4 | 请求带 epoch 并先握手；口令另存两处；异机恢复并按清单逐项比对；把手机重传降为补救并写明限制；备份频率加到每小时一次（§4.6、§9.4、S10b） | 没上 WAL 归档 / 按时间点恢复：一台 2C2G 上由一个人维护，归档链路本身就是新的故障点；每小时全量备份（库不到几 MB）已经把最坏损失限制在 1 小时，已列为第二版候选。 |
| 8 | 被踢设备的进货、盘点、撤销、改商品改为暂存等家用确认；收银员撤销按服务器收到的日期判，伪造时间无效（§4.5、§6、S05） | 被踢设备的**卖出**仍然直接入账、不进暂存：这正是 review-1119-mockups 第四节第 3 条要求的，收银员那几笔不能丢，而且卖出带标记、看得见、可以撤。收银员跨日撤销也没有做「转家用确认」的队列，直接拒绝并提示让家里人撤：少一个状态机，结果一样。 |
| 14 | 写明「连得通不等于合规」；备案前只放假数据和试用数据；向阿里云确认列为提前记真实账的前置条件；补了离线试用的方案 C（§9.2） | 没有把「未确认前完全不用 IP 联调」作为规定：开发联调和 TestFlight 探针用的是假数据，这是本次任务明确要求计划覆盖的内容，不涉及对外经营。 |
| 22 | S08 增加条款核对并留档；图片有总开关；条款明确禁止就关（S08、§10） | 条款没有提及时不默认永久禁用，而是先关着、交 Haoqiang 决定：这是一个需要登录的店内工具，图片不进截图和演示店，是否可接受属于业务判断，不该由计划替他定。 |

---

## 14. S01 疑问裁定（2026-11-20）

S01 的 PR（#4）在描述里列了 14 条计划没写清的地方。裁定如下，结论已改进正文。

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| Q1 | 实收没有上限 | `paid_total_fen` ≤ 19,999,999,800 分（200 行 × 单行上限），多收也不能超过 | §5.0 |
| Q2 | 调整额为 0 还记不记 | 不记。金额为 0 的 `cost_adjust` 一律不记；没有可补记行的 `cost_fix` 也不记 | §5.2 进货 |
| Q3 | `product_review_complete` 的进价是否必填、缺 `entry_id`；`quick` 登记要不要 `base_unit` | 进价必填（可以填 0），只有 `opening` 可以不填；payload 加 `entry_id`；`quick` 登记不带 `base_unit`，服务器默认「个」，`product_edit` 可以改基本单位 | §4.3、§5.2 |
| Q4 | 期初没填进价但进价已知时记成什么类型 | 记 `count`，金额按盘点规则，月报算在「盘点少了的」 | §5.2 |
| Q5 | 撤销后库存为正、货值为负怎么归位 | 归位目标统一是 `v = q × c`；`q > 0` 且 `v < 0` 时也触发 | §5.2 撤销，新增必过向量 |
| Q6 | 补记后撤销卖出，货以 0 成本回到货架，拉低平均进价 | 不接受。撤销时除冲销 `cost_fix` 外再记一条 `cost_adjust`（+数量 × `b`）；`cost_fix` 行存 `unit_cost_fen = b` | §5.2 成本补记，新增必过向量 |
| Q7 | 进价未知时的扔掉、退货、盘点；撤销让进价变已知的那次进货 | 金额记 0、标 `cost_missing`、不参加补记，报表注明笔数；`k` 只增不减，撤销后不回到假，已记的 `cost_fix` 不冲 | §5.2、§5.3 |
| Q8 | 被踢设备的 `product_upsert` | `quick` 的直接收（不要求证明被卖出用到）；非 `quick` 的暂存等家用确认 | §4.5、§6.1 |
| Q9 | `/v1/me`、`/v1/recovery/import` 等不在权限表里 | `/v1/me`：三种身份能，被踢拒；`/v1/recovery/import`：恢复模式下家用和收银员能，审核和被踢拒；`/healthz`、`/v1/auth/demo` 不需登录；`barcode_unlink` 同 `barcode_link`。权限表不允许留待定 | §6.1、§7 |
| Q10 | 数量上限 | 基本单位数量 ≤ 9,999,999；进货总价受单行金额上限约束（执行者的理解正确） | §5.0 |
| Q11 | `snoozed_until` 当天提不提醒；同一到期日谁先扣 | 当天恢复提醒；先扣先建的批次 | §5.4 |
| Q12 | 单件码和整件码同时匹配；超过 4 个显示哪 4 个；完全相等又是前缀 | 按「商品 + 换算数量」去重，单件和整箱是两个候选；完全相等的排第一，其余按条码升序，显示前 4 个；两个都列、不自动选 | §5.5 |
| Q13 | `/v1/health` 还是 `/healthz` | `/healthz`。契约按 §7 写是对的，S02 改服务器代码 | §7、S02 |
| Q14 | 首次同步没有 epoch | 登录、兑码、演示登录的响应带 `epoch`；`/v1/sync` 的 `epoch` 必填，不允许为空 | §4.2、§7 |

S01 改完后（提交 e1046a0）又留了 5 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| R1 | `opening` / `product_review_complete` 带不带 `base_qty` | 服务器只比对 `base_ver`，`base_qty` 只留档。`count` 两个都必带；`product_review_complete` 必带 `base_ver`、`base_qty` 可选；`opening` 两个都可选，但不带 `base_ver` 的只在商品 `stock_ver = 0` 时接受，否则拒 `stale`（执行者设成可选是对的） | §4.3、§5.6 |
| R2 | `remap` 只装得下一个商品 | 改成映射 `{旧商品id: 赢家商品id, …}`，可以有多对，任何引用了别名的 op 都可能带 | §4.2 |
| R3 | 一个候选有多个匹配条码时取哪个 | 取代表条码：完全相等的优先，否则最小的匹配条码；排序、显示、加入购物篮都用它（执行者的做法正确） | §5.5 |
| R4 | 冲销 `cost_fix` 行存不存 `unit_cost_fen` | 存，照抄原行不取反；所有冲销行的 `unit_cost_fen` 都这样（执行者的做法正确） | §3.3 |
| R5 | 进价未知且盘点数等于账面数时记不记 | 记。`d = 0` 的盘点一律记一条数量和金额为 0 的 `count`，不标 `cost_missing`，不论进价是否已知 | §5.2 |

S11 的 PR（#5）提了 4 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S11-1 | 标准模式要不要字号上限 | 要。两种模式的上限都封在 `accessibility2`（review-1119 第 2 节本来就是这个意思，计划写漏了）。标准模式范围 = `xSmall … accessibility2`。改动放到 S15 做 | S11、S15 |
| S11-2 | 大字模式实际是 23 / 21pt，不是设计稿的 22 / 18 | 接受。要求是「不低于 22 / 18」，用系统文字样式比自定义基准字号稳妥；后面哪一页因此放不下，再单独处理那一页，不改这套字号 | S11 |
| S11-3 | Beta / Release 还没有服务器地址 | 可以。接口基址在 S11b（Beta）和 S21（三个配置）加进 xcconfig | 不用改 |
| S11-4 | 数字键 56pt（稿子 54），步进器 56 / 46pt | 接受 56pt 的数字键和 56pt 的步进器。46pt 的小号步进器外观照稿子，但点按区域要扩到不小于 56pt，在 S15 / S16 第一次用到时改 | S11、S15 |

S02 的 PR（#6）提了 10 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S02-1 | `products.image_ver` | 保留为单独一列，`image_key` 每变一次 +1，0 = 没图 | §3.2 |
| S02-2 | 跨表的 `rev` 唯一要不要库层面强制 | 不用。每张表 `unique(store_id, rev)` 加 S04 的统一取号函数和 I7 性质测试就够 | 不用改 |
| S02-3 | 暂存 op 的处理结果存哪 | 改 `status`（记上 → `applied`；不要 → `rejected` + `reject_code = discarded`），更新 `result`，并加 `resolved_at`、`resolved_by_device` 两列 | §3.3 |
| S02-4 | `devices.revoke_reason` 的取值 | `kicked / revoke_others / logout / account_delete / demo_reset`，加 CHECK，与 `revoked_at` 同有同无；`demo_reset` 即 `discard_outbox` | §3.1 |
| S02-5 | 整件码是否必须带价 | 不必。为空表示按「单件卖价 × 换算数量」算 | 不用改 |
| S02-6 | 默认隐私链接；密码最短 8 位 | 都可以。密码最短 8 位作为规定 | 不用改 |
| S02-7 | 启动时不自动迁移 | 同意，由 `deploy.sh` 先单独跑迁移，失败不换镜像 | 不用改 |
| S02-8 | 复合外键；`lot_moves` 没有 `store_id` | 复合外键的做法对。`lot_moves` 加 `store_id` 和两条复合外键（计划漏写了）。另外手机生成 id 的表主键改成 `(store_id, id)`；设备 id 每次登录或兑码新生成 | §3 通用约定、§3.1、§3.3 |
| S02-9 | 一行流水只能被冲销一次 | 对 `cost_fix` 不成立，它会被多次部分冲销。约束改成只管非 `cost_fix` 的行 | §3.3 |
| S02-10 | `REQUIRE_DB` 不再使用 | 同意，服务器测试一律要真实 Postgres | 不用改 |


S12 的 PR（#7）提了 4 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S12-1 | 整件码是否必须带价，schema 与 S02-5 不一致 | schema 跟 S02-5：`pack_qty > 1` 时 `pack_price_fen` 可选；契约改动实际合在 S12 的 PR（#7）里，没有单独开 PR | `ops.schema.json`、例子文件、§4.3 |
| S12-2 | 同码合并的粒度 | 按「商品 + 换算数量 + 这一件的卖价 + 单位名」合并；不同单件码合并，同换算不同价的整件码分行 | §5.5（S12 已实现，S13 的前缀匹配和名称搜索沿用） |
| S12-3 | 库存和进价的可见性不在权限表里 | 不加行；由 `sync:pull` 的 `scope` 推出，ShopCore 给单独的判断，不借用进货能力 | §6、S15 |
| S12-4 | 服务器分摊未实现时的「一致」 | 以共同向量为准；S04 验收补上服务器跑同一份向量 | S04 |

抹零后改购物篮即清掉实收这一条，写进 S16 的验收（S12 只记录，不实现）。

S03 的 PR（#8）提了 9 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S03-1 | 注销期间兑码返回什么 | `403 delete_pending`。先判用过、过期（410），再判注销；申请注销时把未用的码作废，403 只是兜底 | §7、契约 |
| S03-2 | 被踢设备调 HTTP 接口的状态码 | 统一 `401 {code: revoked}`；`/v1/sync` 除外，照 §4.5 正常响应并带 `device.revoked=true`，`discard_outbox` 只由它下发。权限表里「—」的格子按拒处理，被踢设备调 `logout` 也是 `401 revoked`，手机当作退出成功。身份无权是 `403 forbidden`，没令牌或令牌不认识是 `401 unauthorized` | §6.1、§7 |
| S03-3 | 锁定和按 IP 限速的细节 | 第 5 次输错本身返回 `423 locked`（带 `locked_until`）；锁定期内再输错不计数、不延长；上锁时计数清零；成功登录清零。并发请求也必须守住：验对密码后在事务里重查锁，已锁返回 423 且不清锁。按 IP：`login`、`pair/redeem`、`auth/demo` 各自每 IP 15 分钟 30 次，超了 `429 rate_limited` 带 `retry_after_s` | §7、S03 |
| S03-4 | 注销满 7 天到真正删除之间能不能撤回 | 不能，返回 `409 not_delete_pending`（恰好第 7 天整仍可撤回）。S09 的删除任务至少每天跑一次；手机看到 `delete_pending_until` 已过就显示「正在删除」，不给撤回按钮 | §7、S09 |
| S03-5 | 出码的手机被撤销后它出的码 | 作废。不论撤销原因，未用的码兑换时返回 `410 pairing_expired` | §3.1、§7 |
| S03-6 | 反代后面怎么取客户端 IP | 加配置 `TRUST_PROXY`，默认关，只信一跳。S10a 接 Caddy 时必须打开，并且服务器端口只允许 Caddy 访问（只绑本机或内部网络，不对公网开）；S10a 验收加一条：从公网带伪造的 `X-Forwarded-For` 请求，限速仍按真实 IP 生效 | §9.1、S10a |
| S03-7 | 测试单条超时 | Vitest 单条用例和钩子超时 30 秒（登录类测试算真实的 argon2id）。不许为了快在测试里调低 argon2 参数 | 不用改 |
| S03-8 | 改密码、申请注销时原密码输错 | 不计入登录锁定（否则一台家用手机能把登录锁死），但必须限速：按账号 15 分钟内错 5 次后返回 `429 rate_limited`，两个接口共用一个计数 | §7、S03 |
| S03-9 | 演示登录进哪个店、设备越积越多 | 进最早建的演示店的审核号；没有演示店返回 `404 demo_disabled`。每次演示登录新建一行设备，由 S09 每日重置清理；审核号在注销中时演示登录怎么办，S09 做重置时一并处理 | §7、S09 |

S04 的 PR（#10）提了 14 条（S04-1…9 来自计划裁定，S04-10…13 来自 Fable 第一轮审核，S04-14 来自 Fable 第二轮审核），裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S04-1 | 本段没实现的 op 类型返回什么 | 过渡做法：`rejected: invalid`，不留档，实现后重发正常处理。S06 合并时删掉这个分支，并加测试「`ops.schema.json` 里每个 type 都有处理函数」。**已完成（PR #16）** | S04、S06 |
| S04-2 | 注销期间的写入返回什么 | 不能是 `rejected`（手机会当成终局、不再重发，撤回后丢账）。注销期间 `/v1/sync` 里的 op 一个都不应用、不留档，`results` 为空，拉取照常，响应顶层带 `delete_pending_until`；手机把 op 留在 outbox 并停止推送，撤回后自动补传。被踢设备的补传同样处理 | §4.2、§4.4、§7、契约、S04、S22a |
| S04-3 | 商品类 op 引用不存在的商品；条码已挂在别的商品上 | 拒 `invalid` 并留档，不自动建商品、不挪条码（要挪先解除再挂）。解除一个没挂着的条码是无操作，算 `applied` | §4.4 |
| S04-4 | 「逐字段后写者赢」按什么先后 | 按到达服务器、被应用的先后，不按 `occurred_at`。`product_edit` 只改 payload 里带了的字段 | §4.3 |
| S04-5 | 改基本单位时单件码的单位名 | 该商品所有单件码的 `unit_name` 跟着改，各取一个新号；整件码不动。`quick` 登记不论角色一律 `needs_review = true`。`barcode_link` 挂单件码时服务器写商品的基本单位，不看 payload 的 `unit_name` | §3.2、§4.3 |
| S04-6 | 拉取下发多久的流水 | 家用 35 天、收银员 2 天，按 `occurred_at` 的上海日历日、含今天；窗口外的流水和批次头不下发，保质期批次不受限。手机要容忍撤销指向的原流水不在本地；更早的账联网查 | §3.4、§4.2 |
| S04-7 | 条码解除后又挂上，旧墓碑还发不发 | 不发。拉取时按条码当前状态过滤，墓碑本身不删；再次解除写新号的墓碑。手机不必依赖 `removed` 和 `barcodes` 的处理先后 | §4.2 |
| S04-8 | 一家店并发请求多时等锁的请求占满连接池 | 同意进程内按店排队，正确性仍只靠数据库店铺锁。队列要有上限（默认 32），超过返回 `503 unavailable` 带 `retry_after_s`。所有拿店铺锁的写入只走 `withStoreLock` 一个入口 | §4.2、S04 |
| S04-9 | `ajv` 进运行时依赖，新增 `fast-check` | 同意。op 的 payload 按 `ops.schema.json` 用 ajv 校验，请求外壳仍用 TypeBox；`fast-check` 只做测试依赖 | §1 |
| S04-10 | `product_upsert` 的商品 id 已存在（不是别名） | 不改商品任何字段。条码已挂在这个商品上 → `applied` 无操作；其他情况（空闲、解除过、挂在别的商品上）→ `rejected: invalid` 并留档，不挂码。挂码只走 `barcode_link`。不论角色、不论 `quick` | §4.3、§4.4、S04 |
| S04-11 | op 的内容哈希怎么算 | sha256(键排序的 `{type, occurred_at 换算成 UTC 毫秒, payload}`)，不含设备。时钟被校正的 op 按手机原值算，原值存 `ops.flags.client_occurred_at`。同店别的设备发同 id 同内容也拿到当初的结果 | §4.2、§4.6 |
| S04-12 | 页没装满时游标怎么走 | 跳到同一快照里的 `stores.rev`，只进不退。`pull=false` 或被踢时游标原样返回、`total_products = 0`，手机这时不看它。游标比 `stores.rev` 大时原样返回 | §4.2 |
| S04-13 | 请求外壳和 payload 的校验 | 外壳严格校验，不成形整个请求 400。payload 不合 `ops.schema.json` → 这个 op `rejected: invalid` 并留档。权限判在 schema 之前。过了外壳但算不了哈希或存不进库的 op（`\u0000`、不成对的代理项、解析不出的 `occurred_at`；Codex 第二轮补：payload 嵌套超过 16 层或超过 1 万个节点，这项检查不递归）→ `rejected: invalid`，不留档。op 的内容不许导致 500 | §4.2、§4.4、S04 |
| S04-14 | savepoint 兜底把所有 22xxx 都当成「op 内容有问题」 | S04 只有商品类 op，可以接受。S05 / S06 加入卖出、进货以后，服务器自己算错（除零、数值溢出）也是 22xxx，记账 op 被当成终局的 `invalid`、手机不再重发，等于丢账。S05 接入记账 op 时要重新定：记账类 op 遇到预检查没拦住的 22xxx 应当让整个请求 500（手机会重发），不能单个拒收；兜底触发时一律按 error 级别记日志（op id、类型、SQLSTATE） | §4.2、S05、S06 |

待办（S04 只记录，不实现）：收银员拉取的 `removed` 墓碑要按角色过滤。S04 只写 `barcode` 墓碑，没有泄漏；但 `removed.kind` 还允许 `entry / batch / lot`，S05 / S06 里第一个写这些墓碑的段落要在 `sync/projection.ts` 里按角色过滤（收银员只收本机卖出流水和批次头的墓碑，不收 `lot`），并加进收银员裁剪测试。（已由 S05b 提前实现：`cashierRemovedVisible`，原行找不到的 `entry / batch` 墓碑不发给收银员；测试在 `sync.projection.test.ts`。）S05-14 补充：S05b 没有任何地方写 `entry / batch` 墓碑，这个过滤目前不产生实际效果。以后第一个真正删流水行的段，不能指望拉取时再回查原行（那时原行已经没了，收银员手机上的行就永远删不掉）：要么在 `removed` 上存归属（设备、是否卖出），要么不物理删行；那一段的 PR 必须带收银员收到本机卖出墓碑的测试。墓碑不套收银员 2 天的时间窗（S05-15，§4.2）。

S13 的 PR（#9）提了 4 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S13-1 | 同一台手机从家用换成收银员，没传完的进货 op 里的进价留在 outbox | 未确认的照 §4.5 保留，不加密、不拦换角色（不丢账优先；钥匙在同一台手机上，加密没有意义）。「收银员手机找不到进价」指投影和已确认的 op：当前会话是收银员时，旧会话的 op 一确认就删，换成收银员时旧会话已确认的 op 立刻删，都不留 14 天；当前会话自己的 op 照旧留 14 天。兑收银员码成功后、第一次拉取前先传一遍恢复队列，传不完不拦。恢复队列在界面上只显示笔数 | §3.4、§4.5、S13、S22b |
| S13-2 | §5.5 正文的去重键还是「商品 + 换算数量」 | 改成「商品 + 换算数量 + 这一件的卖价 + 单位名」，与 S12-2 的购物篮合并键是同一个；前缀匹配、名称搜索、购物篮都用它。Q12 以此为准 | §5.5 |
| S13-3 | 条码查找「< 5 ms」怎么测 | 1,000 商品 / 2,000 条码，预热后 5 轮 × 1,000 次随机查找：每轮中位数 < 5 ms，最好一轮的平均和 p99 < 5 ms；单次最慢值只打印不断言。PR #9 返修时另加两道护栏，保留：工作负载固定种子，合并 5,000 个样本的 p99 < 20 ms（挡大幅退化，是加严不是放宽；不用 5 ms 卡合并 p99，共享 CI 机器会偶发停顿）；`lookup` 和 `prefixMatch` 各有一条 `EXPLAIN QUERY PLAN` 断言（挡「丢了索引」） | S13 |
| S13-4 | 崩溃注入不是真杀进程 | 认可在注入点拷走库文件（含 -wal / -shm）当作断电时的磁盘，加一条注入点抛错的回滚测试。真正强杀 App 的验收在 S22a | S13 |

S05 的 PR（#11）提了 8 条，Fable 审核裁定如下（S05 拆成 S05a / S05b 两个 PR，见 S05-6）：S05b 的 PR（#13）又提了 8 条（S05-9 至 S05-16），Fable 审核的裁定接在同一张表里，按评论原文。

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S05-1 | 成本补记归属：S06 产出里有 `costfix.ts`，但进货 / 期初让进价变已知、撤销补记过的卖出都发生在 S05 | 同意放进 S05。纯算法在 `cost.ts`（S05a），S05b 在 `stock_in / opening / void` 里当场写库：`cost_fix` 行、原行的 `cost_fix_entry_id`、撤销时的三条流水。S06 的 `costfix.ts` 只剩 `product_review_complete` 的接入，不许另写一套补记逻辑 | §8 S05、S06 |
| S05-2 | `opening` 的版本校验归谁 | S05b 做 §5.6 第 2、3 条：带 `base_ver` 的比对，不带的只在 `stock_ver = 0` 时接受，否则拒 `stale` 带回最新账面数。因此 S05b 起每次库存变动都要 `stock_ver + 1`，期初要写 `last_count_at`。迟到流水补偿（第 4 条）、`count / product_review_complete` 的校验、批次留 S06：S05b 只把 `expiry_date` 存在流水上，不建 `stock_lots / lot_moves`，S06 接入时把进货、期初、卖出、撤销的批次动作一并补上 | §5.6、§8 S05、S06 |
| S05-3 | 进货 0 件 | 拒 `invalid` 并留档（`b = roundDiv(T, 0)` 无定义）。`ops.schema.json` 不改，服务器在应用时判，`limits.json` 加一组让手机同样拦。卖出行 0 件不拒（不为一行空行丢整笔账），照普通行记 | §5.0、§5.2 进货、`limits.json` |
| S05-4 | 年份 0000；与 S04-14 的关系；累计库存溢出 | 一条规则，分三层：**（一）只看 op 自己的内容就能判定的问题，是 op 的问题**，重发多少次结果都一样，拒 `invalid`，在写库之前判。留不留档只看 `ops` 这一行存不存得下：`occurred_at` 年份 0000 存不下 → 不留档（并入 S04-13 的 `storable`，所有 op 类型都判）；`expiry_date` 年份 0000 的 op 本身存得下 → 当作 payload 格式不对，留档。只按「Postgres 存不存得下」判，不按「合不合理」判：1970 年的 `occurred_at` 照收，不许因为时间离谱丢账。**（二）算出来的结果超出列范围也算可预检查的**：`apply` 用 BigInt 算完新的 `stock_qty / stock_value_fen` 再写库，超出列类型范围（`stock_qty` 是 `integer`，满额进货约 215 次就到）拒 `invalid` 并留档。**（三）过了前两层之后写库时再出现 22xxx，只能是服务器自己错了**：记账类 op 整个请求 500、error 日志，不单个拒收（S04-14 不变）。记账类 op 的 22xxx 兜底永远不产生 `rejected` | §4.4、S04-13、S04-14、§8 S05 |
| S05-5 | 流水墓碑 | 撤销不删行：原行打 `voided_at`、加冲销行，都走正常的 `rev` 下发。S05 不写 `entry / batch` 墓碑。「收银员墓碑按角色过滤」的待办原样留给第一个写这类墓碑的段 | 不用改 |
| S05-6 | S05 拆成 S05a（纯算法）和 S05b（写库与同步接入） | 可以。两个 PR 各自过审，S05 段在 S05b 合并后才算完成，依赖 S05 的段等 S05b。S05b 验收 = 执行者列的四条，再加：① `cost.json` 里只含进货 / 卖出 / 期初 / 撤销的各组经 `/v1/sync` 写库后，`entries` 和 `products` 逐分一致；② 抹零：53.50 收 53.00 经同步入库后各行 24.76 / 23.78 / 4.46，`L = 0` 而 `P ≠ 0` 被拒，I4 成立；③ 进价未知的正库存卖出、明确零成本的卖出，各经同步接口断言一次；④ 撤销：整批和单行两种 target，撤销两次第二次无操作、重放返回第一次结果，冲销行 `occurred_at` 是撤销时间，`paid_total_fen` 不改；⑤ 补记写库：`cost_fix_entry_id`、补记后撤销三条流水、同一条 `cost_fix` 被冲两次以上；⑥ `assertLedger` 加强：每条 `cost_fix` 冲销行对应恰好一笔被它补记且已撤销的卖出，实收和进价是那一行的取反，并跟一条 +数量×b 的 `cost_adjust`（b = 0 除外）；`cost_fix` 含冲销的净额 = 仍有效的被补记卖出的合计；⑦ S05-2、S05-3、S05-4 各有测试，含年份 0000 的两种和 `stock_qty` 溢出；⑧ 被踢设备：卖出直接入账带 `late_from_revoked`，进货 / 期初 / 撤销进 `held`；⑨ 收银员拉到真实流水后，递归断言没有成本键，收不到进货、期初、`cost_adjust`、`cost_fix` 行；⑩ S04-1 的过渡分支只对这四种 op 去掉，其余留到 S06 | §8 S05 |
| S05-7 | 填了进价的 `opening` 行，`unit_cost_fen` 存不存 | 存 b（留档用，和 `cost_fix` 一样；冲销行照抄）。没填进价的存空 | §3.3 |
| S05-8 | `cost.json` 没有 u ≠ c 的盘盈 | 把盘盈金额 `d × u` 写成 `d × c` 现在全部向量都能过。S06 给 `cost.json` 加一组（例如库存 6、货值 24280、c = 4000，盘点数到 8 → 盘盈 2 × 4047），服务器纯函数和经 `/v1/sync` 写库两条都要过（S06-12 改口径：§5.2 只在服务器实现，手机不实现，见 §5 开头）。**已完成（PR #16，cost-27）** | `cost.json`、§8 S06 |
| S05-9 | 卖出引用未知商品时自动建的待确认商品：整件行卖价、条码 | 同意。`pack_qty = 1` 的行卖价取行单价；整件行记 0，不用「整件价 ÷ 换算」去猜（猜的价会被当真价卖出去，0 一眼看得出没填）。不挂条码（行里的条码可能属于别的商品，也可能是整件码，换算和整件价都不能从一行卖出里推）。附加：这个商品 id 之后再来 `product_upsert` 会被拒 `invalid`（S04 既有行为），补全只走 `product_edit` + `barcode_link` + `product_review_complete`；补全页（22b）遇到 `needs_review` 且 `price_fen = 0` 要先让人填卖价 | §4.4；S06 接补全、iOS 做 22b 的段照此处理 |
| S05-10 | 记账 op 先写 `ops` 行再补结果 | 同意。`entries.op_id` 有外键，必须先有 `ops` 行；两步在同一个事务、同一个 savepoint 里，中途失败一起回滚，外面看不到中间状态。`held`、权限和 schema 拒收的路径不变，仍是一次写入 | 不用改 |
| S05-11 | 冲销行的 `pack_count` | 同意随数量取反；`pack_qty` 是换算、`unit_cost_fen` 是单价，都照抄不取反。`openapi.yaml` 的 `Entry.pack_count` 已经是不限正负的整数，手机解码和显示要接受负数（列表不显示冲销行，只在求和时用到） | §3.3 撤销的记法补一句 |
| S05-12 | 卖出冲销行带不带原 `batch_id` | 同意带（I4 和按批汇总都要用）。附加规则：凡是按 `batch_id` 取「批内的行」的查询一律加 `reverses_entry_id IS NULL`；跟着冲销产生的 `cost_fix` 冲销行和 `cost_adjust` 不带 `batch_id` | §3.3；S07 报表、S06 照此 |
| S05-13 | `voided_at` 记什么时间 | 同意记撤销 op 的 `occurred_at`（时钟校正之后的），与冲销行的 `occurred_at` 是同一个值，「撤销算在撤销那天」只有一个口径。服务器收到的时间在冲销行的 `received_at` 上 | §3.3 |
| S05-14 | 库里找不到原行的 `entry / batch` 墓碑发不发给收银员 | 同意不发，宁可不删也不泄漏。S05b 没有任何地方写这两种墓碑，目前不产生实际效果。附加：以后第一个真正删流水行的段，不能指望拉取时再回查原行（那时原行已经没了，收银员手机上的行就永远删不掉）；要么在 `removed` 上存归属（设备、是否卖出），要么不物理删行。那一段的 PR 必须带收银员收到本机卖出墓碑的测试。S06（PR #16）没有物理删行，也不写这几种墓碑 | §14 S04 待办处补一句 |
| S05-15 | 墓碑套不套收银员 2 天窗口 | 同意不套。墓碑是删除指令，手机上可能还留着窗口以外的旧行，套了窗口这些行就删不掉；多发一条手机上已经没有的行的墓碑没有害处 | §4.2 按角色裁剪补一句 |
| S05-16 | iOS `StockInPayload` 拦 0 件进货 | 同意，就是 S05-3 裁定的「`limits.json` 加一组让手机同样拦」。`LimitsTests` 已按 lim-10 断言。卖出行 0 件手机不拦 | 不用改 |

S15 的 PR（#12）提了 7 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S15-1 | 首页「刚记的」、快过期黄条、同步状态、设置页右侧小字只在 `-uiFixture` 下显示稿子上的数 | 接受。正常启动时没有真数据的项一律不显示（不出假数），只有待传笔数来自本地库。接真数据的段：刚记的 → S20，快过期 → S27，同步状态和「超过一天没传」→ S22a，已登录的手机 → S23a，扫码枪 → S14 的连接状态在 S16 接。各段验收里加一句「首页 / 设置上对应的数来自真数据」 | S15、S20、S22a、S23a、S27 |
| S15-2 | 改手机名只改本机，不报服务器 | 接受。S21 接 `PATCH /v1/devices/me`，并把登录前（S15–S20 期间）本机改过的名字在第一次登录后补报；名字长度的计数口径以契约 `DeviceLabel` 为准。收银员本机拒改不变 | S21 |
| S15-3 | 16 预选的是「当前本机设置」，「首次进入做完」按设备 id 记 | 接受。刚装好 = 大字；重新登录（新设备 id）会再出 16，预选上次的选择，不强行改回大字 | S15 |
| S15-4 | 未登录时正常启动自动建家用演示会话 | **只允许 Debug 构建**。Beta / Release 没有会话时出「还没登录」占位页，不建会话、不写演示数据；会开出会话的 `-uiFixture` / `-uiRole` 夹具同样只在 Debug 生效。本 PR 内改。S21 用登录页替换占位页，并且不把 `tokenRef` 为 `demo-local` 的遗留会话当作已登录（启动时清掉） | S15、S21 |
| S15-5 | 大字比稿子略大，几处多换一行（16b 手机卡、21b 页脚、21a 大字模式说明） | 接受，是 S11-2 的延续：不截断、不重叠即可，不为此改字号。02 的「我刚记的」条例外：建议横排时让小字换行、「记错了」留在右边，把高度还给卖出卡（建议项，不拦） | S15 |
| S15-6 | 家用首页没有「没传上去」提醒时进不了「记的账」 | S15 接受。入口在 S20 做：家用首页「刚记的」整条可点进 07a（和收银员 02 的「点开看」同一个做法，家用不加「点开看」字样）；还没有任何流水、条不显示时，从「看账」页进。S20 验收加「家用首页没有提醒条时也能进记的账」，S15 的家用遍历届时把 `page.records` 加回必达集合 | S20 |
| S15-7 | 非 Debug 构建里的测试夹具 | 凡是能绕过登录、换身份或装演示数据的启动参数都只在 Debug 编译进去；只换界面状态、不涉及会话的（组件陈列页、`-uiLargeText`）不限 | S15 及以后各段 |

S06 的 PR（#16）提了 15 条，Fable 审核裁定如下（按评论原文；S06-8、S06-10、S06-12 改了口径）：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S06-1 | 补全时的保质期设置；清 `needs_review` 占不占单独的 rev | 同意。`track_expiry / expiry_warn_days / shelf_life_months` 随 payload 写进商品，没带的不动；清 `needs_review` 单独取一个 rev。商品不是 `needs_review` 时也照收，等于一次进价必填的期初 | §4.3 |
| S06-2 | `stale` 的 `current` 长什么样 | 同意。库存类 `{stock_qty, stock_ver}`（盘点、期初、补全同一个），批次类 `{qty_left, handle_ver, closed}`，与 `openapi.yaml` 一致。收银员重发时不带 `current`（I8） | 不用改 |
| S06-3 | 期初 / 补全与已有批次 | 同意。新建一个批次，数量 = 数到的数，不扣也不改已有批次。旧批次可能多提醒，这是安全的方向，处理时以人数的为准 | §5.4 |
| S06-4 | 处理时批次和流水怎么记 | 同意。三种处理关批次时都不改 `qty_left`；扔掉 / 退货不写 `lot_moves`，`lot_id` 和处理前的 `qty_left` 存在流水 `flags`；卖完了不记流水，不占 `entry_id`（所以不能撤销） | §5.4 |
| S06-5 | 重开批次的 `handle_ver`；`lot_snooze` 的「今天」 | 同意。重开不改 `handle_ver`；「今天」= op 的 `occurred_at`（时钟校正后）所在的上海日期 | §5.4 |
| S06-6 | 撤销来源流水时怎么找批次 | 同意。按 `source_entry_id` 找，不看流水类型（没填进价的期初可能记成 `count`） | §5.4 |
| S06-7 | 扔掉 / 退货之后来源进货被撤销，再撤销扔掉 / 退货 | 同意。库存照常加回；批次不重开，`closed_reason` 改成 `voided`，`qty_left` 恢复为处理前的值。生命周期表加这一行 | §5.4 生命周期表 |
| S06-8 | 迟到补偿的口径 | 同意主体：补偿行 = −（这一步全部流水的数量合计、货值合计，含 `cost_adjust`），`cogs = −value_delta`；`k` 为假且数量有变化时标 `cost_missing`；`q` 回到这一步之前，`c、k` 用之后的值；违反 I3 时补一条 `cost_adjust` 归位到 `q × c`，也标 `late_before_count`；收入、成本、`cost_fix` 照记。**改一处**：这一步让 `k` 由假变真时，不论库存正负，补偿后的货值都归位到 `q × c`（否则正库存的货值是 0，之后卖出按零成本记且不标 `cost_missing`）。本 PR 内改 | §5.6 第 4 条 |
| S06-9 | 迟到补偿的适用范围 | 同意。卖出、进货、撤销、扔掉 / 退货；`count / opening / product_review_complete` 本身不补偿。严格早于才算迟到，相等不算。补偿行与主流水同一个 op、同一台设备、同一个 `occurred_at`，`seq` 相邻 | §5.6 第 4 条 |
| S06-10 | 迟到补偿与批次 | **改**。被补偿的迟到卖出不扣批次、不写 `lot_moves`（盘点的盘亏已经扣过一次，再扣会让提醒提前消失）。迟到的进货照常建批次，迟到的扔掉 / 退货照常关批次，迟到的撤销照常加回。其余同意：补偿行不动批次；家用可以撤补偿行，收银员不能。本 PR 内改 | §5.4、§5.6 第 4 条 |
| S06-11 | `last_count_at` 能不能往前走；迟到卖出之后被撤销 | 同意。`last_count_at` 只往后走；撤销发生在盘点之后的不补偿，库存 = 盘点数 + 退回的数。本 PR 补一条测试（现在去掉 `GREATEST` 没有测试会失败） | §5.6 第 3、4 条 |
| S06-12 | cost-27 只在服务器跑，S05-8 写的是「服务器和手机都要过」 | **原文改口径**。§5 开头已经写明成本算法全部在服务器，手机不实现 §5.2，显示的是服务器算的数，所以「手机也要过」本来就没有可以兑现的地方，不留成欠账。S05-8 改成「服务器纯函数和经 `/v1/sync` 写库两条都要过」，标已完成；S06 段同一句照改。另在 §5 开头加一句规则：§5.2 只在服务器实现，手机不读 `cost.json`（§5.1 分摊和 `rounddiv.json` 仍是两端各实现一遍）；以后如果有哪一段要在手机上算成本，那一段必须先把 `cost.json` 全部向量接进 ShopCore 的测试。记在 §5 这条规则里，不挂在某个具体的段上 | §5 开头、§8 S06、§14 S05-8 |
| S06-13 | `product_review_complete` 的 `expiry_date` | 同意。写进 `opening` 流水和新批次，年份 0000 拒 `invalid` 并留档。§4.3 的 payload 要点里补上 `expiry_date?` | §4.3 |
| S06-14 | 性质测试的并发组不放 `expiry_dispose / lot_snooze` | 同意。批次 id 是服务器生成的，单线程重放对不上；批次的乱序与重放由主测试覆盖。一半的撤销指向最近 3 笔也同意 | 不用改 |
| S06-15 | 同步向量跑法里 `count` 的 `base_qty / base_ver` | 同意。`base_qty` 填当时的 `stock_qty`，`base_ver` 填当前版本 | 不用改 |

S07 的 PR（#18）提了 8 条，Fable 审核裁定如下（按评论原文；S07-6、S07-7 改了口径，S07-1、S07-4 各改一处说法 / 契约；S07-8 随后按 Codex 第一轮 1 放宽）：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S07-1 | 「记了 N 笔」的口径；契约加 `ReportToday.count` | 同意。一次记账算一笔 = 当天原行（非冲销行）的不同 op 个数，不算 `cost_adjust`。卖出、进货、盘点、期初、扔掉 / 退货、补全都算；撤销本身不算；记了又撤销的那笔仍算（07a 里它划线显示）；迟到补偿行、当场写的 `cost_fix` 和主流水同一个 op，算同一笔。09 和 07c 用同一个口径。**改一处**：`count` 放进 `required`。手机 07a 的卡片按 `op_id` 归并（`cost_fix` 行、带 `flags.late_before_count` 的补偿行不单独成卡），这样卡片数 = 笔数 | `openapi.yaml`；§5.3 加一条；S20 / S24 照此 |
| S07-2 | 「优惠」只对卖出行求和 | 同意。优惠 = Σ 卖出行（含冲销行）`(list_amount_fen − amount_fen)`。`cost_fix` 行的 `list_amount_fen` 是 0，算进去是负优惠，§5.3 原文漏了限定 | §5.3 |
| S07-3 | `cost_missing` 计数只算未撤销的原行 | 同意。卖出还要 `cost_fix_entry_id` 为空；顶层 `cost_missing_count` 是商品种数，对账各行是笔数。卖出事后被撤销或补记，过去那天的计数跟着减少；计数只是提醒，金额不受影响 | §5.3 |
| S07-4 | 月末货值怎么算 | 同意算法：一律是「下月第一刻之前全部流水的 `value_delta` 之和」，`opening_and_adjust` 非零才出现，`cost_fix` 不单列并断言为 0。**说法改一处**：不写「本月 = 现在」。时钟超前 5 分钟以内又跨月的流水算在下个月，这几分钟里本月月末比商品投影少这一笔，可以接受 | `openapi.yaml` 的 `stock_value_end_fen` 描述；§5.3 |
| S07-5 | 柱状图 `daily` 的范围 | 同意。本月 1 号到今天，过去的月份到月末，没流水的日子补 0，将来的月份为空。跨零点那几分钟 `daily` 之和可能比月合计少一笔（同 S07-4），可以接受。（随后按 Codex 第一轮 2 收紧：柱状图与月合计同一归日口径，有流水落在「今天」之后的那一天就画到那一天，`daily` 之和恒等于月合计） | 不用改（Codex 2 改了 `reports/month.ts`） |
| S07-6 | 「快没货 / 快过期」是现在的状态，与 `date` 无关；各自的条件 | 同意主体，符合设计稿：09 是「今天」页，这两块是「现在该去补货 / 处理什么」，回看过去某天的库存没有用处。手机只在看今天时显示这两块。快过期按商品合并、卖得最好按个数取前 3，同意。**改一处**：快没货的条件 = 没停用、**不是待确认（`NOT needs_review`）**、`stock_ver > 0`、`stock_qty ≤ COALESCE(low_at, low_stock_default)`。库存 ≤ 0 的正式商品照列，手机显示「没货了」。手机 11「快没货」筛选用同一条件 | `reports/today.ts`；§5.3 加一条；S23 / S24 照此（11 在 S25，一并写进 S25） |
| S07-7 | 07c 的翻页；只有冲销行的日子 | 同意 `before` 不含、默认今天、下一页的 `before` = 本页最后一天。**改一处**：只有冲销行的日子，金额非零才列（那笔钱不能在列表里消失）；笔数 0 且金额 0 的日子不列 | `reports/entries.ts`、`openapi.yaml`、性质测试 |
| S07-8 | 日期只接受 2000–2999 年的合法日历日 | 同意。其他一律 400 `invalid`。（随后按 Codex 第一轮 1 放宽：§14 S05-4 允许 1970 年等历史流水入账，查询日期改为接受 0001–9999 年的合法日历日，覆盖全部能入账的日子；日界线改由 Postgres 按 `Asia/Shanghai` 换算，与归日同一份时区数据） | 不用改（Codex 1 改了 `reports/common.ts`、§5.3） |

S08 的 PR（#19）提了 10 条，Fable 审核裁定如下（按评论原文；S08-6 不同意现在的宽松解析，S08-8 改一处，S08-2、S08-3 各带补充或条件）：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S08-1 | 第三方图片地址下不下发给手机 | 同意不下发，对谁都不返回。§0 已定「App 只从自家服务器取图」，手机拿到地址没有用处，只多一条绕过 SSRF 校验和授权开关的路。契约里的 `BarcodeLookup.image_url` 保留为可选字段、服务器永不填；S22c 动契约时顺手删掉。`has_image` = 开关开着、不是演示店、条码库里有图，含义是「稍后可能有图」，不保证抓得到 | §6.1、§7 备注；`openapi.yaml` 的字段说明（S22c） |
| S08-2 | 开关关掉时怎么让手机显示首字 | 同意服务器兜底：读图一律 404、`has_image` 一律 false、任务不跑，手机按「取图 404 → 首字」处理。**补一处**：只靠 404 不够。开关开过再关时，手机里已有按一年 `immutable` 缓存的图，不会再来问服务器，「关掉后所有商品显示首字」就不成立，而关开关最可能的原因正是条款不允许。所以现在就定：`GET /v1/config` 加 `product_images_enabled`，手机见到 false 就不显示也不请求商品图，并清掉本地图片缓存。契约改动和手机实现放 S22c（T11）。服务器这边 S08 不用再改 | §7 `GET /v1/config`、S22c、T11 |
| S08-3 | 每店每天 300 次（11/23 改为 1000）的计数放内存，重启清零 | 同意放内存，不加表，**带两个条件**。理由：单实例；能重启服务的只有我们自己，持令牌的设备触发不了重启；要刷额度先得有本店的有效令牌，还受每设备每分钟 20 次限制；多花的上界是「当天重启次数 × 上限」（现为 1000），不是无限。条件一：T9 接 AppCode 前确认快鸟买的是预付次数包、用完即停、不会后付费超额。如果是后付费，先改成数据库按「店 + 上海日期」原子计数再配 AppCode。条件二：S10c 的「快鸟余量」告警接 `app.catalog.quota`，单店当天用到 200 次就告警（11/23 改为 700）。以后改成多实例时必须挪进数据库。注释里「最多多用一份」的说法改掉（必须改 3）。Codex 3 要求现在就进数据库，按本条裁定本 PR 不要求 | §7 备注、S10c、T9 |
| S08-4 | 每设备每分钟 20 次含不含缓存命中 | 同意含。§7 没有区分，登记新商品一分钟扫不到 20 个；不含的话缓存命中就成了不限速的查库接口 | 不用改 |
| S08-5 | 外部失败返回什么 | 同意。超时、出错、没配 AppCode 一律 `200 {found:false}`，不写缓存，超时也占一次额度（可能已计费）。手机上两种情况做的事一样：手输名称。错误码 `lookup_unavailable` 留在契约里不用，S22c 动契约时删 | §7 备注 |
| S08-6 | 快鸟的请求格式和宽松解析 | 请求格式暂时同意，来源是旧计划，没有实测，T9 核对。宽松解析**不同意现在的写法**：认不出名称就当「没查到」并缓存，会把业务错误缓存下来（必须改 2）。本 PR 改成认不出就抛错不缓存；T9 用真实录制件定下「成功」「没查到」各凭哪个字段认，候选表收紧到实际出现的字段。256 KB 上限、不跟跳转、名称 200 字、去控制字符，同意 | `lookup/kuainiao.ts`、T9 |
| S08-7 | 下载限制 | 同意：只许 80 / 443、不许带口令、最多 3 跳且每跳重验、总时长 8 秒、以文件头认格式、sharp 并发 1、关缓存。像素上限 2500 万暂时保留，实测峰值多占约 220 MB，是否降到单边 4096 由 T10 在 512 MB 容器里实测后定 | T10 |
| S08-8 | 图片任务的重试、对象键、放在哪跑 | 同意：最多 3 次、隔 5 分钟和 60 分钟、格式和地址类失败直接放弃、`last_error` 只记原因代码、上传在锁外、写回在锁内复查、键是 `images/<店>/<商品>/<image_ver>-<哈希>.jpg`、S09 的调度器落地后挪过去。**改一处**：一次领一个（必须改 4）。另记：`ObjectStore` 只有 `put` / `get`，S09 的注销删除要给它加按店前缀的列举和删除，并且同时删本机图片缓存目录里这家店的文件（T12） | `jobs/image-fetch.ts`、S09、T12 |
| S08-9 | 读图的缓存头 | 同意：`v` 等于当前 `image_ver` 时 `private, max-age=31536000, immutable`，否则 `private, no-cache`；带 `nosniff` 和 `CSP default-src 'none'`。一年强缓存的副作用由 S08-2 的配置开关处理 | 不用改 |
| S08-10 | 演示店的内置假数据 | 同意。6 个码的校验位我算过，都是合法的 EAN-13，手机扫得出来。给 S09 加一条要求：这 6 个码**不要**预先种成演示店里的商品，留给审核员走一遍「扫到新条码 → 查到名称 → 登记」，并印在 `/review-barcodes` 页上；已种的 30 个商品用别的码 | S09、S31 的 `/review-barcodes` |

S09 的 PR（#20）提了 16 条，Fable 审核裁定如下（按评论原文；S09-2、S09-6、S09-10 各带一个条件或补充，对应必须改 1 至 3；S09-11 定了生产不许共用桶）：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S09-1 | 前一位的判断 ①：`syncOk` 返回值多取了一层 | 同意，是测试写错 | 不用改 |
| S09-2 | 冲销行、补偿行、批次的 id 从随机改成由来源算出 | 同意，不许用「快照里排除这几列」代替。**加一个条件**：派生 id 撞上已有行必须 `rejected invalid`，不许 500（必须改 1） | `ledger/apply.ts`、§3.3 加一句 |
| S09-3 | 重置把演示店全部设备改成 `demo_reset`，含之前已撤销的 | 同意。§4.5 写的就是「所有设备」；留着别的撤销原因，补传规则会把重置前的卖出记进新种子。保留原撤销时间按 7 天清理，同意 | §4.5 补一句「含已撤销的」 |
| S09-4 | 导出包多了条码.csv、说明.txt；CSV 和金额的写法；自写 ZIP | 同意。BOM、CRLF、整数分转元、公式注入前缀都对。自写 ZIP 我用系统 `unzip` 和 Python 验过；不做 ZIP64、超 4 GiB 报错，同意 | §8 S09 把包内文件列全 |
| S09-5 | 导出在一个只读快照里做；`reportMonth` 拆出 `reportMonthIn` | 同意，算法没变。整包先落临时文件再上传，同意 | 不用改 |
| S09-6 | 导出任务的租约、退避、不设次数上限、撤回的处理 | 同意。**定一条**：到期清除不等导出包，导出一直失败也照样在满 7 天后删（对用户的删除承诺优先）；所以失败和没配存档桶都必须有告警（必须改 2） | `jobs/account-purge.ts` |
| S09-7 | 撤回注销改成条件更新 | 同意 | 不用改 |
| S09-8 | 到期判定严格大于 7 天；演示店不清除 | 同意，和 S03-4 一致，我实测了两侧各 1 毫秒。演示店由每日重置撤回申请，同意 | 不用改 |
| S09-9 | 清除顺序；对象清理在提交之后、先写删除记录 | 同意。删除记录内容只有店 id 和时间，符合 §9.4 | 不用改 |
| S09-10 | 令牌验过之后店被清除：同步回 401 | 同意。**补一处**：登录、改密码、申请注销的同类情况也回 401（必须改 3） | `routes/auth.ts`、`routes/account.ts` |
| S09-11 | 存档桶在 S10a 之前和商品图共用一个对象存储 | 本 PR 同意（生产还没接 OSS）。**生产不许共用**：S10a 加第二个桶的配置，`exports/`、`deletions/` 只写 `yuanhui-backup`；配了阿里云商品图桶却没配存档桶时，存档按没配处理并告警，不许落到 `yuanhui-img`（T13） | S10a、T13 |
| S09-12 | 调度器单进程串行；图片 30 秒、重置 5 分钟、导出 1 分钟、清除 1 小时 | 同意。单实例够用；以后多实例时重置和清除有店铺锁和锁内重查，导出有租约，不会做两遍 | 不用改 |
| S09-13 | 三张运维表不在 §3，测试里手抄字段 | 同意。我在计划里加 §3.5「运维表」把三张表写上；之后迁移测试可以改回从计划解析，不强求 | §3.5（计划） |
| S09-14 | 隔离测试里三条引用元辉 id 的 op 按设计 `applied` | 同意。id 的命名空间是按店的（§14 S02-8），这三条只在演示店里落行，元辉店逐行不变，我用同 id 的两家店另验过 | §6.1 补一句说明 |
| S09-15 | 两个脚本只能凭数据库连接串运行；不覆盖已有文件；密码走标准输入 | 同意 | 不用改 |
| S09-16 | 审核号注销中时演示登录怎么响应（S03-9 留下的） | 照样建设备，响应带 `delete_pending_until`，写账整批不应用，每日重置撤回。同意 | §7 `POST /v1/auth/demo` 备注 |
| S03-6（补） | 只信一跳怎么实现 | 按地址：`TRUST_PROXY=1` 时必须同时配 `TRUSTED_PROXY`（Caddy 的地址），只有 TCP 对端在名单里才看 `X-Forwarded-For`，且只取最右一项；Fastify 5 的 `trustProxy: 1` 实测一律不信，不用。名单不许是 `/0` | §9.1、S10a |
| S10a-1 | 客户端 IP 方案 | 同意 `TRUSTED_PROXY`。Caddy 固定 `172.30.0.2`，动态地址用 `ip_range` 隔开。部署时除伪造 XFF 外，还要确认 Caddy 看到的是真实客户端 IP | PR #22、runbook |
| S10a-2 | `/v1/sync` 反代层不限速 | 同意不做，不为此自编 Caddy 镜像。应用层按设备限速现在也不做；T3 改挂 S10c：`ops` 表体积和磁盘用量告警，出现异常增长再提裁定 | T3、S10c |
| S10a-3 | Let's Encrypt 续期不稳时是否直接换私有 CA | 不直接换。判定标准、前提和约束见 PR #22 Fable 审核第六节 ①；S10a 只在 runbook 写服务器端切换步骤 | §9.2、runbook、S11b |
| S10a-4 | 备案前 IP 站点放什么 | 只放假数据（§9.2 不变）；备案通过前域名不解析到 ECS | §9.2、cloud-manual-steps |
| S10a-5 | 要不要开 443/udp（HTTP/3） | 不开。§9.1 只列 22 / 80 / 443；大陆移动网络对 QUIC 不友好，S11b 少一个变量。compose、ufw、安全组去掉 443/udp，Caddy 全局 `servers { protocols h1 h2 }` | compose、Caddyfile.ip、bootstrap、cloud-manual-steps |
| S10a-6 | api 的 RAM 账号权限 | 比 T13 收紧：去掉 `backups/*`；`deletions/*` 只给读、写，不给删（代码只写不删）；`images/*`、`exports/*` 保持读写删和列举。备份用另一个账号（T21）。api 被攻破时删不了备份和删除记录 | cloud-manual-steps、T13 |
| S10a-7 | api 内存上限算不算数 | `api` 加 `memswap_limit: 512m`，上限才是真的 512 MB。T10 记 cgroup 的 `memory.peak`，不被 OOM 杀且峰值写进 runbook 才算过 | compose、T10 |
| S10a-8 | `image.yml` 里的推送步骤、迁移前备份门禁 | 推送步骤保留：计划的产出就是「构建并推 ACR」，没配 secrets 时跳过，本 PR 没有凭据（不采纳 Codex 10）。迁移前的备份门禁不在 S10a 做，这时还没有备份，库里只有假数据；挪到 S10b（T20）（Codex 4） | image.yml、T20 |
| S10a-9 | 本 PR 合并算不算 S10a 完成 | 不算。部署实测另开一个 PR（只填 runbook 的数字和必要修正），第五节 13 项齐了、经审核后 S10a 才算过；在那之前 S10b 可以开工，S11b 的探针可以先连 | §8 S10a |
| S10b-1 | 加密用 Node 自带 crypto（scrypt N=2^15 + AES-256-GCM），清单也加密，心跳不加密 | 同意。每个文件新盐新 IV，头部进附加认证数据，标签验过才落明文，我改字节验过。格式说明保留在 `crypto.ts` 开头，runbook「恢复」里加一句指过去 | runbook |
| S10b-2 | 清单和 dump 同一快照，`pg_dump` 在 Postgres 容器里跑 | 同意。跨容器导入快照在 B2 验 | runbook B2 |
| S10b-3 | 门禁：营业时间（上海 8:00–22:59）2 小时，其余 6 小时；读 ECS 本地 `last-success` | 同意 6 小时。时间表里最长间隔是 02:30 → 8:00 的 5.5 小时，6 小时刚好罩住，再小会在凌晨误拒，再大等于营业时间外不设防。8:00 那一次没跑完之前发布会被拒，属于正确行为。读本地文件也同意：它只在上传和心跳都成功后才写，发布不用拿备份凭据。T20 字面写的是「心跳」，按此改 | 不用改 |
| S10b-4 | `exports/` 30 天；`deletions/` 不过期 | 都同意。`exports/` 只是兜底，30 天短于 35 天，不破坏「7 + 35 天内清除」；注销卡住超过 30 天时导出包会先没，可以接受（包只在 7 天内交给黄总）。`deletions/` 永久保留：记录只有店的随机编号和时间，必须比任何含这家店的备份活得久，而生命周期可能失效，所以不设期限最稳。条件：隐私政策和注销页写明这两点（T25） | T25 |
| S10b-5 | 恢复只写空库或带恢复标记的库 | 改：标记分「恢复中」「已恢复」两种，已恢复的不再清库（PR #23 必须改 1） | `backup/restore.ts`、`restore.sh` |
| S10b-6 | 重放删除记录不看注销申请，新加 `replayDeletion` | 同意。恢复出来的可能是申请之前的备份，只能这么做。runbook 加人工核对删除记录那一步（建议 2） | runbook |
| S10b-7 | 定时器由 `remote-deploy.sh` 发布成功后装，装不上退出码 4 不回滚；首次发布带 `--skip-backup-gate` | 同意 | 不用改 |
| S10b-8 | `backup` 服务挂 `db` 和 `edge` 两个网络，内存上限 256 MB | 同意网络（api 本来也是两头都通）。加 `memswap_limit: 256m`（必须改 7） | compose |
| S10b-9 | 备份 RAM 账号没有任何删除权限，删除只靠 35 天生命周期 | 同意。写明一条残余风险并接受：`PutObject` 可以覆盖同名对象，拿到 ECS 的人删不了备份但能把它们写坏；桶不能开版本控制（T21），所以第一版不防这一条，靠每周的云盘快照兜底。第二版候选：备份单独一个桶加合规保留策略 | runbook B3 |
| S10b-10 | 备份口令和恢复凭据的保管（§9.1 的「另存两处」落到具体） | ① 口令由 Chitu 在这台 Mac 上生成，直接进钥匙串和 ECS 的 `.env`，不经过任何聊天软件、邮件、备忘录；② 第二处：Haoqiang 本人在这台 Mac 的终端里存进他 iPhone 的「密码」App（iCloud 钥匙串，这台 Mac 丢了还拿得到），另抄一份纸质的放家里；③ 唯一补不回来的是口令。AccessKey 丢了可以用阿里云主账号重发，所以前提是主账号的登录和二次验证在 Haoqiang 手里；④ 验收按 B5，指纹比对是可选的核对手段；⑤ 换口令时旧口令各处再留 35 天，runbook 写上；⑥ S32 的演练再核对一次（T27） | runbook「口令保管」、cloud-manual-steps |
| S10b-11 | 本 PR 合并算不算 S10b 完成 | 不算（同 S10a-9）。部署实测 PR 填齐 B1–B6、B8–B11 并经审核后才算过；B7（T23）和第 36 天的检查（T24）不阻塞 S10b，但阻塞 S32 | runbook |

### 跨段待办与待排查（来自审核评论，不是裁定；做完在这里划掉）

| # | 事项 | 来源 | 放在哪一段 |
|---|---|---|---|
| ~~T1~~ | ~~`createDevice` 要求「调用方必须先锁账号行」，目前只靠注释约束。加固（来源评论只说「以后再加建设备的路径要记得照做」，加固和下面的测试是本次同步计划时新提的建议，不是评论里的要求）：让它自己能查出没拿锁（例如只接受已持有账号行锁的事务，进函数先断言），并加一条「没拿锁调用会失败」的测试。在那之前，任何新增建设备的路径（现有登录、兑码、演示登录三条）都要照「账号 → 开通码 → 设备称呼」的顺序加锁~~ **已完成（PR #20）**：`lockAccount` 返回的凭据只在发它的事务里、对它锁的那个账号有效，`createDevice` 进门核对，没拿锁 / 别的事务的锁 / 别的账号的锁 / 伪造的凭据一律抛 `AccountLockMissing`（`test/demo.test.ts`）；登录、兑码、演示登录三条路径都改用 | PR #8 Fable 第三轮 | S09（动演示登录时一并做）；之前有别的段新增建设备路径，就由那一段做 |
| ~~T2~~ | ~~`server-ci` 偶发失败待排查：PR #12 的 `c2b7f91` 第一次跑（run 44787936776 attempt 1），`test/concurrency.test.ts`「并发登录（§14 S03-3）› 20 个错密码 + 1 个对密码同时发」里 20 个错密码的状态码是 `401,500,500,500,401,401,401,423×13`，出现 3 个 500；当时 server 代码与 main 完全一致，重跑通过。处理要求（以下几条是本次同步计划时新提的建议，来源里只记了现象）：测试断言「没有 500」是对的，不许为了变绿放宽它或加重试。要查清 500 的来源（CI 日志里没有留下 500 的响应体和错误栈，先让这条测试失败时把它们打出来），修掉或写明原因~~ **已完成（PR #15）**。根因：argon2 和 pg 新建连接时的 SCRAM 认证（WebCrypto PBKDF2）共用 libuv 线程池（默认 4 条），一批登录同时到、连接池是冷的，PBKDF2 排在整批 argon2 后面，超过 `connectionTimeoutMillis` → 取连接失败 → 500；每条现建的连接一次，所以正好 3 个。不是数据库错误，也不是行锁。修法和后续见下面 T2-1 至 T2-4 | PR #12 修改说明（d6fd420、c2b7f91）；PR #14 的 run 44804882889 第 1 次又出现一次 | ~~下一个改 `server/src/routes/auth.ts` 或这条测试的段（预计 S09）~~ 已由 PR #15 单开完成 |
| T3 | 上限以内但不合 schema 的 payload 会留档，持有效令牌的设备一个请求最多写近 1 MiB。**（改，PR #22 Fable）** 反代层和应用层都不限速（S10a-2）。S10c 加 `ops` 表体积、磁盘用量告警 | PR #10 Fable 第三轮；PR #22 Fable | S10a → S10c |
| T4 | 验密码的进程内排队没有上限：一大批登录同时到时，后到的要等前面的 argon2 算完，账号已锁的也要等到轮上才回 423。单个 IP 有 15 分钟 30 次的限速，多个 IP 同时来就没有上限。要不要加上限（超过返回 `503 unavailable` 带 `retry_after_s`，`/v1/auth/login`、`/v1/account/password`、`/v1/account/delete-request` 的契约加 503，手机端按「稍后再试」处理）由 S10a 在 ECS 上实测后定，见 T2-2 | PR #15 描述、Fable 审核 | S10a（见该段） |
| T5 | 手机时钟偏慢（不是超前）时，它在盘点之后记的卖出都会被当成迟到流水补偿掉，库存不再减少，而且没有任何提示。实测：盘点到 10 之后，三笔 `occurred_at` 是 2020 年的卖出入账，库存仍是 10。服务器分不出「离线迟到」和「时钟错了」。要不要由手机在同步时对照服务器时间、偏差大就提示或校正，待定。**S22a 结论**：只提示、不校正。每次同步记下响应的 `server_time` 和本机时刻，相差 ≥ 5 分钟首页出提醒条「手机时间和服务器差了 N 分钟……打开自动设置」；不改 op 的 `occurred_at`（outbox 字节不可改、重放哈希要一致；快了服务器已按 §4.4 改成收到时间）。收银员的「今天」（07b 列哪天、能不能撤）按服务器时间算，和服务器的判断一致 | PR #16 Fable 审核 | S22a（做同步时一并定） |
| T6 | 库存增加但没有 `lot_moves` 可以依据时，批次不跟着加，批次会比货架上的少，卖到 `qty_left = 0` 后提醒提前消失（不安全的方向）。两种情况：① 盘盈；② 被补偿的迟到卖出（S06-10，没有 `lot_moves`）在盘点之后被撤销。实测：批次 10 → 盘点到 8 → 迟到卖 2 → 撤销这笔卖出，库存 10、批次 8；接着盘点到 12，库存 12、批次仍是 8。账不受影响。要不要把多出来的数加到到期日最早的未关闭批次上（两种情况用同一条规则；没有未关闭批次时不加；补偿行被撤销时怎么对应），待定。要改的话是服务器 `lots.ts` 的改动，随那一段的 PR 一起做并补测试 | PR #16 修改说明、Fable 第二轮 | S27（做保质期页时一并定） |
| T7 | 月初货值和 `/v1/entries/days` 每次都扫这家店的全部流水，耗时随年头线性增长（25 万行时月报 28 ms、07c 72 ms）。S10a 压测时按 3 年的量（约 40 万行）再量一次，07c 超过 200 ms 就改成按天往前走索引，或存每月月末货值 | PR #18 Fable | S10a |
| T8 | `products.stock_known` 没有定义，也没有任何代码写它。要么给出定义并在记账时维护（然后快没货改用它），要么删掉这一列 | PR #18 Fable | S23 之前定 |
| T9 | S08 延期的人工项，做完前生产不配 `KUAINIAO_APPCODE`、图片开关不开：① 跑 `barcode-trial.ts --record` 测 20 个真实条码（含 5 条香烟、5 个本地品牌），命中率和有图率写进 PR，有图率 < 50% 则商品图降级到第二版；② 用真实录制件替换手写夹具，定下「成功」「明确没查到」的判别字段，只有明确没查到才写负缓存，候选字段表收紧；核对请求格式和网关报错的形态；③ 登录阿里云把图片相关条款原文摘进 `docs/image-rights.md`，按 S08 的规则下结论；④ 确认计费是预付次数包、用完即停（S08-3 的条件），不是的话先把每日计数挪进数据库；⑤ 真实 OSS 往返读写一次，RAM 子账号只能读写 `images/` 前缀；⑥ 定条码格式过滤（只对 8 / 12 / 13 / 14 位数字调外部）做不做 | PR #19 Fable、Codex | S10a |
| T10 | sharp 进镜像和内存：见下面「sharp 对镜像的要求」；在 512 MB 的 `api` 容器里，一边跑 3 个并发登录一边缩一张 5000×5000 隔行 16 位 PNG，不被 OOM 杀掉才算过，否则把上限降到单边 4096 | PR #19 Fable | S10a |
| T11 | ~~`GET /v1/config` 加 `product_images_enabled`（契约 + 服务器）；同一次契约改动里删掉 `BarcodeLookup.image_url` 和错误码 `lookup_unavailable`~~ **契约和服务器部分已在 S22d-server（PR #42）完成**。剩下：手机见 false 不显示、不请求商品图并清本地图片缓存 | PR #19 Fable（S08-1、S08-2、S08-5） | S22c / S22d-iOS |
| T12 | ~~注销删除时删这家店在 OSS 的 `images/<店>/` 和本机图片缓存目录里的文件，先删 `image_jobs` 再删商品（有外键）；`ObjectStore` 加列举和删除~~ **删除部分已完成（PR #20，`jobs/account-purge.ts`、`test/account-purge.test.ts`）**。剩下：运维手册写一条：因条款关掉图片开关时，怎么清掉 OSS 和本机缓存里已有的第三方图（已写进 `docs/runbook.md`「关掉商品图开关时清第三方图（T12）」，S22d 补了清 `images/_catalog/` 和候选表） | PR #19 Fable | S09（删除）、S10a（手册） |
| T13 | 存档桶分开：加第二个桶的配置，`server.ts` 的 `archive` 接 `yuanhui-backup`；RAM 子账号对商品图桶只有 `images/`，对备份桶只有 `exports/`、`deletions/` 和备份前缀；配了商品图桶没配存档桶时不许把导出包写进商品图桶。真实 OSS 上把列举、删除各实测一次 | PR #20 Fable（S09-11） | S10a |
| ~~T14~~ | ~~`restore.sh` 重放删除记录要列举 `deletions/`，现在 `ObjectStore.list` 只认 `images/<店>/`、`exports/<店>/` 两种前缀，要加；重放后这些店的旧令牌和重传按 401 处理~~ **已完成（PR #23）** | PR #20 Fable | S10b |
| T15 | 演示店 16:00 重置后，过北京时间 0 点「今天」页没有卖出。上架演练时在美国西岸白天的时段看一遍，决定要不要改重置时间或种子的日期 | PR #20 Fable | S30 |
| T16 | 导出和清除的告警现在只是带 `alert` 字段的日志（`account_delete_export`、`account_delete_export_failed`、`purge_no_archive` 和必须改 2 新加的那条），接到通知渠道 | PR #20 描述第 6 条 | S10c |
| T17 | ~~孤儿对象清扫。① `store_purges` 的对象清理改成：清除之后至少隔 1 小时再按前缀扫一遍 `images/<店>/`、`exports/<店>/` 和本机缓存，这一遍做完才记 `objects_cleared_at`（盖住图片上传后进程退出、上传后拿店铺锁失败）。② `exports/<店>/` 下没有对应 `export_jobs` 行的包定期删掉（生成期间撤回、包迟到落地又没删成）。两条各加一个测试~~ **已在 S09 实现（PR #20 第二轮返修）**：① `clearPurgedObjects` 每遍记 `store_purges.swept_at`，清除后满 1 小时（`RESCAN_DELAY_MS`，从这家店在线数据实际删完、提交前那一刻的 `purged_at` 起算）开始的那一遍成功了才记 `objects_cleared_at`；每一遍先中止前缀下未完成的分片上传、再列举删除对象，来回到某一次两边都空才算扫干净（第三轮返修，Codex 第三轮 1、2）；② 作废的、生成失败时已写进去的导出包删不掉就记 `object_discards` 待删标记，导出任务每轮按退避重试直到删掉（分片上传中止失败同样记下 uploadId 重试）。测试见 `test/account-purge.test.ts`、`test/image-fetch.test.ts`、`test/oss.multipart.test.ts` | PR #20 Fable 第二轮、修改说明「Codex 2 已知的边界」 | S10a → 已在 S09 实现 |
| T18 | 导出任务失败分支当场删包之前，先确认没有已完成的任务指向这个键（`retryObjectDiscards` 已经这样查，当场删的那一次没查）。场景：写回其实提交了，但数据库连接在应答前断开，失败分支把刚完成的包删掉，任务却记着已完成。读代码得出，没有复现 | PR #20 Fable 第三轮 | S10a |
| T19 | IP 证书剩余有效期低于 48 小时告警；每次续期成功 / 失败留记录，供判定方案 A 是否稳定（S10a-3） | PR #22 Fable | S10c |
| ~~T20~~ | ~~`deploy.sh` 跑迁移前检查最近一次备份心跳，营业时间内超过 2 小时没更新就拒绝，带一个明确的跳过开关~~ **已完成（PR #23）** | PR #22 Codex 4、Fable | S10b |
| ~~T21~~ | ~~备份单独用一个 RAM 账号：`backups/` 只写不删，删除靠生命周期；35 天生命周期只作用于 `backups/` 前缀，`exports/`、`deletions/` 怎么过期单独定；确认两个桶没开版本控制~~ **已完成（PR #23）** | PR #22 Fable（S10a-6） | S10b |
| T22 | S11b 探针把方案 B（包内 CA 锚点固定）一并实测，写明需要的 Info.plist 键值，不等 A 出问题再测 | PR #22 Fable（S10a-3） | S11b |
| ~~T23~~ | 换 epoch 后真手机补回：带保留 op 的测试手机恢复后拿到 `epoch_mismatch`、全量拉取、补回备份之后的流水（原 B7） | PR #23 Fable | S22b（S22b 做完：`S22bLiveUITests.test8EpochChange` 本机 pg_dump → 再卖一笔 → pg_restore + 换 epoch → 手机握手、全量拉取、补回备份之后那笔，服务器不重复） |
| T24 | 第一份备份满 36 天后看 `backup.ts status`：`lifecycle_stale` 为 false、最旧一份不超过 36 天；`exports/` 里没有超过 30 天的对象 | PR #23 Fable | 部署后第 36 天，最迟 S32 |
| T25 | 隐私政策和注销页写明：注销后永久保留一条不含业务数据的删除记录（店的随机编号和时间）；导出包最长保留 30 天 | PR #23 Fable（S10b-4） | §10 |
| T26 | 告警接上：`backup_failed`、`backup_lifecycle_stale`、`consecutive_failures ≥ 2`、备份被跳过（锁）、`gate-skips.log` 有新行、`restore_failed` | PR #23 Fable | S10c |
| T27 | 上线前演练时再核对一次口令三份（可用指纹），并确认阿里云主账号的登录和二次验证可用 | PR #23 Fable（S10b-10） | S32 |
| T28 | §9.5「快鸟额度：每次调用后记余量，< 50 次告警」：快鸟的响应里有没有剩余次数字段，要等 T9 ② 的真实录制件。S10c 先做了单店当天 ≥ 700 次（原 200）（S08-3 条件二）和网关报额度用完 / 限流（`kuainiao_quota`）两条；T9 确认有余量字段后在 `CatalogService` 记下来、接 `< 50` 的条件告警 | S10c 代码 PR | T9 → S10c 部署实测 |
| T29 | PR #25 Fable 建议 3 的后一半：服务器检查任务自己的心跳。返修已做每段各自 try、出错段报 `monitor_check_error:<段>`，但整个检查任务停了（scheduler 卡住、进程活着不跑任务）没人知道。做法：每轮在 `/data/monitor/` 写一个时间戳，本机探测 ssh 拉 outbox 时一起读，超过 10 分钟没动就报 `server_monitor_stale` | S10c 代码 PR 返修 | S10c 部署实测前 |
| ~~T30~~ | ~~PR #31 Fable 建议 2：直接填到期日时年份默认今年，忘改年会记成已过期的日子。到期日早于今天、或生产日期晚于今天时出一句提醒再确认~~ **已在 S20 实现**（`StockInModel.dateWarning`，「日子对吗？」确认后照记；`AppTests/S20Tests` 两条） | PR #31 Fable | S19 之后的进货小改（S27 前） |
| T31 | PR #31 Fable 建议 3：点年份格不清空而月、日格清空，行为不一致；年份填满 4 位再按数字没反应。改成点年份格也从头填，或给一句提示 | PR #31 Fable | 同 T30 |
| T32 | PR #31 Fable 建议 5：最大辅助字号下 06b 的「算出来到期」要往下滚才看得到。记进货前滚进视野，或把算出的到期日并进「记好了」那句话 | PR #31 Fable | 同 T30 |
| T34 | 活店换图（S22d 选图、拍照）后删旧对象失败只记日志 `image_discard_failed`，`images/<店>/` 下这些旧对象暂无清扫（店被注销清除时会按前缀一起删）。要不要加按「没有商品引用」定期清扫，待定 | S22d-server 方案③ | 待排 |
| T33 | PR #31 Codex 建议：04b 进价填 0 直接保存，补上和进货页一样的 0 元二次确认，保留「没填」和「明确为 0」的区别 | PR #31 Codex | S25 商品编辑前 |
| T34 | PR #41 Fable 可选 1：`SyncEngine` 构造时绑定会话的 deviceId，每轮和提交事务内核对（防旧引擎跨会话串店的理论窗口） | PR #41 Fable | S23a |
| T35 | PR #41 Fable 可选 5：恢复队列遇 401（店已清除、设备行已删）永久留着，25b/25f 加「这些账已无法补传」的说明 | PR #41 Fable | S23a |
| T36 | PR #41 Fable 可选 8、9：`relogin` / `liveBoot` / `clearLegacyDemo` 的 `endSession` 移出主线程，`relogin` 结束的会话推迟 logout；同步与恢复上传改专用队列，不阻塞协作线程池 | PR #41 Fable | S23a |
| ~~T37~~ | ~~PR #41 Fable 可选 10：held「记上」不看原设备角色（被踢收银员构造的进货也能被家用记上）~~ **已在 S23a 服务端 PR 完成**：被踢设备的 op 推送时再按被踢前的身份复核（`Guard.originalRoleAllows`，只看和收到时间无关的条件），原角色做不了的 `rejected: forbidden`、不进 held；之前已暂存的这类 op `can_accept=false`、记上回 403；`HeldOp` 加 `device_role`（`test/held.original-role.test.ts`） | PR #41 Fable | S23a |
| T38 | 图片开关关着时服务器对 select / PUT 也回 404：手机还没取到新的 `/v1/config` 前若同步成功 3 次，暂存的选图 / 照片会按「404 满 3 次」丢掉（不算②，见 S22d-10）。可改成发之前确认开关、或 404 只在开关确认开着时计数 | PR #48 Opus 建议 1 | 待排 |
| T39 | 会话结束时暂存的选图 / 照片随目录删掉，本机店 id 每次登录都是新的，认不出同一家店；若要「换身份后同店接着传」，需要服务器下发店 id | S22d-10、Fable 方案 5 | 待排 |

T2 的 PR（#15）定了 4 条，Fable 审核裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| T2-1 | argon2 占满 libuv 线程池，别的线程池任务（SCRAM 认证、`dns.lookup`、`fs`）排不上 | 所有 argon2（hash 和 verify）只走 `src/auth/password.ts` 一个入口，进程内限流，最多同时「线程池大小 − 1」个（默认 3，读 `UV_THREADPOOL_SIZE`；线程池只有 1 条时一个一个算），多出来的在进程里排队，不占连接。别处不许直接调 `argon2`。验密码必须在取数据库连接之外 | S03（已由 PR #15 实现） |
| T2-2 | 排队要不要上限、超过回 503 | PR #15 不做：改前同样在排队，没有变差；单 IP 有限速；上限取多少要看 2C2G 上 argon2 的实际耗时。S10a 实测：30 个登录同时到（单 IP 限速的上限）时最慢一个的响应时间。超过 10 秒就加上限并改契约（`503 unavailable` 带 `retry_after_s`），否则在 PR 里写明不加和实测数字 | S10a、跨段待办 T4 |
| T2-3 | 生产上线程池、数据库认证、连接池怎么配 | `api` 不设 `UV_THREADPOOL_SIZE`（默认 4 → argon2 最多同时 3 个，每个 64 MiB，约 192 MiB，在 512 MB 以内）；要调大先按「(线程数 − 1) × 64 MiB」算内存。数据库用口令认证（Postgres 16 默认 `scram-sha-256`），不为这件事改成 trust。连接池保持 `max 10`、`connectionTimeoutMillis 2000` | §9.1、S10a |
| T2-4 | 冷池那条并发登录测试只在要口令的库上有区分力 | 认可。`server-ci` 的 Postgres 必须一直带 `POSTGRES_PASSWORD`（现状），不许改成 trust；不依赖认证方式的那条在 `test/password.test.ts`。两条都不许放宽、不许加重试。出 500 时断言信息带服务端错误栈的做法保留 | 不用改 |

S14 的 PR（#17）Fable 审核的裁定如下（按评论原文）：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S14-1 | 相机「同码 1.5 秒内忽略」怎么算 | 按码各记各的：某个码从**最后一次被看见**起 1.5 秒内再出现都忽略（一直对着不动只算一次，拿开 1.5 秒再对上才算第二次）；别的码不影响它的计时（A、B 同在画面里各算一次，不来回刷）。记录只留最近 1.5 秒内见过的码。扫码枪和手输不去重，不变 | S14、S16、S19、S26 |
| S14-2 | 相机认哪儿的码 | 只认取景框里的：`rectOfInterest` 设成预览层可见范围。代码在 S14 写，真机效果在 S29 验 | S14、S29 |
| S14-3 | S16 接入扫码层，PR #17 的 8 项之外还要做的 | ⑨ 相机生命周期归页面管：压到下一页、被面板盖住、退到后台时停相机，回来再开；返回 `.ignored` 只是不出声，不代替停相机。⑩ 页面回前台时 `permission.refresh()`；`isIdleTimerDisabled` 保留在卖出页。⑪ 全 App 共用一个 `ScanFeedback`（一个音频引擎），各页的 hub 都用它。⑫ `UIFixture.swift`、`AppRoot.swift`、`Makefile`、`ReleaseBuildUITests` 两边都改了，rebase 时手工合；S16 的 `-uiScan` 走 `FakeScanner` 后 `shots-s16.sh` 和 UI 测试的等待时间按「开页等 1 秒 + 每码 0.3 秒」放宽，需要测相机去重的用例间隔要大于 1.5 秒。⑬ S21 扫码登录页用 `NoCameraCard` 时状态栏设浅色 | S16、S21 |
| S14-4 | S29 真机清单里扫码层要验什么 | 相机实际识别 EAN-13 / EAN-8 / UPC-E / ITF-14 / Code128，取景框外的码不认；画面里两个码各只算一次；静音开关拨下时两种音都响，媒体音量为 0 时的表现记下来；来电 / 闹钟打断后下一次扫码仍响；两种触感分得出；蓝牙扫码枪实连：后缀必须设成回车（Tab 后缀不出码），字符间隔超过 80 ms 的慢枪要调枪或调 `maxGap`，含大写字母的 Code128 完整；扫码枪连着时系统软键盘不弹，手输条码还能不能用；**手输面板 / 弹窗关掉后不点屏幕直接扣扳机，码照常进**（两样有一样不行就在 S17 给出办法）；手电筒开着时相机不卡；设置页「扫码枪 已连上」在接了别的蓝牙键盘时也会显示，接受 | S29、S17 |
| S14-5 | 条码里收哪些字符 | 只收数字和 ASCII 大小写字母，三个入口（相机、扫码枪、手输）同一个规则，放在 `ScanHub` 里用 `HIDScanParser.isCodeCharacter` 把关。含其他字符的码整串不收、不截断：相机和扫码枪不出声、不交给页面；手输面板里提示「条码只能是数字和字母」。字母大小写原样保留、不折叠。以后真遇到带符号的商品码，再在 `isCodeCharacter` 里加，并且必须整串保留 | S14、S16（⑭ 在 `ScanHub.receive` 加这一层和测试）、S17 |

S16 的 PR（#21）Fable 审核的裁定如下（按评论原文）：

| # | 问题 | 裁定 | 影响 |
|---|---|---|---|
| S16-1 | 抹零后再扫码或改数量 | 同意：实收作废，回到按原价收。**但不能悄悄变**：作废那一刻出一条黄条「东西变了，刚才抹的零取消了，要抹请再抹一次」，本 PR 内加，带测试。被拒的扫码（没登记、超上限）不算篮子变了，实收保留 | S16、S17（面板回来后同一规则） |
| S16-2 | 停用商品被扫到 | 同意照卖，价签标「已停用」。货架上还有货就得能卖，不拦、不弹窗。下面两行式里不标。S25 商品页写明「停用只是不进提醒和列表，扫到照卖」 | S16、S25 |
| S16-3 | 没登记的码 | 同意：黄条「这个码还没登记：…」加低音和警告触感，篮子不变。S18 接 04a 后改成直接进登记页，黄条只留给进不了登记页的情况 | S16、S18 |
| S16-4 | 主按钮置灰样式 | 同意：实心按钮灰底白字，描边按钮灰边灰字，空篮总价灰色 ¥0.00。作为全 App 统一的置灰样式，后面各段沿用 `PrimaryButton` 的，不另做 | S16 及以后各段 |
| S16-5 | 没图时缩略图显示什么 | 同意显示商品名首字。名称为空（25e 断网登记）时显示占位图标。商品图接上后有图用图 | S16、S18、S25 |
| S16-6 | 超出 §5.0 上限加不进去 | 同意：黄条「加不进去：…」加低音（`.unknown`）。黄条文字要是店里人看得懂的话（例如「这一样最多 99999 件」），不直接显示 ShopCore 的内部原因；S17 做输入限制时一并核对文案 | S16、S17 |
| S16-7 | `-uiFixture` 没给 `-uiCamera` 时当作允许 | 同意，只限 Debug 夹具。正常启动（含 Debug 不带夹具）读真实权限。真机上第一次的系统询问框在 S29 验 | S16、S29 |
| S16-8 | `Route.scanner` 出真页面 | 同意 `ScannerStatusView`（连接状态加一句设置说明），不补设计稿。更细的设置步骤随 S29 的店里设置说明写；「接了别的蓝牙键盘也显示已连上」按 S14-4 接受 | S16、S29 |
| S16-9 | 「记好了」黑卡的位置（审核新增） | 黑卡不参与布局，在购物篮区居中，显示期间空篮只留虚线框；任何字号下不得把标题栏或记账按钮挤出屏幕 | S16 |
| S16-10 | 03 标准状态要看得全（审核新增） | iPhone 13、大字模式下，03 的三样商品三行完整可见；小号步进器的 56pt 点按区不撑高行；总价放不下时先降到 48pt，再不行才上下排 | S16 |

S18 的 PR（#30）Fable 审核的裁定如下（按评论原文）：

| # | 问题 | 裁定 | 影响 |
|---|---|---|---|
| S18-1 | 名称为空（25e 断网登记）存成什么 | 名称为空存成「没写名称 …尾号四位」：同意。契约 `name` 至少 1 个字不改，占位名是对的做法，账里分得清。家用空名登记**不**自动标待确认：`needs_review` 的口径是 S04-5 定的「`quick` 一律为真」，不为这件事改规则。以后的商品列表 / 补全页用 `ProductNaming.isPlaceholder` 把这类商品挑出来提醒即可。占位名前缀是客户端约定，Android 那边要用同一个字符串 | S18、S25 |
| S18-2 | 键盘键高不小于 56pt、比稿子高 | 同意。点得准优先于和稿子一样高。标准字号和大字下，标题和条码上滚、名称框和「箱 / 条 / 提 / 盒」留在首屏，可以接受；稿子不改 | S18 |
| S18-3 | 05 在系统最大辅助字号下，首屏看不到挂的是哪个商品 | `pack-05-axmax-large.png`：商品卡只剩「单罐卖 ¥3.00」，名称和「换一个」滚到上面去了。默认商品是价签里刚扫的那一样，不一定就是这一箱的东西，而整件码挂错了不能挪（§4.4）。建议把商品名带进钉在底部的那句话，例如「以后扫这个码，按 24 罐 可口可乐 330ml 算」。本段不拦，带到 S19 进货接 05 时一起做。**（S19 已做：`LinkPackModel.conversionHint` 带商品名）** | S19 |

S19 的 PR（#31）Fable 审核的裁定如下（按评论原文）：

| # | 问题 | 裁定 | 影响 |
|---|---|---|---|
| S19-1 | 蓝卡预计平均在有未确认 op 时怎么算（审核新增） | 该商品本机有未确认的库存变动（`pendingDelta != 0`）时不显示「加上原来的，平均进价」；其余条件不变（进价未知或库存不为正不显示）。S19 说明里的「新数量」指基线数量 + 这批。Android 同此 | S19 |
| S19-2 | 没扫到东西时显示相机条和「扫一下送来的货」，扫到后换成 06a，商品卡加「重新扫」；扫码枪扫到别的码就换商品、没记的输入作废 | 同意。建议同一个码再扫一次时保留已填的输入（不拦） | S19 |
| S19-3 | 进货中登记新商品：04b 存好后不再自动记进货；05 存好后带着这一箱进货 | 同意。04b 记的是 `opening`（§5.2「按期初记，不算进货」），带进价，成本正确；月报里这一笔在「期初登记和调整」而不在「本月进货」，等式照样成立，接受。04b 没填数量时不得提示已记上，改为接着进货（必须改 2） | S19 |
| S19-4 | 保质期月数记在本机（按商品），不发 `product_update` | 同意。到期日随 op 上传，不影响别的手机。S25 做商品编辑改 `shelf_life_months` 时，本机记住的值要让位于新设置（清掉该商品的记忆） | S19、S25 |
| S19-5 | 年份默认今年（上海日期）；填日期时隐藏蓝卡和填法切换，底部换「填好了」 | 同意，与 06c 一致 | S19 |
| S19-6 | 最大辅助字号下蓝卡钉在键盘上方、字号封顶 `DiscountPanel.labelCap`、总价 48pt | 同意。看清总价和入账数优先于和稿子一样大 | S19 |
| S19-7 | 06b / 06c 截图用青岛啤酒代替伊利牛奶 | 同意，不补演示数据 | S19 |
| S19-8 | 0 元二次确认（进价 0、卖价 0） | 同意，改了金额收回确认是对的 | S19 |
| S19-9 | 名称框回车时去掉末尾 8 位以上数字 | 同意。真机扫码枪表现按 S29 验 | S19、S29 |

返修说明（不改上表原文）：S19-1、S19-3 的必须改已按裁定做；S19-9 按 PR #31 Codex 必须改 1 改为回车时**不自动删**，名称框下提示「像扫码枪打进来的条码」，人点「是条码，去掉这串数字」才去，不点就照原样存。

S10 部署实测的 PR（#27）Fable 审核的裁定如下（按评论原文；合并不等于 S10a / S10b / S10c 通过）：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S10r-1 | PR #27 合并算不算 S10a / S10b / S10c 完成 | 不算。只算「首次部署完成」。下面 S10r-2 至 S10r-12 做完、数字写回 runbook、经审核后才算过；后续每补一批开一个只改 runbook 的小 PR | runbook |
| S10r-2 | S10a 还差什么 | 第 2 项家外 `nmap`、第 3 项蜂窝出口登录、第 5 项一次自动续期 + 境内一次 `curl` + 14 天观察、第 9 项压测、第 10 项加 3 个并发登录、第 12 项 T9。第 7 项按负责人决定记「不适用」，以 B3 的 `409 FileImmutable` 代替 | runbook「部署时验证」 |
| S10r-3 | S10b 还差什么 | B1 跑满一个营业日 15 次；B5 三份口令和主账号二次验证由 Haoqiang 确认、`~/Downloads` 的明文口令文件删掉；B6 有数据后重做（含一家已清除的店、本机 api 新 epoch 同步）；B10 随压测。B11 按负责人决定记「不开」 | runbook「S10b 部署时验证」 |
| S10r-4 | S10c 还差什么 | 通道配好、本机探测装好后 M1、M2、M4、M12；M5、M6、M8 经通道重发并记「已恢复」；M3 云监控；M7、M10、M11 要测试店和真手机；M9 随 T9 | runbook「S10c 部署时验证」 |
| S10r-5 | 「只到 outbox」算不算通过 | 不算，标「部分」。S10c 的口径是 Chitu 收到并有截图 | runbook |
| S10r-6 | TestFlight 发给黄总家之前的门槛 | S10r-3 的 B1、B5、B6；S10r-4 的 M1、M2、M4 和 M5 / M6 / M8 重发；看到一次证书自动续期；S10r-7、S10r-8、S10r-9；第 2、3 项补测；S10r-10 查清 | §8 S11b / TestFlight 前检查 |
| S10r-7 | 商品图桶 `yuanhui-img` 建不建 | 现在建空桶（私有、无版本控制、无合规保留、无生命周期），需负责人同意第三个桶。不改代码跳过不存在的桶 | `cloud-manual-steps.md` 第 3 步 |
| S10r-8 | 恢复时忘设存档桶，删除记录读成空、已注销的店复活 | `restore.sh` 头部说明补 `BACKUP_OSS_ARCHIVE_BUCKET`；OSS 模式下没设就拒绝；dry-run 打印 `deletions/` 来自哪个桶；`backup.ts status` 打印两个桶名 | `deploy/restore.sh`、`server/src/backup/` |
| S10r-9 | 出口 IP 变了 SSH 连不上 | runbook 加「SSH 连不上」一节：怎么认、CLI 先加后删的两条命令、连带影响、主账号控制台和 VNC 兜底；真做一次演练 | runbook、`cloud-manual-steps.md` 第 1 步 |
| S10r-10 | `ledger.late`、`ledger.lots` 两条测试本机挂、CI 过 | 另开一项查清是测试还是代码和日期 / 时区有关；查清前不发 TestFlight | 新 PR |
| S10r-11 | 对象清理失败不告警；图片桶失败挡住 `exports/` 删除 | `store_purges.attempts` ≥ 3 打 `alert`；各桶分开处理 | `server/src/jobs/account-purge.ts`（T 项，S32 前） |
| S10r-12 | 其余小项 | 手工回滚那句改对；ECS 旧镜像清理说明；`image.yml` 基础镜像按 digest 固定；runbook 时间统一时区；T24 那天看 `backup_lifecycle_stale` 是否误报，误报则阈值改 37 天（注：已在 PR #27 定为 38 天，`LIFECYCLE_GRACE_DAYS`，不要改回 37） | runbook、`image.yml`（S32 前） |

S22d-server 的 PR（#42）按 Fable 方案实现，负责人四点暂按默认（11/24 02:30 CST），裁定如下：

| # | 问题 | 裁定 | 改在哪里 |
|---|---|---|---|
| S22d-1 | 候选要不要按时间过期 | 不过期：ready 候选与 `barcode_catalog` 行同寿。快鸟链接过期后重取要再花一次付费查询，每码最多 6 张、每张约 10 KB。failed 行保留，防止反复重试。每周清扫 `images/_catalog/`，只删没有对应行且落地超过 1 小时的对象。备选（负责人坚持过期时）：按 `fetched_at` 满 N 天删行删对象，之后再扫这个码只能拍照 | `lookup/candidates.ts`、迁移 0005 |
| S22d-2 | 收银员能不能选图、拍照 | 不能：四个新接口收银员 403，查码响应不带 `image_candidates`（scope 不变）。收银员只能 `quick` 登记，它登记的商品由兜底任务落第一张，家用补全时再选或拍。要放宽为「仅 `image_ver=0` 且是本机建的商品」需负责人定 | `permissions.json`、§6.1 |
| S22d-3 | 演示店能不能上传 | 不能：演示店公用，不放用户图，也不用第三方图。候选恒为 `none`，缩图 404，选图和上传 403 | `routes/lookup.ts`、`routes/product-images.ts` |
| S22d-4 | 开关几个 | 单开关 `PRODUCT_IMAGES_ENABLED`：关掉后候选、选图、上传、读图全部 404，`/v1/config.product_images_enabled=false`，连自拍图也不显示。若条款只禁第三方图又想保留拍照，要拆成两个开关，另开一段、需负责人定 | `config.ts`、`routes/config.ts` |
| S22d-5 | 转存怎么做 | 异步：查码只插行、立刻唤醒进程内 worker（并发 1），不等下载（查码 2.5 秒预算，单图最长 8 秒）。重试共 3 次，隔 30 秒、5 分钟；永久性失败沿用 `PERMANENT`。下载和校验全部复用 `fetchImage` / `makeThumbnail`。键 `images/_catalog/<sha256(条码)前 32 位>/<cid>.jpg`，仍在 `images/` 下，RAM 不用改；不属于任何店，注销清除碰不到它。`last_error` 只记原因代码，`source_url` 不进日志、不下发。兜底任务（只在 `image_ver=0` 时落第一张）优先复制已 ready 的候选，没有才下载 | `lookup/candidates.ts`、`jobs/image-fetch.ts`、`jobs/scheduler.ts` |
| S22d-6 | 选图、上传的写回 | 都在 `withStoreLock` 里：`image_ver`+1、`nextRev()`、`image_source` 记 `kuainiao` / `upload`；内容哈希与当前图相同不升版本。上传前查 `storeGone`、锁内复查，店没了走 `dropLateObject`。换图后尽力删旧对象和本机缓存，删不掉记 `image_discard_failed`（T34） | `routes/product-images.ts` |

S22d-iOS 按 Fable 方案（11/25）分两个 PR：① 选图（候选、第三步选图页、暂存重发）；② 拍照和相册、没图时提示拍照、进货页商品卡重拍。裁定如下：

| # | 问题 | 裁定 | 改在哪里 |
|---|---|---|---|
| S22d-7 | 选图放在登记哪一步 | 存好之后的第三步「选一张商品图」（04a 不动，SE 最大字号下已无余量）；返回键等于「跳过」，不回 04a。两张及以上出选图页，默认选中第一张；只有一张不问、直接 select；没有就照常回去。收银员（04c）、演示店、开关关没有这一步 | `NewProductView`、`ImageChoiceView` |
| S22d-8 | 候选什么时候问 | 查码一回来就在后台问，不等存好：`pending` 每秒问一次 `/images`，最多 8 秒；存好时还没定就在第三步显示「还在找图…」，「跳过」随时可点，定了只剩 0 / 1 张就自己往下走。查码没带回候选（进程内记过的码、查码出错）先问一次；没网当没有 | `ImageChoiceModel` |
| S22d-9 | 待发的选图存哪、什么时候发 | 不进账本库：`Application Support/pending-images/<本机店 id>/<商品>.json`（+ 候选缩图 `.jpg`，成功后 prime）。闸门 `LocalDB.imageGate`：本店 outbox 里这个商品的 `product_upsert` 还没拿到结果就等；被拒或本机没这个商品就丢。暂存当下、每次同步成功后、会话建立时各发一趟；只有暂存当下发现要等才踢一次同步。401 / 429 / 5xx / 连不上留到下一趟，503 等 `retry_after_s`（≤ 5 秒）再试一次，404 能发之后累计 3 次丢，400 / 403 / 413 丢，放 14 天丢，每店最多 100 条 | `App/Net/ImageChanges.swift`、`LocalDB/ImageGate.swift` |
| S22d-10 | 会话切换时暂存怎么办 | 跟着会话走：退出、被踢、换身份时整个目录删掉；本机店 id 每次登录都是新的，下次登录认不出是同一家店。暂存的选图 / 照片没传上去就丢，**按 Fable 裁定不算 REVIEW 12.1 第②类**（②指账本和 op；图能重选重拍，不影响钱和库存），负责人要升级需改 REVIEW.md | 同上 |
| S22d-11 | 选完马上看得到 | 本机预览：`ProductImages.previews`，Thumb 先显示它（离线也有），服务器回版本后记下，商品的 `image_ver` 超过它就不再用；会话结束清掉。不改本地 `product.image_ver`，成功后 prime 200px 缩图 + 踢一趟同步拉回新版本 | `ProductImages`、`Thumb` |
| S22d-12 | 拍照、相册 | 「拍一张」用系统相机（模拟器和 UI 测试用 Debug 的假相机 `-uiFakeCamera`，要真点快门；出 4032×3024、方向 `.right` 的图），「从相册选」用系统相册选择器（PhotosPicker，不要相册权限）。拿到图在后台压：按显示方向重绘到长边 ≤ 1024（不放大），JPEG 质量 0.8→0.4，还超 400 KB 就缩到 768 再来；另出 200px 预览（成功后 prime、离线预览）。PUT 和选图共用暂存、闸门、重发；同一商品后来的照片顶掉先前的选图 | `PhotoCapture.swift`、`ImageChanges.swift` |
| S22d-13 | 没图时 | 候选定了一张也没有（none、found:false、8 秒到了还是 0 张、没网）：第三步「这个商品还没有图」，拍一张 / 从相册选 / 跳过；有候选时选图页上也能改拍 | `ImageChoiceView` |
| S22d-14 | 「重新拍照」放哪 | 商品详情页（S25）之前先放进货页商品卡：商品图右下角小相机，点开「换商品图」（只问一次候选，不轮询）：重选候选、拍一张、从相册选、关掉。卖出页不加（收银热路径）。收银员、演示店、开关关没有。S25 做详情页时把入口搬过去 | `StockInView`、`ReplaceImageSheet` |
| S22d-15 | 老条码 / 全失败的条码在「换商品图」里没有候选（真机 11/26，负责人同意「修复 2」） | 改 S22d-1 的「failed 保留、不重取」：`GET …/images` 发现一张能用的都没有（没有行、全部 failed、卡死的 pending）且条码库地址已过期（`fetched_at` 超过 2 小时，api-yun 链接约 2 小时过期）时，重新问一次快鸟、刷新 `barcode_catalog`、删掉非 ready 的行按新地址重登记，回 pending。快鸟按次计费：`images_refreshed_at` 原子占位，每条码每天最多一次（并发轮询只问一次，没问到也算一次），照样占本店当天额度；地址没过期、明确没查到、没有条码库行、演示店不刷新。查码命中旧缓存时不再拿过期地址登记，能刷新就回 pending 让手机轮询 | `lookup/candidate-refresh.ts`、迁移 0007 |
