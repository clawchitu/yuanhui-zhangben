# App 审核信息（Review Notes）草稿（S30）

填在 ASC →「App 审核信息」（App Review Information）。

- **登录信息**：用户名 `<审核号>`、密码 `<密码>`。真值在 ECS `/opt/yuanhui/.env`（审核号密码）和建演示店时的记录里，**不写进仓库**；提审时由负责人直接填进 ASC。审核号登录后进的是「演示小店」（假数据，每天北京时间 16:00 自动恢复，见 plan-v2 §8 S09）。
- **联系人**：姓名、电话、邮箱填负责人的（【待填】），要能在审核期间接电话。
- **备注**：下面英文版直接粘贴到「备注」（Notes）里；中文版是对照，审核员如果是中文团队也看得懂。ASC 备注限 4000 字符，英文版 3274 字符（11/27 用 len() 数），两版一起贴会超，**只贴英文版**；中文版留作对照和回复审核时用。
- **附件**：§10 要求的真机录屏（扫码卖出、抹零、扫码枪、离线记账后补传、给家人开通的扫码登录、收银员界面）作为附件上传。

提审前要确认的（见 README）：
1. 服务器上 `demo_login_enabled` **已经打开**（11/26 21:30 负责人定：从第一次提审起就开「看看演示」，不等被打回再开——审核后再翻服务器开关，有被认为是 2.3.1 隐藏功能的风险）。
2. 下面写到的页面名称和按钮名称和提审的包一致（本稿按 11/27 的 `main` 对照 `ios/App/Features/**` 写）。
3. `https://yuanhuishop.cn/review-barcodes` 已上线、能打开。
4. 关于「今天」页可能是空的那一句，取决于 §14 T15 的处理结果：如果把演示店重置改到北京时间 0 点后、「今天」全天有数，删掉那一句。

---

## 英文版（粘贴用）

```
WHAT THIS APP IS
Yuanhui Zhangben (元辉账本) is an in-house inventory and bookkeeping tool for ONE small family-run store in Jiangyin, Jiangsu, China. Family members use it on their own phones to record sales, stock-in, voids and to view simple reports. It does NOT take or process any payment; it only records what was sold.

WHY THERE IS NO SIGN-UP
Accounts are created by the store, so the app has no registration screen. Family members join by scanning a one-time QR code shown on a phone that is already signed in. A cashier phone is a restricted device of the same account (it can only sell, round off a total, and void its own sales of the day); the cashier interface is a subset of the full (family) interface.

DISTRIBUTION: UNLISTED
We intend to distribute this app as an UNLISTED app (via a direct link sent to the store's family members only). After submitting this build we will submit the Unlisted App Distribution request.

DEMO ACCOUNT
User name: <审核号>
Password: <密码>
This account opens "演示小店" (Demo Store), which contains only sample data (drinks, snacks, daily goods). It is reset automatically every day. The sign-in screen also has "看看演示" (Try the demo), which opens the same demo store without a password.
No second device is needed.

BARCODES FOR TESTING
https://yuanhuishop.cn/review-barcodes
Point the phone camera at the computer screen, or type the digits instead (see below).

HOW TO TEST WITHOUT A SECOND PHONE
1. Sign in: enter the user name and password on the sign-in screen, tap "登录" (Sign in). On first sign-in choose a text size and tap "好了，开始用" (Start).
2. Sell: on the home screen tap "卖出" (Sell). Scan a code from the barcode page, or tap "手输条码" (Enter barcode) under the viewfinder and type e.g. 2100000000012, or switch to "按名称找" (Search by name) and type 可乐. Tap "抹零 / 改总价" to round off the total, then "收好钱了，记账" (Record sale).
3. New product: scan or type one of the six codes in the first section of the barcode page (e.g. 2000000000015). The app looks up the name and opens the new-product form; enter a price and save.
4. Stock in: home screen "进货" (Stock in). Scan or type a code, enter quantity and cost, tap "确认入库" (Confirm).
5. Void: home screen "记错了" (Made a mistake) shows today's records; tap "撤销" (Void) to void a whole sale or one line.
6. Reports: home screen "看账" (Reports): today, this month, profit, stock value, low stock, expiring soon. Reports need a network connection. Dates are in Beijing time (UTC+8); if "今天" (Today) is empty at your local time, record one sale or look at the previous days / this month.
7. Delete account: "更多" (More) → "账号与密码" (Account & password) → "注销账号" (Delete account), re-enter the password to confirm. The request can be withdrawn within 7 days; the demo store is restored the next day.
8. Privacy policy: link at the bottom of the sign-in screen and in "更多" (More). Also https://yuanhuishop.cn/privacy

CAMERA
The camera is used to scan product barcodes and sign-in QR codes; frames are not saved. A photo is uploaded only if the user chooses to take one as a product image (not available in the demo store). If camera access is denied, barcodes can still be typed or scanned with a Bluetooth scanner.

The app contains no third-party SDKs, no ads, no tracking and no in-app purchases.
```

