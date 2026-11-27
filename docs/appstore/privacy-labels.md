# App 隐私标签（App Privacy）问卷答案（S30）

填在 ASC →「App 隐私」（App Privacy）。和 `deploy/site/privacy.html` 一一对应：政策里写了收集的，这里都申报；政策里写了不收集的，这里都选「未收集」。依据：plan-v2 §10「隐私与账号」、§3.1 的 `accounts` / `devices` 表、`ios/App/Features/NewProduct/PhotoCapture.swift`（拍照 / 相册上传商品图）、`server/src/lookup/`（只把条码发给快鸟）。

## 第一问：是否收集数据

**是**，收集（App 要登录、要把账同步到我们自己的服务器）。

苹果的「收集」指数据离开手机、被我们（或合作方）保存超过实时处理一次请求所需的时间。下面每一项都会同步到服务器保存，所以都算收集。

## 第二问：数据类型（逐项）

所有已申报项的三个后续问题答案相同，放在表后。

| 苹果的类别 → 数据类型 | 收集？ | 对应我们的什么 |
|---|---|---|
| 联系信息 → 姓名 | 否 | 不收姓名。（「这台手机的名字」是设备名，见下面「其他用户内容」） |
| 联系信息 → 电子邮件地址 / 电话号码 / 实际地址 / 其他联系信息 | 否 | 没有任何联系方式字段，没有短信 |
| 健康与健身 | 否 | |
| 财务信息 → 支付信息 / 信用信息 | 否 | 不涉及支付 |
| 财务信息 → 其他财务信息 | **是** | 店铺经营数据里的售价、进价、实收、货值、利润报表（门店的经营流水，不是个人财务；按苹果的定义「其他财务信息」最接近，从严申报） |
| 位置 → 精确位置 / 粗略位置 | 否 | 不申请定位权限；上传的商品照片在手机上去掉 EXIF / GPS |
| 敏感信息 | 否 | |
| 通讯录 | 否 | |
| 用户内容 → 电子邮件或短信 | 否 | |
| 用户内容 → 照片或视频 | **是** | 家用手机给商品「拍一张」「从相册选」的那一张商品图（压缩后上传，存 OSS）。扫码画面不保存、不上传 |
| 用户内容 → 音频数据 / 游戏玩法内容 / 客户支持 | 否 | |
| 用户内容 → 其他用户内容 | **是** | 店铺经营数据：商品名称、条码、库存、保质期、卖出 / 进货 / 撤销 / 盘点记录；「这台手机的名字」、收银员称呼 |
| 浏览历史 / 搜索历史 | 否 | 「按名称找」只在手机本地库里搜，不上传 |
| 标识符 → 用户 ID | **是** | 门店开通的用户名、服务器上的账号 id 和店铺 id |
| 标识符 → 设备 ID | **是** | 每次登录 App 随机生成的设备编号（`devices.id`）。不是 IDFA，也不读 IDFV；从严申报 |
| 购买项目 | 否 | 没有 App 内购买；「卖出」是门店卖给顾客的记录，归在上面的「其他用户内容」/「其他财务信息」 |
| 使用数据 → 产品交互 / 广告数据 / 其他使用数据 | 否 | 没有统计分析。服务器记的「最近一次联网时间」「App 版本号」只用于「已登录的手机」列表和强制升级，归在设备 ID 这条下面一起说明 |
| 诊断 → 崩溃数据 / 性能数据 / 其他诊断数据 | 否 | 没有崩溃收集 SDK，App 不上传日志 |
| 周围环境 / 身体 | 否 | |
| 其他数据类型 | 否 | |

**每个已申报项（其他财务信息、照片或视频、其他用户内容、用户 ID、设备 ID）的后续问题：**

| 问题 | 答案 |
|---|---|
| 用途 | 只勾 **App 功能**（App Functionality）。不勾第三方广告、开发者的广告或营销、分析、产品个性化、其他用途 |
| 是否与用户身份关联（Linked to the user） | **是**。都挂在门店账号下 |
| 是否用于追踪（Tracking） | **否** |

## 第三问：追踪

