// 商品图：安全下载 → 校验 → 长边 200px JPEG（§0、S08）。
//
// 图片地址来自第三方条码库，下载内容一律不信：
// - 只允许 http/https、默认端口（80/443），不允许带账号口令；主机名解析出的每个地址都必须是公网地址，
//   连接就用校验过的那个地址（自定义 lookup，防 DNS 重绑定）；IP 字面量（含十进制、十六进制写法，URL 解析会规范化）同样检查。
// - 跳转自己跟（最多 3 次），每一跳重新校验。
// - 单图 ≤ 5 MB：Content-Length 超了直接拒，没有或撒谎的边读边数，超了就断；总时长有上限。
// - 不看 Content-Type 认格式：按文件头只收 JPEG / PNG / WebP / GIF（不收 SVG 等矢量和别的格式），再交给 sharp 解码；
//   sharp 限制像素总数（防解压炸弹），宽高都有上下限；输出重新编码、不带任何元数据。
import http from "node:http";
import https from "node:https";
import net from "node:net";
import dns from "node:dns";
import { createHash } from "node:crypto";
import sharp, { type Metadata } from "sharp";
import type { ObjectStore } from "./oss.ts";
import { atomicWrite, readIfExists, safeJoin } from "./oss.ts";

sharp.cache(false);
// 2C2G 的机器，缩图一次一张就够
sharp.concurrency(1);

export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export const THUMB_LONG_SIDE = 200;
/** 解码前的像素总数上限（约 5000×5000）：5 MB 的 PNG 也能声明极大的尺寸 */
export const MAX_INPUT_PIXELS = 25_000_000;
export const MIN_SIDE = 16;
export const MAX_SIDE = 8000;

export class ImageRejected extends Error {
  readonly reason: string;
  constructor(reason: string, message: string) {
    super(message);
    this.reason = reason;
  }
}

// ───────── 地址校验 ─────────

const DENY_V4 = new net.BlockList();
for (const [a, p] of [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.0.2.0", 24],
  ["192.88.99.0", 24],
  ["192.168.0.0", 16],
  ["198.18.0.0", 15],
  ["198.51.100.0", 24],
  ["203.0.113.0", 24],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4],
] as const)
  DENY_V4.addSubnet(a, p, "ipv4");

const GLOBAL_V6 = new net.BlockList();
GLOBAL_V6.addSubnet("2000::", 3, "ipv6");
const DENY_V6 = new net.BlockList();
for (const [a, p] of [
  ["2001::", 23], // IETF 协议地址（含 Teredo 2001::/32）
  ["2001:db8::", 32], // 文档
  ["2002::", 16], // 6to4，内嵌 IPv4
  ["3fff::", 20], // 文档
] as const)
  DENY_V6.addSubnet(a, p, "ipv6");

/** 是不是可以连的公网地址。IPv4 映射的 IPv6（::ffff:a.b.c.d）按里面的 IPv4 判 */
export function isPublicAddress(ip: string): boolean {
  const v = net.isIP(ip);
  if (v === 4) return !DENY_V4.check(ip, "ipv4");
  if (v === 6) {
    const lower = ip.toLowerCase();
    const mapped = /^(?:0{0,4}:){0,5}:?ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(lower) ?? /^::ffff:(\d+\.\d+\.\d+\.\d+)$/.exec(lower);
    if (mapped) return isPublicAddress(mapped[1]!);
    const hexMapped = /^::ffff:([0-9a-f]{1,4}):([0-9a-f]{1,4})$/.exec(lower);
    if (hexMapped) {
      const hi = parseInt(hexMapped[1]!, 16);
      const lo = parseInt(hexMapped[2]!, 16);
      return isPublicAddress(`${hi >> 8}.${hi & 255}.${lo >> 8}.${lo & 255}`);
    }
    return GLOBAL_V6.check(ip, "ipv6") && !DENY_V6.check(ip, "ipv6");
  }
  return false;
}

export interface FetchPolicy {
  /** 地址能不能连（默认 isPublicAddress；测试里放行本机的假图床） */
  allowAddress: (ip: string) => boolean;
  /** 允许的端口（默认 80、443） */
  allowPorts: readonly number[];
  /** 主机名 → 地址（默认系统 DNS） */
  resolve: (host: string) => Promise<{ address: string; family: number }[]>;
  maxBytes: number;
  timeoutMs: number;
  maxRedirects: number;
}

export const DEFAULT_FETCH_POLICY: FetchPolicy = {
  allowAddress: isPublicAddress,
  allowPorts: [80, 443],
  resolve: (host) => dns.promises.lookup(host, { all: true, verbatim: true }),
  maxBytes: MAX_IMAGE_BYTES,
  timeoutMs: 8000,
  maxRedirects: 3,
};

