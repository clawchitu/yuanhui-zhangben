# 测试向量

`docs/plan-v2.md` §5 各算法的数值用例。服务器（`server/src/ledger/`）和手机各实现一遍，都必须逐条通过。格式由 `schemas/*.schema.json` 约束，CI 里校验（`cd server && npm run contracts:check`）。

通用约定：

- 所有金额是整数**分**，数量是整数**基本单位**；文件里只有 JS 安全整数（≤ 2^53−1），超过的中间值用因子表示（见 `rounddiv.json`）。
- 每个用例有唯一 `id`；`rules` 列出它覆盖的规则编号（见文末对照表）；`calc` / `note` 是手算过程，给评审核对，不参与断言。
- 计划 §14 裁定过的规则（S01 疑问 Q1–Q14）已经写进期望值，向量里没有待定项；`contracts:check` 遇到 `pending_question` 会失败。
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
| `lines[]` | 购物篮各行：`unit_price_fen`（单价，整件码就是整件价）、`pack_count`（件数）、`pack_qty`（可选，缺省 1，只用于基本单位数量上限） |
| `paid_total_fen` | 实收 `P` |
| `expect.list_fen[]` | 各行原价 `L_i = unit_price_fen × pack_count` |
| `expect.list_total_fen` | `L = Σ L_i` |
| `expect.amount_fen[]` | 各行摊完的实收 `a_i`，`Σ a_i = P` |
| `expect.error` | 与上面三项二选一：`"invalid"` 表示这笔要被拒（§5.0 上限：单行金额 ≤ 99,999,999、件数 ≤ 99,999、`pack_qty × pack_count` ≤ 9,999,999、≤ 200 行、实收 ≤ 19,999,999,800；`L = 0` 而 `P ≠ 0`；负数） |

`allocation.schema.json` 故意**不**给 `paid_total_fen` 设上限：被拒的那几组（alloc-23、26）本身就要带超限或为负的值。上限在 `ops.schema.json` 里。

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
| `unit_cost_fen` | stock_in 行：录入的每件单价；cost_fix 行：补记用的单位成本 `b`，撤销时从这里取 `b`。冲销行照抄原行、**不取反**（进货的冲销行、cost_fix 的冲销行都一样，§3.3）。其他类型不断言 |
| `reverses_step` | 冲销行：冲的是第几步产生的、同 `type` 的那行（`reverses_entry_id`） |
| `covers_steps` | cost_fix 行：补记了哪几步的卖出行（这些行要写上 `cost_fix_entry_id`，且本身的 cogs / value_delta 不改） |

`expect` 也可以是 `{ "error": "invalid" }`：这一步被拒（§14 S05-4），不产生流水，状态和已有流水都不变（之后的步号照数，被拒的那步没有主流水，不能被 `void` 引用）。范围：数量（`q`、`qty_delta`）在 integer（±2^31）内；金额、货值、成本（`v`、`c`、各金额列）既要存得进 bigint，又要能按契约 `SignedFen` 下发（JSON 安全整数 ±(2^53−1)），取两者更严，即 ±9,007,199,254,740,991（cost-25、26）。

没列出的字段（id、occurred_at、flags 等）不断言。每一步之后不变式 I3 都成立。冲销行本身（`reverses_step` 非空的 sale 行）不是「未撤销的卖出行」，不参与成本补记。

§14 裁定后要特别注意的几条（都有用例）：

- 金额为 0 的 `cost_adjust` 不记；没有可补记行的 `cost_fix` 也不记（cost-02、07、21、22）。这条通则**只管** `cost_adjust` 和 `cost_fix`：盘点数等于账面数（d = 0，点「没错」）照记一条数量、金额全 0 的 `count`，不标 `cost_missing`，不论进价是否已知（cost-23、24）。
- 进价已知时没填进价的期初，流水记 **`count`**，金额按盘点规则（cost-16）。
- 进价未知时，扔掉、退货、数量有变化的盘点：金额 0、`cost_missing = true`、不参加补记（cost-13、22）。数量没变的盘点、没填进价的 `opening` 不标。
- 补记后撤销卖出：冲销卖出行 + 冲销 `cost_fix`（`b` 取自原 cost_fix 的 `unit_cost_fen`）+ `cost_adjust`（+数量 × `b`）（cost-19）。
- `k` 只增不减：撤销让进价变已知的那次进货，`k`、`c` 不回退，已记的 `cost_fix` 不冲（cost-09 最后一步）。
- 撤销后违反 I3 时归位目标统一是 `v = q × c`，`q > 0` 而 `v < 0` 时也触发（cost-21）。

