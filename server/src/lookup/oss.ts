// 对象存储（商品小图放这里，§0「服务器下载 → 压成长边 200px → 存 OSS」）。
//
// 做成接口：测试用内存实现，本机开发用目录实现，生产用阿里云 OSS（S10a 填凭据接上，本段不连真实 OSS）。
// 键只由服务器生成（imageKey、exportKey、deletionKey），读写前都校验格式，不接受外部传来的路径（防路径穿越）。
// 三种前缀（S09）：images/<店>/…（商品图）、exports/<店>/…（注销导出包）、deletions/<店>.json（删除记录，不随备份回滚，§9.4）。
// 按店列举和删除只接受 images/<店>/、exports/<店>/ 两种前缀：一次调用只可能碰到一家店的对象。
// S10b 加了备份用的键（只在存档桶 yuanhui-backup，由备份专用的 RAM 账号读写，§14 T21）：
//   backups/<UTC 时间>-<随机 16 位>.dump.enc / .manifest.enc（加密的 pg_dump 和清单，35 天生命周期只作用于 backups/）、
//   heartbeat/backup.json（心跳，不加密、不含业务数据）。
// 另外两个整前缀只许列举（§14 T14）：deletions/（restore 重放删除记录）、backups/（找最新的备份、看生命周期有没有生效）。
// S22d：商品图候选 images/_catalog/<条码 sha256 前 32 位>/<候选 id>.jpg（全局、不分店，与 barcode_catalog 同寿）。
//   仍在 images/ 下（RAM 权限不用改）；整前缀 images/_catalog/ 只给每周的孤儿清扫列举。店前缀 images/<店>/ 是 UUID，碰不到它。
import { createReadStream, createWriteStream } from "node:fs";
import { mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { pipeline } from "node:stream/promises";
import { randomBytes } from "node:crypto";
import path from "node:path";
import type { Config } from "../config.ts";

export interface ObjectStore {
  put(key: string, body: Buffer, contentType: string): Promise<void>;
  /**
   * 把本机一个文件传上去，边读边传（导出包用，PR #20 Codex 5）：不把整个文件读进内存。
   * 阿里云走分片上传（每片 1 MiB、同时 2 片），内存里最多两片。
   */
  putFile(key: string, file: string, contentType: string): Promise<void>;
  /** 没有这个键返回 null */
  get(key: string): Promise<Buffer | null>;
  /** 列出一家店某个前缀下的全部键（prefix 只能是 storePrefix 给的） */
  list(prefix: string): Promise<string[]>;
  /** 删一个键；本来就没有也算成功 */
  delete(key: string): Promise<void>;
  /**
   * 列出一家店某个前缀下还没完成的分片上传（PR #20 Codex 第二轮 3）：传到一半失败、中止也失败留下的残片，
   * delete(key) 删不掉它们，复扫时按前缀列出来逐个中止。prefix 只能是 storePrefix 给的。没有分片上传的实现返回空
   */
  listUploads(prefix: string): Promise<PendingUpload[]>;
  /** 中止一个分片上传、丢掉它已传的片；本来就没有也算成功 */
  abortUpload(key: string, uploadId: string): Promise<void>;
  /**
   * 列举并带上最后修改时间（S22d 候选孤儿清扫：只删落地超过 1 小时的）。prefix 规则同 list。
   * 可选：没实现的（备份用的 SplitBackupStore 等）不参加清扫
   */
  listWithTimes?(prefix: string): Promise<Array<{ key: string; modifiedAt: Date }>>;
}

/** 一个还没完成的分片上传 */
export interface PendingUpload {
  key: string;
  uploadId: string;
}

/** putFile 失败、并且没能中止那次分片上传时，错误上带着它（调用方记待删标记、之后重试中止） */
export function pendingUploadOf(e: unknown): PendingUpload | null {
  const p = (e as { pendingUpload?: unknown } | null)?.pendingUpload as PendingUpload | undefined;
  return p && typeof p.key === "string" && typeof p.uploadId === "string" && isObjectKey(p.key) ? { key: p.key, uploadId: p.uploadId } : null;
}

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
// 商品图键；S22d 起选图 / 拍照的键多一段每次请求独有的随机后缀（任何两路请求不共用键）
const KEY_RE = new RegExp(`^images/${UUID}/${UUID}/[1-9][0-9]{0,9}-[0-9a-f]{16}(?:-[0-9a-f]{16})?\\.jpg$`);
const EXPORT_RE = new RegExp(`^exports/${UUID}/[0-9]{13}-[0-9a-f]{16}\\.zip$`);
const DELETION_RE = new RegExp(`^deletions/${UUID}\\.json$`);
const BACKUP_RE = /^backups\/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{16}\.(dump|manifest)\.enc$/;
const HEARTBEAT_KEY = "heartbeat/backup.json";
const CANDIDATE_RE = /^images\/_catalog\/[0-9a-f]{32}\/[0-9a-f]{16}\.jpg$/;
const PREFIX_RE = new RegExp(`^(?:(images|exports)/${UUID}/|deletions/|backups/|images/_catalog/)$`);
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

/** 商品图候选的整前缀（每周孤儿清扫列举用） */
export const CANDIDATES_PREFIX = "images/_catalog/";

/** 商品图候选的键：images/_catalog/<sha256(条码) 前 32 位>/<候选 id>.jpg；候选 id 是缩图 sha256 前 16 位 */
export function candidateKey(barcodeSha256Hex: string, cid: string): string {
  const k = `${CANDIDATES_PREFIX}${barcodeSha256Hex.slice(0, 32)}/${cid}.jpg`;
  if (!CANDIDATE_RE.test(k)) throw new Error("对象键格式不对");
  return k;
}

export function isCandidateKey(k: string): boolean {
  return CANDIDATE_RE.test(k);
}

/** 列举全部删除记录（restore 重放用，§14 T14）、全部备份 */
export const DELETIONS_PREFIX = "deletions/";
export const BACKUPS_PREFIX = "backups/";
export { HEARTBEAT_KEY };

/** 一次备份的两个键：backups/<YYYYMMDDTHHMMSSZ>-<随机 16 位>.dump.enc / .manifest.enc */
export function backupKeys(at: Date, rand16hex: string): { dump: string; manifest: string; id: string } {
  const id = `${at.toISOString().replace(/[-:]/g, "").replace(/\.[0-9]{3}Z$/, "Z")}-${rand16hex}`;
  const out = { id, dump: `backups/${id}.dump.enc`, manifest: `backups/${id}.manifest.enc` };
  assertKey(out.dump);
  assertKey(out.manifest);
  return out;
}

/** 删除记录的键 → 店 id；不是删除记录返回 null */
export function deletionStoreId(key: string): string | null {
  return DELETION_RE.test(key) ? key.slice("deletions/".length, -".json".length) : null;
}

/** 一家店的对象前缀：images/<店>/ 或 exports/<店>/ */
export function storePrefix(kind: "images" | "exports", storeId: string): string {
  const id = storeId.toLowerCase();
  if (!UUID_RE.test(id)) throw new Error("店 id 格式不对");
  return `${kind}/${id}/`;
}

/** 任何一种合法的对象键 */
export function isObjectKey(k: string): boolean {
  return KEY_RE.test(k) || CANDIDATE_RE.test(k) || EXPORT_RE.test(k) || DELETION_RE.test(k) || BACKUP_RE.test(k) || k === HEARTBEAT_KEY;
}

export function assertKey(k: string): void {
  if (!isObjectKey(k)) throw new Error("对象键格式不对");
}

export function assertStorePrefix(p: string): void {
  if (!PREFIX_RE.test(p)) throw new Error("前缀格式不对：只能是 images/<店>/、exports/<店>/、deletions/、backups/ 或 images/_catalog/");
}

/**
 * 商品图的键：images/<店>/<商品>/<image_ver>-<内容哈希前 16 位>[-<随机 16 位>].jpg。
 * nonce：选图 / 拍照每次请求自己生成（S22d），这样出错、冲突时删的永远是本次自己写的键，不会碰到别的请求
 */
export function imageKey(storeId: string, productId: string, ver: number, sha256Hex: string, nonce16hex?: string): string {
  const k = `images/${storeId.toLowerCase()}/${productId.toLowerCase()}/${ver}-${sha256Hex.slice(0, 16)}${nonce16hex ? `-${nonce16hex}` : ""}.jpg`;
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
  /** at：落地时间（测试里可以直接改，模拟「落地超过 1 小时」） */
  readonly objects = new Map<string, { body: Buffer; contentType: string; at?: Date }>();
  async put(key: string, body: Buffer, contentType: string) {
    assertKey(key);
    this.objects.set(key, { body: Buffer.from(body), contentType, at: new Date() });
  }
  async listWithTimes(prefix: string) {
    assertStorePrefix(prefix);
    return [...this.objects].filter(([k]) => k.startsWith(prefix)).sort(([a], [b]) => (a < b ? -1 : 1)).map(([key, o]) => ({ key, modifiedAt: o.at ?? new Date(0) }));
  }
  /** 内存实现只给测试用：读进来存着 */
  async putFile(key: string, file: string, contentType: string) {
    assertKey(key);
    this.objects.set(key, { body: await readFile(file), contentType });
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
  /** 未完成的分片上传：uploadId → 键（测试里直接放进去模拟残片） */
  readonly uploads = new Map<string, string>();
  async listUploads(prefix: string) {
    assertStorePrefix(prefix);
    return [...this.uploads].filter(([, k]) => k.startsWith(prefix)).map(([uploadId, key]) => ({ key, uploadId }));
  }
  async abortUpload(key: string, uploadId: string) {
    assertKey(key);
    if (this.uploads.get(uploadId) === key) this.uploads.delete(uploadId);
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
  /** 流式拷到临时文件再改名（读的一方不会看到写了一半的包） */
  async putFile(key: string, file: string, _contentType?: string) {
    const dest = safeJoin(this.root, key);
    await mkdir(path.dirname(dest), { recursive: true });
    const tmp = `${dest}.${randomBytes(6).toString("hex")}.tmp`;
    try {
      await pipeline(createReadStream(file), createWriteStream(tmp, { mode: 0o640 }));
      await rename(tmp, dest);
    } catch (e) {
      await rm(tmp, { force: true });
      throw e;
    }
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
  async listWithTimes(prefix: string) {
    const out: Array<{ key: string; modifiedAt: Date }> = [];
    for (const key of await this.list(prefix)) {
      try {
        out.push({ key, modifiedAt: (await stat(safeJoin(this.root, key))).mtime });
      } catch (e) {
        if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
      }
    }
    return out;
  }
  /** 本机目录没有分片上传（putFile 失败时自己删掉临时文件） */
  async listUploads(prefix: string) {
    assertStorePrefix(prefix);
    return [];
  }
  async abortUpload(key: string, _uploadId: string) {
    assertKey(key);
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

interface AliClient {
  put(name: string, file: Buffer, o: { headers: Record<string, string> }): Promise<unknown>;
  multipartUpload(
    name: string,
    file: string,
    o: { partSize: number; parallel: number; mime: string; headers: Record<string, string>; progress?: (p: number, cp?: { uploadId?: string } | null) => Promise<void> },
  ): Promise<unknown>;
  abortMultipartUpload(name: string, uploadId: string): Promise<unknown>;
  listUploads(
    q: { prefix: string; "max-uploads": number; "key-marker"?: string; "upload-id-marker"?: string },
    o: object,
  ): Promise<{ uploads?: Array<{ name: string; uploadId: string }>; nextKeyMarker?: string; nextUploadIdMarker?: string; isTruncated?: boolean }>;
  get(name: string): Promise<{ content: Buffer }>;
  list(q: { prefix: string; marker?: string; "max-keys": number }, o: object): Promise<{ objects?: Array<{ name: string; lastModified?: string }>; nextMarker?: string | null; isTruncated?: boolean }>;
  delete(name: string): Promise<unknown>;
  request?: unknown;
}

const NOT_FOUND = new Set(["NoSuchKey", "NoSuchUpload"]);
const notFound = (e: unknown) => NOT_FOUND.has(String((e as { code?: unknown })?.code));

/** 阿里云 OSS。ali-oss 按需加载（测试不加载）。凭据只从环境变量来（config.objectStore），S10a 接 */
export class AliOssObjectStore implements ObjectStore {
  private client: Promise<AliClient>;
  /**
   * 列举、中止分片上传另用一个客户端：ali-oss 的 abortMultipartUpload 会把整个客户端标成「已取消」，
   * 同一个客户端上正在跑的分片上传会被它打断；复扫时的中止不能波及正在上传的导出包
   */
  private ctl: Promise<AliClient>;
  /** 这个实例读写的桶（商品图桶和存档桶各一个实例） */
  readonly bucket: string;
  /** o.request 只给测试用：换掉 ali-oss 的网络传输（分片逻辑仍是实际安装的 ali-oss） */
  constructor(c: Extract<Config["objectStore"], { kind: "aliyun" }>, o: { request?: (params: unknown) => Promise<unknown> } = {}) {
    const make = () =>
      import("ali-oss").then((m) => {
        const cl = new m.default({
          region: c.region,
          bucket: c.bucket,
          accessKeyId: c.accessKeyId,
          accessKeySecret: c.accessKeySecret,
          secure: true,
          timeout: 10_000,
          ...(c.endpoint ? { endpoint: c.endpoint } : {}),
        }) as unknown as AliClient;
        if (o.request) cl.request = o.request;
        return cl;
      });
    this.bucket = c.bucket;
    this.client = make();
    this.ctl = make();
  }
  async put(key: string, body: Buffer, contentType: string) {
    assertKey(key);
    await (await this.client).put(key, body, { headers: { "Content-Type": contentType, "x-oss-forbid-overwrite": "false" } });
  }
  /**
   * 分片上传（ali-oss 按片从文件读流；小于 100 KiB 的它自己改走普通上传，同样从文件读）。S10a 接真实 OSS 时实测一次。
   * 失败时中止这次分片上传（PR #20 Codex 第二轮 3），不让已传的片留在桶里计费、也不会被 delete(key) 漏掉；
   * 中止也失败就把 { key, uploadId } 挂在抛出的错误上（pendingUploadOf），由调用方记待删标记；店被清除时复扫也会按前缀中止
   */
  async putFile(key: string, file: string, contentType: string) {
    assertKey(key);
    await stat(file);
    const c = await this.client;
    let uploadId: string | undefined;
    try {
      await c.multipartUpload(key, file, {
        partSize: 1024 * 1024,
        parallel: 2,
        mime: contentType,
        headers: { "Content-Type": contentType },
        progress: async (_p, cp) => {
          if (cp?.uploadId) uploadId = cp.uploadId;
        },
      });
    } catch (e) {
      if (uploadId) {
        try {
          await c.abortMultipartUpload(key, uploadId);
        } catch (e2) {
          if (!notFound(e2)) {
            if (e && typeof e === "object") Object.assign(e, { pendingUpload: { key, uploadId } });
            else throw Object.assign(new Error("分片上传失败，中止也失败"), { pendingUpload: { key, uploadId } });
          }
        }
      }
      throw e;
    }
  }
  /** 按前缀分页列举未完成的分片上传（每页 1000 个）。S10a 接真实 OSS 时实测一次 */
  async listUploads(prefix: string) {
    assertStorePrefix(prefix);
    const c = await this.ctl;
    const out: PendingUpload[] = [];
    let km: string | undefined;
    let um: string | undefined;
    for (;;) {
      const r = await c.listUploads({ prefix, "max-uploads": 1000, ...(km ? { "key-marker": km } : {}), ...(um ? { "upload-id-marker": um } : {}) }, {});
      for (const u of r.uploads ?? []) if (u.name.startsWith(prefix) && isObjectKey(u.name)) out.push({ key: u.name, uploadId: u.uploadId });
      if (!r.isTruncated || (!r.nextKeyMarker && !r.nextUploadIdMarker)) break;
      km = r.nextKeyMarker;
      um = r.nextUploadIdMarker;
    }
    return out;
  }
  async abortUpload(key: string, uploadId: string) {
    assertKey(key);
    try {
      await (await this.ctl).abortMultipartUpload(key, uploadId);
    } catch (e) {
      if (notFound(e)) return;
      throw e;
    }
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
    return (await this.listWithTimes(prefix)).map((o) => o.key);
  }
  /** 同 list，带上 lastModified（认不出时间的当作刚落地：宁可晚删） */
  async listWithTimes(prefix: string) {
    assertStorePrefix(prefix);
    const c = await this.client;
    const out: Array<{ key: string; modifiedAt: Date }> = [];
    let marker: string | undefined;
    for (;;) {
      const r = await c.list({ prefix, "max-keys": 1000, ...(marker ? { marker } : {}) }, {});
      for (const o of r.objects ?? []) {
        if (!o.name.startsWith(prefix) || !isObjectKey(o.name)) continue;
        const t = o.lastModified ? new Date(o.lastModified) : new Date();
        out.push({ key: o.name, modifiedAt: Number.isNaN(t.getTime()) ? new Date() : t });
      }
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

/**
 * 存档桶（exports/、deletions/，§9.1 的 yuanhui-backup）。S09-11：生产不许和商品图共用桶。
 * - 本机目录（开发、测试）：和商品图同一个目录。
 * - 阿里云：第二个桶 OSS_ARCHIVE_BUCKET（S10a，§14 T13），同一组 RAM 凭据；loadConfig 已要求必填且和商品图桶不同。
 *   万一拿到的配置没有存档桶或和商品图桶相同（只可能是手工拼的 Config），仍按没配处理（返回 null），
 *   导出和清除那边按 export_no_archive / purge_no_archive 告警，绝不把导出包、删除记录写进商品图桶 yuanhui-img。
 */
export function archiveStoreFromConfig(config: Config, images: ObjectStore | null): ObjectStore | null {
  const c = config.objectStore;
  if (c.kind === "local") return images;
  if (c.kind === "aliyun" && c.archiveBucket && c.archiveBucket !== c.bucket) return new AliOssObjectStore({ ...c, bucket: c.archiveBucket });
  return null;
}

export function objectStoreFromConfig(config: Config): ObjectStore | null {
  const c = config.objectStore;
  if (c.kind === "none") return null;
  if (c.kind === "local") return new LocalDirObjectStore(c.dir);
  return new AliOssObjectStore(c);
}
