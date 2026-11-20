# 元辉账本 开发计划 v2（2026-11-20）

本文件取代 `design/plan.md`（11/16 旧版，只留作历史参考）。11/20 已按 Codex 的评审意见修订，逐条处理见 §13；S01 执行者提出的 14 条疑问的裁定见 §14。决策来源按优先级：11/20 最新决定 > README「11/19 新增决策」> review-1119.md / review-1119-mockups.md / changes-1119.md > README 11/16。设计稿以 `design/png/` 下 53 张为准（总览 `overview.png`）。

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
| 商品图 | 服务器下载 → 压成长边 200px → 存 OSS；App 只从自家服务器取图；没图显示名称首字；不做拍照换图 |
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
| iOS 测试 | `swift test`（ShopCore 包，不依赖 UIKit）；XCUITest + `FakeScanner`（启动参数喂条码）；截图用 `-uiFixture <名字>` 直接打开指定界面的指定状态 | |
| 服务器 | Node 24 LTS，TypeScript，**Fastify 5**，Postgres 16 | SQL 用 Kysely；迁移是 `server/migrations/*.sql` 纯 SQL 文件，按文件名顺序执行 |
| 服务器库 | argon2（密码）、sharp（缩图）、ali-oss、TypeBox（请求校验）、pino（日志） | |
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
| `pairing_tokens` | `id, token_hash, account_id, store_id, role, label, created_by_device, expires_at, used_at, used_by_device` | 2 分钟过期，一次性；只有 `role='family'` 的设备能创建 |

### 3.2 商品

| 表 | 字段 | 约束 / 说明 |
|---|---|---|
| `products` | `id, store_id, name, base_unit, price_fen, stock_qty int, stock_value_fen bigint, last_cost_fen null, cost_known bool, stock_ver bigint, last_count_at null, low_at int null, stock_known bool, track_expiry bool, expiry_warn_days int=7, shelf_life_months int null, needs_review bool, image_key null, image_source null, image_ver int=0, archived_at null, created_by_device, rev, updated_at` | 平均进价不存，等于 `stock_value_fen / stock_qty`；`cost_known` = 进价是否已知，用来区分「真的零成本」和「没填」（§5.2）；`stock_ver` 每次库存变动 +1，`last_count_at` 是最近一次盘点或期初的时间（§5.6）；`needs_review` = 收银员临时登记、等家用号补全；`price_fen >= 0` |
| `product_barcodes` | `store_id, barcode, product_id, pack_qty int, unit_name, pack_price_fen, rev, deleted_at` | 主键 `(store_id, barcode)`；`pack_qty >= 1`；**单件码（`pack_qty=1`）的 `pack_price_fen` 必须为空，卖价一律读 `products.price_fen`**（CHECK 约束），只有整件码存自己的价；一个商品可以有多个单件码 |
| `product_aliases` | `store_id, alias_id, product_id` | 两台手机离线时各自登记了同一个条码：先到的赢，后到的商品 id 记成别名，之后引用别名的 op 一律改写到赢家 |
| `barcode_catalog` | `barcode, found bool, name, spec, brand, image_url, source, raw jsonb, fetched_at` | 全局缓存，不分店；查不到也缓存（7 天后可重查） |

### 3.3 流水

| 表 | 字段 | 约束 / 说明 |
|---|---|---|
| `ops` | `id uuid, store_id, device_id, type, payload jsonb, payload_hash, occurred_at, received_at, status 'applied'\|'rejected'\|'held', reject_code, result jsonb, resolved_at null, resolved_by_device null, flags jsonb` | 主键 `id`，幂等靠它；`result` 存当初返回给手机的结果（含 remap、拒绝原因），重发时原样返回；被拒的、暂存待确认的（§4.5）也留档；暂存的 op 被家用手机处理后，`status` 改成 `applied`（记上）或 `rejected`（`reject_code = discarded`，不要），并写 `resolved_at / resolved_by_device` |
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

**撤销的记法（规则）**：原流水打 `voided_at`（界面上划线显示）；同时新增一行**冲销流水**，`type` 与原行相同、`reverses_entry_id` 指向原行、所有数量和金额取反、`occurred_at` = 撤销发生的时间。报表对所有行（原行 + 冲销行）按各自的 `occurred_at` 求和，所以「撤销算在撤销那天」；当天撤当天的（绝大多数情况）正好抵消。列表界面不显示冲销行。`unit_cost_fen` 是单价不是金额，冲销行**照抄原行、不取反**（进货的冲销行、`cost_fix` 的冲销行都一样）。好处：已经过去的月份的月初货值不会被事后改动，对账等式永远是同一张流水表的求和。

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
| `entry` / `sale_batch` | 家用号：最近 35 天全店流水；收银员：仅本机最近 2 天的卖出 |
| `lot` | 仅家用号：未关闭的批次（首页黄条和快过期清单离线可用） |
| `outbox` | 待传的 op，每条绑定产生它时的店、设备和令牌（不可改绑），op id 店内唯一；确认后保留 14 天（§4.6）；旧会话留下的未确认 op 构成「恢复队列」（§4.5）。当前会话是收银员时，旧会话的 op 一确认就删，换成收银员时旧会话已确认的立刻删，都不留 14 天（§14 S13-1） |
| `meta` | 游标、`server_epoch`、角色、店名、设备名 |

