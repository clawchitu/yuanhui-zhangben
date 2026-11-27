# docs/appstore：上架材料（S30）

分发方式：**Unlisted**（不公开、凭链接下载），强哥 2026-11-27 定。「看看演示」从第一次提审起就开，负责人 2026-11-26 21:30 定。被打回时怎么办见 plan-v2 §8 S32。

## 目录

| 文件 | 用途 |
|---|---|
| `listing.md` | 商品页字段：App 名、副标题、推广文本、描述、关键词、支持 / 隐私 URL、分类、年龄分级问卷、价格、销售范围、版权、备案号填哪里。每个字段注明字数限制和实际字数 |
| `review-notes.md` | 「App 审核信息」的备注，英文版（粘贴用）+ 中文版（对照）：门店自用、没有注册、不涉及支付、收银员是子集、打算走 Unlisted、审核号、条码页、不用第二台手机怎么走一遍 |
| `privacy-labels.md` | 「App 隐私」问卷逐项答案（和 `deploy/site/privacy.html` 一致）；加密出口合规 `ITSAppUsesNonExemptEncryption` 和 `PrivacyInfo.xcprivacy` 的现状与待办 |
| `unlisted-request.md` | 苹果 Unlisted App Distribution 申请表的草稿（英文版可直接粘贴，另附中文对照），以及 11/27 核对的苹果官方流程 |

相关的静态页在 `deploy/site/`：`privacy.html`（隐私政策）、`support.html`（使用帮助）、`review-barcodes.html`（审核用条码，由 `scripts/gen-review-barcodes.py` 生成，`deploy/test/deploy.test.sh` 核对页面和脚本输出一致）。Caddy 对 `/privacy`、`/support`、`/review-barcodes` 带不带 `.html` 都给页面。

## 上架前还要人来做的事

按大致先后：

1. **填隐私政策和支持页上的联系方式**：`deploy/site/privacy.html`、`support.html` 里电话、邮箱现在是【待填】。填好再发布（发布走 `deploy/deploy.sh`，改页面不用重载 Caddy）。
2. **发布静态页**，确认 `https://yuanhuishop.cn/privacy`、`/support`、`/review-barcodes` 都能打开；用一台装了 App 的手机对着电脑屏幕把条码页上的码扫一遍（S30 验收「条码图页用屏幕对屏幕能被 App 扫出来」；本 PR 只用 macOS Vision 对渲染出的图片解码核对过 15 个码，没有用 App 真扫过）。
3. **演示店「今天」**：按 plan-v2 §14 T15 的「S30 评估（11/27）」决定是否挪重置时间并改种子日期。不改的话，美西白天审核员看到的「看账 → 今天」是空的（Review Notes 里已经提示）；改了就删掉 Review Notes 里那一句。
4. **iOS 侧待办（本 PR 不改 iOS 代码）**：
   - `ios/project.yml` 加 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption: NO`（现在没设）。
   - 加 `PrivacyInfo.xcprivacy`（现在仓库里没有；要声明的项见 `privacy-labels.md`）。
   - 「更多 → 隐私政策」现在是「这一页还在做（S21）」的占位页，要改成打开服务器下发的 `privacy_url`（§10 要求登录页和设置里都有入口）。
   - 「商品」（S25）、「盘点」（S26）提审时必须已经做完，否则审核员点到占位页有 2.1 被拒的风险。
   - 相机权限说明现在是「扫商品条码、扫登录码、给商品拍照要用相机」，§10 写的是「用来扫商品条码和登录二维码，不保存照片」。S22d 加了拍照换商品图，照片会上传，所以「不保存照片」不能照抄；隐私政策已按实际写（扫码画面不保存，主动拍的商品图会上传）。
5. **服务器**：提审前打开 `demo_login_enabled`（11/26 定），审核期间不改（S32 ①）；提审期间服务器不维护（§10）。
6. **ASC**：按 `listing.md` 填；版权行选 A 还是 B（`listing.md` 第 10 节）由负责人定；App 备案号填 `苏ICP备2026094233号-2A`（不是网站的 `-1`）；版本发布方式选**手动发布**。
7. **审核信息**：审核号用户名和密码、联系人电话邮箱直接填进 ASC，不进仓库；上传 §10 要求的真机录屏。
8. **截图**：S30 的 `make store-shots`（不在本目录），6.9 寸和 6.5 寸各一套，逐张人工看没有烟、酒、「烟酒店」字样和真实包装图。
9. **提审之后**马上提交 Unlisted 申请（`unlisted-request.md`；苹果要求先提审才能申请）。申请表要用开发者账号登录才看得到，本稿没看到表上的字段，填之前按实际字段对号入座。预计用户数等【待负责人确认】的项先确认。
10. **两件事都有了再发布**：App Review 通过 + 苹果批准 Unlisted（ASC「价格与销售范围」里分发方式变成 Unlisted App、拿到链接）。然后手动发布，把链接发给家里人，TestFlight 版本下线（S32）。

## 图标（S29 / §10「图标不含烟酒元素」）

11/27 看过 `ios/App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png`：朱红底，中间一张黄色价签（左上角有个穿绳孔），价签上一个黑色「元」字。没有烟、酒元素，没有文字以外的商品图案。1024×1024，没有 alpha 通道（ASC 要求）。
