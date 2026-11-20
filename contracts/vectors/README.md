# 测试向量

`docs/plan-v2.md` §5 各算法的数值用例。服务器（`server/src/ledger/`）和手机各实现一遍，都必须逐条通过。格式由 `schemas/*.schema.json` 约束，CI 里校验（`cd server && npm run contracts:check`）。

通用约定：

- 所有金额是整数**分**，数量是整数**基本单位**；文件里只有 JS 安全整数（≤ 2^53−1），超过的中间值用因子表示（见 `rounddiv.json`）。
- 每个用例有唯一 `id`；`rules` 列出它覆盖的规则编号（见文末对照表）；`calc` / `note` 是手算过程，给评审核对，不参与断言。
- `pending_question: "Qn"`：这个用例的期望值依赖一处计划没写清的地方，按字面读法给出，见 PR 描述「疑问」一栏的 Qn。定了以后可能要改。
- 日期是上海时区的日历日 `YYYY-MM-DD`。

---

## rounddiv.json — `roundDiv(a, b)`（§5.0）

四舍五入到整数，恰好一半远离零，负数对称；`b > 0`。

| 字段 | 含义 |
|---|---|
| `numerator_factors` | 被除数 `a` 的因子，`a` = 它们的乘积。乘积可能超过 2^53（最大到 2^63−1），JSON 放不下，所以给因子；实现时用 BigInt / 带溢出检查的 Int64 乘出来再除。单个数就是只有一个因子 |
| `b` | 除数，正整数 |
| `expected` | `roundDiv(a, b)` |

覆盖：正负数、恰好一半（b 奇偶都有）、舍去、0、整除、接近 2^63 的乘积（最接近 2^63 的平方数、以及恰好 2^63−1）。

## allocation.json — 优惠分摊（§5.1）

| 字段 | 含义 |
|---|---|
| `lines[]` | 购物篮各行：`unit_price_fen`（单价，整件码就是整件价）、`pack_count`（件数） |
| `paid_total_fen` | 实收 `P` |
| `expect.list_fen[]` | 各行原价 `L_i = unit_price_fen × pack_count` |
| `expect.list_total_fen` | `L = Σ L_i` |
| `expect.amount_fen[]` | 各行摊完的实收 `a_i`，`Σ a_i = P` |
| `expect.error` | 与上面三项二选一：`"invalid"` 表示这笔要被拒（§5.0 上限、`L = 0` 而 `P ≠ 0`、负数） |

算法：`L = 0` → `P` 必须为 0、各行 0；否则 `a_i = roundDiv(L_i × P, L)`，`d = P − Σa_i` 加到原价最大的一行（并列取最前）；该行因此小于 0 时，把它设为 0，不足部分依次从下一大的行扣（同样按原价降序、并列取最前）。

## cost.json — 移动加权平均与成本（§5.2）

每个用例是一个商品从 `initial` 状态开始、依次执行 `steps` 的过程。

**状态**（`initial` 和每步后的 `expect.state`）：

| 字段 | 含义 |
|---|---|
| `q` | `stock_qty` |
| `v` | `stock_value_fen` |
| `c` | `last_cost_fen`，没有时 `null` |
| `k` | `cost_known` |
| `u` | 派生量：当前单位成本，`k` 真且 `q > 0` 时 `roundDiv(v, q)`，否则 `c`。只用来核对（例如必过向量的「平均 40.05」） |

**动作**（`steps[].action`，`type` 区分）：

| type | 字段 | 说明 |
|---|---|---|
| `stock_in` | `pack_qty, pack_count, unit_cost_fen` | `n = pack_qty × pack_count`，`T = pack_count × unit_cost_fen` |
| `sale` | `pack_qty, pack_count, amount_fen, list_amount_fen` | `n = pack_qty × pack_count`；`amount_fen` 是已经摊完的实收（分摊另见 allocation.json） |
| `opening` | `counted_qty, unit_cost_fen` | 期初 / 待确认补全；`unit_cost_fen: null` = 没填，`0` = 明确填 0 |
| `count` | `counted_qty` | 盘点（版本校验不在这里测，见 §5.6） |
| `expire_loss` / `supplier_return` | `qty` | 过期扔掉 / 退给供货商，基本单位 |
| `void` | `target_step` | 撤销第几步（从 0 数）产生的主流水 |

**期望流水**（`steps[].expect.entries[]`，按产生顺序）：

| 字段 | 含义 |
|---|---|
| `type, qty_delta, amount_fen, list_amount_fen, cogs_fen, value_delta_fen, cost_missing` | 同 `entries` 表（§3.3）；没列在 §3.3 里的取 0 / false |
| `unit_cost_fen` | 只有 stock_in 行断言：录入的每件单价 |
| `reverses_step` | 冲销行：冲的是第几步产生的、同 `type` 的那行（`reverses_entry_id`） |
| `covers_steps` | cost_fix 行：补记了哪几步的卖出行（这些行要写上 `cost_fix_entry_id`，且本身的 cogs / value_delta 不改） |

没列出的字段（id、occurred_at、flags 等）不断言。每一步之后不变式 I3 都成立。冲销行本身（`reverses_step` 非空的 sale 行）不是「未撤销的卖出行」，不参与成本补记。

`must_pass: true` 的 6 组是 §5.2 列出的必过向量。

## expiry.json — 保质期批次（§5.4）