退出、被踢、换角色、换账号时清空**投影**（商品、流水、批次、游标）再同步，但**绝不清未确认的 outbox**，它们连同旧令牌进恢复队列（§4.5）。大字模式、扫码枪开关等偏好存 `UserDefaults`，不进库。设备令牌（当前的和恢复队列用的旧令牌）存钥匙串（`kSecAttrAccessibleAfterFirstUnlock`）。

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
- **首次同步（review 四-4）**：先把 `catalog` 拉到底就进首页、可以开始卖；`ledger` 和图片在后台继续，图片不占同步队列、不阻塞扫码。拉取期间别的手机继续记账没有关系：新改的行序号更大，排在后面，不会漏。
- **`remap` 的形状**：一个对象，键是这个 op 里引用到的、已经成为别名的商品 id，值是赢家商品的 id；可以有多对（一笔卖出的好几行可能各引用一个别名）。任何引用了别名的 op 都可能带它，不只是 `product_upsert`。手机收到后把本地所有对旧 id 的引用改写成新 id。
- **结果可重放**：服务器把每个 op 的结果（应用 / 拒绝及原因 / 暂存 / remap）存在 `ops.result`。重发同一个 id，返回当初的结果并带 `replayed: true`，不返回笼统的「重复」。同一个 id 但 payload 哈希不同 → 拒 `id_conflict`，不应用。
- **epoch 握手**：请求带手机记着的 `epoch`，必填、不允许为空；手机的第一个 `epoch` 来自登录或兑码的响应（§7）。与服务器不一致时，服务器**不应用**这次请求里的任何 op，只返回 `epoch_mismatch` 和新 epoch，手机按 §4.6 处理后再发。
- **店铺锁只有一个入口**：所有拿店铺锁的写入（S04 同步、S05/S06 记账、S08 图片任务、S09 重置）都只走 `withStoreLock`，不许自己另拿锁。进程内按店排队，每家店在途上限默认 32（`STORE_QUEUE_LIMIT`），超过返回 `503 {code: unavailable, retry_after_s}`，不进队列、不取连接（§14 S04-8）。
- **请求体上限**：1 MiB。超过返回 `413 {code: invalid}`，一个 op 都不处理。手机按字节拆批（≤200 个 op 且 ≤1 MiB）；最大的合法 op（200 行的卖出、字符串写满、非 ASCII 全转义）约 0.75 MiB，单独一个总放得下。op 的内容（存不进库的字符、解析不出的时间、payload 嵌套超过 16 层或超过 1 万个节点）只让这个 op `rejected: invalid`、不留档，不会让整个请求失败（§14 S04-13）。
- **注销期间**：`/v1/sync` 里的 op 一个都不应用、不留档，`results` 为空，拉取照常，响应顶层带 `delete_pending_until`；手机把 op 留在 outbox 并停止推送，撤回后自动补传（§14 S04-2）。
- **按角色裁剪**（在 `sync/projection.ts` 一处实现）：收银员拿不到 `product_private` 里的任何字段、任何进货/盘点/损耗流水、别的手机的流水、保质期批次、`cogs_fen`/`value_delta_fen`/`unit_cost_fen`。响应 JSON 里**不出现这些键**，不是置空。
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
| `product_review_complete` | `entry_id, product_id, unit_cost_fen（必填，可为 0）, counted_qty, base_ver, base_qty?, 保质期设置?`（22b 待确认补全；`entry_id` 是它生成的那条 `opening` 流水的 id）→ 记一条 `opening` 流水，清 `needs_review` | 家用，**只能联网提交**（§5.6） |
| `count` | `entry_id, product_id, counted_qty, base_qty, base_ver` | 家用，**只能联网提交**（§5.6） |
| `expiry_dispose` | `lot_id, handle_ver, actual_qty, action: sold_out\|discard\|return, entry_id` | 家用 |
| `lot_snooze` | `lot_id, handle_ver, actual_qty, days` | 家用 |

（设备改名、踢人、改密码等不是 op，是在线接口，见 §7。）

### 4.4 拒绝与冲突

| 情况 | 处理 |
|---|---|
| 角色无权 | `rejected: forbidden`。手机把这条 op 标成「没记上」并在首页提示，不再重试；它对本地库存的临时增减随之消失 |
| 同一条码已经登记过（两台手机各登记了一次，或有人故意重复登记） | 先到的赢。后到的 `product_upsert` **不修改赢家的任何字段**（不论角色），只返回 `remap` 并写 `product_aliases`，手机改写本地引用。家用号想改名称或卖价，另发 `product_edit` |
| 收银员卖了一个还没同步到服务器的商品 | 同一请求内 op 按顺序应用，`product_upsert` 在前即可；手机 outbox 保证先后顺序 |
| 卖出引用了不存在的商品（极端） | 服务器按 payload 里的名称和卖价自动建一个 `needs_review` 商品，流水照收，绝不丢账 |
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
- **演示小店重置**：重置时把演示店所有设备标记为已撤销并带 `discard_outbox=true`。手机收到后**丢弃**这家店的 outbox 和恢复队列，不重放，回到登录页。重置不换 `epoch`。

### 4.6 服务器从备份恢复之后（补救手段，不是保证）

正常的灾备靠 §9.4 的备份（营业时间内每小时一次）。手机重传只是在此之上再补回一些数据：

- 手机上已确认的 op 保留 14 天。
- 恢复后运维给店铺换新 `epoch`。手机下一次同步得到 `epoch_mismatch`：丢弃投影和游标 → 重新全量拉取 → 把保留的 op 全部重新标为待传 → 正常同步。服务器上还在的 op 按 id 幂等跳过，丢了的重新入账。
- 讲清楚的限制：① 重传的先后顺序可能与原来不同，平均进价和个别流水的成本可能与恢复前差几分钱；② 备份之后才开通的设备，令牌在恢复后的库里不存在，无法认证。这类设备要重新开通，然后由运维临时打开「恢复模式」，设备（家用或收银员）通过 `POST /v1/recovery/import` 用新令牌补交保留的 op（按原 id 幂等，打 `flags.recovered`）。恢复模式平时关闭，步骤写进 runbook。

---

## 5. 成本与金额算法（规则，不许改口径）

全部在 `server/src/ledger/`，`contracts/vectors/cost.json` 给出逐步的数值用例。

### 5.0 整数规范与输入上限

- 金额是 64 位有符号整数（分）。服务器上凡是金额相乘的中间运算一律用 `BigInt`；手机只做两种乘法（优惠分摊、进货页的预计平均），用带溢出检查的 `Int64` 乘法，溢出按无效输入处理。JSON 里金额和数量都是整数，不带小数点、不用字符串。
- `roundDiv(a, b)`（`b > 0`）：四舍五入到整数，恰好一半时远离零；对负数对称，`roundDiv(−a, b) = −roundDiv(a, b)`。本节所有「除」都指它。
- 服务器校验的上限（超出拒 `invalid`，手机端输入框同样限制）：
  - 单价、进货的每件单价、单行金额（单价 × 件数；进货是件数 × 每件单价，即进货总价）≤ 99,999,999 分；
  - 一笔卖出的实收 `paid_total_fen` ≤ 19,999,999,800 分（= 200 行 × 单行上限；多收也不能超过它）；
  - 件数 `pack_count` ≤ 99,999；`pack_qty` ≤ 9,999；**基本单位数量**（件数 × 换算、盘点数、期初数、处理快过期时的实际数、扔掉和退货的数量）≤ 9,999,999；`base_qty`（账面数，可以为负）绝对值 ≤ 9,999,999；
  - 一笔卖出 ≤ 200 行；除 `base_qty` 外数量和金额不为负。
  - 进货件数 `pack_count` ≥ 1（0 件时 `b = roundDiv(T, 0)` 无定义）：`ops.schema.json` 不改，服务器在应用时判，拒 `invalid` 并留档；`limits.json` 有对应的一组，手机同样拦。卖出行 0 件不拒（§14 S05-3）。
  - 算出来的结果也要存得进列：新的 `stock_qty`（`integer`）和 `stock_value_fen`、各行金额（`bigint`）用 `BigInt` 算完再比，超出拒 `invalid` 并留档，在写库之前判；过了这一层写库时再出 22xxx 的记账 op 整个请求 500（§14 S05-4）。
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

- 本月对账（设计稿 10）：`月初货值 + 本月进货 − 卖掉的货的进价 − 盘点少了的 − 过期扔掉的 − 退给供货商的 (± 期初登记和调整，非零才显示这一行) = 现在店里货值`。**每一项都是 `entries.value_delta_fen` 按类型的分组求和**（「卖掉的货的进价」= 卖出行 `value_delta_fen` 之和取负，不是 `cogs_fen` 之和），所以等式恒成立。
- 赚了 = Σ 进价已知的卖出行 `(amount_fen − cogs_fen)` + Σ `cost_fix` 行 `(amount_fen − cogs_fen)`。尚未补记的 `cost_missing` 卖出行不计入，并在报表上计数；标了 `cost_missing` 的损耗行另行计数（§5.2）。卡片下写「赚了 = 卖出 − 进价，损耗和盘点少的另算」。
- 卖了 = Σ 卖出行 `amount_fen`（`cost_fix` 行的 `amount_fen` 不算进「卖了」，否则重复）。
- 优惠 = Σ `(list_amount_fen − amount_fen)`。
- 日和月的界线按 `occurred_at` 的上海时间。

