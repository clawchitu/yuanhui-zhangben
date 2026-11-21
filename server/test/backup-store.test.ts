// 备份桶开合规保留（WORM）后：backups/ 进备份桶，心跳和 deletions/ 进存档桶（S10 部署实测）
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, describe, expect, it } from "vitest";
import { LocalDirObjectStore, AliOssObjectStore } from "../src/lookup/oss.ts";
import { SplitBackupStore, backupStoreFromEnv } from "../src/backup/store.ts";

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
});
