// S05b ①：cost.json 里只含进货 / 卖出 / 期初 / 撤销的各组，逐步经 /v1/sync 写库，entries 和 products 与向量逐分一致（§14 S05-6 ①）。
// 另：S05-4 经同步接口——Int64 / 契约 SignedFen 货值越界拒 invalid 并留档、不产生 500；occurred_at 年份 0000 拒 invalid、不留档。
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { sql } from "kysely";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import { FEN, INT64 } from "../src/ledger/cost.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { makeApp, TestClock } from "./helpers/auth.ts";
import { CONTRACTS_DIR } from "./helpers/contract.ts";
import { assertDbLedger, makeFastShop } from "./helpers/ledger.ts";
import { op, sync, syncOk, upsertFull } from "./helpers/sync.ts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;
const { cases } = JSON.parse(readFileSync(resolve(CONTRACTS_DIR, "vectors", "cost.json"), "utf8")) as { cases: Any[] };
// S06 起盘点（count）也经同步写库：带当前 stock_ver 做 base_ver
const SYNCABLE = new Set(["stock_in", "sale", "opening", "void", "count"]);
const syncable = cases.filter((c) => c.steps.every((s: Any) => SYNCABLE.has(s.action.type)));

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());
const AT = "2026-11-20T01:59:00Z";

async function shopWithProduct() {
  const shop = await makeFastShop(tdb.kysely);
  const app = makeApp(tdb, { clock: new TestClock() });
  const u = upsertFull();
  await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [u], pull: false });
  return { shop, app, pid: u.payload.product_id as string };
}
const product = (storeId: string, pid: string) => tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).where("id", "=", pid).executeTakeFirstOrThrow();
const setState = (storeId: string, pid: string, s: { q: number | bigint; v: number | bigint; c: number | bigint | null; k: boolean }) =>
  tdb.kysely
    .updateTable("products")
    .set({ stock_qty: Number(s.q), stock_value_fen: String(s.v), last_cost_fen: s.c === null ? null : String(s.c), cost_known: s.k })
    .where("store_id", "=", storeId)
    .where("id", "=", pid)
    .execute();