### 5.4 保质期批次（只管提醒）

- 管保质期的商品，每次进货 / 期初生成一个批次；没填到期日也生成（`expiry_date = null`，不提醒）。到期日两种填法：直接填；或生产日期 + 保质期月数（按日历月加，月末对齐：1/31 + 1 个月 = 2/28 或 2/29）。必过向量：2026-11-12 + 6 个月 = 2027-05-12；2026-11-19 + 12 个月 = 2027-11-19。
- 卖出、盘亏按到期日从早到晚扣批次（空日期排最后），写 `lot_moves`。到期日相同（或都为空）的批次，先扣先建的（来源流水 `seq` 小的在前）。
- 提醒：`今天 >= expiry_date − expiry_warn_days`，批次未关闭、`qty_left > 0`、不在「过几天再提醒」期内。`今天 < snoozed_until` 才算在期内，**到 `snoozed_until` 当天就恢复提醒**。首页黄条数的是**商品种数**。
- **处理时一律以人数的为准**（20、20b）：先填「货架上这批实际还有几个」，再选：卖完了（关批次，不动库存）/ 下架扔掉（记 `expire_loss`，数量 = 实际数）/ 退给供货商（记 `supplier_return`）/ 还在卖过几天再提醒（批次数量改成实际数，`snoozed_until = 今天 + 天数`）。批次数量之和**不强求**等于库存，批次不准不会把账带歪。
- **防两台手机各处理一次**：每个批次有 `handle_ver`，只在「处理」和「过几天再提醒」时 +1（普通卖出扣批次不改它）。`expiry_dispose / lot_snooze` 带手机看到的 `handle_ver`；批次已关闭或版本不一致 → 拒 `stale`，手机刷新后让人重新确认。
- **批次的生命周期**（`closed_at` 只由下面两种情况设置；卖到 `qty_left = 0` 不算关闭，只是不再提醒）：

| 事件 | 对批次的影响 |
|---|---|
| 处理为卖完了 / 扔掉 / 退货 | 关闭，`closed_reason = disposed`；处理前的 `qty_left` 记在流水的 `flags` 里 |
| 撤销「扔掉」或「退货」 | 库存加回；批次重新打开，`qty_left` 恢复为处理前的值，重新参与提醒 |
| 撤销卖出 | 按 `lot_moves` 原样加回；若对应批次已关闭，则这部分不加回、也不重开（批次只管提醒） |
| 撤销来源进货 | 这次进货生成的批次关闭，`closed_reason = voided`；已经从这批扣过的 `lot_moves` 保留不动 |

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
   因此**每次库存变动**（卖出、进货、期初、撤销等任何改 `stock_qty` 的流水）`stock_ver + 1`，期初和盘点写 `last_count_at`。`opening` 的第 2、3 条由 S05b 实现；第 4 条、`count / product_review_complete` 的校验和批次在 S06（§14 S05-2）。
4. **迟到的流水**：任何影响库存的 op 入账时，如果它的 `occurred_at` 早于这个商品最近一次盘点 / 期初的时间（`products.last_count_at`），说明数的时候这些货已经不在货架上了。处理：流水照常入账（收入、成本照记），同时自动追加一条 `count` 类型的补偿流水（数量和货值正好抵消这笔流水对库存的影响，`flags.late_before_count`），库存保持为盘点得到的数。效果：原先被算成盘亏的那几个，改由这笔卖出解释。
5. 不做「盘点期间暂停其他手机记账」，店里不能因为有人在盘点就卖不了东西。

---

## 6. 权限矩阵

三种身份：**家用**（家用号登录或扫家人码的设备）、**收银员**（扫收银员码的设备）、**审核**（审核号登录的设备；权限同家用，但只在演示小店内，演示小店里也能开通演示用的收银员设备）。机器可读版在 `contracts/permissions.json`，服务器的 `guard` 中间件和两边的测试都读它。

三条实现原则：① 权限在服务器上判，界面隐藏只是体验；② 进价、货值、库存不下发到收银员手机；③ 收银员撤销「自己当天」的判断不信手机填的时间：必须是同一设备记的卖出，且这笔卖出的日期（上海时区）等于**服务器收到撤销请求那天**。离线撤销当天传上来照常生效；隔天才传上来的被拒，提示让家里人撤（这一条取代 review-1119 §5.1 第 3 点「按手机上记录的时间算」）。

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

跨店隔离：任何接口都只能碰令牌所属的店。S09 有专门测试：用审核号令牌把元辉店的每一种 id 都试一遍，全部 404 / 拒绝。

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
| `GET /v1/config` | `min_build, demo_login_enabled, privacy_url, support_url` | 无鉴权 |
| `POST /v1/auth/login` | `{username, password, device_id, label?}` → `{token, role, store, label, epoch, delete_pending_until?}` | 连错 5 次锁 15 分钟（25c），另有按 IP 限速；错误信息不区分「账号不存在」和「密码错」 |
| `POST /v1/auth/pair/redeem` | `{code, device_id}` → 同上 | 码用过或过期 → 明确错误码（25d） |
| `POST /v1/auth/demo` | 一键进演示小店（「看看演示」，受 `demo_login_enabled` 开关控制，**默认关**，被打回再开） | 发的是演示店的家用设备令牌 |
| `POST /v1/auth/logout` | 作废本机令牌 | 手机先尽量把 outbox 传完 |
| `GET /v1/me` | 角色、店名、设备名、注销状态 | |
| `POST /v1/sync` | 推 op + 拉变更（§4） | 平时唯一的写账入口 |
| `GET /v1/barcode-lookup/:barcode` | 查名称（先查 `barcode_catalog`，没有再调快鸟，2 秒超时） | 每设备每分钟 20 次；每店每天 300 次上限，防止刷掉付费额度 |
| `GET /v1/images/:product_id?v=` | 200px 小图 | 强缓存；本地磁盘缓存，缺了回源 OSS |
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
| `POST /v1/account/password` | `{old, new}` | 不强制其他手机退出 |
| `POST /v1/account/delete-request` | `{password}` → 记 `delete_requested_at`，全部设备退出 | 注销期间禁止写账和开通设备；非演示店先生成导出包交给黄总；7 天后删除在线数据和 OSS 图片，备份在此后 35 天内滚动清除（§9.4） |
| `POST /v1/account/delete-cancel` | 7 天内用账号密码登录后撤回 | |

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