**不追踪。** 没有广告、没有第三方 SDK、不和其他公司的数据合并、不请求 ATT（App Tracking Transparency）授权，所以 Info.plist 里也不需要 `NSUserTrackingUsageDescription`。

## 没申报、但要知道的

- **服务器访问日志里的 IP 地址**：Caddy 和 api 的日志带客户端 IP，用于安全（登录限速、排查）。苹果的数据类型里没有单列 IP；它只用于安全和运维、不用来定位，日志按容量滚动覆盖（20 MB × 5，`deploy/compose.yml`）。隐私政策第二节已写明。如果审核追问，按「用于 App 功能（安全），不追踪，不用于定位」回答。
- **条码发给快鸟**：登记新商品时由**服务器**把条码数字发给阿里云云市场的条码查询服务，不含账号和经营数据，App 里没有它的 SDK。不属于「与第三方共享用户数据」。
- **审核号 / 演示小店**：数据是假的，申报口径不变。

## 和隐私政策的对照

| 隐私政策（privacy.html）第二节 | 这里 |
|---|---|
| 账号信息 | 用户 ID |
| 店铺经营数据 | 其他用户内容 + 其他财务信息 |
| 设备信息 | 设备 ID（+ 设备名归其他用户内容） |
| 商品图 | 照片或视频 |
| 访问日志 | 不单独申报，见上 |

---

## 加密出口合规：`ITSAppUsesNonExemptEncryption`

- **现状（11/27 `main`）：没有设。** `ios/project.yml` 用 `GENERATE_INFOPLIST_FILE: YES` 生成 Info.plist，`INFOPLIST_KEY_*` 里没有 `ITSAppUsesNonExemptEncryption`；`ios/Config/{Debug,Beta,Release}.xcconfig` 里也没有。仓库里没有手写的 Info.plist。
- **应该是 `NO`**（§10「加密出口合规」）：App 只用系统的 HTTPS（`URLSession`）和系统钥匙串，没有自己实现或引入加密算法。苹果的豁免说明里，只用操作系统提供的加密、用于 HTTPS 通信的，属于可豁免的范畴，不需要上传出口合规文件。GRDB 是 SQLite 封装，没有开 SQLCipher。
- **待办（不在本 PR 改 iOS 代码）**：在 `ios/project.yml` 的 `YuanhuiZhangben` target `settings.base` 加一行 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`。不加的话，每次上传构建版本 ASC 都会在 TestFlight / 提审前问一遍「是否使用加密」，手动答「否」也能过，但容易漏。
- **中国大陆区**：只上中国大陆时，ASC 可能还会就加密问「是否符合法国 / 中国的加密要求」之类的补充问题；答案同上（只用系统 HTTPS，不使用专有加密）。以 ASC 当时的问题为准。

## `PrivacyInfo.xcprivacy`

- **现状（11/27 `main`）：仓库里没有**（`find . -name PrivacyInfo.xcprivacy` 为空）。S30 的产出里有它，由主代理补。
- 补的时候要声明的（按本仓库代码 grep 的结果，补之前再查一遍）：
  - `NSPrivacyAccessedAPICategoryUserDefaults`，原因 `CA92.1`（只读写本 App 自己的 UserDefaults：字号、服务器地址等，`ios/App/Net/AppServices.swift`、`APIEnvironment.swift`、`AppModel.swift`、`StockInModel.swift`）。
  - 没查到 `systemUptime`、`mach_absolute_time`、文件时间戳（`creationDate` / `modificationDate` / `attributesOfItem`）、磁盘空间、`activeInputModes` 的直接调用；`ContinuousClock` 不在苹果的「需要说明原因的 API」清单里。
  - `NSPrivacyTracking` = `false`，`NSPrivacyTrackingDomains` 为空。
  - `NSPrivacyCollectedDataTypes` 和上面的标签一致（用户 ID、设备 ID、照片或视频、其他用户内容、其他财务信息；都 Linked、不 Tracking、用途 App Functionality）。
  - 依赖 GRDB 7.9.0（`ios/ShopCore/Package.swift`），GRDB 自带自己的隐私清单，不用在 App 的清单里重复写它的项；归档后用 Xcode 的「Generate Privacy Report」核对合并结果。
