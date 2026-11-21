// S04：并发下的变更序号（§4.2「店铺锁内每改一行取一个新号」）与条码冲突。真实 Postgres，多个连接同时写。
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createDb, type Db } from "../src/db.ts";
import { buildApp } from "../src/app.ts";
import { takeRev, storeLockKey, withStoreLock } from "../src/sync/lock.ts";
import { TestClock } from "./helpers/auth.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { makeFastShop, makeTokenDevice } from "./helpers/ledger.ts";
import { newBarcode, op, sync, upsertFull, upsertQuick } from "./helpers/sync.ts";

let tdb: TestDb;
/** 三个独立的连接池，相当于三个服务器进程：进程内的排队各管各的，同一家店的写入只靠数据库里的店铺锁互斥 */
let pools: Db[];
beforeAll(async () => {
  tdb = await createTestDb();
  pools = Array.from({ length: 3 }, () => createDb({ connectionString: process.env.DATABASE_URL!, searchPath: tdb.schema, max: 8 }));
});
afterAll(async () => {
  for (const p of pools) await p.close();
  await tdb.drop();
});

/** 三个「进程」，请求轮流发给它们 */
function cluster() {
  const apps = pools.map((db) => buildApp({ config: testConfig(), db, logger: false, clock: new TestClock().now }));
  let i = 0;
  return {
    next: () => apps[i++ % apps.length]!,
    close: () => Promise.all(apps.map((a) => a.close())),
  };
}

/** 同店所有带 rev 的表 */
async function allRevs(storeId: string) {
  const out: number[] = [];
  for (const t of ["products", "product_barcodes", "removed", "entries", "sale_batches", "stock_lots"] as const) {
    const rows = await tdb.kysely.selectFrom(t).select("rev").where("store_id", "=", storeId).execute();
    out.push(...rows.map((r) => Number(r.rev)));
  }
  return out.sort((a, b) => a - b);
}

describe("变更序号", () => {
  it("8 台手机同时各登记 10 个新商品（只新增不修改）：所有行的 rev 恰好是 1..stores.rev，不重不漏", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const devices = [shop.family, ...(await Promise.all(Array.from({ length: 7 }, () => makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId))))];
    const c = cluster();
    const results = await Promise.all(
      devices.flatMap((d) =>
        Array.from({ length: 5 }, () => sync(c.next(), d.token, { epoch: shop.epoch, ops: [upsertFull(), upsertFull()], pull: false })),
      ),
    );
    await c.close();
    expect(results.filter((r) => !(r.status === 200 && r.body.results.every((x: { status: string }) => x.status === "applied"))).map((r) => [r.status, r.body])).toEqual([]);
    const revs = await allRevs(shop.storeId);
    const s = await tdb.kysely.selectFrom("stores").select("rev").where("id", "=", shop.storeId).executeTakeFirstOrThrow();
    expect(revs.length).toBe(8 * 10 * 2);
    expect(revs).toEqual(Array.from({ length: Number(s.rev) }, (_, i) => i + 1));
    // 每个 op 的两行（商品、单件码）拿的是连续的两个号：事务在锁内，别的请求插不进来
    const ps = await tdb.kysely
      .selectFrom("products as p")
      .innerJoin("product_barcodes as b", (j) => j.onRef("b.store_id", "=", "p.store_id").onRef("b.product_id", "=", "p.id"))
      .select(["p.rev as prev", "b.rev as brev"])
      .where("p.store_id", "=", shop.storeId)
      .execute();
    expect(ps.every((r) => Number(r.brev) === Number(r.prev) + 1)).toBe(true);
  });

  it("两家店同时写：各自从 1 开始编号，互不影响", async () => {
    const s1 = await makeFastShop(tdb.kysely);
    const s2 = await makeFastShop(tdb.kysely);
    const c = cluster();
    await Promise.all(
      Array.from({ length: 10 }, (_, i) => {
        const s = i % 2 ? s1 : s2;
        return sync(c.next(), s.family.token, { epoch: s.epoch, ops: [upsertFull()], pull: false });
      }),
    );
    await c.close();
    expect(await allRevs(s1.storeId)).toEqual(Array.from({ length: 10 }, (_, i) => i + 1));
    expect(await allRevs(s2.storeId)).toEqual(Array.from({ length: 10 }, (_, i) => i + 1));
  });

  it("同步写入真的在店铺锁里：另一个事务拿着这家店的锁时，请求等到锁放开才应用；别的店不受影响", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const other = await makeFastShop(tdb.kysely);
    const c = cluster();
    const locker = await tdb.pool.connect();
    await locker.query("BEGIN");
    await locker.query("SELECT pg_advisory_xact_lock($1)", [storeLockKey(shop.storeId)]);
    let done = false;
    const pending = sync(c.next(), shop.family.token, { epoch: shop.epoch, ops: [upsertFull()], pull: false }).then((r) => {
      done = true;
      return r;
    });
    // 别的店照常
    const r2 = await sync(c.next(), other.family.token, { epoch: other.epoch, ops: [upsertFull()], pull: false });
    expect(r2.status).toBe(200);
    await new Promise((r) => setTimeout(r, 300));
    expect(done).toBe(false);
    expect(await allRevs(shop.storeId)).toEqual([]);
    await locker.query("COMMIT");
    locker.release();
    const r = await pending;
    await c.close();
    expect(r.status).toBe(200);
    expect(await allRevs(shop.storeId)).toEqual([1, 2]);
  });

  it("事务回滚时取到的号一起回滚，不留空洞", async () => {
    const shop = await makeFastShop(tdb.kysely);
    await expect(
      withStoreLock(tdb.kysely, shop.storeId, async (tx) => {
        expect(await tx.nextRev()).toBe(1);
        expect(await tx.nextRev()).toBe(2);
        throw new Error("故意失败");
      }),
    ).rejects.toThrow("故意失败");
    await withStoreLock(tdb.kysely, shop.storeId, async (tx) => {
      expect(await tx.nextRev()).toBe(1);
    });
  });

  it("取号函数只能在店铺锁里用：没拿锁直接取号会报错", async () => {
    const shop = await makeFastShop(tdb.kysely);
    await expect(
      tdb.kysely.transaction().execute(async (trx) => {
        await takeRev(trx, shop.storeId);
      }),
    ).rejects.toThrow(/店铺锁/);
    const s = await tdb.kysely.selectFrom("stores").select("rev").where("id", "=", shop.storeId).executeTakeFirstOrThrow();
    expect(s.rev).toBe("0");
  });
});