describe("cost.json 经 /v1/sync 写库（①）", () => {
  it("只含进货 / 卖出 / 期初 / 撤销 / 盘点的向量不少于 21 组，含 u ≠ c 的盘盈 cost-27", () => {
    expect(syncable.length).toBeGreaterThanOrEqual(21);
    expect(syncable.map((c) => c.id)).toContain("cost-27");
  });
  for (const c of syncable) {
    it(`${c.id}：${c.title}`, async () => {
      const { shop, app, pid } = await shopWithProduct();
      await setState(shop.storeId, pid, c.initial);
      const send = async (o: ReturnType<typeof op>) => (await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [o], pull: false })).results[0];
      const stepEntry: string[] = []; // 每一步主流水的 id（撤销的 target）
      const stepRows: string[][] = [];
      for (const [i, s] of (c.steps as Any[]).entries()) {
        const a = s.action;
        const eid = randomUUID();
        let o: ReturnType<typeof op>;
        if (a.type === "stock_in") o = op("stock_in", { entry_id: eid, product_id: pid, barcode: "6900000000001", pack_qty: a.pack_qty, pack_count: a.pack_count, unit_cost_fen: a.unit_cost_fen }, { at: AT });
        else if (a.type === "sale") {
          expect(a.list_amount_fen % a.pack_count, `${c.id} 第 ${i} 步：原价要能整除件数`).toBe(0);
          o = op("sale_batch", {
            batch_id: randomUUID(),
            paid_total_fen: a.amount_fen,
            lines: [{ entry_id: eid, product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: a.pack_qty, pack_count: a.pack_count, unit_price_fen: a.list_amount_fen / a.pack_count }],
          }, { at: AT });
        } else if (a.type === "opening") {
          const ver = Number((await product(shop.storeId, pid)).stock_ver);
          o = op("opening", { entry_id: eid, product_id: pid, counted_qty: a.counted_qty, base_ver: ver, ...(a.unit_cost_fen === null ? {} : { unit_cost_fen: a.unit_cost_fen }) }, { at: AT });
        } else if (a.type === "count") {
          const p = await product(shop.storeId, pid);
          o = op("count", { entry_id: eid, product_id: pid, counted_qty: a.counted_qty, base_qty: p.stock_qty, base_ver: Number(p.stock_ver) }, { at: AT });
        } else o = op("void", { target: { entry_id: stepEntry[a.target_step]! } }, { at: AT });
        if (s.expect.error !== undefined) {
          // 被拒的一步：拒 invalid 并留档，库里不变
          const before = await product(shop.storeId, pid);
          expect(await send(o), `${c.id} 第 ${i} 步`).toEqual({ id: o.id, status: "rejected", code: s.expect.error });
          expect(await tdb.kysely.selectFrom("entries").select("id").where("store_id", "=", shop.storeId).where("op_id", "=", o.id).execute()).toEqual([]);
          expect(await product(shop.storeId, pid), `${c.id} 第 ${i} 步之后商品不变`).toEqual(before);
          stepEntry.push(eid);
          stepRows.push([]);
          continue;
        }
        expect(await send(o), `${c.id} 第 ${i} 步`).toEqual({ id: o.id, status: "applied" });
        stepEntry.push(eid);
        const got = await tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", shop.storeId).where("op_id", "=", o.id).orderBy("seq").execute();
        stepRows.push(got.map((e) => e.id));
        const want = s.expect.entries as Any[];
        expect(got.map((e) => e.type), `${c.id} 第 ${i} 步的流水类型`).toEqual(want.map((w) => w.type));
        for (const [j, w] of want.entries()) {
          const g = got[j]!;
          const at = `${c.id} 第 ${i} 步第 ${j} 条（${w.type}）`;
          for (const k of ["qty_delta", "amount_fen", "list_amount_fen", "cogs_fen", "value_delta_fen"] as const) expect(Number(g[k]), `${at} ${k}`).toBe(w[k]);
          expect(g.cost_missing, `${at} cost_missing`).toBe(w.cost_missing);
          if ("unit_cost_fen" in w) expect(g.unit_cost_fen === null ? null : Number(g.unit_cost_fen), `${at} unit_cost_fen`).toBe(w.unit_cost_fen ?? null);
          if ("reverses_step" in w) {
            const types = await tdb.kysely.selectFrom("entries").select(["id", "type"]).where("store_id", "=", shop.storeId).where("id", "in", stepRows[w.reverses_step]!).execute();
            expect(g.reverses_entry_id, `${at} reverses`).toBe(types.find((x) => x.type === w.type)!.id);
          } else expect(g.reverses_entry_id, `${at} 不是冲销行`).toBeNull();
          if ("covers_steps" in w) {
            const covered = await tdb.kysely.selectFrom("entries").select("id").where("store_id", "=", shop.storeId).where("cost_fix_entry_id", "=", g.id).orderBy("seq").execute();
            expect(covered.map((x) => x.id), `${at} covers`).toEqual((w.covers_steps as number[]).map((st) => stepEntry[st]));
          }
        }
        const p = await product(shop.storeId, pid);
        const st = s.expect.state;
        expect({ q: p.stock_qty, v: Number(p.stock_value_fen), c: p.last_cost_fen === null ? null : Number(p.last_cost_fen), k: p.cost_known }, `${c.id} 第 ${i} 步之后的状态`).toEqual({ q: st.q, v: st.v, c: st.c, k: st.k });
      }
      const init = c.initial;
      await assertDbLedger(tdb.kysely, shop.storeId, pid, { q: BigInt(init.q), v: BigInt(init.v), c: init.c === null ? null : BigInt(init.c), k: init.k });
      await app.close();
    });
  }
});

