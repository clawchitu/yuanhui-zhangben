// 快鸟条码接口客户端（阿里云云市场 cmapi00067757，§0、§7）。
//
// - 只有服务器调，AppCode 只从环境变量来（config.kuainiao.appCode），不进仓库、不进日志、不进错误信息。
// - 请求：GET <endpoint>?Code=<条码>，请求头 `Authorization: APPCODE <AppCode>`（旧计划 design/plan.md 记下的格式）。
// - 响应解析按真实录制件校准（test/fixtures/kuainiao/recorded-*.json，PR #39）：「查到」「明确没查到」各凭 status + message 认，
//   其余一律 format（调用方不写缓存），不把业务错误当「没查到」（PR #19 审核，§14 S08-6）。见 parseKuainiao。
// - 网关报错头 X-Ca-Error-Message 不可信（可能回显 AppCode），只拿来归成固定分类，内容不进错误信息、不进日志。
// - 外部服务做成接口（BarcodeSource），测试和演示店都不碰真实接口。
import type { Config } from "../config.ts";

export interface CatalogHit {
  name: string;
  spec?: string;
  brand?: string;
  /** 第一张图（= imageUrls[0]）：图片任务只下这一张 */
  imageUrl?: string;
  /** 全部图片地址（去重、只有 http/https）；以后多图选择用，不下发给手机（§14 S08-1） */
  imageUrls?: string[];
}

export type SourceResult = { kind: "found"; hit: CatalogHit; raw: unknown } | { kind: "not_found"; raw: unknown };

/** 外部条码库。lookup 失败（超时、HTTP 错、额度用完、格式认不出）一律抛错，调用方不缓存失败 */
export interface BarcodeSource {
  readonly name: string;
  lookup(barcode: string, signal: AbortSignal): Promise<SourceResult>;
}

/**
 * 调快鸟失败。message 只用固定文字（状态码、固定分类），不带 AppCode、不带网关报错头、不带响应体。
 * raw：认不出的响应原文，只给 scripts/barcode-trial.ts --record 留档用；不可枚举，日志序列化错误对象时不会带出来，调用方也不许记它。
 */
export class SourceError extends Error {
  readonly kind: "timeout" | "http" | "format" | "network";
  declare readonly raw?: unknown;
  constructor(kind: SourceError["kind"], message: string, raw?: unknown) {
    super(message);
    this.kind = kind;
    if (raw !== undefined) Object.defineProperty(this, "raw", { value: raw, enumerable: false });
  }
}

/** 网关报错头归成的固定分类（只看不记） */
export function gatewayErrorClass(header: string | null): "auth" | "quota" | "other" {
  const h = (header ?? "").toLowerCase();
  if (/quota|exhausted|limit|throttl/.test(h)) return "quota";
  if (/appcode|unauthori|forbidden|signature|auth/.test(h)) return "auth";
  return "other";
}

/** 响应体上限：正常一条记录几百字节，超过就当格式不对，不往内存里读 */
export const MAX_RESPONSE_BYTES = 256 * 1024;

// 控制字符、零宽字符、行分隔符、双向控制符
const CONTROL_CHARS = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u2028-\\u202e\\u2066-\\u2069\\ufeff]", "g");

/** 去掉控制字符和首尾空白，限长；空串当没有 */
export function cleanText(v: unknown, max: number): string | undefined {
  if (typeof v !== "string" && typeof v !== "number") return undefined;
  const s = String(v).replace(CONTROL_CHARS, "").trim();
  if (!s) return undefined;
  return [...s].slice(0, max).join("");
}

/** 一条商品最多留几张图、单个地址最长多少 */
export const MAX_IMAGE_URLS = 10;
const MAX_URL_LEN = 2048;

/**
 * 快鸟的 Image：`[{Imageurl: "http://..."}]`，没图是 `[]` 或 null。只收 http/https、能解析的地址，去重、保序、限个数。
 * 形态不对（不是数组、元素不是对象、Imageurl 不是字符串）返回 null，调用方按 format。
 * 注意：真实地址是 http、路径里带时间戳签名，可能过期（下载失败走 image_jobs 的重试，见 jobs/image-fetch.ts）。
 */