`must_pass: true` 的 8 组是 §5.2 列出的必过向量（cost-01–06、19、21）。

## expiry.json — 保质期批次（§5.4）

| 段 | 字段 | 含义 |
|---|---|---|
| `add_months[]` | `start, months, expected` | 生产日期 + 保质期月数，按日历月加，月末对齐 |
| `remind[]` | `today, lot{expiry_date, expiry_warn_days, qty_left, closed, snoozed_until}, expected` | 今天要不要提醒：`今天 >= expiry_date − expiry_warn_days`，未关闭，`qty_left > 0`，不在「过几天再提醒」期内（`today < snoozed_until` 才算在期内，到 `snoozed_until` 当天恢复提醒，rem-12） |
| `deduct[]` | `lots[]{lot_id, expiry_date, qty_left, closed, snoozed_until, seq}, qty, expected{moves[]{lot_id, qty}, unassigned}` | 卖出 / 盘亏扣批次：到期日从早到晚，空日期最后，到期日相同（或都为空）时按 `seq`（来源流水的 `entries.seq`）小的先扣，**与数组顺序无关**（ded-04、05 故意把数组顺序和 seq 反过来）；跳过已关闭；扣不完的 `unassigned`（批次之和不强求等于库存） |
| `handle_ver[]` | `lot{handle_ver, closed}, op_handle_ver, expected{result: ok\|stale, new_handle_ver}` | 防两台手机各处理一次 |
| `dispose[]` | `today, lot{qty_left, handle_ver}, op{action, actual_qty, handle_ver, days?}, expected{lot{…}, entry, flags_qty_left_before?}` | 处理快过期：`sold_out / discard / return` 对应 `expiry_dispose`，`snooze` 对应 `lot_snooze`；`entry` 是产生的流水（类型和数量，金额按 cost.json 的取法），`null` = 不产生；`flags_qty_left_before` 是处理前的 `qty_left`，记在流水 flags 里 |
| `undo[]` | `event, lot_before{…}, lot_move_qty?, expected{closed, closed_reason?, qty_left}` | 撤销对批次的影响（§5.4 生命周期表） |

## prefix.json — 手输条码前缀匹配（§5.5）

| 字段 | 含义 |
|---|---|
| `catalog[]` | 本地条码表：`product_id, name, barcode, pack_qty`（一个商品可以有多个条码；`pack_qty > 1` 是整件码） |
| `cases[].input` | 已输入的数字 |
| `expected.listed` | 是否列候选（满 8 位起） |
| `expected.candidates[]` | **有序**的全部候选 `{product_id, pack_qty, barcode}`。候选按「商品 + 换算数量」去重：同一商品的两个单件码算一个，单件码和整箱码是两个。`barcode` 是这个候选的代表条码：与输入完全相等的那个，否则是它以输入为前缀的条码里最小的。排序：与输入完全相等的排第一，其余按代表条码字符串升序 |
| `expected.shown[]` | 显示的行 = `candidates` 的前 4 个 |
| `expected.more_count` | 没显示的个数，> 0 时提示「还有 N 个，接着输」 |
| `expected.auto_select` | 只剩一个候选时自动选中它 `{product_id, pack_qty}`，否则 `null`（主按钮置灰）；绝不自动选第一个 |

收银员看到的候选行不带库存，这是界面断言，不在向量里。

## limits.json — schema 表达不了的乘积上限（§5.0）

`ops.schema.json` 能限制单个字段，限制不了两个字段的乘积，这几条由服务器在应用 op 时校验，超出拒 `invalid`。

| 字段 | 含义 |
|---|---|
| `op_type` | `stock_in`（进货 op）或 `sale_line`（`sale_batch` 的一行） |
| `fields` | `pack_qty, pack_count`，以及 `unit_cost_fen`（进货每件单价）或 `unit_price_fen`（卖出单价） |
| `expected` | `ok` 或 `invalid` |

规则：`pack_qty × pack_count ≤ 9,999,999`（基本单位数量）；进货 `pack_count × unit_cost_fen ≤ 99,999,999`（进货总价）；卖出 `unit_price_fen × pack_count ≤ 99,999,999`（单行金额）。另外进货 `pack_count ≥ 1`（0 件拒 `invalid`，§14 S05-3；卖出行 0 件不拒）。实收上限见 allocation.json alloc-25、26。