**S05 记账引擎一：卖出、抹零、进货、期初、撤销**
- 产出：`ledger/apply.ts cost.ts allocation.ts void.ts invariants.ts rounddiv.ts`。
- 验收：`allocation.json`、`cost.json`、`rounddiv.json` 全部向量通过；fast-check 性质测试（随机 op 序列 ≥ 500 组，含乱序重放）断言 I1–I8；正库存但进价没填时卖出 → `cost_missing`、不进利润；明确零成本的商品不标 `cost_missing`；超出 §5.0 上限的输入被拒；收银员撤销别的设备的卖出、撤销进货被拒；收银员撤销本机**昨天**的卖出被拒，把撤销的 `occurred_at` 伪造成昨天也一样被拒（按服务器收到的日期判）；收银员当天撤本机的成功；引用未知商品的卖出自动建待确认商品，不丢账；手机时钟超前 1 天的 op 被校正并打标记。
- 拆分（§14 S05-6）：S05a 只做纯算法（`cost.ts`、`invariants.ts`，PR #11），S05b 做写库与同步接入（`apply.ts`、`void.ts`）。两个 PR 各自过审，S05 段在 S05b 合并后才算完成，依赖 S05 的段等 S05b。
  - S05a 已做：§5.2 全部纯算法与 `cost.json` 全部向量；返回前统一检查新状态和每条流水都存得进对应列（`stock_qty`、`qty_delta` 是 `integer`，金额、货值、成本是 `bigint`），越界整步拒 `invalid`（S05-4 第二层）；`assertLedger` 加了列范围、补记不含当时已撤销的行、`cost_fix` 冲销行逐分（用原补记的 b、跟 +数量 × b 的 `cost_adjust`、净额 = 仍有效的被补记卖出合计）；性质测试加了贴着列上限的生成器、「补记 → 改变当前进价 → 撤销」定向生成器（同一条 `cost_fix` 多次部分冲销）、u ≠ c 的盘盈。
  - S05b 验收 = 本段验收里的写库与同步部分，加 §14 S05-6 列的 ①–⑩。另外（Codex 对 #11 的意见）：S05a 里「同一序列跑两遍」只证明确定性，不证明 I5 幂等；I4–I8 和乱序重放必须在 S05b 经 `/v1/sync` 写库完整验收。S05-4 第二层在 S05b 要经同步接口各测一次（含 `stock_qty` 溢出、`Int64` 货值溢出，拒 `invalid` 并留档，不产生 500）。`assertLedger` 的 `cost_fix` 冲销断言依赖「同一次撤销产生的流水相邻（id 递增）」，S05b 写库时要保持这个顺序。

**S06 记账引擎二：盘点、保质期批次、损耗、退货、待确认补全、成本补记**
- 产出：`ledger/count.ts lots.ts costfix.ts`，op：`count / expiry_dispose / lot_snooze / product_review_complete`，§5.6 的版本校验和迟到流水补偿。
- 与 S05 的分工（§14）：成本补记已由 S05b 在 `stock_in / opening / void` 里当场写库，`costfix.ts` 只剩 `product_review_complete` 的接入，不许另写一套补记逻辑（S05-1）；`opening` 的版本校验、`stock_ver + 1`、`last_count_at` 已在 S05b，本段做 §5.6 第 4 条迟到补偿、`count / product_review_complete` 的版本校验，并把进货、期初、卖出、撤销的批次动作（`stock_lots / lot_moves`）一并补上（S05b 只在流水上存 `expiry_date`，S05-2）；给 `cost.json` 加一组 u ≠ c 的盘盈（例如库存 6、货值 24280、c = 4000，数到 8 → 盘盈 2 × 4047），服务器和手机都要过（S05-8）。
- 验收：
  - `expiry.json` 向量通过；账面 2 实数 1 → 盘亏 1 个，按平均进价。
  - 并发盘点：A 看到 10（版本 n）→ B 卖 2 → A 提交盘点 10 被拒 `stale` 并带回 8 → A 带新版本确认后成功，库存 10、盘盈 2。
  - 迟到流水：B 在盘点前离线卖了 2 个，盘点（数到 8）之后才传上来 → 卖出入账、自动补偿，库存仍是 8，盘亏相应减少 2 个。
  - 批次：卖出按到期日从早到晚扣，撤销后各批次数量与卖出前逐一相等；两台设备带同一个 `handle_ver` 各提交一次「扔掉 2 个」→ 只成功一次，另一次 `stale`；处理（关闭）后再撤销此前的卖出 → 批次不重开；撤销「扔掉」→ 批次重开且数量恢复；已有销售后撤销来源进货 → 批次关闭、`lot_moves` 保留、I1–I3 成立。
  - 处理快过期四个动作各一条测试（扔掉减库存减货值记损耗且**不改变「赚了」**；退货不计盈亏；卖完了不动库存；过几天再提醒到期后重新出现）。
  - 待确认补全：记的是 `opening` 不是 `stock_in`、清 `needs_review`、生成一条 `cost_fix`，原卖出行的 `cogs_fen` 不变。
  - 两组逐分用例：「先卖出 → 撤销 → 补进价」（已撤销的不参与补记）；「先卖出 → 补进价 → 跨月撤销」（撤销月出现冲销的 `cost_fix`，上月数字不变，对账等式两个月都成立）。
  - 性质测试加入新 op 后 I1–I8 仍成立。

**S07 报表与查询接口**
- 产出：`reports/today.ts month.ts entries.ts`。
- 验收：用一份固定夹具复现设计稿 10 的数字：卖了 23,474、赚了 5,487、月初货值 + 本月进货 41,595、卖掉的货的进价 17,987、盘点少了 128、过期扔掉 58、退供货商 160、现在货值 23,262，等式逐分成立；随机序列上「对账等式成立」作为性质测试；跨月撤销不改变上月的月初货值；未补记的 `cost_missing` 行不进「赚了」并计数，`cost_fix` 进「赚了」但不进「卖了」；收银员访问全部 403（真实请求）；一个月 1 万条流水时月报 < 300 ms。

**S08 条码查询与商品图**
- 产出：`lookup/kuainiao.ts catalog.ts images.ts oss.ts`、`jobs/image-fetch.ts`、`scripts/barcode-trial.ts`、`docs/image-rights.md`。
- 验收：快鸟客户端用录制的响应做测试（密钥只从环境变量读，不进仓库、不进日志）；查到的结果写缓存，第二次不再调外部；外部超时 2 秒时接口仍在 2.5 秒内返回「没查到」；图片下载 → 长边 200px JPEG → 写 OSS → 写回 `image_key`（走店铺锁和取号函数）；图片下载失败不影响商品保存；只允许 http/https 且解析后不是内网地址的图片 URL（防 SSRF），单图 ≤ 5 MB；每店每天 300 次上限生效；演示店不调外部；图片功能有一个服务器开关 `product_images_enabled`，关掉后所有商品显示首字。
- 人工项一：用免费额度跑 `barcode-trial.ts` 测 20 个真实条码（含 5 条香烟、5 个本地品牌），把命中率和有图率写进 PR。有图率 < 50% → 商品图降级到第二版；香烟命中率低 → 记入风险，登记时手输名称。
- 人工项二（图片使用授权）：读快鸟在云市场的服务协议和接口说明，把关于返回图片能否缓存、缩图、在自己的 App 里展示的原文摘进 `docs/image-rights.md`。**条款明确禁止 → 开关保持关闭，全部用首字。条款没有提及 → 开关是否打开交 Haoqiang 决定（§12），在他决定前保持关闭。** 演示店和商店截图无论如何不用第三方图。