function imageUrls(v: unknown): string[] | null {
  if (v === null || v === undefined) return [];
  if (!Array.isArray(v)) return null;
  const out: string[] = [];
  for (const x of v) {
    if (!isObject(x)) return null;
    const u = x.Imageurl;
    if (u === null || u === undefined || u === "") continue;
    if (typeof u !== "string") return null;
    const s = u.replace(CONTROL_CHARS, "").trim();
    if (s.length > MAX_URL_LEN || !/^https?:\/\//i.test(s)) continue;
    try {
      new URL(s);
    } catch {
      continue;
    }
    if (!out.includes(s)) out.push(s);
    if (out.length >= MAX_IMAGE_URLS) break;
  }
  return out;
}

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const isTextOrNull = (v: unknown) => v === null || v === undefined || typeof v === "string";
/** 快鸟的业务状态是字符串（"200" / "400"），数字也认 */
const statusIs = (v: unknown, code: number) => v === code || v === String(code);

const format = (why: string, json: unknown) => new SourceError("format", `快鸟响应认不出（${why}）`, json);

/**
 * 解析快鸟响应（按 test/fixtures/kuainiao/recorded-*.json 的真实格式校准，PR #39）。真实格式是扁平的：
 *   查到：{status:"200", message:"查询成功！", Barcode, ItemName, BrandName, ItemSpecification, Image:[{Imageurl}], ...}
 *   没查到：{status:"400", message:"经查，暂无该条码相关信息。", Barcode:null, ItemName:null, Image:null, ...}
 * 判别：
 *   - status 200 且 message 含「成功」且 ItemName 清洗后非空 → found（名称 ItemName、规格 ItemSpecification、品牌 BrandName、
 *     图片 Image[].Imageurl 的列表，imageUrl = 第一张）；传了 barcode 时 Barcode 必须等于所查的码；
 *   - status 400 且 message 含「暂无」且 ItemName 为空 → not_found（调用方负缓存 7 天）；
 *   - 其余一切（别的状态码、message 对不上、字段类型不对、名称为空、条码对不上）→ 抛 format，调用方不缓存，下次重查。
 *     不把业务错误（额度、系统繁忙、参数错等）当「没查到」负缓存（PR #19 审核，§14 S08-6）。
 * format 错误的 message 只有固定文字，原始响应只放在 SourceError.raw（不进日志）。
 */
export function parseKuainiao(json: unknown, barcode?: string): SourceResult {
  if (!isObject(json)) throw format("不是对象", json);
  const { status, message, ItemName } = json;
  if (typeof message !== "string") throw format("没有 message", json);
  if (!isTextOrNull(ItemName)) throw format("ItemName 类型不对", json);
  const name = cleanText(ItemName, 200);

  if (statusIs(status, 400) && message.includes("暂无")) {
    if (name) throw format("没查到却带名称", json);
    return { kind: "not_found", raw: json };
  }
  if (!statusIs(status, 200) || !message.includes("成功")) throw format("业务状态不是成功", json);
  if (!name) throw format("没有名称", json);
  if (!isTextOrNull(json.ItemSpecification) || !isTextOrNull(json.BrandName)) throw format("字段类型不对", json);
  if (barcode !== undefined && json.Barcode !== barcode) throw format("条码对不上", json);
  const urls = imageUrls(json.Image);
  if (urls === null) throw format("Image 形态不对", json);
  const spec = cleanText(json.ItemSpecification, 100);
  const brand = cleanText(json.BrandName, 100);
  const hit: CatalogHit = {
    name,
    ...(spec ? { spec } : {}),
    ...(brand ? { brand } : {}),
    ...(urls.length ? { imageUrl: urls[0], imageUrls: urls } : {}),
  };
  return { kind: "found", hit, raw: json };
}

/** 读响应体，超过上限就中止（不信 Content-Length） */
async function readCapped(res: Response, max: number): Promise<string> {
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let n = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    n += value.byteLength;
    if (n > max) {
      await reader.cancel().catch(() => {});
      throw new SourceError("format", `响应超过 ${max} 字节`);
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export class KuainiaoClient implements BarcodeSource {
  readonly name = "kuainiao";
  private readonly appCode: string;
  private readonly endpoint: string;
  private readonly fetchFn: typeof fetch;
  constructor(o: { appCode: string; endpoint: string; fetch?: typeof fetch }) {
    if (!o.appCode) throw new Error("快鸟 AppCode 为空");
    this.appCode = o.appCode;
    this.endpoint = o.endpoint;
    this.fetchFn = o.fetch ?? fetch;
  }

  async lookup(barcode: string, signal: AbortSignal): Promise<SourceResult> {
    const u = new URL(this.endpoint);
    u.searchParams.set("Code", barcode);
    let res: Response;
    try {
      res = await this.fetchFn(u, {
        method: "GET",
        headers: { Authorization: `APPCODE ${this.appCode}`, Accept: "application/json" },
        redirect: "error",
        signal,
      });
    } catch (e) {
      if (signal.aborted) throw new SourceError("timeout", "快鸟超时");
      throw new SourceError("network", `快鸟连不上：${(e as Error).name}`);
    }
    // 云市场网关的错误（额度用完、AppCode 不对）是 4xx/5xx，原因在 X-Ca-Error-Message 头里。这个头不可信
    // （「Invalid AppCode `<码>`」会把 AppCode 原样回显），只用来归成固定分类，内容不进错误信息
    if (!res.ok) {
      await res.body?.cancel().catch(() => {});
      throw new SourceError("http", `快鸟 HTTP ${res.status}（${gatewayErrorClass(res.headers.get("x-ca-error-message"))}）`);
    }
    let text: string;
    try {
      text = await readCapped(res, MAX_RESPONSE_BYTES);
    } catch (e) {
      if (signal.aborted) throw new SourceError("timeout", "快鸟超时");
      if (e instanceof SourceError) throw e;
      throw new SourceError("network", "快鸟响应读取失败");
    }
    let json: unknown;
    try {
      json = JSON.parse(text);
    } catch {
      throw new SourceError("format", "快鸟响应不是 JSON");
    }
    return parseKuainiao(json, barcode);
  }
}

/** 按配置建外部条码库；没配 AppCode 返回 null（查不到就是「没查到」，不报错） */
export function sourceFromConfig(config: Config): BarcodeSource | null {
  return config.kuainiao.appCode ? new KuainiaoClient(config.kuainiao) : null;
}