describe("并发的条码冲突", () => {
  it("6 台手机同时登记同一个条码（各自的商品 id）：只有一个商品，其余 5 个都是别名并拿到指向它的 remap", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const cashier = await makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId, "cashier");
    const devices = [shop.family, cashier, ...(await Promise.all(Array.from({ length: 4 }, () => makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId))))];
    const code = newBarcode();
    const ops = devices.map((d, i) => (d === cashier ? upsertQuick({ barcode: code, name: `收银员的`, price: 1 }) : upsertFull({ barcode: code, name: `第${i}台`, price: 100 + i })));
    const c = cluster();
    const rs = await Promise.all(devices.map((d, i) => sync(c.next(), d.token, { epoch: shop.epoch, ops: [ops[i]!], pull: false })));
    // 每台手机接着改自己以为的那个商品
    const edits = await Promise.all(
      devices.map((d, i) =>
        d === cashier ? null : sync(c.next(), d.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: ops[i]!.payload.product_id, low_at: i })], pull: false }),
      ),
    );
    await c.close();
    const ps = await tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", shop.storeId).execute();
    expect(ps).toHaveLength(1);
    const winner = ps[0]!;
    const winnerOp = ops.find((o) => o.payload.product_id === winner.id)!;
    expect(winner.name).toBe(winnerOp.payload.name);
    expect(winner.price_fen).toBe(String(winnerOp.payload.price_fen));
    const aliases = await tdb.kysely.selectFrom("product_aliases").selectAll().where("store_id", "=", shop.storeId).execute();
    expect(aliases.map((x) => x.alias_id).sort()).toEqual(ops.filter((o) => o !== winnerOp).map((o) => o.payload.product_id as string).sort());
    expect(aliases.every((x) => x.product_id === winner.id)).toBe(true);
    rs.forEach((r, i) => {
      const res = r.body.results[0];
      expect(res.status).toBe("applied");
      if (ops[i] === winnerOp) expect(res.remap).toBeUndefined();
      else expect(res.remap).toEqual({ [ops[i]!.payload.product_id as string]: winner.id });
    });
    for (const e of edits) if (e) expect(e.body.results[0].status).toBe("applied");
  });
});