**S09 演示小店、每日重置、账号注销与导出**
- 产出：`demo/seed.ts reset.ts`、`jobs/account-purge.ts`、`jobs/scheduler.ts`、`scripts/export-store.ts`。
- 演示数据：店名「演示小店」；约 30 个商品，**全部是饮料、零食、日用品，没有烟和酒**，图片只用首字或自绘通用图；最近 7 天的流水（日期相对「今天」生成，含一笔抹零、一笔撤销、一次进货）；一个 3 天后到期和一个已过期的批次；一个待确认商品；一个整箱码（可乐 1 箱 = 24 罐）。
- 重置：每天北京时间 16:00（美国西岸半夜）；如果演示店最近 60 分钟有请求就顺延 1 小时再试。重置恢复审核号密码、撤回注销申请、把演示店全部设备标为已撤销并带 `discard_outbox`（§4.5），不换 `epoch`。
- 注销：申请时为非演示店生成一份导出包（商品、流水、月报的 CSV 压缩包）放到 OSS 的 `exports/`，告警通知 Chitu 转交黄总；满 7 天后删除店铺全部在线数据、OSS 图片和导出包，并往 OSS 的 `deletions/` 写一条删除记录（不在数据库里，不随备份回滚）。`restore.sh` 恢复后必须重放删除记录（S10b）。
- 验收：重置后数据与种子逐表一致；有活动时不重置；**一台在重置前登录、带着未传 op 的手机跨过重置**：得到 `revoked + discard_outbox`，重新登录后看到的是干净的种子数据，旧 op 没有进库；重置前改了审核号密码或申请了注销，重置后用原密码能登录；审核号令牌遍历元辉店的商品、流水、设备、报表 id 全部拿不到（隔离测试）；注销申请中写账和开通被拒；满 7 天后在线数据清空、删除记录存在、7 天内撤回则无事发生；导出包内的合计与月报一致。

**S10a 部署：ECS、镜像链路、Compose、TLS**
- 要读：§9.1、§9.2。
- 产出：`deploy/bootstrap-ecs.sh mirror-base-images.sh compose.yml Caddyfile.ip deploy.sh`、`.github/workflows/image.yml`（构建并推 ACR）、`docs/runbook.md` 初版。
- 验收：`deploy.sh` 一条命令完成发布，健康检查失败自动回到上一个镜像（用一个故意坏掉的镜像演示一次）；Caddy 版本锁定，IP 站点**显式配置**公网 ACME 签发方和短期证书 profile，证书状态持久化在数据卷；`curl` 从境外和本机验证证书链为公开受信任；观察到至少一次自动续期成功后才算通过（不通则按 §9.2 切方案 B，并在 PR 写明）。App 端的验证在 S11b，不以 Safari 无警告代替。

**S10b 备份与恢复**
- 要读：§9.4。
- 产出：`deploy/backup.sh restore.sh`、定时任务、备份清单文件格式。
- 验收：备份按 §9.4 的时间表产生并加密上传，OSS 生命周期规则生效；加密口令确认已另存两处（§9.1）；**恢复演练在另一台机器上做**（本机的 Postgres 即可）：只凭 OSS 上的备份和另存的口令恢复，然后逐项比对备份清单：每个商品的库存和货值、每条流水的成本、月报各数字，全部一致（不是只对行数）；恢复后重放删除记录（已注销的店不会复活）；恢复后换 `epoch`，一台带保留 op 的测试手机完成握手并补回备份之后的流水；过程写进 runbook。

**S10c 监控与告警**
- 要读：§9.5。
- 产出：本机定时探测、云监控规则、服务器内的检查任务（备份心跳、证书有效期、营业时间无同步、错误率、快鸟余量）。
- 验收：§9.5 表里的每一项都人为触发一次，Chitu 收到告警；告警内容不含密码、令牌、开通码。

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

**S12 ShopCore：模型与纯逻辑**
- 产出：`Models Money Basket PackConversion Allocation Roles Ops`。
- 验收（`swift test`）：`allocation.json`、`rounddiv.json` 全部向量与服务器结果一致；设计稿 03 的购物篮合计 ¥53.50；扫整箱码换算成 24 个基本单位；`Roles` 从 `permissions.json` 生成能力表，收银员没有进货、看账、商品等能力；每种 op 编码出的 JSON 通过 `ops.schema.json` 校验；金额类型没有任何浮点运算，乘法带溢出检查；超出 §5.0 上限的输入在模型层被拒。

**S13 本地库与 outbox**
- 产出：`ShopCore/LocalDB/*`（§3.4 的表、迁移、各仓库）、前缀匹配和名称搜索、临时库存（服务器基线与本机未确认增减分开存）、恢复队列的存储、演示用种子数据。
- 验收：1,000 个商品时条码查找 < 5 ms（口径见 §14 S13-3）；`prefix.json` 向量通过；**记账的原子性**：在「写流水」和「写 outbox」之间注入崩溃（在注入点拷走库文件含 -wal / -shm 当作断电时的磁盘，另加抛错回滚，§14 S13-4），重启后两者要么都在要么都不在；outbox 在 App 重启后仍在且顺序不变；以收银员形态建库后 `product_private` 为空，并且对库文件做字符串扫描找不到进价数值（测试写入一个特征值来验证）；**清投影不清未确认的 outbox**：有 3 条未确认 op 时切换角色，投影被清空，3 条 op 进入恢复队列且仍绑定原来的店和设备；换成收银员后旧会话已确认的 op 立刻删、未确认的确认后立刻删，压缩中途崩溃或被读事务挡住时重开 / 重试后库文件里仍找不到进价（§14 S13-1）；一个商品有两个单件码时，扫任一个或按名称找，得到同一个卖价。

**S14 扫码层**
- 设计稿：27a、27b。
- 产出：`Scanner/*`、提示音与触感（`.playback` 音频会话，静音开关下也响；没登记过的码用另一种低音）、相机权限三态。
- 验收：单元测试：一串数字 + 回车 = 恰好一次扫码；慢速逐个按键不算扫码；相机同码 1.5 秒内忽略，扫码枪每次扣扳机都算；`FakeScanner` 能由启动参数喂码。相机被拒时显示「没打开相机，扫不了码」+「去打开」，手输条码和扫码枪照常可用（XCUITest 用启动参数模拟被拒）。真机项留到 S29。

**S15 两种首页、首次进入、设置壳**
- 设计稿：01、02、24a、25a、16、16b、21a、21b。
- 产出：`Features/Home Onboarding Settings`、导航骨架（按角色决定有哪些入口）。
- 验收：XCUITest：收银员形态下遍历所有可点元素，**到不了**进货、看账、商品、盘点、快过期、开通；家用形态下都能到；16 默认选中大字，选择保存在本机，重启后保持；标准模式下系统字号调到最大时也封顶在 `accessibility2`（S11 留下的改动，连同单元测试）；小号步进器（46pt 圆钮）的点按区域不小于 56pt；16b 不出现起名；21b 恰好五项；「没同步」和「快过期」两条提醒同时出现时没同步的在上；系统最大辅助字号下首页两个大按钮不被截断；截图与 01、02、16、21a 对照附 PR。

