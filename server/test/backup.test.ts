// S10b 备份与恢复（§9.4、§4.6、§14 T14）。真实 Postgres + 本机 pg_dump / pg_restore，对象存储用内存实现。
// 端到端：经 /v1/sync 记账 → 快照 + 清单 + pg_dump（同一快照）→ 加密上传 → 备份之后继续记账、注销到期清除一家店 →
// 删库 → 恢复到新库 → 按清单逐项比对 → 重放删除记录（已注销的店被重新删掉、旧令牌 401）→ 其余店和备份一致 → 换 epoch。
import { execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import pg from "pg";
import { sql } from "kysely";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, quoteIdent, type Db } from "../src/db.ts";
import { BackupCryptoError, decryptBuffer, decryptFile, encryptBuffer, encryptFile } from "../src/backup/crypto.ts";
import { backupStatus, listBackups, uploadBackup, withBackupSnapshot } from "../src/backup/backup.ts";
import { computeManifest, diffManifests, type Manifest } from "../src/backup/manifest.ts";
import { RestoreError, clearMarker, fetchBackup, finishRestore, inspectTarget, listDeletions, prepareTarget, resolveBackup } from "../src/backup/restore.ts";
import { purgeStore } from "../src/jobs/account-purge.ts";
import { DELETE_GRACE_MS } from "../src/auth/session.ts";
import { HEARTBEAT_KEY, LocalDirObjectStore, MemoryObjectStore, backupKeys, deletionKey } from "../src/lookup/oss.ts";
import { createTestDb, databaseUrl, type TestDb } from "./helpers/db.ts";
import { TestClock, login, makeApp, makeLoginShop } from "./helpers/auth.ts";
import { upsertFull, sync } from "./helpers/sync.ts";
import { saleOp, shopIO, stockInOp } from "./helpers/reports.ts";

const run = promisify(execFile);
const PG_BIN = process.env.PG_BIN ? `${process.env.PG_BIN}/` : "";
const PASS = "test-only-passphrase-0123456789";
const NOW = Date.parse("2026-11-20T03:00:00Z");

let tdb: TestDb;
let work: string;
beforeAll(async () => {
  tdb = await createTestDb();
  work = await mkdtemp(path.join(tmpdir(), "yh-backup-"));
});
afterAll(async () => {
  await tdb.drop().catch(() => {});
  await rm(work, { recursive: true, force: true });
});

describe("加密", () => {
  it("文件、清单往返；口令不对、改一个字节、太短的口令都拒绝，失败时不留明文文件", async () => {
    const src = path.join(work, "plain");
    await writeFile(src, Buffer.concat([Buffer.from("PGDMP"), randomBytes(300_000)]));
    const enc = path.join(work, "plain.enc");
    const r = await encryptFile(src, enc, PASS);
    expect(r.bytes).toBe(300_005);
    const out = path.join(work, "plain.out");
    expect((await decryptFile(enc, out, PASS)).sha256).toBe(r.sha256);
    expect(await readFile(out)).toEqual(await readFile(src));
    await rm(out);
    await expect(decryptFile(enc, out, "wrong-passphrase-0123456789")).rejects.toThrow(BackupCryptoError);
    await expect(stat(out)).rejects.toThrow();
    for (const pos of [6, 30, 1000, (await stat(enc)).size - 1]) {
      const b = await readFile(enc);
      b[pos] = b[pos]! ^ 1;
      await writeFile(`${enc}.bad`, b);
      await expect(decryptFile(`${enc}.bad`, out, PASS)).rejects.toThrow(BackupCryptoError);
      await expect(stat(out)).rejects.toThrow();
    }
    await expect(encryptFile(src, enc, "short")).rejects.toThrow(/至少 20 位/);
    const m = await encryptBuffer(Buffer.from("清单"), PASS);
    expect((await decryptBuffer(m, PASS)).toString()).toBe("清单");
    m[m.length - 1] = m[m.length - 1]! ^ 1;
    await expect(decryptBuffer(m, PASS)).rejects.toThrow(BackupCryptoError);
  });
});

