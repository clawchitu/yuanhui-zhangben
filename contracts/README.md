# contracts/

服务器和 iOS 共用的契约（S01，对应 `docs/plan-v2.md` §3–§7）。两边都只读这里，不各自抄一份。

| 文件 | 内容 | 来源 |
|---|---|---|
| `openapi.yaml` | 全部 HTTP 接口（OpenAPI 3.1），每个操作的 `x-permission` 指向 `permissions.json` 的一行 | §7、§4.2 |
| `ops.schema.json` | `POST /v1/sync` 里 `ops[]` 每一项的格式（JSON Schema 2020-12），含 §5.0 的上限 | §4.3、§5.0 |
| `permissions.json` | 权限矩阵，四列：家用 / 收银员 / 审核 / 被踢设备；格式见 `permissions.schema.json` | §6.1、§4.5 |
| `vectors/` | 算法的测试向量，服务器和手机的单测都读它；字段说明见 `vectors/README.md` | §5、§14 |
| `examples/ops-valid.json`、`ops-invalid.json` | op 示例：前者必须通过 `ops.schema.json`，后者每条都必须被拒（`why` 写了为什么） | §4.3、§5.0 |

## 约定

- 金额一律整数**分**，数量一律整数**基本单位**；JSON 里不带小数点、不用字符串。
- 收银员拿到的响应里，被裁剪的字段**整个键不出现**（§4.2）。`openapi.yaml` 里这些字段都是可选的，描述里写「收银员不下发」；商品的私有字段放在 `Product.private` 里，收银员的响应没有这个键。
- `permissions.json` 的 `decision`：`public` 不需登录；`allow` 能（带 `conditions` 时全部满足才能）；`deny` 拒；`held` 记为暂存等家用确认；`not_applicable` 这个身份不会调。表里不允许有待定的格子（§6.1），`contracts:check` 遇到会失败。
- 同一种 op 权限因 payload 而不同时分多行，用 `match` 选行：`op:product_upsert[quick]`（`quick=true`）和 `op:product_upsert[full]`（`quick=false`）。
- `/v1/recovery/import` 里的每个 op 仍按提交设备的角色过 `op:*` 行。

## 校验

```
cd server && npm run contracts:check
```

CI（`server-ci`）每个 PR 都跑这一步：openapi 语法（含对 `ops.schema.json` 的外部引用）、所有 JSON Schema 的语法（ajv strict）、每个向量文件符合 `vectors/schemas/` 里对应的 schema、向量里只有安全整数、向量和权限表里没有待定标记、op 示例的正反例、`permissions.json` 正好覆盖 openapi 的全部接口和 `ops.schema.json` 的全部 op 类型。

它只查格式，**不重算向量里的数字**。数字是按 §5 手算、再用独立程序复核的；重算是 S04（服务器）和 iOS 对应段的单测要做的事。

改了契约的哪一处，先改这里、过评审，再改两边的代码。