**S16 卖出**
- 设计稿：03、03b、03c、03d、24b、27a。
- 产出：`Features/Sell`。相机条常开、连续扫码、屏幕常亮（`isIdleTimerDisabled`）、手电筒、价签（64pt 小图或首字 + 单价）、购物篮两行式、步进器减到 0 删除、「收好钱了，记账」后显示「记好了 ¥53.00」再清空并停在卖出页。
- 验收：XCUITest：喂三个码后记账 → 本地一笔批次三行，合计正确，outbox 多一条 `sale_batch`；同码扫两次数量为 2；从首页卖一样东西共两次点击；连点两次记账只产生一笔；空篮时记账按钮置灰；商品名很长时换行不截断、金额不出右边距；系统最大辅助字号下总价和记账按钮完整可见。

**S17 抹零与手输条码**
- 设计稿：18、28、15、15b。
- 产出：`Features/Discount ManualCode`（卖出、进货、盘点共用）。
- 验收：¥53.50 抹到 ¥53 → 三行实收 24.76 / 23.78 / 4.46；低于七折（53 输成 5）弹 28「输错了，重填 / 没错，就收 ¥5.00」，多收弹同一面板的另一套文案；「不抹了」恢复原价；购物篮全是零价商品时改价按钮不可用；手输条码前缀命中两个时列出两个且主按钮灰，点一行后可加入；按名称找用系统键盘，结果行在收银员形态下没有库存字样。

**S18 新商品登记与整件码**
- 设计稿：04a、04b、04c、05、25e。
- 产出：`Features/NewProduct LinkPack`、查名称客户端（协议 + 桩实现，真实网络在 S21 接）。
- 验收：卖出中扫到新码 → 04a，填卖价后「存好，接着卖」回到卖出且该商品已在篮里；「再填进价和库存」进 04b，填了库存没填进价出现黄字提醒；打开「要管保质期」才出现到期日和提前天数，「不知道，先不填」可用；04a 的「这是整箱、整条的码」进 05，关联后扫该码按 24 个算；收银员形态只有 04c，存好后提示「已记下，回头让家里人补全」，产生的是 `quick` 的 `product_upsert`；断网时（25e）名称为空也能登记并卖出；从卖出进来两步都是红色标题栏，从进货进来都是蓝色。

**S19 进货**
- 设计稿：06a、06b、06c。
- 产出：`Features/StockIn`。
- 说明：本段只验收手机自己能确定的东西：数量换算、入账总价、这批的单位成本、临时库存。蓝卡第三行「加上原来的，平均进价」是**仅供显示的预计值**（本地基线货值 + 这批总价，除以新数量；进价未知或库存不为正时不显示这一行），不写入任何流水；权威的平均进价由服务器算，在 S22a 和 S28 对账。
- 验收：可乐整箱码，5 箱 × ¥48 → 蓝卡显示「一共 ¥240.00 / 入账 120 罐，每罐 ¥2.00」，标签随单位变（每箱 / 每条 / 每瓶）；5 条 × ¥400、原有 6 包 → 临时库存 56 包，outbox 里的 `stock_in` 带的是件数和每条单价；管保质期的商品出现到期日区，两种填法可切换，生产日期 2026-11-12 + 6 个月 = 2027-05-12，年月日三格用自家键盘、填满自动跳格（06c），保质期月数记住上次的值；「记进货」始终固定在底部可见；进货中遇到新商品必须走完 04b；数量键盘没有小数点。

**S20 记的账与撤销**
- 设计稿：07a、07b、07c、08。
- 产出：`Features/Records Undo`、首页「刚记的」条接真数据。
- 验收：撤销后临时库存恢复、原流水划线仍可见；撤两次第二次无操作；有优惠的批次在 08 显示「这笔抹了 ¥0.50，撤一样按比例退」和每行摊后金额；「只撤这样」和「整笔都撤销」各一条测试；收银员形态只列本机当天的卖出、没有日期切换、昨天的流水没有撤销按钮；家用形态「更早」列出每天一行（离线时只到本地 35 天）；流水上显示的是手机名，不是人名。

### 阶段 D：联网

**S21 网络层、凭据、登录、扫码登录**
- 设计稿：13、25c、14、27b。
- 产出：`ShopCore/SyncClient/APIClient`（基址来自 xcconfig；Beta 配置的证书处理沿用 S11b 定下的做法）、`Features/Login`、钥匙串里的当前令牌和恢复用旧令牌、`/v1/config` 最低版本检查、「看看演示」入口（`demo_login_enabled` 为假时不显示，默认假）。
- 验收：XCUITest 连本机起的服务器：账号密码登录成功进 16；密码错 5 次显示锁定到几点；登录页没有「注册」字样、没有店名（副标题「小店扫码记账」）、有隐私政策链接、密码可显示；扫码登录解析 `YHZB1:` 码，过期码给出 25d 的提示；杀掉 App 重开仍是登录状态；`min_build` 高于本包时显示「请更新」；开关打开时「看看演示」能进演示小店，关闭时界面上找不到它。（本段**不做**同步，登录后进的是空首页。）

**S22a 同步引擎一：正常同步、首次同步、本地原子提交**
- 设计稿：29、25a。
- 产出：`SyncClient/SyncEngine`（outbox 推送、两条流的分页拉取、`remap` 改写、每个 op 的结果处理、同步状态指示）。
- 验收（XCUITest + 本机服务器）：首次同步显示「194 / 312 样」式进度，**商品拉完即可进首页开卖**，流水在后台继续；断网卖三笔 → 联网 → 服务器上每条流水恰好一条；第二台模拟器 20 秒内看到这笔；**崩溃注入**：在「请求发出后、响应到达前」「响应到达后、本地提交前」「本地提交中途」三处强杀 App，重启后不漏拉、不重复扣临时库存、服务器上不重复记账；服务器已拒绝但响应丢失 → 重试拿到的仍是拒绝，本地把这条标为没记上，临时库存被纠正；`remap` 响应丢失后重试仍得到 `remap`；进货后服务器给出的平均进价与 `cost.json` 一致（5 条 × ¥400、原 6 包货值 ¥242.80 → ¥40.05），手机显示的是服务器的数。

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

**S22c 商品图的后台下载与缓存**
- 产出：图片下载器、磁盘缓存、`Thumb` 组件接真数据。
- 验收：图片在后台低优先级下载，不占同步请求；下载失败或很慢时扫码卖出不受任何影响（注入 10 秒延迟，连扫 50 次无卡顿）；`image_ver` 变化后刷新；没图或开关关闭时显示首字；图片请求的主机是自家服务器；收银员形态同样能看到图。

**S23a 开通与设备管理**
- 设计稿：17a、17b、25d、26。
- 产出：`Features/Pairing`、已登录的手机列表、被退出手机补传的「待确认的账」列表（用 26 号通用确认面板）、通用确认面板接入（让它退出、退出登录）。
- 验收：A 出家人码，B 扫后 20 秒内看到 A 的流水；同一个码第二台扫失败；倒计时到 0 显示「这个码过期了 / 换一个新码」；收银员码未填称呼时「出码」置灰、称呼重名有提示；B 扫收银员码后是 02 首页；「让它退出」先弹确认；待确认的账逐笔「记上 / 不要」，记上后出现在记的账里；退出登录先弹确认并走 S22b 的排空流程。