/** 检查图片地址本身（协议、口令、端口、IP 字面量）。通过后返回规范化的 URL */
export function checkImageUrl(raw: string, policy: Pick<FetchPolicy, "allowAddress" | "allowPorts">): URL {
  if (typeof raw !== "string" || raw.length > 2048) throw new ImageRejected("bad_url", "图片地址太长或不是字符串");
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw new ImageRejected("bad_url", "图片地址不合法");
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") throw new ImageRejected("bad_scheme", "只允许 http/https");
  if (u.username || u.password) throw new ImageRejected("bad_url", "图片地址不能带账号口令");
  const port = u.port ? Number(u.port) : u.protocol === "https:" ? 443 : 80;
  if (!policy.allowPorts.includes(port)) throw new ImageRejected("bad_port", `不允许的端口 ${port}`);
  const host = u.hostname.replace(/^\[|\]$/g, "");
  if (!host) throw new ImageRejected("bad_url", "没有主机名");
  if (net.isIP(host) && !policy.allowAddress(host)) throw new ImageRejected("private_address", "图片地址指向内网");
  return u;
}

type LookupCb = (err: NodeJS.ErrnoException | null, address: string | { address: string; family: number }[], family?: number) => void;

/** 给 http(s).request 用的 lookup：解析出的地址全部是允许的才放行，连接用的就是校验过的地址 */
function guardedLookup(policy: FetchPolicy) {
  return (hostname: string, options: { all?: boolean } | number, cb: LookupCb) => {
    policy.resolve(hostname).then(
      (addrs) => {
        if (addrs.length === 0) return cb(Object.assign(new Error("解析不到地址"), { code: "ENOTFOUND" }), "", 0);
        const bad = addrs.find((a) => !policy.allowAddress(a.address));
        if (bad) return cb(new ImageRejected("private_address", "图片地址解析到内网") as NodeJS.ErrnoException, "", 0);
        if (typeof options === "object" && options.all) return cb(null, addrs);
        cb(null, addrs[0]!.address, addrs[0]!.family);
      },
      (e: NodeJS.ErrnoException) => cb(e, "", 0),
    );
  };
}

/** 下载一张图（只做网络层的限制；格式校验在 makeThumbnail） */
export async function fetchImage(raw: string, policy: FetchPolicy = DEFAULT_FETCH_POLICY): Promise<Buffer> {
  const deadline = Date.now() + policy.timeoutMs;
  let url = checkImageUrl(raw, policy);
  for (let hop = 0; ; hop++) {
    const r = await getOnce(url, policy, deadline);
    if (r.kind === "body") return r.body;
    if (hop >= policy.maxRedirects) throw new ImageRejected("too_many_redirects", "跳转太多");
    let next: URL;
    try {
      next = new URL(r.location, url);
    } catch {
      throw new ImageRejected("bad_url", "跳转地址不合法");
    }
    url = checkImageUrl(next.toString(), policy);
  }
}

function getOnce(url: URL, policy: FetchPolicy, deadline: number): Promise<{ kind: "body"; body: Buffer } | { kind: "redirect"; location: string }> {
  return new Promise((resolve, reject) => {
    const left = deadline - Date.now();
    if (left <= 0) return reject(new ImageRejected("timeout", "下载超时"));
    const mod = url.protocol === "https:" ? https : http;
    let settled = false;
    const fail = (e: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      req.destroy();
      reject(e);
    };
    const req = mod.request(
      url,
      {
        method: "GET",
        headers: { Accept: "image/jpeg,image/png,image/webp,image/gif", "User-Agent": "yuanhui-image-fetch/1" },
        lookup: guardedLookup(policy) as never,
        agent: false,
        // 不走「同时试多个地址族」，连接只用 lookup 返回的那一个地址
        ...({ autoSelectFamily: false } as object),
      },
      (res) => {
        const status = res.statusCode ?? 0;
        if ([301, 302, 303, 307, 308].includes(status)) {
          const loc = res.headers.location;
          res.resume();
          if (!loc) return fail(new ImageRejected("bad_status", `跳转没有地址`));
          settled = true;
          clearTimeout(timer);
          req.destroy();
          return resolve({ kind: "redirect", location: loc });
        }
        if (status !== 200) {
          res.resume();
          return fail(new ImageRejected("bad_status", `HTTP ${status}`));
        }
        const ct = String(res.headers["content-type"] ?? "").toLowerCase();
        if (ct && !ct.startsWith("image/") && !ct.startsWith("application/octet-stream")) {
          res.resume();
          return fail(new ImageRejected("bad_type", "不是图片"));
        }
        const declared = Number(res.headers["content-length"]);
        if (Number.isFinite(declared) && declared > policy.maxBytes) return fail(new ImageRejected("too_large", "图片超过 5 MB"));
        const chunks: Buffer[] = [];
        let n = 0;
        res.on("data", (c: Buffer) => {
          n += c.length;
          if (n > policy.maxBytes) return fail(new ImageRejected("too_large", "图片超过 5 MB"));
          chunks.push(c);
        });
        res.on("end", () => {
          if (settled) return;
          settled = true;
          clearTimeout(timer);
          resolve({ kind: "body", body: Buffer.concat(chunks) });
        });
        res.on("error", (e) => fail(e));
      },
    );
    const timer = setTimeout(() => fail(new ImageRejected("timeout", "下载超时")), left);
    req.on("error", (e) => fail(e instanceof ImageRejected ? e : new ImageRejected("network", `下载失败：${(e as NodeJS.ErrnoException).code ?? e.name}`)));
    req.end();
  });
}

