# 快鸟响应样例

**这些不是真实录制。** S08 不调真实付费接口（没有 AppCode），这里按云市场条码接口常见的返回结构手写了几份样例，
用来测 `src/lookup/kuainiao.ts` 的解析。

- `found*.json`：业务状态是成功、认得出名称 → 查到。
- `not-found.json`：手写的「没查到」样子。真实格式没核对过，`parseKuainiao` 现在**不认**它是「没查到」，而是抛 `format`
  （调用方不写缓存），免得把业务错误当成没查到负缓存 7 天（PR #19 审核，§14 S08-6）。

§14 T9（S10a）：拿到 AppCode 后用 `scripts/barcode-trial.ts --record` 录真实响应放进本目录（`recorded-*.json`，
认不出的响应也会录下），用它替换这些手写样例，定下「成功」「明确没查到」各凭哪个字段认，只有明确没查到才写负缓存，
并收紧 `parseKuainiao` 的字段候选表。