**S23b 账号与密码、注销**
- 设计稿：23、21a（下级页）。
- 产出：设置里的「账号与密码」下级页、改密码、注销账号。
- 验收：改密码后其他手机不被强制退出，「让其他手机全部退出」可用；注销页「不注销了」是实心主按钮、「确认注销」是描边，需重输密码，页面文字与 §9.4 的真实删除期限一致（在线数据 7 天后删除，备份 35 天内清除）；提交后回到登录页，7 天内登录可撤回；注销申请期间其他手机不能记账；收银员手机上没有这些入口。

**S24 看账**
- 设计稿：09、10。
- 产出：`Features/Reports`（Swift Charts：单色，今天用朱红，其余灰；点柱子显示数值）。
- 验收：对着 S07 的夹具服务器，页面上每个数字与接口一致，对账各行相加等于最后一行；没有优惠时优惠卡不显示；口径小字「赚了 = 卖出 − 进价，损耗和盘点少的另算」；离线时显示「要联网才能看账」而不是空白或旧数；坐标轴字号 ≥ 18pt；截图对照 09、10。

**S25 商品列表、改商品、待确认补全**
- 设计稿：11、22、22b、24c。
- 产出：`Features/Products`、通用确认面板接入（不卖了、删整箱码）。
- 验收：筛选「全部 / 快没货 / 快过期 / 待确认」数量正确；改卖价后，**扫任一单件码、按名称找、另一台离线后再联网的手机**都用新价，整箱码的价不变，旧流水保持原名称原价；平均进价只读；22b：待确认商品可填进价和「货架上现在有几个」，必须联网，遇到 `stale` 时提示账面数变了并重新确认；确认后「待确认」数减一，服务器上记的是 `opening`；「不卖了」单独一行在页面最下面，点了先确认，停用后扫码提示已停用但仍可卖。

**S26 盘点**
- 设计稿：12a、12b。
- 验收：扫码 → 显示账上数 → 填实数或点「没错」→ 下一个；账面 2 填 1 → 服务器记盘亏 1 个；**必须联网**，没网时提示「要联网才能盘点」；提交前先传完本机 outbox；另一台手机在这期间卖了一个 → 出现「账上现在是 N 个，你数的还对吗」并可确认；进度「已数 86 种 / 还有 226 种」按本月已有盘点流水的商品数算；12b 列出没数的，「去数」可直接填；没扫的商品不变；键盘无小数点。

**S27 保质期**
- 设计稿：19、20、20b、01（黄条）。
- 产出：`Features/Expiry`、首页黄条和 09 的「快过期了」接真数据。
- 验收：清单分「已过期 / 快过期 / 过几天再提醒的」；处理面板先问实际数量；已过期的默认突出「下架扔掉」，没过期的默认突出「还在卖，过几天再提醒」；数量减到 0 时突出「卖完了」并把扔掉、退货置灰；有「先不处理」按钮；扔掉后首页黄条数量减一、月报过期损耗增加、「赚了」不变；另一台手机已经处理过同一批 → 提示「这批已经处理过了」并刷新；收银员手机上没有黄条。

**S28 端到端回归与权限扫尾**
- 产出：`UITests/E2E/*`、`docs/test-matrix.md`。
- 验收：一条完整剧本在两个模拟器 + 本机服务器上自动跑通：登录 → 登记商品 → 进货 → 卖出抹零 → 撤一行 → 给收银员开通 → 收银员卖出 → 踢掉收银员 → 月报对账成立，且手机上看到的平均进价、货值与服务器逐分一致；收银员手机：界面遍历到不了任何家用页面，本地库文件里没有进价，记录下来的全部响应里没有成本字段；大字 / 标准 / 最大辅助字号各跑一遍首页和卖出页截图；连续 200 次假扫码无丢失无卡顿（主线程单帧 < 100 ms）；冷启动到可扫码 < 2 秒（模拟器上记录数值即可）。

### 阶段 E：发布

**S29 TestFlight 完整包与真机验收**
- 要读：§9.2。
- 产出：完整功能的 Beta 包、`docs/device-checklist.md`、App 图标（不含烟酒元素）。
- 验收：完整包通过 Beta 审核，家里人用外部测试公开链接装上；真机清单（iPhone 13 和 iPhone 17 各一遍）：相机连扫 20 个店里的条码一次过、静音开关打开时仍有提示音、蓝牙扫码枪 HID 模式、飞行模式下卖出再联网补传、连扫 50 次无漏无卡、强光和弱光各试、开通码两台真机互扫、给收银员开通再踢掉。服务器上放什么数据按 §9.2 的前置条件执行。

**S30 上架材料**
- 要读：§10。
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

- ECS 上只开 22（仅密钥登录，安全组限制来源）、80、443。Postgres 不对外。开 2 GB swap。
- Compose 三个服务：`caddy`（TLS、静态页、反代；**版本锁定**，证书状态放在持久化数据卷）、`api`（Node，内存上限 512 MB）、`postgres`（`shared_buffers=256MB`，数据卷 `/data/pg`）。图片缓存 `/data/img`。
- 配置和密钥在 ECS 的 `/opt/yuanhui/.env`（权限 600）：数据库密码、OSS 密钥（给 RAM 子账号最小权限：只读写两个 bucket）、快鸟 AppCode、审核号密码、备份加密口令。**任何密钥不进仓库、不进 CI 日志。**
- **备份加密口令和 OSS 恢复用的凭据另存两处**：这台 Mac 的钥匙串，以及 Haoqiang 的密码管理器。整台 ECS 丢了也要能解开备份。S10b 验收时确认。
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
- 删除记录：账号注销清除完成后，往 OSS `deletions/` 写一条记录（店 id、时间）。它不在数据库里，不会随备份回滚。`restore.sh` 恢复完任何备份后**必须重放删除记录**，把已注销的店再删一遍，并拒绝这些店的旧令牌和重传。
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
| S04-1 | 本段没实现的 op 类型返回什么 | 过渡做法：`rejected: invalid`，不留档，实现后重发正常处理。S06 合并时删掉这个分支，并加测试「`ops.schema.json` 里每个 type 都有处理函数」 | S04、S06 |
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

待办（S04 只记录，不实现）：收银员拉取的 `removed` 墓碑要按角色过滤。S04 只写 `barcode` 墓碑，没有泄漏；但 `removed.kind` 还允许 `entry / batch / lot`，S05 / S06 里第一个写这些墓碑的段落要在 `sync/projection.ts` 里按角色过滤（收银员只收本机卖出流水和批次头的墓碑，不收 `lot`），并加进收银员裁剪测试。（已由 S05b 提前实现：`cashierRemovedVisible`，原行找不到的 `entry / batch` 墓碑不发给收银员；测试在 `sync.projection.test.ts`。）

