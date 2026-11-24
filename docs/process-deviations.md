# 流程偏差记录

记录实际做法和 `docs/plan-v2.md` 不一致的地方，以及原因。

## D-S00-1 没有分支保护，改用 `scripts/merge-pr.sh`（2026-11-19）

**计划写的**（§2.1、§8 S00）：`main` 受保护，禁止直接推送；必需状态检查 `server-ci`、`ios-ci`、`review/codex`、`review/fable`；验收要求「直接推 main 被拒」「没有 review 状态不能合并」；产出 `scripts/protect-main.sh`。

**实际情况**：`clawchitu` 是免费账号，私有仓库用不了分支保护和 rulesets（GitHub 要 Pro 才开放）。平台层面拦不住直接推 main，也没有「必需检查」。

**改为**：

1. 规则写在 `CLAUDE.md`：所有改动走 PR，不直接推 `main`，合并只用 `scripts/merge-pr.sh`。
2. `scripts/merge-pr.sh <PR号> [--dry-run]` 在合并前检查：
   - PR 是 open、非草稿、无冲突、目标 main；
   - `server-ci` 在当前 head 上成功；
   - `ios-ci`：PR 改了 `ios/**`、`contracts/**` 或 `.github/workflows/ios.yml` 时必须成功（`contracts/**` 自 S12 起加入）；没改、工作流没触发时视为不需要；只要出现过就必须成功；
   - PR 评论里有当前 head 推送之后的「Codex 审核：通过」开头的评论，以及「Opus 审核：通过」或「Fable 审核：通过」开头的评论之一（2026-11-24 起第二路是 Opus，Fable 只为兼容旧 PR），每方以最后一条「X 审核：」评论为准；Opus、Fable 当前 head 上任一方最后一条是「不通过」就拒绝。
   - 全过才 `gh pr merge --squash --match-head-commit <sha>`。
3. 评审结论用 **PR 评论**而不是 `review/codex`、`review/fable` 状态（没有必需检查，状态也拦不住合并，评论更直观）。
4. 不写 `scripts/protect-main.sh`（开不了）。

**风险**：这是约定，不是强制。任何有写权限的人或代理仍可以直接推 main、用网页按钮合并。补救：如果之后升级 Pro 或把仓库转到有 Team 计划的组织，补上 `protect-main.sh`，把四个检查设为必需。

## D-1124-1 第二路评审由 Fable 换成 Opus（2026-11-24）

**之前**：每个 PR 由 Codex 和 Fable 双审。

**改为**（负责人 11/24 定，对所有项目生效）：两路评审 = Codex（默认模型 gpt-6.1-terra）+ Opus。Fable 不再做代码评审。`scripts/merge-pr.sh` 要求「Codex 审核：通过」，另外要「Opus 审核：通过」或「Fable 审核：通过」之一；接受 Fable 只是为了兼容 11/24 之前已经用 Fable 审过的旧 PR。只有评审确实通过才发「X 审核：通过」，不替没通过的评审发通过。

## D-S00-2 iOS 工作流用 paths 过滤（2026-11-19）

**计划写的**（§2.1）：两条工作流对每个 PR 都触发，不用工作流级 paths 过滤（怕被跳过的必需检查停在 Pending 卡死合并）。

**改为**：`ios.yml` 用 `paths` 过滤，只在 `ios/**` 或 `.github/workflows/ios.yml` 改动时触发，省掉自托管 Mac 上的无谓构建。因为没有平台级必需检查，不存在 Pending 卡死；「工作流没触发」由 `merge-pr.sh` 按改动路径判断为不需要。`server.yml` 仍然对每个 PR 都触发。

注意：以后 `ios/` 依赖仓库里别的目录（例如 S01 的 `contracts/vectors/`）时，要把那个目录加进 `ios.yml` 的 `paths`，并同步改 `merge-pr.sh` 里判断 `ios_needed` 的正则。S12 起 ShopCore 的测试直接读 `contracts/`，已把 `contracts/**` 加进两处。

## D-S00-3 iOS 模拟器运行时（2026-11-19）

本机 Xcode 27.1 装了 iOS 27.0 和 27.1 运行时，但 27.1 运行时建不了任何 iPhone 模拟器（`Incompatible device`）。`ios/scripts/sim-create.sh` 从新到旧尝试，目前实际用 iOS 27.0 + iPhone 17。CI 每次新建一台 `yuanhui-ci-<run_id>-<attempt>`，结束时只关、只删这一台。

## S00 验收记录（2026-11-19）

示例 PR 验完已关闭，不合并：

| PR | 改动 | server-ci | ios-ci | merge-pr.sh |
|---|---|---|---|---|
| #1 | 只改文档 | 成功 | 没触发 | 无评论时拒绝；两方「通过」后可合并（ios-ci 判为不需要） |
| #2 | 只改 server/ | 成功 → 故意改坏后失败 | 没触发 | 新提交后：拒绝（server-ci 失败；旧的「通过」早于新 head，要重审） |
| #3 | 只改 ios/ | 成功 | 成功 | Fable「不通过」时拒绝，改「通过」后可合并；runner 停掉再推，ios-ci 排队中时拒绝 |

真正执行 `gh pr merge` 的那一步没在示例 PR 上跑（示例 PR 不合并），第一个真实 PR（S01）合并时验证。
