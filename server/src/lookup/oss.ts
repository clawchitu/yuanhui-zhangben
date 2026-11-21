// 对象存储（商品小图放这里，§0「服务器下载 → 压成长边 200px → 存 OSS」）。
//
// 做成接口：测试用内存实现，本机开发用目录实现，生产用阿里云 OSS（S10a 填凭据接上，本段不连真实 OSS）。
// 键只由服务器生成（imageKey、exportKey、deletionKey），读写前都校验格式，不接受外部传来的路径（防路径穿越）。
// 三种前缀（S09）：images/<店>/…（商品图）、exports/<店>/…（注销导出包）、deletions/<店>.json（删除记录，不随备份回滚，§9.4）。
// 按店列举和删除只接受 images/<店>/、exports/<店>/ 两种前缀：一次调用只可能碰到一家店的对象。
import { mkdir, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import path from "node:path";
import type { Config } from "../config.ts";

export interface ObjectStore {
  put(key: string, body: Buffer, contentType: string): Promise<void>;
  /** 没有这个键返回 null */
  get(key: string): Promise<Buffer | null>;
  /** 列出一家店某个前缀下的全部键（prefix 只能是 storePrefix 给的） */
  list(prefix: string): Promise<string[]>;
  /** 删一个键；本来就没有也算成功 */
  delete(key: string): Promise<void>;
}

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const KEY_RE = new RegExp(`^images/${UUID}/${UUID}/[1-9][0-9]{0,9}-[0-9a-f]{16}\\.jpg$`);
const EXPORT_RE = new RegExp(`^exports/${UUID}/[0-9]{13}-[0-9a-f]{16}\\.zip$`);
const DELETION_RE = new RegExp(`^deletions/${UUID}\\.json$`);
const PREFIX_RE = new RegExp(`^(images|exports)/${UUID}/$`);
const UUID_RE = new RegExp(`^${UUID}$`);

/** 注销导出包的键：exports/<店>/<申请时间毫秒>-<随机 16 位>.zip（随机部分让键猜不出来） */
export function exportKey(storeId: string, requestedAt: Date, rand16hex: string): string {
  const k = `exports/${storeId.toLowerCase()}/${String(requestedAt.getTime()).padStart(13, "0")}-${rand16hex}.zip`;
  assertKey(k);
  return k;
}

/** 删除记录的键：deletions/<店>.json */
export function deletionKey(storeId: string): string {
  const k = `deletions/${storeId.toLowerCase()}.json`;
  assertKey(k);
  return k;
}

/** 一家店的对象前缀：images/<店>/ 或 exports/<店>/ */
export function storePrefix(kind: "images" | "exports", storeId: string): string {
  const id = storeId.toLowerCase();
  if (!UUID_RE.test(id)) throw new Error("店 id 格式不对");
  return `${kind}/${id}/`;
}

/** 任何一种合法的对象键 */
export function isObjectKey(k: string): boolean {
  return KEY_RE.test(k) || EXPORT_RE.test(k) || DELETION_RE.test(k);
}

export function assertKey(k: string): void {
  if (!isObjectKey(k)) throw new Error("对象键格式不对");
}

export function assertStorePrefix(p: string): void {
  if (!PREFIX_RE.test(p)) throw new Error("前缀格式不对：只能是 images/<店>/ 或 exports/<店>/");
}

/** 商品图的键：images/<店>/<商品>/<image_ver>-<内容哈希前 16 位>.jpg */
export function imageKey(storeId: string, productId: string, ver: number, sha256Hex: string): string {
  const k = `images/${storeId.toLowerCase()}/${productId.toLowerCase()}/${ver}-${sha256Hex.slice(0, 16)}.jpg`;
  assertImageKey(k);
  return k;
}

export function isImageKey(k: string): boolean {
  return KEY_RE.test(k);
}

export function assertImageKey(k: string): void {
  if (!isImageKey(k)) throw new Error("对象键格式不对");
}

export class MemoryObjectStore implements ObjectStore {
  readonly objects = new Map<string, { body: Buffer; contentType: string }>();
  async put(key: string, body: Buffer, contentType: string) {
    assertKey(key);
    this.objects.set(key, { body: Buffer.from(body), contentType });
  }
  async get(key: string) {
    assertKey(key);
    return this.objects.get(key)?.body ?? null;
  }
  async list(prefix: string) {
    assertStorePrefix(prefix);
    return [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
  }
  async delete(key: string) {
    assertKey(key);
    this.objects.delete(key);
  }
}

/** 键 → 目录下的文件。键已校验过格式；再确认拼出来的路径没有跑出根目录 */
export function safeJoin(root: string, key: string): string {
  assertKey(key);
  const base = path.resolve(root);
  const p = path.resolve(base, ...key.split("/"));
  if (!p.startsWith(base + path.sep)) throw new Error("路径越界");
  return p;
}

/** 原子写：先写临时文件再改名，读的一方不会看到写了一半的图 */
export async function atomicWrite(file: string, body: Buffer): Promise<void> {
  await mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${randomBytes(6).toString("hex")}.tmp`;
  await writeFile(tmp, body, { mode: 0o640 });
  await rename(tmp, file);
}

export async function readIfExists(file: string): Promise<Buffer | null> {
  try {
    return await readFile(file);
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "ENOENT") return null;
    throw e;
  }
}

/** 本机目录（开发、测试用；也是 GET /v1/images 磁盘缓存的同一套写法） */
export class LocalDirObjectStore implements ObjectStore {
  readonly root: string;
  constructor(root: string) {
    this.root = root;
  }
  async put(key: string, body: Buffer, _contentType?: string) {
    await atomicWrite(safeJoin(this.root, key), body);
  }
  async get(key: string) {
    return readIfExists(safeJoin(this.root, key));
  }
  async list(prefix: string) {
    assertStorePrefix(prefix);
    const dir = path.resolve(this.root, ...prefix.split("/").filter(Boolean));
    let names: string[];
    try {
      names = (await readdir(dir, { recursive: true, withFileTypes: true }))
        .filter((e) => e.isFile())
        .map((e) => path.relative(path.resolve(this.root), path.join(e.parentPath, e.name)).split(path.sep).join("/"));
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw e;
    }
    return names.filter(isObjectKey).sort();
  }
  async delete(key: string) {
    await rm(safeJoin(this.root, key), { force: true });
  }
}

/**
 * 删掉本机目录里一家店的整棵子树（GET /v1/images 的磁盘缓存，§14 T12）。路径由校验过的前缀拼出，再确认没跑出根目录。
 */
export async function removeStoreDir(root: string, kind: "images" | "exports", storeId: string): Promise<void> {
  const prefix = storePrefix(kind, storeId);
  const base = path.resolve(root);
  const dir = path.resolve(base, ...prefix.split("/").filter(Boolean));
  if (!dir.startsWith(base + path.sep)) throw new Error("路径越界");
  await rm(dir, { recursive: true, force: true });
}

/** 阿里云 OSS。ali-oss 按需加载（测试不加载）。凭据只从环境变量来（config.objectStore），S10a 接 */
export class AliOssObjectStore implements ObjectStore {
  private client: Promise<{
    put(name: string, file: Buffer, o: { headers: Record<string, string> }): Promise<unknown>;
    get(name: string): Promise<{ content: Buffer }>;
    list(q: { prefix: string; marker?: string; "max-keys": number }, o: object): Promise<{ objects?: Array<{ name: string }>; nextMarker?: string | null; isTruncated?: boolean }>;
    delete(name: string): Promise<unknown>;
  }>;
  constructor(c: Extract<Config["objectStore"], { kind: "aliyun" }>) {
    this.client = import("ali-oss").then(
      (m) =>
        new m.default({
          region: c.region,
          bucket: c.bucket,
          accessKeyId: c.accessKeyId,
          accessKeySecret: c.accessKeySecret,
          secure: true,
          timeout: 10_000,
          ...(c.endpoint ? { endpoint: c.endpoint } : {}),
        }) as never,
    );
  }
  async put(key: string, body: Buffer, contentType: string) {
    assertKey(key);
    await (await this.client).put(key, body, { headers: { "Content-Type": contentType, "x-oss-forbid-overwrite": "false" } });
  }
  async get(key: string) {
    assertKey(key);
    try {
      return (await (await this.client).get(key)).content;
    } catch (e) {
      if ((e as { code?: string }).code === "NoSuchKey") return null;
      throw e;
    }
  }
  /** 按前缀分页列举（每页 1000 个，跟着 nextMarker 走到底）。S10a 接真实 OSS 时实测一次（§14 T9 ⑤） */
  async list(prefix: string) {
    assertStorePrefix(prefix);
    const c = await this.client;
    const out: string[] = [];
    let marker: string | undefined;
    for (;;) {
      const r = await c.list({ prefix, "max-keys": 1000, ...(marker ? { marker } : {}) }, {});
      for (const o of r.objects ?? []) if (o.name.startsWith(prefix)) out.push(o.name);
      if (!r.isTruncated || !r.nextMarker) break;
      marker = r.nextMarker;
    }
    return out;
  }
  async delete(key: string) {
    assertKey(key);
    try {
      await (await this.client).delete(key);
    } catch (e) {
      if ((e as { code?: string }).code === "NoSuchKey") return;
      throw e;
    }
  }
}

export function objectStoreFromConfig(config: Config): ObjectStore | null {
  const c = config.objectStore;
  if (c.kind === "none") return null;
  if (c.kind === "local") return new LocalDirObjectStore(c.dir);
  return new AliOssObjectStore(c);
}