S13 的 PR（#9）提了 4 条，裁定如下：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S13-1 | 同一台手机从家用换成收银员，没传完的进货 op 里的进价留在 outbox | 未确认的照 §4.5 保留，不加密、不拦换角色（不丢账优先；钥匙在同一台手机上，加密没有意义）。「收银员手机找不到进价」指投影和已确认的 op：当前会话是收银员时，旧会话的 op 一确认就删，换成收银员时旧会话已确认的 op 立刻删，都不留 14 天；当前会话自己的 op 照旧留 14 天。兑收银员码成功后、第一次拉取前先传一遍恢复队列，传不完不拦。恢复队列在界面上只显示笔数 | §3.4、§4.5、S13、S22b |
| S13-2 | §5.5 正文的去重键还是「商品 + 换算数量」 | 改成「商品 + 换算数量 + 这一件的卖价 + 单位名」，与 S12-2 的购物篮合并键是同一个；前缀匹配、名称搜索、购物篮都用它。Q12 以此为准 | §5.5 |
| S13-3 | 条码查找「< 5 ms」怎么测 | 1,000 商品 / 2,000 条码，预热后 5 轮 × 1,000 次随机查找：每轮中位数 < 5 ms，最好一轮的平均和 p99 < 5 ms；单次最慢值只打印不断言 | S13 |
| S13-4 | 崩溃注入不是真杀进程 | 认可在注入点拷走库文件（含 -wal / -shm）当作断电时的磁盘，加一条注入点抛错的回滚测试。真正强杀 App 的验收在 S22a | S13 |

S05 的 PR（#11）提了 8 条，Fable 审核裁定如下（S05 拆成 S05a / S05b 两个 PR，见 S05-6）：

| # | 疑问 | 裁定 | 改在哪里 |
|---|---|---|---|
| S05-1 | 成本补记归属：S06 产出里有 `costfix.ts`，但进货 / 期初让进价变已知、撤销补记过的卖出都发生在 S05 | 同意放进 S05。纯算法在 `cost.ts`（S05a），S05b 在 `stock_in / opening / void` 里当场写库：`cost_fix` 行、原行的 `cost_fix_entry_id`、撤销时的三条流水。S06 的 `costfix.ts` 只剩 `product_review_complete` 的接入，不许另写一套补记逻辑 | §8 S05、S06 |
| S05-2 | `opening` 的版本校验归谁 | S05b 做 §5.6 第 2、3 条：带 `base_ver` 的比对，不带的只在 `stock_ver = 0` 时接受，否则拒 `stale` 带回最新账面数。因此 S05b 起每次库存变动都要 `stock_ver + 1`，期初要写 `last_count_at`。迟到流水补偿（第 4 条）、`count / product_review_complete` 的校验、批次留 S06：S05b 只把 `expiry_date` 存在流水上，不建 `stock_lots / lot_moves`，S06 接入时把进货、期初、卖出、撤销的批次动作一并补上 | §5.6、§8 S05、S06 |
| S05-3 | 进货 0 件 | 拒 `invalid` 并留档（`b = roundDiv(T, 0)` 无定义）。`ops.schema.json` 不改，服务器在应用时判，`limits.json` 加一组让手机同样拦。卖出行 0 件不拒（不为一行空行丢整笔账），照普通行记 | §5.0、§5.2 进货、`limits.json` |
| S05-4 | 年份 0000；与 S04-14 的关系；累计库存溢出 | 一条规则，分三层：**（一）只看 op 自己的内容就能判定的问题，是 op 的问题**，重发多少次结果都一样，拒 `invalid`，在写库之前判。留不留档只看 `ops` 这一行存不存得下：`occurred_at` 年份 0000 存不下 → 不留档（并入 S04-13 的 `storable`，所有 op 类型都判）；`expiry_date` 年份 0000 的 op 本身存得下 → 当作 payload 格式不对，留档。只按「Postgres 存不存得下」判，不按「合不合理」判：1970 年的 `occurred_at` 照收，不许因为时间离谱丢账。**（二）算出来的结果超出列范围也算可预检查的**：`apply` 用 BigInt 算完新的 `stock_qty / stock_value_fen` 再写库，超出列类型范围（`stock_qty` 是 `integer`，满额进货约 215 次就到）拒 `invalid` 并留档。**（三）过了前两层之后写库时再出现 22xxx，只能是服务器自己错了**：记账类 op 整个请求 500、error 日志，不单个拒收（S04-14 不变）。记账类 op 的 22xxx 兜底永远不产生 `rejected` | §4.4、S04-13、S04-14、§8 S05 |
| S05-5 | 流水墓碑 | 撤销不删行：原行打 `voided_at`、加冲销行，都走正常的 `rev` 下发。S05 不写 `entry / batch` 墓碑。「收银员墓碑按角色过滤」的待办原样留给第一个写这类墓碑的段 | 不用改 |
| S05-6 | S05 拆成 S05a（纯算法）和 S05b（写库与同步接入） | 可以。两个 PR 各自过审，S05 段在 S05b 合并后才算完成，依赖 S05 的段等 S05b。S05b 验收 = 执行者列的四条，再加：① `cost.json` 里只含进货 / 卖出 / 期初 / 撤销的各组经 `/v1/sync` 写库后，`entries` 和 `products` 逐分一致；② 抹零：53.50 收 53.00 经同步入库后各行 24.76 / 23.78 / 4.46，`L = 0` 而 `P ≠ 0` 被拒，I4 成立；③ 进价未知的正库存卖出、明确零成本的卖出，各经同步接口断言一次；④ 撤销：整批和单行两种 target，撤销两次第二次无操作、重放返回第一次结果，冲销行 `occurred_at` 是撤销时间，`paid_total_fen` 不改；⑤ 补记写库：`cost_fix_entry_id`、补记后撤销三条流水、同一条 `cost_fix` 被冲两次以上；⑥ `assertLedger` 加强：每条 `cost_fix` 冲销行对应恰好一笔被它补记且已撤销的卖出，实收和进价是那一行的取反，并跟一条 +数量×b 的 `cost_adjust`（b = 0 除外）；`cost_fix` 含冲销的净额 = 仍有效的被补记卖出的合计；⑦ S05-2、S05-3、S05-4 各有测试，含年份 0000 的两种和 `stock_qty` 溢出；⑧ 被踢设备：卖出直接入账带 `late_from_revoked`，进货 / 期初 / 撤销进 `held`；⑨ 收银员拉到真实流水后，递归断言没有成本键，收不到进货、期初、`cost_adjust`、`cost_fix` 行；⑩ S04-1 的过渡分支只对这四种 op 去掉，其余留到 S06 | §8 S05 |
| S05-7 | 填了进价的 `opening` 行，`unit_cost_fen` 存不存 | 存 b（留档用，和 `cost_fix` 一样；冲销行照抄）。没填进价的存空 | §3.3 |
| S05-8 | `cost.json` 没有 u ≠ c 的盘盈 | 把盘盈金额 `d × u` 写成 `d × c` 现在全部向量都能过。S06 给 `cost.json` 加一组（例如库存 6、货值 24280、c = 4000，盘点数到 8 → 盘盈 2 × 4047），服务器和手机都要过 | `cost.json`、§8 S06 |
