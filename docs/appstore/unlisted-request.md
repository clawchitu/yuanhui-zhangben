# Unlisted App Distribution 申请草稿（S30）

**已定**：元辉账本用苹果的 Unlisted App Distribution（不公开上架、凭链接下载）。负责人强哥 2026-11-27 定。

## 一、苹果的流程（2026-11-27 北京时间核对）

来源：<https://developer.apple.com/support/unlisted-app-distribution/>（公开页，页面上没有「最后更新」日期，只有页脚 Copyright © 2026 Apple Inc.）。申请表 <https://developer.apple.com/contact/request/unlisted-app/> 要用 Apple ID 登录才能看，**这次没有登录，表上的字段没看到**。

页面原文要点（引号里是原文）：

1. **先提审，再申请。** "Before you request unlisted app distribution, your app must either already be on the App Store or be ready for final distribution and submitted to App Review." 没提交审核、或者只是 beta / 预发布状态的，申请会被拒："Requests will be declined for unlisted distribution if your app hasn't been submitted to App Review, or if your app is in a beta or prerelease state." TestFlight 不算。
2. **Review Notes 里写明意图**："Add a note in the Review Notes section of your submission to indicate that your app is intended for unlisted distribution. Then, submit a request for unlisted app distribution."
3. **批准之后**："you can continue with the usual app release process. Your app's distribution method will change to Unlisted App in the Pricing and Availability section of the app record, and will apply to any future versions of the app. A link will be generated to access your app on the App Store and on Apple Business or Apple School Manager." 分发方式由苹果批准后改，不是自己在 ASC 里选；以后的版本都沿用。
4. **谁都能用链接下载**："Unlisted apps are available to anyone who has access to the link. Consider implementing a mechanism within your app to prevent unauthorized use." 我们的 App 本来就要门店开通的账号才能登录，满足这一条。
5. 适合的例子（原文）："Apps for partner sales tools, employee resources, or research studies are examples of good candidates"；面向 "Limited audiences (such as part-time employees, franchisees, partners, business affiliates, …)"，可用于 "Employee-owned devices"、"Managed and unmanaged devices"、"All regions that are supported by the App Store"。页面没有列不适合的例子。
6. 页面没写审批要多久、链接怎么通知（只说 "A link will be generated"）。

### 和 11/27 记录里的说法对不上的地方

记录里写的顺序是「**先交 Unlisted 申请**（写明用户 = 黄总一家店、为何不适合公开），仍走完整审核，审核号带预置数据，备案号已有」。按苹果官方页面：

- **「先交申请」做不到**：申请必须在这一版**已经提交审核之后**才能交（或者 App 已经在 App Store 上）；在提审之前交会被拒。能做到的是：提审时就在 Review Notes 里写明打算走 Unlisted，**提交审核后马上**交申请，不用等审核通过（页面没要求等通过）。
- 「仍走完整审核」：对，Unlisted 的 App 照常过 App Review。
- 「审核号带预置数据」「备案号已有」：页面没提，但这是 App Review 和中国大陆上架本身的要求，照做。

### 所以实际的顺序

1. ASC 填好全部信息（`listing.md`、`privacy-labels.md`、`review-notes.md`），版本发布方式选 **「手动发布此版本」（Manually release this version）**。这一条很重要：如果选了自动发布，审核一通过、Unlisted 还没批下来，App 就会**公开**上架、能被搜到。
2. 提交审核。Review Notes 里写明 "We intend to distribute this app as an UNLISTED app"（`review-notes.md` 英文版已写）。
3. 提交审核后马上用开发者账号（Haoqiang 的个人账号）登录，打开申请表，按下面「三、英文版」填写提交。
4. 等两件事都完成：App Review 通过 + 苹果批准 Unlisted。批准后 ASC「价格与销售范围」里分发方式变成「Unlisted App」，同时生成链接。
5. 两件事都完成后再手动发布，把链接发给家里人。
6. 审核通过了但 Unlisted 被拒、或迟迟没回复：**先不发布**（版本停在「等待开发者发布」），处理办法见 plan-v2 §8 S32「被打回时的顺序」。

时间：苹果没写审批时长。按计划预留一到两周（§10）。

## 二、要准备的信息

| 项目 | 值 |
|---|---|
| App 名称 | 元辉账本（Yuanhui Zhangben） |
| Bundle ID | `cn.yuanhuishop.zhangben` |
| Apple ID（ASC 里这个 App 的数字 ID，「App 信息 → 通用信息 → Apple ID」） | `<Apple ID：建好 App 记录后从 ASC 抄>` |
| 开发者账号 | Haoqiang 的个人开发者账号，Team `C29GS8XSA6` |
| 使用的门店 | 江阴市周庄元辉烟酒店（个体户，江苏省江阴市周庄镇），黄总一家经营 |
| 用户 | 黄总家里人的手机（家用号）和店里收银的手机（收银员），只有这一家店 |
| 预计用户数 / 设备数 | **【待负责人确认】**，按 plan-v2 的设想是家里几台手机加一两台收银手机，十台以内 |
| 分发方式 | 把 App Store 链接直接发给家里人（微信等私下发送），不在任何地方公开宣传 |
| 地区 | 只上中国大陆 |
| 不公开的理由 | 只给这一家店用；账号由店里开通、没有注册，公众下载了也登录不了；App 里是这家店内部的经营数据（进价、利润、库存） |

