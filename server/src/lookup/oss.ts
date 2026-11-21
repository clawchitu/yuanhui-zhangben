// 对象存储（商品小图放这里，§0「服务器下载 → 压成长边 200px → 存 OSS」）。
//
// 做成接口：测试用内存实现，本机开发用目录实现，生产用阿里云 OSS（S10a 填凭据接上，本段不连真实 OSS）。
// 键只由服务器生成（imageKey），读写前都校验格式，不接受外部传来的路径（防路径穿越）。
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import path from "node:path";
import type { Config } from "../config.ts";

export interface ObjectStore {
  put(key: string, body: Buffer, contentType: string): Promise<void>;
  /** 没有这个键返回 null */
  get(key: string): Promise<Buffer | null>;
}

const UUID = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}";
const KEY_RE = new RegExp(`^images/${UUID}/${UUID}/[1-9][0-9]{0,9}-[0-9a-f]{16}\\.jpg$`);

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
    assertImageKey(key);
    this.objects.set(key, { body: Buffer.from(body), contentType });
  }
  async get(key: string) {
    assertImageKey(key);
    return this.objects.get(key)?.body ?? null;
  }
}

/** 键 → 目录下的文件。键已校验过格式；再确认拼出来的路径没有跑出根目录 */
export function safeJoin(root: string, key: string): string {
  assertImageKey(key);
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
}

/** 阿里云 OSS。ali-oss 按需加载（测试不加载）。凭据只从环境变量来（config.objectStore），S10a 接 */
export class AliOssObjectStore implements ObjectStore {
  private client: Promise<{
    put(name: string, file: Buffer, o: { headers: Record<string, string> }): Promise<unknown>;
    get(name: string): Promise<{ content: Buffer }>;
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
    assertImageKey(key);
    await (await this.client).put(key, body, { headers: { "Content-Type": contentType, "x-oss-forbid-overwrite": "false" } });
  }
  async get(key: string) {
    assertImageKey(key);
    try {
      return (await (await this.client).get(key)).content;
    } catch (e) {
      if ((e as { code?: string }).code === "NoSuchKey") return null;
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
