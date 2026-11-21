// 快鸟条码接口客户端（阿里云云市场 cmapi00067757，§0、§7）。
//
// - 只有服务器调，AppCode 只从环境变量来（config.kuainiao.appCode），不进仓库、不进日志、不进错误信息。
// - 请求：GET <endpoint>?Code=<条码>，请求头 `Authorization: APPCODE <AppCode>`（旧计划 design/plan.md 记下的格式）。
// - 响应格式没有实测过（S08 不调真实付费接口）。名称、规格等按「字段名候选表」认，测试用 test/fixtures/kuainiao/ 里的手写样例。
//   往安全的方向收（PR #19 审核，§14 S08-6）：业务状态不是明确的成功、或认不出名称，一律抛 format（调用方不写缓存），
//   不当「没查到」。所以真实接口上查不到的条码每次都会重查，有每日额度兜着。「成功」「明确没查到」各凭哪个字段认，
//   由 T9（S10a）用 scripts/barcode-trial.ts --record 录到的真实响应定下，再收紧候选表、加上「没查到」的负缓存。
// - 网关报错头 X-Ca-Error-Message 不可信（可能回显 AppCode），只拿来归成固定分类，内容不进错误信息、不进日志。
// - 外部服务做成接口（BarcodeSource），测试和演示店都不碰真实接口。
import type { Config } from "../config.ts";

export interface CatalogHit {
  name: string;
  spec?: string;
  brand?: string;
  imageUrl?: string;
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

const NAME_KEYS = ["goodsName", "goods_name", "name", "productName", "product_name", "title"];
const SPEC_KEYS = ["spec", "specification", "guige", "standard", "model"];
const BRAND_KEYS = ["brand", "trademark", "brandName", "brand_name"];
const IMAGE_KEYS = ["img", "image", "imgurl", "imgUrl", "image_url", "imageUrl", "picture", "pic", "picUrl", "images"];
const BODY_KEYS = ["data", "result", "showapi_res_body", "body", "goods", "info"];
/** 顶层的业务状态字段和算「成功」的值。至少要有一个、并且出现的都是成功值，才往下认名称 */
const STATUS_KEYS = ["code", "status", "showapi_res_code", "ret_code", "error_code", "errcode", "errCode", "resultcode", "result_code"];
const SUCCESS_VALUES = new Set(["0", "200", "ok", "success"]);
/** 嵌套体里的业务状态字段（嵌套体里的 code 常常是条码本身，不算状态） */
const NESTED_STATUS_KEYS = ["ret_code", "showapi_res_code", "error_code", "errcode"];

// 控制字符、零宽字符、行分隔符、双向控制符
const CONTROL_CHARS = new RegExp("[\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u2028-\\u202e\\u2066-\\u2069\\ufeff]", "g");

/** 去掉控制字符和首尾空白，限长；空串当没有 */
export function cleanText(v: unknown, max: number): string | undefined {
  if (typeof v !== "string" && typeof v !== "number") return undefined;
  const s = String(v).replace(CONTROL_CHARS, "").trim();
  if (!s) return undefined;
  return [...s].slice(0, max).join("");
}

function firstImage(v: unknown): string | undefined {
  const pick = (x: unknown): string | undefined => {
    if (typeof x !== "string") return undefined;
    for (const part of x.split(/[,;\s]+/)) if (/^https?:\/\//i.test(part) && part.length <= 2048) return part;
    return undefined;
  };
  if (Array.isArray(v)) {
    for (const x of v) {
      const u = pick(x);
      if (u) return u;
    }
    return undefined;
  }
  return pick(v);
}

function pickKey(o: Record<string, unknown>, keys: string[]): unknown {
  for (const k of keys) if (o[k] !== undefined && o[k] !== null && o[k] !== "") return o[k];
  return undefined;
}

function statusOk(v: unknown): boolean {
  return (typeof v === "string" || typeof v === "number") && SUCCESS_VALUES.has(String(v).trim().toLowerCase());
}

/**
 * 从快鸟的 JSON 里认出名称、规格、品牌、图片。
 * 业务状态不是明确的成功、或认不出名称 → 抛 SourceError("format")，不返回 not_found（见文件头；T9 定下判别字段前不做负缓存）。
 */
export function parseKuainiao(json: unknown): SourceResult {
  const bad = (why: string) => new SourceError("format", `快鸟响应认不出（${why}）`, json);
  if (json === null || typeof json !== "object" || Array.isArray(json)) throw bad("不是对象");
  const top = json as Record<string, unknown>;
  const statuses = STATUS_KEYS.filter((k) => top[k] !== undefined && top[k] !== null && top[k] !== "");
  if (statuses.length === 0) throw bad("没有业务状态");
  if (!statuses.every((k) => statusOk(top[k]))) throw bad("业务状态不是成功");
  if (top.success === false) throw bad("业务状态不是成功");
  const candidates: Record<string, unknown>[] = [];
  const visit = (v: unknown, depth: number) => {
    if (depth > 3 || v === null || typeof v !== "object") return;
    if (Array.isArray(v)) {
      if (v.length > 0) visit(v[0], depth + 1);
      return;
    }
    const o = v as Record<string, unknown>;
    candidates.push(o);
    for (const k of BODY_KEYS) if (o[k] !== undefined) visit(o[k], depth + 1);
  };
  visit(json, 0);
  for (const o of candidates.slice(1)) for (const k of NESTED_STATUS_KEYS) if (o[k] !== undefined && o[k] !== null && !statusOk(o[k])) throw bad("业务状态不是成功");
  for (const o of candidates) {
    const name = cleanText(pickKey(o, NAME_KEYS), 200);
    if (!name) continue;
    const spec = cleanText(pickKey(o, SPEC_KEYS), 100);
    const brand = cleanText(pickKey(o, BRAND_KEYS), 100);
    const imageUrl = firstImage(pickKey(o, IMAGE_KEYS));
    return {
      kind: "found",
      hit: { name, ...(spec ? { spec } : {}), ...(brand ? { brand } : {}), ...(imageUrl ? { imageUrl } : {}) },
      raw: json,
    };
  }
  throw bad("没有名称");
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
    return parseKuainiao(json);
  }
}

/** 按配置建外部条码库；没配 AppCode 返回 null（查不到就是「没查到」，不报错） */
export function sourceFromConfig(config: Config): BarcodeSource | null {
  return config.kuainiao.appCode ? new KuainiaoClient(config.kuainiao) : null;
}
