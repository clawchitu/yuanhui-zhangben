# 元辉账本 开发规则（给执行代理）

先读 `docs/plan-v2.md` 开头的「执行者须知」和你这一段在 §8 里的内容；只读本段「要读」列出的章节和设计稿，不要通读全部设计稿。

计划 11/21 精简过：开头的「11/21 精简说明」和「最小可用上线路径」优先于下文；各段开头标「11/21 精简」的那一行优先于该段原文。

## 只做验收列出的项（11/21）

- 只做本段验收列出的项。不顺手加固，不新增契约字段，不扩大范围；想到的别的问题在 PR 描述里记一行。
- 疑问最多提三条，其余按最简单的做法自己定，并在 PR 里写明。
- 界面与设计稿「大体一致」即可（布局、主要文字、主按钮对得上），不逐像素比。

## 提交与合并

- **所有改动都走 PR，不许直接推 `main`。** 分支名 `sNN-简述`，一段一个 PR，squash 合并。
- PR 用仓库模板，四栏都要填：对应段号、验收清单（逐条附证据）、Codex 审核、Fable 审核。
- **审核（11/21 起，细则见计划 §2.1）**：评审由 Chitu 触发，结论以 PR 评论留下，评论以「Codex 审核：通过」/「Fable 审核：通过」开头。有新提交后旧的通过作废，要重审。
  - 纯界面段和部署段只要 **Fable 一方**审核；金额与同步段（**S19、S20、S22a、S26**）要 Codex 和 Fable 都通过。
  - **必须改只有四类**：算错钱或库存、丢数据、扫不出、卡死或崩溃。其余（包括越权、店铺隔离）记一行待办，不拦合并。
  - **每段最多两轮**：第二轮只核对第一轮的必须改项，不提新问题；分歧由 Chitu 当场裁定。
  - 计划 §14 不再逐 PR 写裁定表，新待办只在 T 表记一行。
- **合并只用 `scripts/merge-pr.sh <PR号>`**，不要用 `gh pr merge` 或网页按钮。这个脚本检查两条 CI 和两条审核评论，缺一样就拒绝（一方审核的段，在脚本改好之前由 Chitu 处理合并，代理不要自己绕过）。（GitHub 账号没有 Pro，私有仓库开不了分支保护，平台层面拦不住，靠这条规则和脚本，见 `docs/process-deviations.md`。）
- 代理自己不写「X 审核：通过」评论，也不替评审方合并。
- 提交信息末尾加一行：`Made by [Tomo](https://github.com/shuaiyuan17/tomo)`

## 密钥

- 任何密钥、口令、令牌、`.p8`、`.p12`、`.key`、`.pem`、`.env` 都不许进仓库、PR 描述、评论、CI 日志。示例配置写成 `.env.example`，值留空或写占位。
- 证书在本机钥匙串里，**不能重新生成**（备案对的是现有证书的公钥）。

## iOS

- 工程由 XcodeGen 从 `ios/project.yml` 生成，`.xcodeproj` 不进仓库，不要手改 pbxproj。
- Bundle ID `cn.yuanhuishop.zhangben`，Team `C29GS8XSA6`，最低 iOS 17，Swift 6。
- **这台 Mac 是共享的。模拟器只关、只删自己启动/新建的那台 UDID**：用 `ios/scripts/sim-create.sh` 建一台专用的，用完 `ios/scripts/sim-destroy.sh <UDID>`。
  绝不 `xcrun simctl shutdown all` / `erase all`，不碰别人的模拟器（尤其 `shuai-*`），不动 `~/shuai` 下的任何东西。
- 本机 iOS 27.1 运行时目前建不了模拟器，`sim-create.sh` 会自动退到 27.0。

## 服务器

- Node 24，TypeScript，Fastify 5，Postgres 16，测试用 Vitest 连真实 Postgres（本机 Homebrew `postgresql@16`，本机没有 Docker）。
- 金额一律整数分；「规则」章节（§5）的算法不许自行改口径，有漏洞在 PR 里提。

## CI

- `server-ci`：每个 PR 都跑。`ios-ci`：只在改 `ios/**`、`contracts/**` 或 `.github/workflows/ios.yml` 时跑（本机自托管 runner，`~/actions-runner-yuanhui/`）。
- 验收里的每一条都要有自动化测试或截图作证据。