---

## 规则编号对照

| 编号 | §5 里的规则 | 用例 |
|---|---|---|
| `5.0-舍` | roundDiv 普通舍入 | rd-07, 09, 11, 12, 14, 18, 21 |
| `5.0-半` | 恰好一半远离零 | rd-01–06, 16, 17, 19, 20, 24, 25；alloc-11 |
| `5.0-负` | 负数对称 | rd-02, 04, 06, 08, 10, 13, 15, 17, 20, 22, 25, 27, 29 |
| `5.0-溢出` | 接近 2^63 的中间乘积 | rd-23–29；alloc-18 |
| `5.0-上限` | 输入上限（等于上限合法，超出拒 invalid） | alloc-18–28；limits.json 全部 |
| `5.0-全零` / `5.1-0` | 全零购物篮 | alloc-12, 13 |
| `5.1-1` / `5.1-2` | 按比例摊、差额给原价最大行 | alloc-01–11, 14–19 |
| `5.1-3` | 最大行变负，不足部分依次给下一大的行 | alloc-16, 17 |
| `5.1-多收` | P > L 用同一公式 | alloc-03, 04, 06, 25 |
| `5.1-单行` | 单行 | alloc-05, 06, 24, 25, 27 |
| `5.1-并列` | 并列最大取最前 | alloc-07, 08, 09 |
| `5.1-1分` | 1 分钱 | alloc-09, 10 |
| `5.2-进货-已知且正` | 进货，k 真且 q > 0 | cost-01, 18, 21 |
| `5.2-进货-未知或非正` | 进货，q ≤ 0 或进价没填：目标货值 + cost_adjust（差额 0 不记） | cost-02, 03, 07, 08, 09, 10, 17, 21 |
| `5.2-卖出-未知` | 卖出，k 假（正库存也一样） | cost-04, 09, 10 |
| `5.2-卖出-已知且正` | 卖出，k 真且 q > 0（take、余数、n ≥ q 时 c = u） | cost-02, 05, 07, 08, 18, 21 |
| `5.2-卖出-已知且非正` | 卖出，k 真且 q ≤ 0 | cost-08, 17 |
| `5.2-整件卖` | 整件码卖出 | cost-02 |
| `5.2-期初-填了` | 期初填了进价（含明确 0） | cost-04, 05, 15, 22 |
| `5.2-期初-没填` | 期初没填进价（k 假只设数量；k 真记 count、按盘点） | cost-04, 16 |
| `5.2-成本补记` | cost_fix（存 unit_cost_fen），补记前后撤销，损耗不参加 | cost-04, 09, 10, 19, 20, 22 |
| `5.2-盘点-已知且正` | 盘点，k 真且 q > 0：盘亏、盘盈、数到 0、数对了 | cost-11, 24, 27 |
| `5.2-盘点-盘盈按u` | 盘盈金额 = d × u（当前单位成本 roundDiv(v, q)），u ≠ c 时与 d × c 区分开（§14 S05-8） | cost-27 |
| `5.2-盘点-已知且非正` | 盘点，k 真且 q ≤ 0 | cost-06, 12 |
| `5.2-盘点-未知` | 盘点，k 假（金额 0；d ≠ 0 时标 cost_missing） | cost-13, 23 |
| `5.2-盘点-没错` | 盘点数等于账面数，照记全 0 的 count | cost-23, 24 |
| `5.2-未知-非卖出` | 进价未知时扔掉、退货、盘点标 cost_missing | cost-13, 22 |
| `5.2-k只增` | 撤销让进价变已知的进货，k / c 不回退，cost_fix 不冲 | cost-09 |
| `5.2-过期退货` | 过期扔掉、退给供货商 | cost-14, 22 |
| `5.2-范围` | 结果超出可存、可下发范围（金额 ±(2^53−1)，数量 ±2^31）拒 invalid，恰好等于边界收 | cost-25, 26 |
| `5.2-撤销` | 撤销，违反 I3 时 cost_adjust 归位到 q × c（含 q > 0 而 v < 0） | cost-09, 17, 18, 19, 20, 21 |
| §5.4 | 保质期 | expiry.json 全部 |
| §5.5 | 手输前缀匹配 | prefix.json 全部 |
