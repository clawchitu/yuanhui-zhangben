// S04：变更序号与分页（§4.2，不变式 I7）。两条流各自游标；墓碑；拉取中途有新写入不漏不重。
import fc from "fast-check";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { makeApp } from "./helpers/auth.ts";
import { insertSale, insertStockIn, makeFastShop, makeTokenDevice } from "./helpers/ledger.ts";
import { newBarcode, op, pullAll, Replica, syncOk, upsertFull, type Op } from "./helpers/sync.ts";

let tdb: TestDb;
let oneShot: FastifyInstance;
beforeAll(async () => {
  tdb = await createTestDb();
  oneShot = makeApp(tdb, { syncPageSize: 100_000 });
});
afterAll(async () => {
  await oneShot.close();
  await tdb.drop();
});

/** 一次拉完（页大小足够大） */
async function full(token: string, epoch: string) {
  const r = await pullAll(oneShot, token, epoch);
  expect(r.pages).toBe(1);
  return r;
}

/** 一个店里造一批「一个 op 改多行」的数据：登记（商品 + 单件码）、改基本单位（商品 + 所有单件码）、整件码、解除、流水 */
async function seed(app: FastifyInstance, shop: Awaited<ReturnType<typeof makeFastShop>>, n = 4) {
  const ids: string[] = [];
  for (let i = 0; i < n; i++) {
    const p = upsertFull({ name: `商品${i}`, price: 100 + i });
    const pid = p.payload.product_id as string;
    ids.push(pid);
    const box = newBarcode();
    await syncOk(app, shop.family.token, {
      epoch: shop.epoch,
      ops: [
        p,
        op("barcode_link", { barcode: newBarcode(), product_id: pid, pack_qty: 1, unit_name: "罐" }),
        op("barcode_link", { barcode: box, product_id: pid, pack_qty: 24, unit_name: "箱", pack_price_fen: 5000 }),
        // 改基本单位：商品 + 两个单件码，一个 op 改 3 行
        op("product_edit", { product_id: pid, base_unit: "听" }),
        ...(i % 2 ? [op("barcode_unlink", { barcode: box, product_id: pid })] : []),
      ],
      pull: false,
    });
    await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: shop.family.id, productIds: [pid, pid] });
    if (i % 2 === 0) await insertStockIn(tdb.kysely, { storeId: shop.storeId, deviceId: shop.family.id, productId: pid });
  }
  return ids;
}

