// 备份桶开合规保留（WORM）后：backups/ 进备份桶，心跳和 deletions/ 进存档桶（S10 部署实测）
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { LocalDirObjectStore, AliOssObjectStore, MemoryObjectStore } from "../src/lookup/oss.ts";
import { backupStatus } from "../src/backup/backup.ts";
import { RestoreConfigError, SplitBackupStore, backupStoreFromEnv, backupStoreSource, restoreStoreFromEnv } from "../src/backup/store.ts";

const dirs: string[] = [];
afterAll(async () => {
  for (const d of dirs) await rm(d, { recursive: true, force: true });
});
const tmp = async () => {
  const d = await mkdtemp(path.join(tmpdir(), "yh-split-"));
  dirs.push(d);
  return d;
};
const env = {
  BACKUP_OSS_REGION: "oss-cn-shanghai",
  BACKUP_OSS_BUCKET: "b-backup",
  BACKUP_OSS_ACCESS_KEY_ID: "id",
  BACKUP_OSS_ACCESS_KEY_SECRET: "secret",
};

describe("SplitBackupStore", () => {
  it("backups/ 走备份桶，heartbeat 和 deletions/ 走存档桶", async () => {
    const a = new LocalDirObjectStore(await tmp());
    const b = new LocalDirObjectStore(await tmp());
    const s = new SplitBackupStore(a, b);
    const dump = "backups/20261122T010203Z-0123456789abcdef.dump.enc";
    await s.put(dump, Buffer.from("x"), "application/octet-stream");
    await s.put("heartbeat/backup.json", Buffer.from("{}"), "application/json");
    await s.put(
      "deletions/00000000-0000-4000-8000-000000000001.json",
      Buffer.from("{}"),
      "application/json",
    );
    expect(await a.list("backups/")).toEqual([dump]);
    expect(await b.get("heartbeat/backup.json")).not.toBeNull();
    expect(await a.get("heartbeat/backup.json")).toBeNull();
    expect(await s.list("deletions/")).toEqual([
      "deletions/00000000-0000-4000-8000-000000000001.json",
    ]);
    expect(await a.list("deletions/")).toEqual([]);
    expect(await s.list("backups/")).toEqual([dump]);
  });
  it("backupStoreFromEnv：配了不同的存档桶才拆，否则单桶；存档桶不许是商品图桶", () => {
    expect(backupStoreFromEnv(env)).toBeInstanceOf(AliOssObjectStore);
    expect(
      backupStoreFromEnv({ ...env, BACKUP_OSS_ARCHIVE_BUCKET: "b-backup" }),
    ).toBeInstanceOf(AliOssObjectStore);
    expect(
      backupStoreFromEnv({ ...env, BACKUP_OSS_ARCHIVE_BUCKET: "b-archive" }),
    ).toBeInstanceOf(SplitBackupStore);
    expect(() =>
      backupStoreFromEnv({
        ...env,
        OSS_BUCKET: "b-img",
        BACKUP_OSS_ARCHIVE_BUCKET: "b-img",
      }),
    ).toThrow(/商品图桶/);
  });
  it("恢复：OSS 跑法没配存档桶就拒绝（deletions/ 读成空、已注销的店复活，PR #27 Fable S10r-8）；单桶老布局要显式同名；本机目录不受影响", async () => {
    expect(() => restoreStoreFromEnv(env)).toThrow(RestoreConfigError);
    expect(() => restoreStoreFromEnv({ ...env, BACKUP_OSS_ARCHIVE_BUCKET: "" })).toThrow(/BACKUP_OSS_ARCHIVE_BUCKET.*已注销的店/);
    expect(restoreStoreFromEnv({ ...env, BACKUP_OSS_ARCHIVE_BUCKET: "b-backup" })).toBeInstanceOf(AliOssObjectStore);
    expect(restoreStoreFromEnv({ ...env, BACKUP_OSS_ARCHIVE_BUCKET: "b-archive" })).toBeInstanceOf(SplitBackupStore);
    const dir = await tmp();
    expect(restoreStoreFromEnv({ BACKUP_STORE_DIR: dir })).toBeInstanceOf(LocalDirObjectStore);
    // 备份照旧可以不配（老布局），日志里打印实际用的桶
    expect(backupStoreFromEnv(env)).toBeInstanceOf(AliOssObjectStore);
    expect(backupStoreSource(env)).toEqual({ backups: "oss://b-backup", deletions: "oss://b-backup" });
    expect(backupStoreSource({ ...env, BACKUP_OSS_ARCHIVE_BUCKET: "b-archive" })).toEqual({ backups: "oss://b-backup", deletions: "oss://b-archive" });
    expect(backupStoreSource({ BACKUP_STORE_DIR: dir })).toEqual({ backups: `dir:${dir}`, deletions: `dir:${dir}` });
  });
});

describe("backup_lifecycle_stale 的阈值（PR #27 Fable：合规保留 35 天 + 生命周期一天一轮不准点，36 天会误报）", () => {
  // 真机上第一份备份是 2026-11-21 20:34 UTC（北京 11/22 04:34）
  const first = Date.UTC(2026, 10, 21, 20, 34, 0);
  const at = (days: number) => new Date(first + days * 86_400_000);
  const bucket = async () => {
    const b = new MemoryObjectStore();
    for (const ext of ["dump.enc", "manifest.enc"]) await b.put(`backups/20261121T203400Z-0123456789abcdef.${ext}`, Buffer.from("x"), "application/octet-stream");
    return b;
  };
  it("12/27 前后（36–37 天多）生命周期还没轮到：不报；超过 38 天才报", async () => {
    const b = await bucket();
    expect((await backupStatus(b, new Date(Date.UTC(2026, 11, 27, 12, 0, 0)))).lifecycle_stale).toBe(false);
    for (const d of [35.5, 36.2, 37, 37.9, 38]) expect([d, (await backupStatus(b, at(d))).lifecycle_stale]).toEqual([d, false]);
    for (const d of [38.05, 40]) expect([d, (await backupStatus(b, at(d))).lifecycle_stale]).toEqual([d, true]);
  });
  it("桶是空的不报", async () => {
    expect((await backupStatus(new MemoryObjectStore(), at(100))).lifecycle_stale).toBe(false);
  });
});
