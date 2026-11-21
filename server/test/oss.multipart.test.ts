// 阿里云分片上传失败的善后（PR #20 Codex 第二轮 3）：用实际安装的 ali-oss 分片逻辑，只把网络传输换成内存里的假 OSS。
// 某一片失败 → 中止这次分片上传（不留残片）；失败重试两次 → 两个 uploadId 都中止；中止也失败 → 错误里带上 uploadId（交给待删标记），
// 列举未完成的分片上传能看到它、之后能中止掉。不连真实 OSS、不需要数据库。
import { randomBytes, randomUUID } from "node:crypto";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import type { Readable } from "node:stream";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { AliOssObjectStore, MemoryObjectStore, exportKey, pendingUploadOf, storePrefix } from "../src/lookup/oss.ts";

interface Params {
  method: string;
  object?: string;
  subres?: string | Record<string, string | number>;
  query?: Record<string, string | number>;
  stream?: Readable;
}

/** 内存里的假 OSS：只认分片上传用到的几个请求 */
class FakeOss {
  readonly uploads = new Map<string, { key: string; parts: Set<number> }>();
  readonly objects = new Set<string>();
  inits = 0;
  aborts = 0;
  failPart: number | null = null;
  failAbort = false;
  private n = 0;
  async request(p: Params) {
    if (p.stream) {
      p.stream.resume();
      await new Promise((r) => p.stream!.once("close", r).once("end", r));
    }
    const sub = p.subres;
    const err = (status: number, code: string) => Object.assign(new Error(code), { status, code, name: `${code}Error` });
    if (p.method === "POST" && sub === "uploads") {
      const id = `up-${++this.n}`;
      this.inits++;
      this.uploads.set(id, { key: p.object!, parts: new Set() });
      return { res: { status: 200, headers: {} }, data: { Bucket: "b", Key: p.object, UploadId: id } };
    }
    if (p.method === "GET" && sub === "uploads") {
      const prefix = String(p.query?.prefix ?? "");
      const ups = [...this.uploads].filter(([, u]) => u.key.startsWith(prefix)).map(([id, u]) => ({ Key: u.key, UploadId: id, Initiated: "" }));
      return { res: { status: 200, headers: {} }, data: { Bucket: "b", Upload: ups, IsTruncated: "false" } };
    }
    if (typeof sub === "object" && sub.uploadId) {
      const id = String(sub.uploadId);
      const up = this.uploads.get(id);
      if (p.method === "PUT") {
        if (!up) throw err(404, "NoSuchUpload");
        if (Number(sub.partNumber) === this.failPart) throw err(500, "InternalError");
        up.parts.add(Number(sub.partNumber));
        return { res: { status: 200, headers: { etag: `"e${sub.partNumber}"` } }, data: null };
      }
      if (p.method === "DELETE") {
        this.aborts++;
        if (this.failAbort) throw err(500, "InternalError");
        if (!up) throw err(404, "NoSuchUpload");
        this.uploads.delete(id);
        return { res: { status: 204, headers: {} }, data: null };
      }
      if (p.method === "POST") {
        if (!up) throw err(404, "NoSuchUpload");
        this.uploads.delete(id);
        this.objects.add(up.key);
        return { res: { status: 200, headers: { etag: '"done"' } }, data: {} };
      }
    }
    throw new Error(`假 OSS 不认识的请求：${p.method} ${JSON.stringify(sub)}`);
  }
}

const CFG = { kind: "aliyun" as const, region: "oss-cn-shanghai", bucket: "test-bucket", accessKeyId: "x", accessKeySecret: "y" };
let dir: string;
let file: string;
beforeAll(async () => {
  dir = await mkdtemp(path.join(tmpdir(), "yh-multipart-"));
  file = path.join(dir, "export.zip");
  // 2.5 MiB：每片 1 MiB → 3 片
  await writeFile(file, randomBytes(2.5 * 1024 * 1024));
});
afterAll(async () => {
  await rm(dir, { recursive: true, force: true });
});

function store(fake: FakeOss) {
  return new AliOssObjectStore(CFG, { request: (p) => fake.request(p as Params) });
}

describe("阿里云分片上传失败（PR #20 Codex 第二轮 3）", () => {
  const storeId = randomUUID();
  const key = () => exportKey(storeId, new Date(Date.parse("2026-11-20T02:00:00Z")), randomBytes(8).toString("hex"));

  it("成功：3 片传完合成一个对象，不留未完成的分片上传", async () => {
    const fake = new FakeOss();
    const k = key();
    await store(fake).putFile(k, file, "application/zip");
    expect([fake.objects.has(k), fake.inits, fake.uploads.size, fake.aborts]).toEqual([true, 1, 0, 0]);
  });

  it("第 2 片失败：putFile 报错，这次分片上传被中止；失败重试两次 → 两个 uploadId 都中止，不累积残片", async () => {
    const fake = new FakeOss();
    fake.failPart = 2;
    const s = store(fake);
    const k = key();
    await expect(s.putFile(k, file, "application/zip")).rejects.toMatchObject({ code: "InternalError" });
    await expect(s.putFile(k, file, "application/zip")).rejects.toMatchObject({ code: "InternalError" });
    expect([fake.inits, fake.aborts, fake.uploads.size, fake.objects.size]).toEqual([2, 2, 0, 0]);
    // 恢复之后同一个客户端照常能传（中止不会让后面的上传一直处于取消状态）
    fake.failPart = null;
    await s.putFile(k, file, "application/zip");
    expect([fake.objects.has(k), fake.uploads.size]).toEqual([true, 0]);
  });

  it("中止也失败：错误里带上 key 和 uploadId；列举未完成的分片上传能看到它，之后中止掉", async () => {
    const fake = new FakeOss();
    fake.failPart = 3;
    fake.failAbort = true;
    const s = store(fake);
    const k = key();
    const e = await s.putFile(k, file, "application/zip").then(
      () => null,
      (x: unknown) => x,
    );
    expect(e).toMatchObject({ code: "InternalError" });
    const pending = pendingUploadOf(e);
    expect(pending?.key).toBe(k);
    expect(fake.uploads.has(pending!.uploadId)).toBe(true);
    expect(await s.listUploads(storePrefix("exports", storeId))).toEqual([{ key: k, uploadId: pending!.uploadId }]);
    expect(await s.listUploads(storePrefix("exports", randomUUID()))).toEqual([]);
    fake.failAbort = false;
    await s.abortUpload(k, pending!.uploadId);
    // 已经没有了也算成功
    await s.abortUpload(k, pending!.uploadId);
    expect(fake.uploads.size).toBe(0);
    await expect(s.listUploads("exports/../")).rejects.toThrow(/前缀/);
  });

  it("内存实现：listUploads / abortUpload 按前缀，只碰一家店", async () => {
    const m = new MemoryObjectStore();
    const a = key();
    const b = exportKey(randomUUID(), new Date(), randomBytes(8).toString("hex"));
    m.uploads.set("u1", a);
    m.uploads.set("u2", b);
    expect(await m.listUploads(storePrefix("exports", storeId))).toEqual([{ key: a, uploadId: "u1" }]);
    await m.abortUpload(a, "u1");
    await m.abortUpload(a, "u1");
    expect([...m.uploads.keys()]).toEqual(["u2"]);
  });
});