## 中文版（对照）

```
这是什么
元辉账本是江苏江阴一家家庭经营的小店自用的进销存记账工具。家里人用各自的手机记卖出、进货、撤销，看简单的报表。App 不收款、不涉及任何支付，只记账。

为什么没有注册
账号由门店开通，所以 App 没有注册页。家里人在已登录的手机上出一个一次性二维码，扫了就登录。收银员手机是同一账号下受限的设备（只能卖出、抹零、撤销本机当天的卖出），收银员界面是家用界面的子集。

分发方式：Unlisted
我们打算以 Unlisted（不公开）方式分发，只把链接发给店里的家人。提交这一版审核后，我们会提交 Unlisted 分发申请。

演示账号
用户名：<审核号>
密码：<密码>
登录后是「演示小店」，只有假数据（饮料、零食、日用品），每天自动恢复。登录页还有「看看演示」，不用密码进同一家演示店。
不需要第二台手机。

测试用条码
https://yuanhuishop.cn/review-barcodes
手机摄像头对着电脑屏幕扫，或者照下面的办法手输。

不用第二台手机怎么走一遍
1. 登录：登录页输入用户名和密码，点「登录」。第一次登录选字号，点「好了，开始用」。
2. 卖出：首页点「卖出」。扫条码页上的码，或者点取景框下面的「手输条码」输入（如 2100000000012），或切到「按名称找」输入「可乐」。点「抹零 / 改总价」抹零，再点「收好钱了，记账」。
3. 登记新商品：扫或输入条码页第一部分的 6 个码之一（如 2000000000015），App 查出名称并打开登记页，填售价存好。
4. 进货：首页点「进货」，扫或输入条码，填数量和进价，点「确认入库」。
5. 撤销：首页点「记错了」看今天记的账，点「撤销」，可撤整笔或其中一样。
6. 看账：首页点「看账」：今天、本月、赚了、店里货值、快没货、快过期。看账要联网。日期按北京时间（UTC+8）；如果你那里看「今天」是空的，先卖一笔，或看前几天和本月。
7. 注销：「更多 → 账号与密码 → 注销账号」，再输一次密码确认。7 天内可以撤回；演示店第二天自动恢复。
8. 隐私政策：登录页底部和「更多」里都有入口，也可以打开 https://yuanhuishop.cn/privacy

相机
相机用来扫商品条码和登录二维码，画面不保存。只有用户主动给商品拍照当商品图时才上传那一张（演示小店里不能拍照换图）。不给相机权限，也可以手输条码或用蓝牙扫码枪。

App 里没有第三方 SDK、没有广告、不追踪、没有 App 内购买。
```

## 写这份时对照过、需要提审前再确认的地方

- 页面和按钮名：「登录」「好了，开始用」「卖出」「手输条码」「按名称找」「抹零 / 改总价」「收好钱了，记账」「进货」「确认入库」「记错了」「撤销」「看账」「更多」「账号与密码」「注销账号」都取自 `ios/App/Features/**` 里的字符串（11/27 `main`）。
- 「看看演示」只有 `demo_login_enabled` 打开时才显示（`ios/App/Features/Login/LoginView.swift`）。
- 「更多」里的「隐私政策」：11/27 的 `main` 上它还是「这一页还在做（S21）」的占位页（`Route.plannedIn` 里 `.privacy: "S21"`），登录页底部的链接才是真打开网页的。**提审前要把设置里的入口改成打开 `privacy_url`**（§10「登录页和设置里都有入口」），否则第 8 条要改成只写登录页。这一项不在本 PR 里改 iOS 代码。
- 「商品」（S25）、「盘点」（S26）同样还是占位页；Review Notes 没提它们。提审时如果还没做完，审核员点进去会看到「这一页还在做」，有 2.1（App 完整性）被打回的风险，提审前必须做完或从界面上拿掉。
- 第 3 步「查出名称」：演示店查码不调付费接口，用服务器内置的 6 个码（`server/src/lookup/catalog.ts` 的 `DEMO_CATALOG`），查出的名字是「演示可乐」之类。
- 第 7 步：演示店的注销申请由每日重置撤回（S09），审核号第二天照常能用。