describe("分页", () => {
  it("页大小 2：每页每条流不超过 2 行，逐页拉取的结果 = 一次拉完的结果", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const app = makeApp(tdb, { syncPageSize: 2 });
    await seed(app, shop);
    const paged = await pullAll(app, shop.family.token, shop.epoch, new PageCheck(2));
    await app.close();
    const once = await full(shop.family.token, shop.epoch);
    expect(paged.pages).toBeGreaterThan(5);
    expect(paged.snapshot()).toEqual(once.snapshot());
    expect(paged.cursors).toEqual(once.cursors);
    expect(paged.duplicates()).toEqual([]);
    // 一次拉完的结果里确实有「一个 op 改了多行」：同一个 op 的 3 行 rev 连续
    expect(once.snapshot().products.length).toBe(4);
    expect(once.snapshot().entries.length).toBe(4 * 2 + 2);
    expect(once.snapshot().lots.length).toBe(2);
  });

  it("I7 性质测试：随机的 op 序列、随机页大小，分页拉取的结果集合 = 一次拉完的结果集合", async () => {
    // 每种页大小建一个应用、各轮共用（每轮新建应用要重新编译路由的 schema，机器忙的时候很慢）
    const apps = new Map<number, FastifyInstance>();
    const appWithPageSize = (n: number) => {
      let a = apps.get(n);
      if (!a) apps.set(n, (a = makeApp(tdb, { syncPageSize: n })));
      return a;
    };
    try {
      const details = await fc.check(
        fc.asyncProperty(
          fc.array(fc.constantFrom("new", "edit", "edit_unit", "link", "unlink", "sale", "stock_in"), { minLength: 1, maxLength: 25 }),
          fc.integer({ min: 1, max: 7 }),
          fc.integer({ min: 0, max: 2 ** 31 }),
          async (script, pageSize, seed) => {
            const shop = await makeFastShop(tdb.kysely);
            const app = appWithPageSize(pageSize);
            await runScript(app, shop, script, seed);
            const paged = await pullAll(app, shop.family.token, shop.epoch, new PageCheck(pageSize));
            const once = await full(shop.family.token, shop.epoch);
            expect(paged.snapshot()).toEqual(once.snapshot());
            expect(paged.duplicates()).toEqual([]);
            await expectRevsUnique(shop.storeId);
          },
        ),
        // 时间预算：这条测试的耗时 ≈ 几千次顺序的数据库往返，机器忙（同批的 argon2 测试、共享的 Mac）时每次往返慢几十倍，
        // 固定跑 40 轮会超过用例的 30 秒时限，报成「超时」而不是反例（Codex 第二轮实测首跑超时）。
        // 改成最多 40 轮、最多 20 秒（含缩小反例），到时间停下不算失败，但至少要跑满 10 轮；平时 40 轮不到 1 秒。
        { numRuns: 40, interruptAfterTimeLimit: 20_000, markInterruptAsFailure: false },
      );
      if (details.failed) throw new Error(fc.defaultReportMessage(details));
      expect(details.numRuns).toBeGreaterThanOrEqual(details.interrupted ? 10 : 40);
    } finally {
      for (const a of apps.values()) await a.close();
    }
  });

  it("拉取进行到一半时别的手机继续记账：最终不漏不重（新增的行每个版本只收到一次）", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const other = await makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId);
    const app = makeApp(tdb, { syncPageSize: 2 });
    await seed(app, shop, 3);
    const phone = new PageCheck(2);
    let rounds = 0;
    for (;;) {
      const body = await syncOk(app, shop.family.token, { epoch: shop.epoch, cursors: phone.cursors });
      phone.apply(body);
      if (!body.has_more.catalog && !body.has_more.ledger) break;
      // 每拉一页，另一台手机就新登记一个商品、记一笔卖出、改一下最早那个商品
      if (rounds < 8) {
        const p = upsertFull({ name: `中途${rounds}` });
        await syncOk(app, other.token, { epoch: shop.epoch, ops: [p], pull: false });
        await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: other.id, productIds: [p.payload.product_id as string] });
      }
      rounds += 1;
      expect(rounds).toBeLessThan(500);
    }
    await app.close();
    const once = await full(shop.family.token, shop.epoch);
    expect(phone.snapshot()).toEqual(once.snapshot());
    expect(phone.duplicates()).toEqual([]);
    expect(once.snapshot().products.filter((p: { name: string }) => p.name.startsWith("中途"))).toHaveLength(8);
  });

  it("中途有行被改（拿到新 rev）：拿到的是最新版本，旧版本不会在新版本之后出现", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const app = makeApp(tdb, { syncPageSize: 2 });
    const ids = await seed(app, shop, 3);
    const phone = new PageCheck(2);
    let i = 0;
    for (;;) {
      const body = await syncOk(app, shop.family.token, { epoch: shop.epoch, cursors: phone.cursors });
      phone.apply(body);
      if (!body.has_more.catalog && !body.has_more.ledger) break;
      // 反复改已经拉过的商品和还没拉到的商品
      await syncOk(app, shop.family.token, {
        epoch: shop.epoch,
        ops: [op("product_edit", { product_id: ids[i % ids.length]!, price_fen: 1000 + i })],
        pull: false,
      });
      i += 1;
    }
    await app.close();
    expect(phone.snapshot()).toEqual((await full(shop.family.token, shop.epoch)).snapshot());
  });
});