## 三、英文版（直接粘贴用）

申请表的字段没有看到（要登录）。下面按「这类申请一般会问的问题」分段写，每段都能单独粘贴。**登录后按表上的实际字段对号入座**；如果表上只有一个大文本框，就把「Full description」那一段整段贴进去。

**App name**

```
元辉账本 (Yuanhui Zhangben)
```

**Apple ID / Bundle ID**

```
Apple ID: <Apple ID>
Bundle ID: cn.yuanhuishop.zhangben
```

**Who is the app for (intended audience)**

```
One small family-run convenience store in Jiangyin, Jiangsu, China (registered business: 江阴市周庄元辉烟酒店, a sole proprietorship). The only users are the store owner's family members and the store's cashier, on their own iPhones.
```

**Why it is not suited for public distribution**

```
The app is the store's internal bookkeeping tool: it records the store's own sales, purchases, stock and profit. Accounts are created by the store; there is no sign-up, so members of the public who download it cannot use it. The data inside is the store's private business information (purchase costs, margins, inventory). Listing it publicly on the App Store would only show strangers a sign-in screen they cannot get past.
```

**How the app will be distributed**

```
We will send the App Store link directly to the store owner's family members and cashier (privately, e.g. by message). It will not be promoted or published anywhere. Distribution region: China mainland only.
```

**Estimated number of users**

```
Fewer than 10 devices (family members' phones plus one or two cashier phones), all belonging to one store.
```
（数字以负责人确认的为准。）

**Full description（表上只有一个文本框时用这一段）**

```
Yuanhui Zhangben (元辉账本), Bundle ID cn.yuanhuishop.zhangben, Apple ID <Apple ID>, is an in-house bookkeeping and inventory app for one small family-run convenience store in Jiangyin, Jiangsu, China (registered business: 江阴市周庄元辉烟酒店, a sole proprietorship). The only users are the owner's family members and the store's cashier, on fewer than 10 iPhones.

It is not suited for public distribution: accounts are created by the store and there is no sign-up, so the public cannot use the app, and it contains the store's private business data (sales, purchase costs, margins, stock). It does not process payments.

We will send the App Store link directly and privately to the family members and the cashier; it will not be promoted anywhere. Region: China mainland only.

The version has been submitted to App Review with a demo account and sample data, and the Review Notes state that we intend to distribute it as an unlisted app.
```

## 四、中文版（对照，不用粘贴）

**这个 App 给谁用**：江苏江阴一家家庭经营的小店（登记名称：江阴市周庄元辉烟酒店，个体户）。用户只有店主一家人和店里的收银员，用各自的 iPhone。

**为什么不适合公开上架**：这是店里内部的记账工具，记的是这家店自己的卖出、进货、库存和利润。账号由店里开通、没有注册，公众下载了也用不了；里面是这家店的内部经营数据（进价、毛利、库存）。公开上架只会让陌生人看到一个登不进去的登录页。

**怎么分发**：把 App Store 链接私下直接发给店主家里人和收银员，不在任何地方宣传。只上中国大陆。

**预计用户数**：十台以内（家里人的手机加一两台收银手机），都属于这一家店。【待负责人确认】

**整段**：元辉账本（Bundle ID cn.yuanhuishop.zhangben，Apple ID <Apple ID>）是江苏江阴一家家庭经营小店（江阴市周庄元辉烟酒店，个体户）自用的记账和库存 App，用户只有店主家里人和收银员，十台以内的 iPhone。它不适合公开分发：账号由店里开通、没有注册，公众用不了；里面是店里的内部经营数据；不处理任何付款。我们会把链接私下直接发给家里人和收银员，不做任何宣传，只上中国大陆。这一版已经带着演示账号和假数据提交审核，Review Notes 里写明了打算以 Unlisted 方式分发。

## 五、措辞说明

- 英文里说 "a small family-run convenience store"：店里卖食品、日用百货，也卖烟酒（见 `deploy/site/index.html`），"convenience store" 是真实的概括，没有隐瞒什么。登记名称照实写了中文全称（含「烟酒店」），因为苹果可能拿它和开发者信息、备案信息核对，不能换名字。App 本身、演示数据和截图里都不出现烟酒（§10）。
- 不要写 "employees"：用户是店主家里人，不是雇员；收银员写 "the store's cashier"。
- 开发者账号是 Haoqiang 个人，门店是另一个主体。表上如果问开发者和使用方的关系，照实写 "The developer builds and maintains the app for the store at the owner's request"；被要求证明授权时再补授权书（plan-v2 §12）。