describe("对象键", () => {
  it("备份键、心跳、deletions/ 与 backups/ 整前缀列举；别的前缀照旧拒绝", async () => {
    const k = backupKeys(new Date("2026-11-20T03:04:05.678Z"), "0123456789abcdef");
    expect(k.dump).toBe("backups/20261120T030405Z-0123456789abcdef.dump.enc");
    expect(() => backupKeys(new Date(), "xyz")).toThrow();
    for (const s of [new MemoryObjectStore(), new LocalDirObjectStore(path.join(work, "keys"))]) {
      const id = "11111111-2222-4333-8444-555555555555";
      await s.put(deletionKey(id), Buffer.from(JSON.stringify({ store_id: id, purged_at: "2026-11-01T00:00:00Z" })), "application/json");
      await s.put(k.dump, Buffer.from("x"), "a");
      await s.put(HEARTBEAT_KEY, Buffer.from("{}"), "a");
      expect(await s.list("deletions/")).toEqual([deletionKey(id)]);
      expect(await s.list("backups/")).toEqual([k.dump]);
      await expect(s.list("heartbeat/")).rejects.toThrow(/前缀格式不对/);
      await expect(s.list("")).rejects.toThrow(/前缀格式不对/);
      expect(await listDeletions(s)).toEqual([{ storeId: id, purgedAt: new Date("2026-11-01T00:00:00Z") }]);
    }
  });
  it("删除记录内容和键对不上 → 拒绝，不按坏记录删店", async () => {
    const s = new MemoryObjectStore();
    await s.put(deletionKey("11111111-2222-4333-8444-555555555555"), Buffer.from(JSON.stringify({ store_id: "99999999-2222-4333-8444-555555555555", purged_at: "2026-11-01T00:00:00Z" })), "a");
    await expect(listDeletions(s)).rejects.toThrow(RestoreError);
  });
});

/** 一家店：登录、建两个商品、进货、卖出（全部经 /v1/sync） */
async function makeShop(clock: TestClock) {
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb, { clock });
  const boss = await login(app, shop.username);
  const io = shopIO(app, boss.token, shop.epoch);
  const pids: string[] = [];
  for (const price of [1500, 2350]) {
    const u = upsertFull({ price });
    await io.send(u);
    pids.push(u.payload.product_id as string);
  }
  const at = new Date(clock.t - 3_600_000).toISOString();
  await io.send(stockInOp(pids[0]!, 10, 1100, at), stockInOp(pids[1]!, 7, 1733, at), stockInOp(pids[0]!, 5, 1210, at));
  await io.send(saleOp([{ pid: pids[0]!, n: 3, price: 1500 }, { pid: pids[1]!, n: 2, price: 2350 }], at, 20).op);
  return { ...shop, app, token: boss.token, io, pids };
}

async function expire(storeId: string, clock: TestClock, archive: MemoryObjectStore) {
  await tdb.kysely.updateTable("accounts").set({ delete_requested_at: new Date(clock.t - DELETE_GRACE_MS - 60_000) }).where("store_id", "=", storeId).execute();
  expect(await purgeStore(tdb.kysely, storeId, clock.now(), archive)).toBe("purged");
}

async function pgDump(snapshot: string, file: string) {
  await run(`${PG_BIN}pg_dump`, ["-d", databaseUrl(), "-n", tdb.schema, "-Fc", `--snapshot=${snapshot}`, "-f", file]);
}

/** 一个商品的库存、货值，和它的卖出流水条数、成本合计 */
async function stockOf(db: Db, pid: string) {
  const p = await db.kysely.selectFrom("products").select(["stock_qty", "stock_value_fen"]).where("id", "=", pid).executeTakeFirstOrThrow();
  const e = await sql<{ n: string; c: string }>`SELECT count(*)::text AS n, coalesce(sum(cogs_fen), 0)::text AS c FROM entries WHERE product_id = ${pid}`.execute(db.kysely);
  return { qty: Number(p.stock_qty), value: Number(p.stock_value_fen), entries: Number(e.rows[0]!.n), cogs: Number(e.rows[0]!.c) };
}

async function newDatabase(): Promise<{ name: string; url: string }> {
  const name = `yh_restore_${randomBytes(4).toString("hex")}`;
  const c = new pg.Client({ connectionString: databaseUrl() });
  await c.connect();
  await c.query(`CREATE DATABASE ${quoteIdent(name)}`);
  await c.end();
  const u = new URL(databaseUrl());
  u.pathname = `/${name}`;
  return { name, url: u.toString() };
}
async function dropDatabase(name: string) {
  const c = new pg.Client({ connectionString: databaseUrl() });
  await c.connect();
  await c.query(`DROP DATABASE IF EXISTS ${quoteIdent(name)} WITH (FORCE)`);
  await c.end();
}