describe("墓碑", () => {
  it("解除整件码后，别的设备增量拉取收到墓碑，本地删掉这个条码", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const other = await makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId);
    const app = makeApp(tdb);
    const p = upsertFull();
    const pid = p.payload.product_id as string;
    const box = newBarcode();
    await syncOk(app, shop.family.token, {
      epoch: shop.epoch,
      ops: [p, op("barcode_link", { barcode: box, product_id: pid, pack_qty: 24, unit_name: "箱", pack_price_fen: 6500 })],
    });
    const phoneB = await pullAll(app, other.token, shop.epoch);
    expect(phoneB.barcodes.has(box)).toBe(true);

    await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [op("barcode_unlink", { barcode: box, product_id: pid })] });
    const delta = await syncOk(app, other.token, { epoch: shop.epoch, cursors: phoneB.cursors });
    phoneB.apply(delta);
    expect(delta.changes.removed).toEqual([{ kind: "barcode", row_id: box, rev: expect.any(Number) }]);
    expect(delta.changes.barcodes).toEqual([]);
    expect(phoneB.barcodes.has(box)).toBe(false);
    expect(phoneB.barcodes.has(p.payload.barcode as string)).toBe(true);

    // 重新挂上：之后拉到的是这一行，不再下发那条旧墓碑（不管手机先处理哪个数组都不会误删）
    await syncOk(app, shop.family.token, {
      epoch: shop.epoch,
      ops: [op("barcode_link", { barcode: box, product_id: pid, pack_qty: 12, unit_name: "箱" })],
    });
    const fresh = await pullAll(app, other.token, shop.epoch);
    const again = await syncOk(app, other.token, { epoch: shop.epoch, cursors: phoneB.cursors });
    phoneB.apply(again);
    await app.close();
    expect(fresh.barcodes.get(box)).toMatchObject({ pack_qty: 12 });
    expect(again.changes.removed).toEqual([]);
    expect(phoneB.snapshot()).toEqual(fresh.snapshot());
  });
});

describe("两条流各自游标", () => {
  it("只推进 catalog 游标：ledger 游标不动，ledger 的行一条不少；两条流的行互不串", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const app = makeApp(tdb, { syncPageSize: 2 });
    await seed(app, shop, 3);
    const once = await full(shop.family.token, shop.epoch);

    // 只拉 catalog：每次都带 ledger=0，响应里的 ledger 页永远是同一页
    let catalog = 0;
    const firstLedger = await syncOk(app, shop.family.token, { epoch: shop.epoch, cursors: { catalog: 0, ledger: 0 } });
    const catalogRows = new Set<number>();
    for (;;) {
      const b = await syncOk(app, shop.family.token, { epoch: shop.epoch, cursors: { catalog, ledger: 0 } });
      expect(b.changes.entries).toEqual(firstLedger.changes.entries);
      expect(b.changes.batches).toEqual(firstLedger.changes.batches);
      expect(b.changes.lots).toEqual(firstLedger.changes.lots);
      expect(b.cursors.ledger).toBe(firstLedger.cursors.ledger);
      expect(b.has_more.ledger).toBe(true);
      for (const x of [...b.changes.products, ...b.changes.barcodes, ...b.changes.removed]) catalogRows.add(x.rev);
      catalog = b.cursors.catalog;
      if (!b.has_more.catalog) break;
    }
    // catalog 拉到底以后，再从 ledger=0 拉 ledger：全部流水都在
    const phone = new Replica();
    phone.cursors = { catalog, ledger: 0 };
    await pullAll(app, shop.family.token, shop.epoch, phone);
    await app.close();
    expect(phone.snapshot().entries).toEqual(once.snapshot().entries);
    expect(phone.snapshot().batches).toEqual(once.snapshot().batches);
    expect(phone.snapshot().lots).toEqual(once.snapshot().lots);
    expect(phone.snapshot().products).toEqual([]);
    const ledgerRevs = [...phone.entries.values(), ...phone.batches.values(), ...phone.lots.values()].map((x) => x.rev);
    expect(ledgerRevs.filter((r) => catalogRows.has(r))).toEqual([]);
  });

  it("游标超过本店当前序号（手机记错了）：不报错、不倒退，什么都不返回", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const app = makeApp(tdb);
    await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [upsertFull()] });
    const b = await syncOk(app, shop.family.token, { epoch: shop.epoch, cursors: { catalog: 1000, ledger: 1000 } });
    await app.close();
    expect(b.cursors).toEqual({ catalog: 1000, ledger: 1000 });
    expect(b.changes.products).toEqual([]);
    expect(b.has_more).toEqual({ catalog: false, ledger: false });
  });

  it("total_products = 本店商品总数（首次同步的进度用）", async () => {
    const shop = await makeFastShop(tdb.kysely);
    const app = makeApp(tdb, { syncPageSize: 2 });
    const ops: Op[] = Array.from({ length: 5 }, (_, i) => upsertFull({ name: `p${i}` }));
    const b = await syncOk(app, shop.family.token, { epoch: shop.epoch, ops });
    await app.close();
    expect(b.total_products).toBe(5);
    expect(b.changes.products.length + b.changes.barcodes.length).toBe(2);
  });
});

