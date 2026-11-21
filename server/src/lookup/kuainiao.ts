// 快鸟条码接口客户端（阿里云云市场 cmapi00067757，§0、§7）。
//
// - 只有服务器调，AppCode 只从环境变量来（config.kuainiao.appCode），不进仓库、不进日志、不进错误信息。
// - 请求：GET <endpoint>?Code=<条码>，请求头 `Authorization: APPCODE <AppCode>`（旧计划 design/plan.md 记下的格式）。
// - 响应格式没有实测过（S08 不调真实付费接口）。名称、规格等按下面的成功形态白名单认，测试用 test/fixtures/kuainiao/ 里的手写样例。
//   往安全的方向收（PR #19 审核，§14 S08-6）：用成功形态白名单（SUCCESS_SHAPES），响应不严格匹配其中一种就抛 format
//   （调用方不写缓存），不当「没查到」。所以真实接口上查不到的条码每次都会重查，有每日额度兜着。「成功」「明确没查到」各凭哪个字段认，
//   由 T9（S10a）用 scripts/barcode-trial.ts --record 录到的真实响应定下，再校准白名单、加上「没查到」的负缓存。
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

/**
 * 成功形态白名单（PR #19 第二轮审核）。快鸟的真实格式没核对过，这里只收手写样例（test/fixtures/kuainiao/found*.json）
 * 的三种形态，而且是**严格匹配**：顶层和嵌套体的键必须都在列表里（多一个、少一个必需键都不行），
 * 成功码只认 0 / "0"，msg 只认几个固定的成功文字，商品字段只能是字符串（价格可以是数字）。
 * 其余一切形态（含未知字段组合、嵌套里的 status / success / errCode / error 等）一律 format，调用方不写缓存。
 * 待 T9（S10a）用真实录制件校准：成功形态只留实际出现的那一种，错误响应都补成「不是商品」的测试。
 */
interface SuccessShape {
  /** 顶层：成功码字段 → 必须是成功码 */
  topCodes: string[];
  /** 顶层可选的文字字段：出现就必须是成功文字（showapi_res_error 必须是空串） */
  topMsg?: string;
  topEmptyError?: string;
  /** 嵌套体所在的键 */
  body: string;
  /** 嵌套体里的成功码字段（必须有，必须是成功码） */
  bodyCodes: string[];
  /** 嵌套体里的商品字段 */
  name: string;
  spec?: string;
  brand?: string;
  image?: string;
  /** 嵌套体里允许出现、但不用的字段（值必须是字符串，条码字段必须像条码） */
  barcodeKey?: string;
  ignored: string[];
}
const SUCCESS_SHAPES: SuccessShape[] = [
  // found.json：{code:"0", msg, data:{code:<条码>, goodsName, spec, trademark, img, manuName, price}}
  { topCodes: ["code"], topMsg: "msg", body: "data", bodyCodes: [], name: "goodsName", spec: "spec", brand: "trademark", image: "img", barcodeKey: "code", ignored: ["manuName", "price"] },
  // found-no-image.json：{status:0, msg, result:{barcode, name, specification, brand, images}}
  { topCodes: ["status"], topMsg: "msg", body: "result", bodyCodes: [], name: "name", spec: "specification", brand: "brand", image: "images", barcodeKey: "barcode", ignored: [] },
  // found-image-list.json：{showapi_res_code:0, showapi_res_error:"", showapi_res_body:{ret_code:0, goodsName, spec, trademark, img, imgList, manuName, price, code}}
  {
    topCodes: ["showapi_res_code"],
    topEmptyError: "showapi_res_error",
    body: "showapi_res_body",
    bodyCodes: ["ret_code"],
    name: "goodsName",
    spec: "spec",
    brand: "trademark",
    image: "img",
    barcodeKey: "code",
    ignored: ["imgList", "manuName", "price"],
  },
];
const SUCCESS_MSGS = new Set(["ok", "success", "成功", "查询成功"]);

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

const isObject = (v: unknown): v is Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v);
const isSuccessCode = (v: unknown) => v === 0 || v === "0";
const isText = (v: unknown) => typeof v === "string";

/** 严格匹配一种成功形态；匹配不上返回 null（不说为什么，调用方统一按 format） */
function matchShape(top: Record<string, unknown>, sh: SuccessShape): CatalogHit | null {
  const topAllowed = new Set([...sh.topCodes, sh.body, ...(sh.topMsg ? [sh.topMsg] : []), ...(sh.topEmptyError ? [sh.topEmptyError] : [])]);
  if (!Object.keys(top).every((k) => topAllowed.has(k))) return null;
  if (!sh.topCodes.every((k) => isSuccessCode(top[k]))) return null;
  if (sh.topMsg && sh.topMsg in top && !(isText(top[sh.topMsg]) && SUCCESS_MSGS.has(String(top[sh.topMsg]).trim().toLowerCase()))) return null;
  if (sh.topEmptyError && sh.topEmptyError in top && top[sh.topEmptyError] !== "") return null;
  const body = top[sh.body];
  if (!isObject(body)) return null;
  const fields = [sh.name, sh.spec, sh.brand, sh.image].filter((k): k is string => !!k);
  const bodyAllowed = new Set([...sh.bodyCodes, ...fields, ...(sh.barcodeKey ? [sh.barcodeKey] : []), ...sh.ignored]);
  if (!Object.keys(body).every((k) => bodyAllowed.has(k))) return null;
  if (!sh.bodyCodes.every((k) => isSuccessCode(body[k]))) return null;
  // 文字字段只能是字符串（价格可以是数字）；图片字段可以是字符串数组
  for (const k of [sh.name, sh.spec, sh.brand, ...sh.ignored].filter((k): k is string => !!k)) {
    if (!(k in body)) continue;
    const v = body[k];
    if (!(isText(v) || (k === "price" && typeof v === "number" && Number.isFinite(v)))) return null;
  }
  if (sh.image && sh.image in body) {
    const v = body[sh.image];
    if (!(isText(v) || (Array.isArray(v) && v.every(isText)))) return null;
  }
  if (sh.barcodeKey && sh.barcodeKey in body) {
    const v = body[sh.barcodeKey];
    if (!(isText(v) && /^\d{6,14}$/.test(v))) return null;
  }
  const name = cleanText(body[sh.name], 200);
  if (!name) return null;
  const spec = sh.spec ? cleanText(body[sh.spec], 100) : undefined;
  const brand = sh.brand ? cleanText(body[sh.brand], 100) : undefined;
  const imageUrl = sh.image ? firstImage(body[sh.image]) : undefined;
  return { name, ...(spec ? { spec } : {}), ...(brand ? { brand } : {}), ...(imageUrl ? { imageUrl } : {}) };
}

/**
 * 从快鸟的 JSON 里认出名称、规格、品牌、图片：只有严格匹配 SUCCESS_SHAPES 里某一种的才是商品。
 * 其余一切 → 抛 SourceError("format")（原始响应放 raw，不进 message），不返回 not_found（见文件头；T9 定下判别字段前不做负缓存）。
 */
export function parseKuainiao(json: unknown): SourceResult {
  if (isObject(json)) {
    for (const sh of SUCCESS_SHAPES) {
      const hit = matchShape(json, sh);
      if (hit) return { kind: "found", hit, raw: json };
    }
  }
  throw new SourceError("format", "快鸟响应认不出（不是已知的成功形态）", json);
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
