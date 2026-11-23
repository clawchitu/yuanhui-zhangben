# 快鸟响应：真实录制

`recorded-<条码>.json` 是用 `scripts/barcode-trial.ts --record` 对真实快鸟接口（阿里云云市场 cmapi00067757）录下的响应体，
只有响应体，没有请求头、没有 AppCode。`src/lookup/kuainiao.ts` 的 `parseKuainiao` 按它们校准（PR #39），测试在 `test/lookup.kuainiao.test.ts`。
录制已经做完，测试不再调真实接口（每次查询都扣次数）。

| 文件 | 内容 | 解析结果 |
|---|---|---|
| `recorded-6901028075831.json` | 红双喜（硬8mg），1 张图 | 查到 |
| `recorded-6902083881405.json` | 娃哈哈饮用纯净水，1 张图 | 查到 |
| `recorded-6920152400777.json` | 康师傅红烧牛肉面碗装，`Image: []` | 查到，没有图 |
| `recorded-6921168509256.json` | 农夫山泉 饮用天然水550ml，4 张图 | 查到，4 张图（`imageUrl` = 第一张） |
| `recorded-6970000000001.json` | 不存在的码：`status:"400"`、`message:"经查，暂无该条码相关信息。"`、其余字段 null | 明确没查到（负缓存 7 天） |

## 真实格式（扁平，不是手写样例猜的嵌套体）

- 业务状态：`status` 是字符串，`"200"` = 查到，`"400"` = 没查到；`message` 是中文（「查询成功！」/「经查，暂无该条码相关信息。」）。
- 商品字段：`Barcode`、`ItemName`（名称）、`ItemSpecification`（规格）、`BrandName`（品牌），另有分类、尺寸、厂商等不用的字段。
- 图片：`Image: [{Imageurl}]`（没图是 `[]`，没查到是 `null`）；`ImageStream` 是同一批图的另一种地址，不用。
  地址是 **http**，路径里带时间戳签名（`/getPic/getPics/<码>/<时间戳>/<签名>/<序号>`），**可能会过期**：图片任务下载失败按 `jobs/image-fetch.ts` 的重试（最多 3 次）处理，失败就显示首字。

## 判别规则（`parseKuainiao`）

- `status` 200 且 `message` 含「成功」且 `ItemName` 非空 → 查到；`Barcode` 必须等于所查的码（客户端核对）。
- `status` 400 且 `message` 含「暂无该条码」（不是只含「暂无」：「暂无权限 / 暂无可用次数」之类不算）且 `ItemName` 为空 → 明确没查到，调用方写负缓存（7 天后重查）。
- 其余一切（别的状态码、`message` 对不上、字段类型不对、名称为空、条码对不上、不是 JSON）→ `format`：不缓存、下次重查，
  原始响应只放在 `SourceError.raw`（不进日志）。不把业务错误当「没查到」（PR #19 审核，§14 S08-6）。

S08 时手写的三份「成功形态」样例（`found*.json`）和手写的 `not-found.json` 与真实格式一种都对不上，已删除；
测试里需要的错误、畸形响应在 `test/lookup.kuainiao.test.ts` 里就地构造（以录制件为底改字段）。