| 段 | 字段 | 含义 |
|---|---|---|
| `add_months[]` | `start, months, expected` | 生产日期 + 保质期月数，按日历月加，月末对齐 |
| `remind[]` | `today, lot{expiry_date, expiry_warn_days, qty_left, closed, snoozed_until}, expected` | 今天要不要提醒：`今天 >= expiry_date − expiry_warn_days`，未关闭，`qty_left > 0`，不在「过几天再提醒」期内（`today < snoozed_until` 视为在期内） |
| `deduct[]` | `lots[]{lot_id, expiry_date, qty_left, closed, snoozed_until}, qty, expected{moves[]{lot_id, qty}, unassigned}` | 卖出 / 盘亏扣批次：到期日从早到晚，空日期最后，跳过已关闭；扣不完的 `unassigned`（批次之和不强求等于库存） |
| `handle_ver[]` | `lot{handle_ver, closed}, op_handle_ver, expected{result: ok\|stale, new_handle_ver}` | 防两台手机各处理一次 |
| `dispose[]` | `today, lot{qty_left, handle_ver}, op{action, actual_qty, handle_ver, days?}, expected{lot{…}, entry, flags_qty_left_before?}` | 处理快过期：`sold_out / discard / return` 对应 `expiry_dispose`，`snooze` 对应 `lot_snooze`；`entry` 是产生的流水（类型和数量，金额按 cost.json 的取法），`null` = 不产生；`flags_qty_left_before` 是处理前的 `qty_left`，记在流水 flags 里 |
| `undo[]` | `event, lot_before{…}, lot_move_qty?, expected{closed, closed_reason?, qty_left}` | 撤销对批次的影响（§5.4 生命周期表） |

## prefix.json — 手输条码前缀匹配（§5.5）

| 字段 | 含义 |
|---|---|
| `catalog[]` | 本地条码表：`product_id, name, barcode`（一个商品可以有多个条码） |
| `cases[].input` | 已输入的数字 |
| `expected.listed` | 是否列候选（满 8 位起） |
| `expected.candidates` | 有条码以 `input` 为前缀的**商品** id，去重，按字符串排序（当集合比较） |
| `expected.shown_count` | 显示几行（最多 4） |
| `expected.too_many` | 超过 4 个，提示继续输 |
| `expected.auto_select` | 只剩一个候选时自动选中它，否则 `null`（主按钮置灰）；绝不自动选第一个 |

收银员看到的候选行不带库存，这是界面断言，不在向量里。

---

## 规则编号对照

| 编号 | §5 里的规则 | 用例 |
|---|---|---|
| `5.0-舍` | roundDiv 普通舍入 | rd-07, 09, 11, 12, 14, 18, 21 |
| `5.0-半` | 恰好一半远离零 | rd-01–06, 16, 17, 19, 20, 24, 25；alloc-11 |
| `5.0-负` | 负数对称 | rd-02, 04, 06, 08, 10, 13, 15, 17, 20, 22, 25, 27, 29 |
| `5.0-溢出` | 接近 2^63 的中间乘积 | rd-23–29；alloc-18 |
| `5.0-上限` | 输入上限（等于上限合法，超出拒 invalid） | alloc-18–24 |
| `5.0-全零` / `5.1-0` | 全零购物篮 | alloc-12, 13 |
| `5.1-1` / `5.1-2` | 按比例摊、差额给原价最大行 | alloc-01–11, 14–19 |
| `5.1-3` | 最大行变负，不足部分依次给下一大的行 | alloc-16, 17 |
| `5.1-多收` | P > L 用同一公式 | alloc-03, 04, 06 |
| `5.1-单行` | 单行 | alloc-05, 06, 24 |
| `5.1-并列` | 并列最大取最前 | alloc-07, 08, 09 |
| `5.1-1分` | 1 分钱 | alloc-09, 10 |
| `5.2-进货-已知且正` | 进货，k 真且 q > 0 | cost-01, 18 |
| `5.2-进货-未知或非正` | 进货，q ≤ 0 或进价没填：目标货值 + cost_adjust | cost-02, 03, 07, 08, 09, 10, 17 |
| `5.2-卖出-未知` | 卖出，k 假（正库存也一样） | cost-04, 09, 10 |
| `5.2-卖出-已知且正` | 卖出，k 真且 q > 0（take、余数、n ≥ q 时 c = u） | cost-02, 05, 07, 08, 18 |
| `5.2-卖出-已知且非正` | 卖出，k 真且 q ≤ 0 | cost-08, 17 |
| `5.2-整件卖` | 整件码卖出 | cost-02 |
| `5.2-期初-填了` | 期初填了进价（含明确 0） | cost-04, 05, 15 |
| `5.2-期初-没填` | 期初没填进价（k 假只设数量；k 真按盘点） | cost-04, 16 |
| `5.2-成本补记` | cost_fix，补记前后撤销 | cost-04, 09, 10, 19, 20 |
| `5.2-盘点-已知且正` | 盘点，k 真且 q > 0：盘亏、盘盈、数到 0 | cost-11 |
| `5.2-盘点-已知且非正` | 盘点，k 真且 q ≤ 0 | cost-06, 12 |
| `5.2-盘点-未知` | 盘点，k 假 | cost-13 |
| `5.2-过期退货` | 过期扔掉、退给供货商 | cost-14 |
| `5.2-撤销` | 撤销，违反 I3 时 cost_adjust 归位 | cost-17, 18, 19, 20 |
| §5.4 | 保质期 | expiry.json 全部 |
| §5.5 | 手输前缀匹配 | prefix.json 全部 |