describe("备份 → 删库 → 恢复 → 重放删除记录", () => {
  it("和备份清单逐项一致；已注销的店不复活、旧令牌 401；没注销的店换 epoch 后补回备份之后的流水；恢复中可重来，恢复完成后不再清库", { timeout: 120_000 }, async () => {
    const clock = new TestClock(NOW);
    const bucket = new MemoryObjectStore(); // yuanhui-backup：备份、删除记录在同一个桶
    const keep = await makeShop(clock);
    const doomed = await makeShop(clock);
    const early = await makeShop(clock);
    await expire(early.storeId, clock, bucket); // 备份之前就清除了：备份里没有它，重放记为 absent

    // ── 备份 ──
    const dir = await mkdtemp(path.join(work, "b-"));
    const dumpFile = path.join(dir, "db.dump");
    let manifest!: Manifest;
    await withBackupSnapshot(tdb.kysely, clock.now(), async (snap, m) => {
      manifest = m;
      // 快照之后、dump 之前又记了一笔：清单和 dump 都不该有它（同一快照）
      await keep.io.send(saleOp([{ pid: keep.pids[0]!, n: 1, price: 1500 }], new Date(clock.t - 60_000).toISOString()).op);
      await pgDump(snap, dumpFile);
    });
    expect(Object.keys(manifest.stores).sort()).toEqual([keep.storeId, doomed.storeId].sort());
    expect(manifest.stores[keep.storeId]!.entries).toBeGreaterThan(0);
    expect(Number(manifest.stores[keep.storeId]!.cogs_fen)).toBeGreaterThan(0);
    expect(manifest.stores[keep.storeId]!.months["2026-11"]!.sold_fen).toBeGreaterThan(0);
    const up = await uploadBackup(bucket, { dumpFile, manifest, passphrase: PASS, now: clock.now(), workDir: dir });
    const hb = JSON.parse((await bucket.get(HEARTBEAT_KEY))!.toString());
    expect(hb).toMatchObject({ backup_id: up.id, stores: 2 });
    // 上传的是密文：明文 dump 的文件头不出现
    expect(bucket.objects.get(up.dumpKey)!.body.subarray(0, 5).toString()).toBe("YHBK\u0001");
    expect((await listBackups(bucket)).map((b) => b.id)).toEqual([up.id]);
    expect(await backupStatus(bucket, new Date(NOW + 39 * 86_400_000))).toMatchObject({ count: 1, lifecycle_stale: true });
    expect(await backupStatus(bucket, clock.now())).toMatchObject({ count: 1, lifecycle_stale: false });
    // 不是 pg_dump 的文件不上传
    await writeFile(path.join(dir, "junk"), "pg_dump: error: connection failed");
    await expect(uploadBackup(bucket, { dumpFile: path.join(dir, "junk"), manifest, passphrase: PASS, now: clock.now(), workDir: dir })).rejects.toThrow(/PGDMP/);

    // ── 备份之后：继续记账（这一笔恢复后要靠手机重传补回）、清除一家店（往 deletions/ 写记录），然后删库 ──
    clock.advance(30 * 60_000);
    const lateSale = saleOp([{ pid: keep.pids[1]!, n: 1, price: 2350 }], clock.now().toISOString()).op;
    await keep.io.send(lateSale);
    const liveBefore = await stockOf(tdb, keep.pids[1]!);
    await expire(doomed.storeId, clock, bucket);
    await tdb.drop();

    // ── 恢复到另一个库：只用桶里的东西和口令 ──
    const target = await newDatabase();
    let rdb: Db | undefined;
    try {
      const id = await resolveBackup(bucket, "latest");
      expect(id).toBe(up.id);
      const out = await mkdtemp(path.join(work, "r-"));
      await expect(fetchBackup(bucket, id, "wrong-passphrase-0123456789", out)).rejects.toThrow(BackupCryptoError);
      const { manifest: got, dumpFile: restoredDump } = await fetchBackup(bucket, id, PASS, out);
      expect(got.stores).toEqual(manifest.stores);
      const pgRestore = () => run(`${PG_BIN}pg_restore`, ["-d", target.url, "--no-owner", "--no-acl", "--exit-on-error", restoredDump]);

      rdb = createDb({ connectionString: target.url, searchPath: tdb.schema, max: 2 });
      expect(await prepareTarget(rdb.kysely, id, true)).toBe("empty");
      expect((await inspectTarget(rdb.kysely)).state).toBe("empty"); // dry-run 什么都不改
      expect(await prepareTarget(rdb.kysely, id, false)).toBe("empty");
      expect(await inspectTarget(rdb.kysely)).toMatchObject({ state: "restoring", backupId: id });
      await pgRestore();

      // ── 中途断了（恢复中）：重跑会清空重来 ──
      expect(await prepareTarget(rdb.kysely, id, false)).toBe("reset");
      await pgRestore();

      // ── 恢复后库里的数被改过 → 比对报错（演示「改坏后失败」），还是「恢复中」，可以重来 ──
      await rdb.kysely.updateTable("entries").set({ cogs_fen: 1 }).where("store_id", "=", keep.storeId).where("type", "=", "sale").execute();
      await expect(finishRestore(rdb.kysely, bucket, got, { dryRun: false })).rejects.toThrow(/cogs_fen|entries_checksum/);
      expect((await inspectTarget(rdb.kysely)).state).toBe("restoring");
      expect(await prepareTarget(rdb.kysely, id, false)).toBe("reset");
      await pgRestore();

      const dry = await finishRestore(rdb.kysely, bucket, got, { dryRun: true });
      expect(dry).toMatchObject({ dry_run: true, deletions: 2, replayed: [doomed.storeId], epochs_rotated: 0, backup_id: id });
      expect(await rdb.kysely.selectFrom("stores").select("id").where("id", "=", doomed.storeId).executeTakeFirst()).toBeTruthy();
      expect((await inspectTarget(rdb.kysely)).state).toBe("restoring");

      const rep = await finishRestore(rdb.kysely, bucket, got, { dryRun: false });
      expect(rep).toMatchObject({ dry_run: false, deletions: 2, replayed: [doomed.storeId], epochs_rotated: 1, backup_id: id });
      expect(await inspectTarget(rdb.kysely)).toMatchObject({ state: "restored", backupId: id });
      const fresh = await checkRestored(rdb, got);

      // ── 换 epoch 后手机重传备份之后的那一笔（§4.6）：旧 epoch 不应用；新 epoch 入账一次；再发一遍不重复 ──
      expect(await stockOf(rdb, keep.pids[1]!)).toEqual({ qty: liveBefore.qty + 1, value: expect.any(Number), entries: liveBefore.entries - 1, cogs: expect.any(Number) });
      const app = makeApp(tdb, { clock, db: rdb });
      try {
        const stale = await sync(app, keep.token, { epoch: keep.epoch, ops: [lateSale], pull: false });
        expect(stale.status).toBe(409);
        expect(stale.body).toMatchObject({ code: "epoch_mismatch", epoch: fresh });
        expect(await rdb.kysely.selectFrom("ops").select("id").where("id", "=", lateSale.id).execute()).toEqual([]);
        const r1 = await sync(app, keep.token, { epoch: fresh, ops: [lateSale], pull: true });
        expect(r1.status, JSON.stringify(r1.body)).toBe(200);
        expect((r1.body as { results: Array<{ status: string }> }).results.map((x) => x.status)).toEqual(["applied"]);
        const r2 = await sync(app, keep.token, { epoch: fresh, ops: [lateSale], pull: false });
        expect((r2.body as { results: Array<{ status: string; replayed?: boolean }> }).results).toMatchObject([{ status: "applied", replayed: true }]);
      } finally {
        await app.close();
      }
      // 库存、货值、成本、流水条数都回到删库前的样子（这一笔只入账一次）
      expect(await stockOf(rdb, keep.pids[1]!)).toEqual(liveBefore);

      // ── 已恢复完成、又记了新账的库：再跑同一次恢复 → 「已恢复完成」，什么都不动；别的备份 → 拒绝；finish 也拒绝 ──
      expect(await prepareTarget(rdb.kysely, id, true)).toBe("done");
      expect(await prepareTarget(rdb.kysely, id, false)).toBe("done");
      expect(await stockOf(rdb, keep.pids[1]!)).toEqual(liveBefore);
      expect(await rdb.kysely.selectFrom("ops").select("id").where("id", "=", lateSale.id).execute()).toHaveLength(1);
      await expect(prepareTarget(rdb.kysely, "20991231T000000Z-0123456789abcdef", false)).rejects.toThrow(/恢复完成/);
      await expect(finishRestore(rdb.kysely, bucket, got, { dryRun: false })).rejects.toThrow(/恢复中/);
      expect((await rdb.kysely.selectFrom("stores").select("epoch").executeTakeFirstOrThrow()).epoch).toBe(fresh);

      // ── 整机重建：清掉标记后它就是普通的在用库，任何恢复都拒绝 ──
      expect(await clearMarker(rdb.kysely)).toBe("foreign");
      await expect(prepareTarget(rdb.kysely, id, true)).rejects.toThrow(/拒绝覆盖/);
      expect(await stockOf(rdb, keep.pids[1]!)).toEqual(liveBefore);
    } finally {
      await rdb?.close();
      await dropDatabase(target.name);
    }

    /** 校验恢复结果，返回 keep 店的新 epoch */
    async function checkRestored(db: Db, m: Manifest): Promise<string> {
      const ids = (await db.kysely.selectFrom("stores").select(["id", "epoch"]).execute());
      expect(ids.map((s) => s.id)).toEqual([keep.storeId]);
      expect(ids[0]!.epoch).not.toBe(keep.epoch);
      for (const t of ["devices", "accounts", "entries", "products", "ops"] as const) {
        expect(await db.kysely.selectFrom(t).select("store_id").where("store_id", "=", doomed.storeId).execute()).toEqual([]);
      }
      expect(await db.kysely.selectFrom("store_purges").select("store_id").where("objects_cleared_at", "is", null).orderBy("store_id").execute()).toEqual(
        [{ store_id: doomed.storeId }, { store_id: early.storeId }].sort((a, b) => a.store_id.localeCompare(b.store_id)),
      );
      // 备份之后记的那笔不在：keep 店和清单逐项一致
      const now = await db.kysely.transaction().setIsolationLevel("repeatable read").execute((trx) => computeManifest(trx, new Date(m.taken_at)));
      expect(diffManifests(m, now, { excludeStores: [doomed.storeId], skipTables: true })).toEqual([]);
      // 旧令牌：已清除的店 401；没清除的店握手得到 epoch_mismatch，换新 epoch 后同步正常
      const app = makeApp(tdb, { clock, db });
      try {
        expect((await sync(app, doomed.token, { epoch: doomed.epoch, ops: [], pull: true })).status).toBe(401);
        const r1 = await sync(app, keep.token, { epoch: keep.epoch, ops: [], pull: true });
        expect(JSON.stringify(r1.body)).toContain("epoch_mismatch");
        const ok = await sync(app, keep.token, { epoch: ids[0]!.epoch, ops: [], pull: true });
        expect(ok.status, JSON.stringify(ok.body)).toBe(200);
      } finally {
        await app.close();
      }
      return ids[0]!.epoch;
    }
  });

  it("目标库里有大对象（本项目不用）→ 拒绝，空库判断也算上它", async () => {
    const t = await newDatabase();
    const db = createDb({ connectionString: t.url, max: 1 });
    try {
      await sql`SELECT lo_create(0)`.execute(db.kysely);
      expect((await inspectTarget(db.kysely)).state).toBe("foreign");
      await expect(prepareTarget(db.kysely, "20261120T030000Z-0123456789abcdef", true)).rejects.toThrow(/大对象/);
      await expect(prepareTarget(db.kysely, "20261120T030000Z-0123456789abcdef", false)).rejects.toThrow(/大对象/);
    } finally {
      await db.close();
      await dropDatabase(t.name);
    }
  });

  it("目标库不空又不是恢复留下的（可能是在用的库）→ 拒绝", async () => {
    const other = await createTestDb();
    try {
      await expect(prepareTarget(other.kysely, "20261120T030000Z-0123456789abcdef", true)).rejects.toThrow(/拒绝覆盖/);
    } finally {
      await other.drop();
    }
  });
});
