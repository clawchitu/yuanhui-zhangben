# 元辉账本 开发规则（给执行代理）

先读 `docs/plan-v2.md` 开头的「执行者须知」和你这一段在 §8 里的内容；只读本段「要读」列出的章节和设计稿，不要通读全部设计稿。

## 提交与合并

- **所有改动都走 PR，不许直接推 `main`。** 分支名 `sNN-简述`，一段一个 PR，squash 合并。
- PR 用仓库模板，四栏都要填：对应段号、验收清单（逐条附证据）、Codex 审核、Fable 审核。
- **每个 PR 要 Codex 和 Fable 都审过才能合。** 评审由 Chitu 触发，结论以 PR 评论留下，评论以「Codex 审核：通过」/「Fable 审核：通过」开头。有新提交后旧的通过作废，要重审。
- **合并只用 `scripts/merge-pr.sh <PR号>`**，不要用 `gh pr merge` 或网页按钮。这个脚本检查两条 CI 和两条审核评论，缺一样就拒绝。（GitHub 账号没有 Pro，私有仓库开不了分支保护，平台层面拦不住，靠这条规则和脚本，见 `docs/process-deviations.md`。）
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

- `server-ci`：每个 PR 都跑。`ios-ci`：只在改 `ios/**` 或 `.github/workflows/ios.yml` 时跑（本机自托管 runner，`~/actions-runner-yuanhui/`）。
- 验收里的每一条都要有自动化测试或截图作证据。