describe("S05-4 经同步接口", () => {
  it("货值越过契约 SignedFen 上限（还在 Int64 内）：进货拒 invalid 并留档，不产生 500，库里不变", async () => {
    const { shop, app, pid } = await shopWithProduct();
    await setState(shop.storeId, pid, { q: 1, v: FEN.max - 50n, c: 1, k: true });
    const o = op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: 1, unit_cost_fen: 100 }, { at: AT });
    const r = await sync(app, shop.family.token, { epoch: shop.epoch, ops: [o] });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.results).toEqual([{ id: o.id, status: "rejected", code: "invalid" }]);
    expect(BigInt((await product(shop.storeId, pid)).stock_value_fen)).toBe(FEN.max - 50n);
    await app.close();
  });

  it("货值溢出 Int64：进货拒 invalid 并留档，不产生 500，库里不变", async () => {
    const { shop, app, pid } = await shopWithProduct();
    await setState(shop.storeId, pid, { q: 1, v: INT64.max - 50n, c: 1, k: true });
    const o = op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: 1, unit_cost_fen: 100 }, { at: AT });
    const r = await sync(app, shop.family.token, { epoch: shop.epoch, ops: [o], pull: false });
    expect(r.status).toBe(200);
    expect(r.body.results).toEqual([{ id: o.id, status: "rejected", code: "invalid" }]);
    expect(await tdb.kysely.selectFrom("ops").select(["status", "reject_code"]).where("store_id", "=", shop.storeId).where("id", "=", o.id).executeTakeFirst()).toEqual({ status: "rejected", reject_code: "invalid" });
    const p = await product(shop.storeId, pid);
    expect([p.stock_qty, BigInt(p.stock_value_fen), Number(p.stock_ver)]).toEqual([1, INT64.max - 50n, 0]);
    await app.close();
  });

  it("货值超出契约 SignedFen（±2^53−1，Codex P1 复现）：卖出拒 invalid 并留档，开着拉取不 500，重放同结果", async () => {
    const { shop, app, pid } = await shopWithProduct();
    const opening = op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 0, base_ver: 0, unit_cost_fen: 99_999_999 }, { at: AT });
    expect((await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [opening] })).results).toEqual([{ id: opening.id, status: "applied" }]);
    const before = await product(shop.storeId, pid);
    const sale = op("sale_batch", {
      batch_id: randomUUID(),
      paid_total_fen: 10_000,
      lines: Array.from({ length: 10 }, () => ({ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 9_999, pack_count: 1_000, unit_price_fen: 1 })),
    }, { at: AT });
    for (let i = 0; i < 2; i++) {
      // 第二次是同 id、同内容的重放；两次都开着拉取（不传 pull:false）
      const r = await sync(app, shop.family.token, { epoch: shop.epoch, ops: [sale] });
      expect(r.status, JSON.stringify(r.body)).toBe(200);
      expect(r.body.results).toEqual([{ id: sale.id, status: "rejected", code: "invalid", ...(i === 1 ? { replayed: true } : {}) }]);
    }
    expect(await tdb.kysely.selectFrom("ops").select(["status", "reject_code"]).where("store_id", "=", shop.storeId).where("id", "=", sale.id).executeTakeFirst()).toEqual({ status: "rejected", reject_code: "invalid" });
    expect(await tdb.kysely.selectFrom("entries").select("id").where("store_id", "=", shop.storeId).where("op_id", "=", sale.id).execute()).toEqual([]);
    expect(await product(shop.storeId, pid)).toEqual(before);
    // 之后拉取照常
    const pulled = await sync(app, shop.family.token, { epoch: shop.epoch, ops: [] });
    expect(pulled.status, JSON.stringify(pulled.body)).toBe(200);
    await assertDbLedger(tdb.kysely, shop.storeId, pid);
    await app.close();
  });

  it("occurred_at 年份 0000（含换算成 UTC 落到公元前的）：四种记账 op 和商品 op 都拒 invalid、不留档，不产生 500；同批别的 op 照常", async () => {
    const { shop, app, pid } = await shopWithProduct();
    const Y0 = "0000-06-01T00:00:00Z";
    const bad = [
      op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: 1, unit_cost_fen: 100 }, { at: Y0 }),
      op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 3 }, { at: Y0 }),
      op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 100, lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 100 }] }, { at: Y0 }),
      op("void", { target: { entry_id: randomUUID() } }, { at: Y0 }),
      { ...upsertFull(), occurred_at: Y0 },
      op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 100, lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 100 }] }, { at: "0001-01-01T00:30:00+01:00" }),
    ];
    const good = op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 3 }, { at: AT });
    const r = await sync(app, shop.family.token, { epoch: shop.epoch, ops: [...bad, good], pull: false });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.results).toEqual([...bad.map((o) => ({ id: o.id, status: "rejected", code: "invalid" })), { id: good.id, status: "applied" }]);
    const ops = await tdb.kysely.selectFrom("ops").select("id").where("store_id", "=", shop.storeId).where("id", "in", bad.map((o) => o.id)).execute();
    expect(ops).toEqual([]);
    expect((await product(shop.storeId, pid)).stock_qty).toBe(3);
    await app.close();
  });
});

describe("手机时钟超前（§4.4，§8 S05 验收）", () => {
  it("卖出的 occurred_at 超前 1 天：批次头和流水都改成服务器收到的时间，流水 flags 带 clock_adjusted 和原始时间", async () => {
    const { shop, app, pid } = await shopWithProduct();
    const ahead = "2026-11-21T02:00:00Z"; // TestClock 是 2026-11-20T02:00:00Z
    const s = op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 300, lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 300 }] }, { at: ahead });
    expect((await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [s], pull: false })).results).toEqual([{ id: s.id, status: "applied" }]);
    const now = new Date("2026-11-20T02:00:00Z");
    const e = await tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", shop.storeId).where("op_id", "=", s.id).executeTakeFirstOrThrow();
    expect(e.occurred_at).toEqual(now);
    expect(e.flags).toMatchObject({ clock_adjusted: true, client_occurred_at: ahead });
    const b = await tdb.kysely.selectFrom("sale_batches").selectAll().where("store_id", "=", shop.storeId).where("id", "=", s.payload.batch_id as string).executeTakeFirstOrThrow();
    expect(b.occurred_at).toEqual(now);
    await app.close();
  });
});

