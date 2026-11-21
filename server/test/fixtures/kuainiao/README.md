# 快鸟响应样例

**这些不是真实录制。** S08 不调真实付费接口（没有 AppCode），这里按云市场条码接口常见的返回结构手写了几份样例，
用来测 `src/lookup/kuainiao.ts` 的宽松解析。S10a 拿到 AppCode 后用 `scripts/barcode-trial.ts --record` 录一份真实响应
放进本目录（`recorded-*.json`），再按实测收紧 `parseKuainiao` 的字段候选表。
