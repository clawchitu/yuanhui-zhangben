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
   - `ios-ci`：PR 改了 `ios/**`、`contracts/**`、`scripts/ci/**` 或 `.github/workflows/ios.yml` 时必须成功（`contracts/**` 自 S12 起加入，`scripts/ci/**` 自 11/27 CI 精简起加入）；没改、工作流没触发时视为不需要；只要出现过就必须成功；
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

## D-S22b-1 ios-ci 时限 45 → 75 分钟（2026-11-23）

PR #41 的 ios-ci 两次都在 45 分钟时被取消：`xcodebuild test` 本身全部通过（约 40 分钟，S15 遍历四条就占约 15 分钟），被砍在随后的 Release 构建检查上（Release、Beta 各约 6 分钟）。`ios.yml` 的 `timeout-minutes` 改成 75。检查内容不变。

## D-1126-1 ios-ci 关掉测试后的诊断收集（2026-11-26）

**现象**：PR #50、#51 和 main 上 #49 合并后的 ios-ci 都在 75 分钟时被取消，测试本身全过。三次 `xcodebuild test`（全量测试、Release 检查、Beta 检查）在打出 `** TEST SUCCEEDED **` 之后都不退出，挂着一个 `simctl diagnose -l -b --timeout=600 …`，每次卡满 600 秒才结束（PR #50 run 45727332462：Release 检查 19:23:36 测完、19:33:37 才退出；全量测试最后一条用例 03:11:34、步骤 03:21:46 结束）。三次共多出约 30 分钟，加上约 40 分钟测试和两次构建，超过 75 分钟。

**改为**：`ios.yml` 的 `xcodebuild test` 和 `ios/scripts/release-check.sh` 加 `-collect-test-diagnostics never`。检查内容、时限不变。代价：用例失败时 xcresult 里不再附 sysdiagnose 级别的模拟器诊断（失败用例本身的日志、截图照样在）。

## D-1127-1 iOS CI 精简：PR 选测，全量挪到 main 和夜间（2026-11-27，负责人同意 Fable 方案）

PR 上的 ios-ci 原来每次跑全量，要 55–65 分钟（S15 遍历四条约 16 分钟、S22d 约 5 分钟），两台 runner 排队时常常再等 1 小时。

**改为**：PR 上跑编译、全部单元测试、冒烟集（含家用全页面遍历）、按 `scripts/ci/ios-test-map.txt` 选出的 UI 测试、Release / Beta 构建检查；改到公共层、导航、数据模型、契约或没登记的路径时自动全量。全量在 push 到 main 后和每晚北京时间 03:00 跑，main 上同一时间只跑一轮，新的取消旧的。`merge-pr.sh` 加了一条：main 最近一轮跑完的 ios 全量不是 success 就拒绝合并（`--fix-main` 例外，要求本 PR head 上手动全量通过）。

代价：PR 上没选中的 UI 测试出问题，要到合并后 main 上的全量才发现，那时 main 红、锁住合并，由合进去的人修。缓解：没登记的路径一律全量；公共层一律全量；夜间兜底。