/** 每页检查行数不超过页大小 */
class PageCheck extends Replica {
  private readonly size: number;
  constructor(size: number) {
    super();
    this.size = size;
  }
  override apply(body: Parameters<Replica["apply"]>[0]) {
    const c = body.changes;
    expect(c.products.length + c.barcodes.length + c.removed.length).toBeLessThanOrEqual(this.size);
    expect(c.entries.length + c.batches.length + c.lots.length).toBeLessThanOrEqual(this.size);
    // 页内按 rev 升序拼起来，且都大于请求的游标
    const revs = [...c.products, ...c.barcodes, ...c.removed].map((x: { rev: number }) => x.rev);
    expect(revs.every((r: number) => r > this.cursors.catalog && r <= body.cursors.catalog)).toBe(true);
    const lrevs = [...c.entries, ...c.batches, ...c.lots].map((x: { rev: number }) => x.rev);
    expect(lrevs.every((r: number) => r > this.cursors.ledger && r <= body.cursors.ledger)).toBe(true);
    super.apply(body);
  }
}

/** 同店所有表的 rev 合起来不重复，且都不超过 stores.rev */
async function expectRevsUnique(storeId: string) {
  const k = tdb.kysely;
  const all: number[] = [];
  for (const t of ["products", "product_barcodes", "removed", "entries", "sale_batches", "stock_lots"] as const) {
    const rows = await k.selectFrom(t).select("rev").where("store_id", "=", storeId).execute();
    all.push(...rows.map((r) => Number(r.rev)));
  }
  const s = await k.selectFrom("stores").select("rev").where("id", "=", storeId).executeTakeFirstOrThrow();
  expect(new Set(all).size).toBe(all.length);
  expect(Math.max(0, ...all)).toBeLessThanOrEqual(Number(s.rev));
}

/** 按脚本造数据：随机选已有的商品 / 条码 */
async function runScript(app: FastifyInstance, shop: Awaited<ReturnType<typeof makeFastShop>>, script: string[], seed: number) {
  let x = seed || 1;
  const rnd = (n: number) => {
    x = (x * 1103515245 + 12345) % 2 ** 31;
    return x % n;
  };
  const products: string[] = [];
  const links: Array<{ barcode: string; pid: string }> = [];
  // 连续的商品类 op 攒成一个请求发（一个请求里按顺序逐个应用，号的先后和一个一个发完全一样），
  // 遇到直接写库的卖出 / 进货之前先发掉，保证号的先后就是脚本的先后
  let pending: Op[] = [];
  const send = async (o: Op) => void pending.push(o);
  const flush = async () => {
    if (pending.length === 0) return;
    const ops = pending;
    pending = [];
    await syncOk(app, shop.family.token, { epoch: shop.epoch, ops, pull: false });
  };
  for (const step of script) {
    if (step === "new" || products.length === 0) {
      const p = upsertFull({ name: `p${products.length}` });
      products.push(p.payload.product_id as string);
      await send(p);
      continue;
    }
    const pid = products[rnd(products.length)]!;
    switch (step) {
      case "edit":
        await send(op("product_edit", { product_id: pid, price_fen: rnd(10_000), name: `改${rnd(100)}` }));
        break;
      case "edit_unit":
        await send(op("product_edit", { product_id: pid, base_unit: ["个", "瓶", "罐", "包"][rnd(4)]! }));
        break;
      case "link": {
        const barcode = newBarcode();
        links.push({ barcode, pid });
        await send(op("barcode_link", { barcode, product_id: pid, pack_qty: 2 + rnd(30), unit_name: "箱", ...(rnd(2) ? { pack_price_fen: rnd(9999) } : {}) }));
        break;
      }
      case "unlink": {
        const l = links.splice(rnd(links.length || 1), 1)[0];
        if (l) await send(op("barcode_unlink", { barcode: l.barcode, product_id: l.pid }));
        break;
      }
      case "sale":
        await flush();
        await insertSale(tdb.kysely, { storeId: shop.storeId, deviceId: shop.family.id, productIds: [pid, products[rnd(products.length)]!] });
        break;
      case "stock_in":
        await flush();
        await insertStockIn(tdb.kysely, { storeId: shop.storeId, deviceId: shop.family.id, productId: pid });
        break;
    }
  }
  await flush();
}