// ───────── 格式校验与缩图 ─────────

/** 按文件头认格式；认不出的（SVG、BMP、TIFF、HEIC、HTML……）返回 null */
export function sniffFormat(b: Buffer): "jpeg" | "png" | "webp" | "gif" | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "jpeg";
  if (b.length >= 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "png";
  if (b.length >= 12 && b.toString("latin1", 0, 4) === "RIFF" && b.toString("latin1", 8, 12) === "WEBP") return "webp";
  if (b.length >= 6 && (b.toString("latin1", 0, 6) === "GIF87a" || b.toString("latin1", 0, 6) === "GIF89a")) return "gif";
  return null;
}

/** 长边 200px 的 JPEG（不放大小图；透明底垫白；按 EXIF 转正后丢掉全部元数据） */
export async function makeThumbnail(input: Buffer): Promise<Buffer> {
  if (input.length === 0) throw new ImageRejected("empty", "空文件");
  if (input.length > MAX_IMAGE_BYTES) throw new ImageRejected("too_large", "图片超过 5 MB");
  const fmt = sniffFormat(input);
  if (!fmt) throw new ImageRejected("bad_format", "只收 JPEG / PNG / WebP / GIF");
  const opts = { limitInputPixels: MAX_INPUT_PIXELS, failOn: "error", animated: false } as const;
  let meta: Metadata;
  try {
    // metadata 只读文件头、不解码像素，所以这里不设像素上限，先拿到声明的尺寸自己判（解码时再由 limitInputPixels 兜底）
    meta = await sharp(input, { ...opts, limitInputPixels: false }).metadata();
  } catch {
    throw new ImageRejected("bad_format", "图片解不开");
  }
  if (meta.format !== fmt && !(fmt === "jpeg" && meta.format === "jpeg")) throw new ImageRejected("bad_format", "文件头和内容对不上");
  const w = meta.width ?? 0;
  const h = meta.pageHeight ?? meta.height ?? 0;
  if (w < MIN_SIDE || h < MIN_SIDE) throw new ImageRejected("too_small", `图片太小（${w}×${h}）`);
  if (w > MAX_SIDE || h > MAX_SIDE || w * h > MAX_INPUT_PIXELS) throw new ImageRejected("too_big_dimensions", `图片尺寸太大（${w}×${h}）`);
  try {
    return await sharp(input, opts)
      .rotate()
      .resize({ width: THUMB_LONG_SIDE, height: THUMB_LONG_SIDE, fit: "inside", withoutEnlargement: true })
      .flatten({ background: "#ffffff" })
      .jpeg({ quality: 80, mozjpeg: true })
      .toBuffer();
  } catch {
    throw new ImageRejected("bad_format", "图片解不开");
  }
}

export const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

// ───────── 给 GET /v1/images 用：本机磁盘缓存，缺了回源对象存储 ─────────

export class ImageCache {
  private readonly dir: string;
  private readonly store: ObjectStore | null;
  private readonly inflight = new Map<string, Promise<Buffer | null>>();
  constructor(dir: string, store: ObjectStore | null) {
    this.dir = dir;
    this.store = store;
  }

  async get(key: string): Promise<Buffer | null> {
    const file = safeJoin(this.dir, key);
    const local = await readIfExists(file);
    if (local) return local;
    if (!this.store) return null;
    let p = this.inflight.get(key);
    if (!p) {
      const store = this.store;
      p = (async () => {
        const body = await store.get(key);
        if (body) await atomicWrite(file, body).catch(() => {}); // 磁盘写不进去也照样返回
        return body;
      })().finally(() => this.inflight.delete(key));
      this.inflight.set(key, p);
    }
    return p;
  }
}
