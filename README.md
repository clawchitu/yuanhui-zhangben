# 元辉账本

江阴市周庄元辉烟酒店用的扫码记账 App：原生 iOS（SwiftUI）+ 自有后端（Node 24 / Fastify 5 / Postgres 16）。只记账不收钱。

- 开发计划：[`docs/plan-v2.md`](docs/plan-v2.md)（以仓库内这份为准）
- 设计稿：[`docs/design/png/`](docs/design/png/)，总览 `overview.png`
- 评审意见与改动记录：`docs/review-1119.md`、`docs/review-1119-mockups.md`、`docs/changes-1119.md`
- 流程上和计划不一致的地方：[`docs/process-deviations.md`](docs/process-deviations.md)
- 给代理的开发规则：[`CLAUDE.md`](CLAUDE.md)

## 目录

| 目录 | 内容 |
|---|---|
| `server/` | 后端。`npm ci && npm test`（本机设 `DATABASE_URL` 才跑数据库测试） |
| `ios/` | iOS 工程。`cd ios && xcodegen generate` 生成 `.xcodeproj`（不进仓库） |
| `contracts/` | 接口、op、权限、测试向量（S01 起） |
| `deploy/` | 部署脚本（S10a 起） |
| `scripts/` | 仓库流程脚本，`merge-pr.sh` 是合并 PR 的唯一入口 |

## CI

| 检查 | 工作流 | runner | 触发 |
|---|---|---|---|
| `server-ci` | `.github/workflows/server.yml` | GitHub 托管 ubuntu-24.04 + Postgres 16 服务容器 | 每个 PR、推 main |
| `ios-ci` | `.github/workflows/ios.yml` | 本机自托管 runner（label `self-hosted, macOS, yuanhui`，装在 `~/actions-runner-yuanhui/`，launchd 服务） | 只在改 `ios/**` 或该工作流时 |

## 合并

```
scripts/merge-pr.sh <PR号> --dry-run   # 只检查
scripts/merge-pr.sh <PR号>             # 检查通过后 squash 合并
```

<!-- S00 示例 PR：只改文档 -->