describe("记账 op 预检查之后写库报 22xxx（§14 S04-14、S05-4 第三层，注入故障）", () => {
  beforeAll(async () => {
    await sql`CREATE TABLE fault_ops (op_id uuid PRIMARY KEY, sqlstate text NOT NULL)`.execute(tdb.kysely);
    await sql.raw(`
      CREATE FUNCTION inject_entry_fault() RETURNS trigger LANGUAGE plpgsql AS $$
      DECLARE s text;
      BEGIN
        SELECT sqlstate INTO s FROM fault_ops WHERE op_id = NEW.op_id;
        IF s IS NOT NULL THEN RAISE EXCEPTION '注入的故障 %', s USING ERRCODE = s; END IF;
        RETURN NEW;
      END $$;
      CREATE TRIGGER inject_entry_fault BEFORE INSERT ON entries FOR EACH ROW EXECUTE FUNCTION inject_entry_fault();
    `).execute(tdb.kysely);
  });

  /** 这家店的全部记账状态：ops、流水、批次头、投影、stores.rev */
  const snapshot = async (storeId: string) => {
    const k = tdb.kysely;
    return {
      ops: await k.selectFrom("ops").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
      entries: await k.selectFrom("entries").selectAll().where("store_id", "=", storeId).orderBy("seq").execute(),
      batches: await k.selectFrom("sale_batches").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
      products: await k.selectFrom("products").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
      rev: (await k.selectFrom("stores").select("rev").where("id", "=", storeId).executeTakeFirstOrThrow()).rev,
    };
  };
  const saleOf = (pid: string) =>
    op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 300, lines: [{ entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", name: "x", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 300 }] }, { at: AT });
  const kinds = {
    stock_in: async (pid: string) => op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: 2, unit_cost_fen: 100 }, { at: AT }),
    opening: async (pid: string, ver: number) => op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: 7, base_ver: ver, unit_cost_fen: 120 }, { at: AT }),
    sale_batch: async (pid: string) => saleOf(pid),
    void: async (_pid: string, _ver: number, saleBatchId: string) => op("void", { target: { batch_id: saleBatchId } }, { at: AT }),
  } as const;

  for (const [type, make] of Object.entries(kinds)) {
    for (const sqlstate of ["22003", "22P02"]) {
      it(`${type}（${sqlstate}）：整个请求 500、同批的 op 一起回滚、库里什么都不变、记 error 日志；去掉故障重发后正常入账`, async () => {
        const shop = await makeFastShop(tdb.kysely);
        const lines: Array<Record<string, unknown>> = [];
        const app = buildApp({ config: testConfig(), db: tdb, logStream: { write: (l) => void lines.push(JSON.parse(l)) } });
        const u = upsertFull();
        const pid = u.payload.product_id as string;
        const sale0 = saleOf(pid);
        await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [u, sale0], pull: false });
        // 同批前面那条进货先应用、stock_ver + 1，期初的 base_ver 要对上它之后的版本
        const ver = Number((await product(shop.storeId, pid)).stock_ver) + 1;
        const bad = await make(pid, ver, sale0.payload.batch_id as string);
        const other = op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: 1, unit_cost_fen: 50 }, { at: AT });
        await tdb.kysely.insertInto("fault_ops" as never).values({ op_id: bad.id, sqlstate } as never).execute();
        const before = await snapshot(shop.storeId);
        const r = await sync(app, shop.family.token, { epoch: shop.epoch, ops: [other, bad], pull: false });
        expect(r.status, JSON.stringify(r.body)).toBe(500);
        expect(r.body).toEqual({ code: "unavailable" });
        expect(await snapshot(shop.storeId), "库里有部分写入").toEqual(before);
        expect(lines.some((l) => l.level === 50 && l.op_id === bad.id && l.sqlstate === sqlstate), "没记 error 日志").toBe(true);
        expect(lines.some((l) => String(l.msg).includes("savepoint 兜底")), "记账 op 不许走单个拒收").toBe(false);

        await tdb.kysely.deleteFrom("fault_ops" as never).where("op_id" as never, "=", bad.id as never).execute();
        const again = await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: [other, bad], pull: false });
        expect(again.results).toEqual([{ id: other.id, status: "applied" }, { id: bad.id, status: "applied" }]);
        expect((await tdb.kysely.selectFrom("entries").select("id").where("store_id", "=", shop.storeId).where("op_id", "=", bad.id).execute()).length).toBeGreaterThan(0);
        await assertDbLedger(tdb.kysely, shop.storeId, pid);
        await app.close();
      });
    }
  }
});
