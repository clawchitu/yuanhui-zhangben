// 数据库层性质测试（§3.3 I1–I8，§8 S05 验收「fast-check 性质测试，随机 op 序列 ≥ 500 组，含乱序重放」，S06「性质测试加入新 op 后 I1–I8 仍成立」）。
// 随机生成多台设备（两台家用、一台收银）的 sale_batch / stock_in / opening / void，以及 S06 的 count / product_review_complete /
// expiry_dispose / lot_snooze 序列，打乱到达顺序、随机分包、中途和最后重发，经真实 /v1/sync 写库；每组结束后从库里读流水和投影断言 I1–I8，
// 再断言批次一致性（assertLots）和迟到补偿的成本、批次口径（assertLate，§14 S06-8、S06-10）。occurred_at 随机、盘点 / 期初也随机落在时间轴上，盘点之后才到的更早的流水走迟到补偿（§5.6 第 4 条）。
// 另有并发测试：多个连接池（相当于多个服务器进程）同时推，断言 seq 不重不漏、rev 不重，
// 投影与「按 seq 顺序把这些 op 单线程重放到一家新店」的结果一致。
//
// 组数：PROP_RUNS（默认 500，CI 也跑 500）；并发组数 PROP_CONCURRENT_RUNS（默认 40）。
import { randomUUID } from "node:crypto";
import fc from "fast-check";
import type { FastifyInstance } from "fastify";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { buildApp } from "../src/app.ts";
import { createDb, type Db } from "../src/db.ts";
import { roundDiv } from "../src/ledger/rounddiv.ts";
import { createTestDb, testConfig, type TestDb } from "./helpers/db.ts";
import { TestClock } from "./helpers/auth.ts";
import { assertDbLedger, makeFastShop, makeTokenDevice } from "./helpers/ledger.ts";
import { op as mkOp, Replica, sync, syncOk, upsertFull, type Op } from "./helpers/sync.ts";

const RUNS = Number(process.env.PROP_RUNS ?? 500);
const CONCURRENT_RUNS = Number(process.env.PROP_CONCURRENT_RUNS ?? 40);
const NOW = Date.parse("2026-11-20T02:00:00Z");
const HOUR = 3_600_000;

let tdb: TestDb;
let clock: TestClock;
/** 写入用的应用（默认页大小）；分页比对用几个小页的应用 */
let app: FastifyInstance;
let pagedApps: Array<{ size: number; app: FastifyInstance }>;
beforeAll(async () => {
  tdb = await createTestDb();
  clock = new TestClock(NOW);
  const mk = (syncPageSize?: number) => buildApp({ config: testConfig(), db: tdb, logger: false, clock: clock.now, syncPageSize });
  app = mk();
  pagedApps = [3, 7, 19].map((size) => ({ size, app: mk(size) }));
});
afterAll(async () => {
  await app?.close();
  for (const a of pagedApps ?? []) await a.app.close();
  await tdb.drop();
});

// ---------- 随机 op ----------

/** 抽象的 op：商品用下标引用（-1 = 卖出时引用一个库里没有的商品，服务器自动建待确认商品），撤销用下标引用之前生成的 op */
type Gen =
  | { kind: "sale"; dev: number; lines: Array<{ p: number; packQty: number; count: number; price: number }>; discount: number; atH: number }
  | { kind: "stock_in"; dev: number; p: number; packQty: number; count: number; unit: number; expiry?: string; atH: number }
  | { kind: "opening"; dev: number; p: number; counted: number; cost: number | null; base: "none" | "current" | number; expiry?: string; atH: number }
  | { kind: "void"; dev: number; target: number; line: number | null; recent: boolean; atH: number }
  | { kind: "count"; dev: number; p: number; counted: number; base: "current" | number; atH: number }
  | { kind: "review"; dev: number; p: number; counted: number; cost: number; base: "current" | number; track: boolean | null; atH: number }
  | { kind: "dispose"; dev: number; p: number; lot: number; actual: number; action: "sold_out" | "discard" | "return"; hv: "current" | number; atH: number }
  | { kind: "snooze"; dev: number; p: number; lot: number; actual: number; days: number; hv: "current" | number; atH: number };

const N_PRODUCTS = 3;
/** 商品 0、1 管保质期（进货 / 期初生成批次），2 不管 */
const TRACKED = (i: number) => i < 2;
const expiryArb = fc.option(fc.constantFrom("2026-11-25", "2026-12-01", "2026-12-01", "2027-01-15"), { nil: undefined });
/** 版本：大多取发送时库里的当前值，少数是随手写的旧值（→ stale） */
const verArb = fc.oneof({ weight: 3, arbitrary: fc.constant("current" as const) }, { weight: 1, arbitrary: fc.integer({ min: 0, max: 6 }) });
/** 0、1 家用，2 收银员 */
const devArb = fc.constantFrom(0, 0, 1, 1, 2);
/** occurred_at = 服务器时间往前 0–60 小时；偶尔超前 1 天（手机时钟错，服务器校正） */
const atArb = fc.oneof({ weight: 12, arbitrary: fc.integer({ min: 0, max: 60 }) }, { weight: 1, arbitrary: fc.constant(-24) });
const genArb: fc.Arbitrary<Gen> = fc.oneof(
  {
    weight: 4,
    arbitrary: fc.record({
      kind: fc.constant("sale" as const),
      dev: devArb,
      lines: fc.array(
        fc.record({
          p: fc.oneof({ weight: 12, arbitrary: fc.integer({ min: 0, max: N_PRODUCTS - 1 }) }, { weight: 1, arbitrary: fc.constant(-1) }),
          packQty: fc.constantFrom(1, 1, 1, 6, 24),
          count: fc.integer({ min: 1, max: 4 }),
          price: fc.oneof(fc.integer({ min: 0, max: 5000 }), fc.constant(0)),
        }),
        { minLength: 1, maxLength: 3 },
      ),
      discount: fc.oneof(fc.constant(0), fc.integer({ min: 0, max: 99 }), fc.integer({ min: 0, max: 100_000 })),
      atH: atArb,
    }),
  },
  {
    weight: 3,
    arbitrary: fc.record({
      kind: fc.constant("stock_in" as const),
      dev: devArb,
      p: fc.integer({ min: 0, max: N_PRODUCTS - 1 }),
      packQty: fc.constantFrom(1, 6, 24),
      count: fc.oneof({ weight: 10, arbitrary: fc.integer({ min: 1, max: 5 }) }, { weight: 1, arbitrary: fc.constant(0) }),
      unit: fc.oneof(fc.integer({ min: 0, max: 10_000 }), fc.constant(0)),
      expiry: expiryArb,
      atH: atArb,
    }),
  },
  {
    weight: 2,
    arbitrary: fc.record({
      kind: fc.constant("opening" as const),
      dev: devArb,
      p: fc.integer({ min: 0, max: N_PRODUCTS - 1 }),
      counted: fc.integer({ min: 0, max: 60 }),
      cost: fc.option(fc.integer({ min: 0, max: 800 }), { nil: null }),
      base: fc.oneof(fc.constant("none" as const), fc.constant("current" as const), fc.constant("current" as const), fc.integer({ min: 0, max: 6 })),
      expiry: expiryArb,
      atH: atArb,
    }),
  },
  {
    weight: 3,
    arbitrary: fc.record({
      kind: fc.constant("void" as const),
      dev: devArb,
      target: fc.nat(40),
      line: fc.option(fc.nat(3), { nil: null }),
      // 一半撤最近的几笔（撤刚扔掉的、刚盘的），否则扔掉 / 退货的冲销太少见
      recent: fc.boolean(),
      atH: atArb,
    }),
  },
  {
    weight: 2,
    arbitrary: fc.record({
      kind: fc.constant("count" as const),
      dev: devArb,
      p: fc.integer({ min: 0, max: N_PRODUCTS - 1 }),
      counted: fc.integer({ min: 0, max: 40 }),
      base: verArb,
      atH: atArb,
    }),
  },
  {
    weight: 1,
    arbitrary: fc.record({
      kind: fc.constant("review" as const),
      dev: devArb,
      p: fc.integer({ min: 0, max: N_PRODUCTS - 1 }),
      counted: fc.integer({ min: 0, max: 40 }),
      cost: fc.oneof(fc.integer({ min: 0, max: 800 }), fc.constant(0)),
      base: verArb,
      track: fc.option(fc.boolean(), { nil: null }),
      atH: atArb,
    }),
  },
  {
    weight: 2,
    arbitrary: fc.record({
      kind: fc.constant("dispose" as const),
      dev: devArb,
      p: fc.integer({ min: 0, max: 1 }),
      lot: fc.nat(5),
      actual: fc.integer({ min: 0, max: 8 }),
      action: fc.constantFrom("sold_out" as const, "discard" as const, "discard" as const, "return" as const),
      hv: verArb,
      atH: atArb,
    }),
  },
  {
    weight: 1,
    arbitrary: fc.record({
      kind: fc.constant("snooze" as const),
      dev: devArb,
      p: fc.integer({ min: 0, max: 1 }),
      lot: fc.nat(5),
      actual: fc.integer({ min: 0, max: 8 }),
      days: fc.integer({ min: 1, max: 10 }),
      hv: verArb,
      atH: atArb,
    }),
  },
);

/**
 * 一组：op 序列 + 到达方式。
 * delays：第 i 个 op 推迟 delays[i] 个位置到达（乱序；撤销可能比被撤的卖出先到 → invalid 并留档，之后重发结果不变）。
 * replays：在到达序列的第 pos 个位置插入一次第 which 个 op 的重发。
 * chunks：每个请求最多带几个 op（同一台设备的连续 op 合进一个请求）。
 */
const scenarioArb = fc
  .array(genArb, { minLength: 1, maxLength: 30, size: "medium" })
  .chain((gens) =>
    fc.record({
      gens: fc.constant(gens),
      delays: fc.array(fc.oneof({ weight: 3, arbitrary: fc.constant(0) }, { weight: 1, arbitrary: fc.integer({ min: 1, max: 8 }) }), { minLength: gens.length, maxLength: gens.length }),
      replays: fc.array(fc.record({ pos: fc.nat(gens.length), which: fc.nat(gens.length - 1) }), { maxLength: 6 }),
      chunk: fc.integer({ min: 1, max: 6 }),
      page: fc.nat(2),
    }),
  );

interface World {
  storeId: string;
  epoch: string;
  tokens: string[];
  products: string[];
}

async function makeWorld(): Promise<World> {
  const shop = await makeFastShop(tdb.kysely);
  const fam2 = await makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId, "family");
  const cashier = await makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId, "cashier");
  const ups = Array.from({ length: N_PRODUCTS }, (_, i) => upsertFull({ price: 100 * (i + 1), extra: { track_expiry: TRACKED(i), expiry_warn_days: 7 } }));
  const body = await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: ups, pull: false });
  expect(body.results.every((r: { status: string }) => r.status === "applied")).toBe(true);
  return { storeId: shop.storeId, epoch: shop.epoch, tokens: [shop.family.token, fam2.token, cashier.token], products: ups.map((u) => u.payload.product_id as string) };
}

/** 把抽象 op 变成真 op。撤销引用的目标在生成时就定下（目标 op 的 id 是事先定好的，不管它到没到） */
class Materializer {
  readonly ids: string[];
  readonly made = new Map<number, Op>();
  /** 每个 sale 的 batch_id、行 entry_id；stock_in / opening 的 entry_id */
  readonly refs: Array<{ batch?: string; entries: string[] }>;
  private readonly w: World;
  private readonly gens: Gen[];
  constructor(w: World, gens: Gen[]) {
    this.w = w;
    this.gens = gens;
    this.ids = gens.map(() => randomUUID());
    this.refs = gens.map((g) => (g.kind === "sale" ? { batch: randomUUID(), entries: g.lines.map(() => randomUUID()) } : g.kind === "snooze" ? { entries: [] } : { entries: [randomUUID()] }));
  }

  private async stockVer(p: number) {
    const r = await tdb.kysely.selectFrom("products").select("stock_ver").where("store_id", "=", this.w.storeId).where("id", "=", this.w.products[p]!).executeTakeFirstOrThrow();
    return Number(r.stock_ver);
  }

  /** 批次：这个商品的第 k 个（按来源流水的应用顺序）；还没有批次就指向一个不存在的（→ invalid 留档） */
  private async lotOf(p: number, k: number) {
    const lots = await tdb.kysely
      .selectFrom("stock_lots as l")
      .innerJoin("entries as e", (j) => j.onRef("e.store_id", "=", "l.store_id").onRef("e.id", "=", "l.source_entry_id"))
      .select(["l.id", "l.handle_ver"])
      .where("l.store_id", "=", this.w.storeId)
      .where("l.product_id", "=", this.w.products[p]!)
      .orderBy("e.seq")
      .execute();
    return lots.length === 0 ? { id: randomUUID(), handle_ver: 0 } : lots[k % lots.length]!;
  }

  /** 第一次发之前才定 payload（期初 / 盘点 / 补全的 base_ver、处理批次的 lot_id 和 handle_ver 取发送时库里的值，像手机那样）；之后的重发用同一个对象 */
  async get(i: number): Promise<Op> {
    const have = this.made.get(i);
    if (have) return have;
    const g = this.gens[i]!;
    const at = new Date(NOW - g.atH * HOUR - i * 1000);
    const pid = (p: number) => this.w.products[p]!;
    let o: Op;
    switch (g.kind) {
      case "sale": {
        const lines = g.lines.map((l, j) => ({
          entry_id: this.refs[i]!.entries[j]!,
          product_id: l.p < 0 ? randomUUID() : pid(l.p),
          barcode: "6900000000001",
          name: "随便",
          unit_name: l.packQty === 1 ? "个" : "箱",
          pack_qty: l.packQty,
          pack_count: l.count,
          unit_price_fen: l.price,
        }));
        const list = lines.reduce((x, l) => x + l.unit_price_fen * l.pack_count, 0);
        o = mkOp("sale_batch", { batch_id: this.refs[i]!.batch!, paid_total_fen: Math.max(0, list - g.discount), lines }, { id: this.ids[i], at });
        break;
      }
      case "stock_in":
        o = mkOp(
          "stock_in",
          { entry_id: this.refs[i]!.entries[0]!, product_id: pid(g.p), barcode: "6900000000001", pack_qty: g.packQty, pack_count: g.count, unit_cost_fen: g.unit, ...(g.expiry === undefined ? {} : { expiry_date: g.expiry }) },
          { id: this.ids[i], at },
        );
        break;
      case "opening": {
        let base_ver: number | undefined;
        if (g.base === "current") {
          const p = await tdb.kysely.selectFrom("products").select("stock_ver").where("store_id", "=", this.w.storeId).where("id", "=", pid(g.p)).executeTakeFirstOrThrow();
          base_ver = Number(p.stock_ver);
        } else if (g.base !== "none") base_ver = g.base;
        o = mkOp(
          "opening",
          {
            entry_id: this.refs[i]!.entries[0]!,
            product_id: pid(g.p),
            counted_qty: g.counted,
            ...(g.cost === null ? {} : { unit_cost_fen: g.cost }),
            ...(base_ver === undefined ? {} : { base_ver }),
            ...(g.expiry === undefined ? {} : { expiry_date: g.expiry }),
          },
          { id: this.ids[i], at },
        );
        break;
      }
      case "void": {
        // 目标：之前（生成顺序）的一个记账 op；没有就指向一个不存在的流水
        const cands = this.gens.slice(0, i).flatMap((x, j) => (x.kind === "void" || x.kind === "snooze" ? [] : [j]));
        let target: Record<string, string>;
        if (cands.length === 0) target = { entry_id: randomUUID() };
        else {
          const pool = g.recent ? cands.slice(-3) : cands;
          const j = pool[g.target % pool.length]!;
          const r = this.refs[j]!;
          target = r.batch !== undefined && g.line === null ? { batch_id: r.batch } : { entry_id: r.entries[(g.line ?? 0) % r.entries.length]! };
        }
        o = mkOp("void", { target }, { id: this.ids[i], at });
        break;
      }
      case "count": {
        const base_ver = g.base === "current" ? await this.stockVer(g.p) : g.base;
        o = mkOp("count", { entry_id: this.refs[i]!.entries[0]!, product_id: pid(g.p), counted_qty: g.counted, base_qty: 0, base_ver }, { id: this.ids[i], at });
        break;
      }
      case "review": {
        const base_ver = g.base === "current" ? await this.stockVer(g.p) : g.base;
        o = mkOp(
          "product_review_complete",
          { entry_id: this.refs[i]!.entries[0]!, product_id: pid(g.p), counted_qty: g.counted, unit_cost_fen: g.cost, base_ver, ...(g.track === null ? {} : { track_expiry: g.track }) },
          { id: this.ids[i], at },
        );
        break;
      }
      case "dispose": {
        const lot = await this.lotOf(g.p, g.lot);
        const handle_ver = g.hv === "current" ? lot.handle_ver : g.hv;
        o = mkOp("expiry_dispose", { lot_id: lot.id, handle_ver, actual_qty: g.actual, action: g.action, entry_id: this.refs[i]!.entries[0]! }, { id: this.ids[i], at });
        break;
      }
      case "snooze": {
        const lot = await this.lotOf(g.p, g.lot);
        const handle_ver = g.hv === "current" ? lot.handle_ver : g.hv;
        o = mkOp("lot_snooze", { lot_id: lot.id, handle_ver, actual_qty: g.actual, days: g.days }, { id: this.ids[i], at });
        break;
      }
    }
    this.made.set(i, o);
    return o;
  }
}

/** 到达序列：按 i + delay 稳定排序，再插入重发 */
function arrival(s: { gens: Gen[]; delays: number[]; replays: Array<{ pos: number; which: number }> }): number[] {
  const order = s.gens.map((_, i) => i).sort((a, b) => a + s.delays[a]! - (b + s.delays[b]!) || a - b);
  for (const r of [...s.replays].sort((a, b) => b.pos - a.pos)) order.splice(Math.min(r.pos, order.length), 0, r.which);
  return order;
}

/** 同一台设备的连续 op 合成一个请求（最多 chunk 个，同一个 op 不进同一个请求两次） */
function chunks(order: number[], gens: Gen[], chunk: number): number[][] {
  const out: number[][] = [];
  for (const i of order) {
    const last = out.at(-1);
    if (last && last.length < chunk && gens[last[0]!]!.dev === gens[i]!.dev && !last.includes(i)) last.push(i);
    else out.push([i]);
  }
  return out;
}

type Result = { id: string; status: string; replayed?: boolean } & Record<string, unknown>;

/** 发一批，记下每个 op 第一次的结果；之后再收到的同一个 op 的结果必须 = 第一次 + replayed（I8） */
async function push(w: World, m: Materializer, first: Map<number, Result>, batch: number[], dev: number) {
  const ops = await Promise.all(batch.map((i) => m.get(i)));
  const body = await syncOk(app, w.tokens[dev]!, { epoch: w.epoch, ops, pull: false });
  expect(body.results.length).toBe(batch.length);
  for (const [k, i] of batch.entries()) {
    const r = body.results[k] as Result;
    expect(r.id).toBe(ops[k]!.id);
    const f = first.get(i);
    if (f === undefined) {
      expect(r.replayed, "第一次收到的 op 不该是 replayed").toBeUndefined();
      first.set(i, r);
    } else expect(r, `I8：重发第 ${i} 个 op 的结果与第一次不同`).toEqual({ ...f, replayed: true });
  }
}

/** 库里这家店的全部记账状态（判 I5：重放前后不变） */
async function snapshot(storeId: string) {
  const k = tdb.kysely;
  const [products, entries, batches, ops, lots, store] = await Promise.all([
    k.selectFrom("products").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
    k.selectFrom("entries").selectAll().where("store_id", "=", storeId).orderBy("seq").execute(),
    k.selectFrom("sale_batches").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
    k.selectFrom("ops").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
    k.selectFrom("stock_lots").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
    k.selectFrom("stores").select(["rev", "epoch"]).where("id", "=", storeId).executeTakeFirstOrThrow(),
  ]);
  return { products, entries, batches, ops, lots, store };
}

/** I1–I4、I6、I7：从库里读出来逐条断言 */
async function assertStore(w: World, pageApp: FastifyInstance) {
  const k = tdb.kysely;
  const products = await k.selectFrom("products").select(["id", "stock_value_fen"]).where("store_id", "=", w.storeId).execute();
  // I1–I3 + 冲销、补记、cost_fix 冲销（assertLedger）
  for (const p of products) await assertDbLedger(k, w.storeId, p.id);
  // I4：每个卖出批次，原始行（不含冲销行）的实收合计 = paid_total_fen，撤销过的行也算（paid_total_fen 不改）
  const batches = await k.selectFrom("sale_batches").select(["id", "paid_total_fen"]).where("store_id", "=", w.storeId).execute();
  const lineSums = await k
    .selectFrom("entries")
    .select(["batch_id", (eb) => eb.fn.sum<string>("amount_fen").as("s")])
    .where("store_id", "=", w.storeId)
    .where("batch_id", "is not", null)
    .where("reverses_entry_id", "is", null)
    .groupBy("batch_id")
    .execute();
  const byBatch = new Map(lineSums.map((r) => [r.batch_id, BigInt(r.s)]));
  for (const b of batches) expect(byBatch.get(b.id), `I4：批次 ${b.id}`).toBe(BigInt(b.paid_total_fen));
  // I6：任取时间段 [t1, t2)，期初货值 + Σ value_delta（按类型分组）= 期末货值；期末取到最后 = 投影的货值合计
  const es = await k.selectFrom("entries").select(["product_id", "type", "occurred_at", "value_delta_fen", "seq"]).where("store_id", "=", w.storeId).execute();
  const times = [...new Set(es.map((e) => e.occurred_at.getTime()))].sort((a, b) => a - b);
  const valueBefore = async (t: number) => {
    const r = await k.selectFrom("entries").select((eb) => eb.fn.sum<string>("value_delta_fen").as("s")).where("store_id", "=", w.storeId).where("occurred_at", "<", new Date(t)).executeTakeFirst();
    return BigInt(r?.s ?? 0);
  };
  const cuts = [Number.NEGATIVE_INFINITY, ...times.filter((_, i) => i % 3 === 0), Number.POSITIVE_INFINITY];
  for (let i = 0; i + 1 < cuts.length; i++) {
    const t1 = cuts[i]!;
    const t2 = cuts[i + 1]!;
    const lo = Number.isFinite(t1) ? await valueBefore(t1) : 0n;
    const hi = Number.isFinite(t2) ? await valueBefore(t2) : products.reduce((x, p) => x + BigInt(p.stock_value_fen), 0n);
    let q = k.selectFrom("entries").select(["type", (eb) => eb.fn.sum<string>("value_delta_fen").as("s")]).where("store_id", "=", w.storeId);
    if (Number.isFinite(t1)) q = q.where("occurred_at", ">=", new Date(t1));
    if (Number.isFinite(t2)) q = q.where("occurred_at", "<", new Date(t2));
    const groups = await q.groupBy("type").execute();
    expect(lo + groups.reduce((x, g) => x + BigInt(g.s), 0n), `I6：[${t1}, ${t2})`).toBe(hi);
  }
  // seq：店内 1..N 不重不漏
  expect(es.map((e) => Number(e.seq)).sort((a, b) => a - b)).toEqual(es.map((_, i) => i + 1));
  // I7：rev 店内不重；随机页大小逐页拉取的结果 = 一次拉完的结果，且没有同一版本收到两次
  const revs: number[] = [];
  for (const t of ["products", "product_barcodes", "removed", "entries", "sale_batches", "stock_lots"] as const) {
    revs.push(...(await k.selectFrom(t).select("rev").where("store_id", "=", w.storeId).execute()).map((r) => Number(r.rev)));
  }
  expect(new Set(revs).size, "I7：rev 重复").toBe(revs.length);
  const whole = await pull(app, w);
  const paged = await pull(pageApp, w);
  expect(paged.duplicates()).toEqual([]);
  expect(paged.snapshot()).toEqual(whole.snapshot());
  expect(whole.entries.size).toBe(es.length);
  await assertLots(w.storeId);
  await assertLate(w.storeId);
}

/**
 * 迟到补偿与成本、批次（§5.6 第 4 条，§14 S06-8、S06-10）：
 * LT1 迟到的进货让进价从没填变已知（这一步之前这个商品没有进价已知的进货 / 期初）：这个 op 结束时货值 = 库存 × 这次的进价，不论库存正负。
 * LT2 被补偿的迟到卖出（紧跟着同一个 op 的 late_before_count 盘点行）不扣批次、不写 lot_moves。
 */
async function assertLate(storeId: string) {
  const es = await tdb.kysely.selectFrom("entries").selectAll().where("store_id", "=", storeId).orderBy("seq").execute();
  const moved = new Set((await tdb.kysely.selectFrom("lot_moves").select("entry_id").where("store_id", "=", storeId).execute()).map((m) => m.entry_id));
  const isLate = (e: (typeof es)[number] | undefined) => e !== undefined && (e.flags as Record<string, unknown>).late_before_count === true;
  for (const [i, e] of es.entries()) {
    if (e.reverses_entry_id !== null) continue;
    const mine = es.filter((x) => x.product_id === e.product_id);
    const sameOp = mine.filter((x) => x.op_id === e.op_id);
    if (e.type === "stock_in" && sameOp.some(isLate)) {
      const knownBefore = mine.some((x) => BigInt(x.seq) < BigInt(e.seq) && x.reverses_entry_id === null && (x.type === "stock_in" || x.type === "opening") && x.unit_cost_fen !== null);
      if (!knownBefore) {
        const end = BigInt(sameOp.at(-1)!.seq);
        const upTo = mine.filter((x) => BigInt(x.seq) <= end);
        const q = upTo.reduce((x, y) => x + BigInt(y.qty_delta), 0n);
        const v = upTo.reduce((x, y) => x + BigInt(y.value_delta_fen), 0n);
        const c = roundDiv(BigInt(e.amount_fen), BigInt(e.qty_delta));
        expect(v, `LT1：迟到进货 ${e.id} 补上进价后货值应归位到 q × c = ${q} × ${c}`).toBe(q * c);
        coverage.set("迟到进货补进价", (coverage.get("迟到进货补进价") ?? 0) + 1);
        if (q > 0n) coverage.set("迟到进货补进价且库存为正", (coverage.get("迟到进货补进价且库存为正") ?? 0) + 1);
      }
    }
    if (e.type === "sale") {
      const next = es[i + 1];
      if (isLate(next) && next!.op_id === e.op_id && next!.product_id === e.product_id && next!.type === "count") {
        expect(moved.has(e.id), `LT2：被补偿的迟到卖出 ${e.id} 扣了批次`).toBe(false);
        coverage.set("迟到卖出", (coverage.get("迟到卖出") ?? 0) + 1);
        const p = await tdb.kysely.selectFrom("products").select("track_expiry").where("store_id", "=", storeId).where("id", "=", e.product_id).executeTakeFirstOrThrow();
        if (p.track_expiry) coverage.set("迟到卖出（管保质期）", (coverage.get("迟到卖出（管保质期）") ?? 0) + 1);
      }
    }
  }
}

/**
 * 批次一致性（§5.4 生命周期表、§3.3 stock_lots / lot_moves）。批次不参与成本，这里断言的是它自己的账：
 * L1 qty_left ≥ 0、qty_in ≥ 0。
 * L2 来源流水存在、同一商品、不是冲销行，类型是进货 / 期初（没填进价的期初可能记成 count）。
 * L3 lot_moves：流水存在、同一商品。数量 > 0 的（扣批次）是原始的卖出或盘亏（count 且 qty_delta < 0），一条流水扣的合计 ≤ 它的数量；
 *    数量 < 0 的（加批次，§14 T6）是原始的盘盈（count 且 qty_delta > 0）或卖出的冲销行，一条流水只加一个批次、加的数 ≤ 它的数量。
 * L4 handle_ver = 对这个批次 applied 的 expiry_dispose + lot_snooze 个数（普通卖出、撤销重开都不改它）。
 * L5 关闭原因：voided ⇔ 来源流水已撤销且关闭时还没被处理；disposed ⇒ 最近一次处理（payload.handle_ver 最大的那个 applied expiry_dispose）
 *    是「卖完了」，或它的扔掉 / 退货流水还没撤销；未关闭 ⇒ 来源没撤销，且每一次处理都是扔掉 / 退货并且都已撤销（撤销 → 重开）。
 * L6 从没处理过、也没关过的批次：qty_left = qty_in − Σ 未撤销流水的扣减 + Σ 全部加批次（撤销卖出 / 盘亏原样加回；
 *    加给批次的数不随撤销减回，T6）。
 */
async function assertLots(storeId: string) {
  const k = tdb.kysely;
  const [lots, moves, entries, ops] = await Promise.all([
    k.selectFrom("stock_lots").selectAll().where("store_id", "=", storeId).execute(),
    k.selectFrom("lot_moves").selectAll().where("store_id", "=", storeId).execute(),
    k.selectFrom("entries").select(["id", "product_id", "type", "qty_delta", "reverses_entry_id", "voided_at"]).where("store_id", "=", storeId).execute(),
    k.selectFrom("ops").select(["type", "payload", "status"]).where("store_id", "=", storeId).where("type", "in", ["expiry_dispose", "lot_snooze"]).where("status", "=", "applied").execute(),
  ]);
  const entry = new Map(entries.map((e) => [e.id, e]));
  const movedBy = new Map<string, number>();
  const addedBy = new Set<string>();
  for (const m of moves) {
    const e = entry.get(m.entry_id);
    const l = lots.find((x) => x.id === m.lot_id);
    expect(m.qty, "L3：lot_moves 数量 ≠ 0").not.toBe(0);
    expect(e && l && e.product_id === l.product_id, `L3：lot_move ${m.entry_id} → ${m.lot_id} 的流水或批次不对`).toBe(true);
    if (m.qty > 0) {
      expect(e!.reverses_entry_id === null && (e!.type === "sale" || (e!.type === "count" && e!.qty_delta < 0)), `L3：扣批次的不是原始卖出 / 盘亏（${e!.type}）`).toBe(true);
      movedBy.set(m.entry_id, (movedBy.get(m.entry_id) ?? 0) + m.qty);
    } else {
      const gain = e!.reverses_entry_id === null && e!.type === "count" && e!.qty_delta > 0;
      const unvoid = e!.reverses_entry_id !== null && e!.type === "sale";
      expect(gain || unvoid, `L3：加批次的不是原始盘盈 / 卖出的冲销行（${e!.type}）`).toBe(true);
      expect(-m.qty, `L3：流水 ${m.entry_id} 加的批次超过它的数量`).toBeLessThanOrEqual(e!.qty_delta);
      expect(addedBy.has(m.entry_id), `L3：流水 ${m.entry_id} 加了不止一个批次`).toBe(false);
      addedBy.add(m.entry_id);
      coverage.set(gain ? "盘盈加批次" : "撤销迟到卖出加批次", (coverage.get(gain ? "盘盈加批次" : "撤销迟到卖出加批次") ?? 0) + 1);
    }
  }
  for (const [eid, q] of movedBy) expect(q, `L3：流水 ${eid} 扣的批次合计超过它的数量`).toBeLessThanOrEqual(-entry.get(eid)!.qty_delta);
  type P = { lot_id: string; handle_ver: number; action?: string; entry_id?: string };
  for (const l of lots) {
    const ctx = `批次 ${l.id}`;
    expect(l.qty_left >= 0 && l.qty_in >= 0, `L1：${ctx} qty_left ${l.qty_left}`).toBe(true);
    const src = entry.get(l.source_entry_id);
    expect(src !== undefined && src.product_id === l.product_id && src.reverses_entry_id === null && ["stock_in", "opening", "count"].includes(src.type), `L2：${ctx} 的来源流水`).toBe(true);
    const handled = ops.map((o) => ({ type: o.type, p: o.payload as P })).filter((o) => o.p.lot_id.toLowerCase() === l.id);
    expect(l.handle_ver, `L4：${ctx} 的 handle_ver`).toBe(handled.length);
    const disposals = handled.filter((o) => o.type === "expiry_dispose").sort((a, b) => a.p.handle_ver - b.p.handle_ver);
    const undone = (d: (typeof disposals)[number]) => d.p.action !== "sold_out" && entry.get(d.p.entry_id!.toLowerCase())?.voided_at != null;
    const srcVoided = src!.voided_at !== null;
    if (l.closed_at === null) {
      expect(l.closed_reason, ctx).toBeNull();
      expect(srcVoided, `L5：${ctx} 来源已撤销但批次没关`).toBe(false);
      expect(disposals.every(undone), `L5：${ctx} 处理过且没撤销，却是打开的`).toBe(true);
    } else if (l.closed_reason === "voided") {
      expect(srcVoided, `L5：${ctx} 关闭原因 voided 但来源没撤销`).toBe(true);
    } else {
      expect(l.closed_reason, ctx).toBe("disposed");
      const last = disposals.at(-1);
      expect(last !== undefined && !undone(last), `L5：${ctx} 是 disposed，但最近一次处理（${last?.p.action}）的流水已撤销——撤销扔掉 / 退货应当重开批次`).toBe(true);
    }
    if (handled.length === 0 && l.closed_at === null) {
      const out = moves.filter((m) => m.lot_id === l.id && (m.qty < 0 || entry.get(m.entry_id)!.voided_at === null)).reduce((x, m) => x + m.qty, 0);
      expect(l.qty_left, `L6：${ctx} qty_left ≠ qty_in − 未撤销的扣减 + 加批次`).toBe(l.qty_in - out);
    }
  }
}

async function pull(a: FastifyInstance, w: World) {
  const r = new Replica();
  for (let i = 0; i < 10_000; i++) {
    const body = await syncOk(a, w.tokens[0]!, { epoch: w.epoch, cursors: r.cursors });
    r.apply(body);
    if (!body.has_more.catalog && !body.has_more.ledger) return r;
  }
  throw new Error("拉不完");
}

/** 覆盖面统计：各类流水（含冲销行）出现了多少条，防止生成器退化 */
const coverage = new Map<string, number>();
async function tally(storeId: string) {
  const es = await tdb.kysely.selectFrom("entries").select(["type", "reverses_entry_id", "cost_fix_entry_id", "flags"]).where("store_id", "=", storeId).execute();
  for (const e of es) {
    const k = `${e.type}${e.reverses_entry_id === null ? "" : "冲销"}`;
    coverage.set(k, (coverage.get(k) ?? 0) + 1);
    if (e.cost_fix_entry_id !== null) coverage.set("被补记的卖出", (coverage.get("被补记的卖出") ?? 0) + 1);
    if ((e.flags as Record<string, unknown>).clock_adjusted) coverage.set("时钟校正", (coverage.get("时钟校正") ?? 0) + 1);
    if ((e.flags as Record<string, unknown>).late_before_count) coverage.set("迟到补偿", (coverage.get("迟到补偿") ?? 0) + 1);
  }
  const lots = await tdb.kysely.selectFrom("stock_lots").select(["closed_reason", "handle_ver", "snoozed_until"]).where("store_id", "=", storeId).execute();
  for (const l of lots) {
    coverage.set("批次", (coverage.get("批次") ?? 0) + 1);
    if (l.closed_reason !== null) coverage.set(`批次${l.closed_reason}`, (coverage.get(`批次${l.closed_reason}`) ?? 0) + 1);
    if (l.closed_reason === null && l.handle_ver > 0) coverage.set("批次处理后重开或推迟", (coverage.get("批次处理后重开或推迟") ?? 0) + 1);
  }
  const moved = await tdb.kysely.selectFrom("lot_moves").select("entry_id").where("store_id", "=", storeId).execute();
  coverage.set("lot_moves", (coverage.get("lot_moves") ?? 0) + moved.length);
  const ops = await tdb.kysely.selectFrom("ops").select(["type", "status", "reject_code"]).where("store_id", "=", storeId).execute();
  for (const o of ops) {
    const key = `${o.type}:${o.status === "applied" ? "applied" : o.reject_code ?? o.status}`;
    coverage.set(key, (coverage.get(key) ?? 0) + 1);
  }
}

interface Scenario {
  gens: Gen[];
  delays: number[];
  replays: Array<{ pos: number; which: number }>;
  chunk: number;
  page: number;
}

async function runScenario(s: Scenario) {
  const w = await makeWorld();
  const m = new Materializer(w, s.gens);
  const first = new Map<number, Result>();
  for (const batch of chunks(arrival(s), s.gens, s.chunk)) await push(w, m, first, batch, s.gens[batch[0]!]!.dev);
  await assertStore(w, pagedApps[s.page]!.app);
  await tally(w.storeId);
  // I5、I8：把全部 op 再按生成顺序重发一遍（每台设备各自分包）：结果与第一次相同，库里什么都不变
  const before = await snapshot(w.storeId);
  const all = s.gens.map((_, i) => i);
  for (const batch of chunks(all, s.gens, 8)) await push(w, m, first, batch, s.gens[batch[0]!]!.dev);
  expect(await snapshot(w.storeId), "I5：重放之后库里变了").toEqual(before);
  return first;
}

/**
 * 固定带上的一组（fast-check 的 examples，每次都跑）：随机生成里扔掉 / 退货再被撤销、处理后来源又被撤销都不常见，
 * 这一组保证每次都覆盖到：两批进货 → 扔掉、退货 → 撤销来源进货 → 撤销扔掉、撤销退货（一个重开、一个因来源已撤销而记 voided），
 * 外加盘点之后才到的更早的卖出（迟到补偿）和它的重发。
 */
const LOT_EXAMPLE: Scenario = {
  gens: [
    { kind: "stock_in", dev: 0, p: 0, packQty: 1, count: 5, unit: 100, expiry: "2026-11-25", atH: 50 },
    { kind: "stock_in", dev: 0, p: 0, packQty: 1, count: 5, unit: 120, expiry: "2026-12-01", atH: 49 },
    { kind: "dispose", dev: 0, p: 0, lot: 0, actual: 2, action: "discard", hv: "current", atH: 40 },
    { kind: "dispose", dev: 1, p: 0, lot: 1, actual: 1, action: "return", hv: "current", atH: 40 },
    { kind: "void", dev: 0, target: 1, line: null, recent: false, atH: 30 },
    { kind: "void", dev: 0, target: 2, line: null, recent: false, atH: 20 },
    { kind: "void", dev: 1, target: 3, line: null, recent: false, atH: 20 },
    { kind: "count", dev: 0, p: 0, counted: 4, base: "current", atH: 10 },
    { kind: "sale", dev: 2, lines: [{ p: 0, packQty: 1, count: 2, price: 300 }], discount: 0, atH: 15 },
    { kind: "snooze", dev: 0, p: 0, lot: 0, actual: 3, days: 2, hv: "current", atH: 5 },
  ],
  delays: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  replays: [{ pos: 9, which: 8 }],
  chunk: 1,
  page: 0,
};

/**
 * 固定带上的第二组：迟到补偿与成本、批次（§14 S06-8、S06-10）。
 * 商品 0：没填进价的期初 5 个之后，更早的进货 5 × 100 才到（进价从没填变已知、库存为正）→ LT1。
 * 商品 1：进货 10 个（批次 10）→ 盘点到 8（盘亏扣批次到 8）→ 盘点前卖的 2 个才到（被补偿）→ LT2，批次仍是 8（L6）。
 */
const LATE_EXAMPLE: Scenario = {
  gens: [
    { kind: "opening", dev: 0, p: 0, counted: 5, cost: null, base: "current", atH: 10 },
    { kind: "stock_in", dev: 0, p: 0, packQty: 1, count: 5, unit: 100, atH: 20 },
    { kind: "stock_in", dev: 0, p: 1, packQty: 1, count: 10, unit: 100, expiry: "2026-12-01", atH: 30 },
    { kind: "count", dev: 0, p: 1, counted: 8, base: "current", atH: 10 },
    { kind: "sale", dev: 2, lines: [{ p: 1, packQty: 1, count: 2, price: 300 }, { p: 0, packQty: 1, count: 1, price: 300 }], discount: 0, atH: 20 },
  ],
  delays: [0, 0, 0, 0, 0],
  replays: [],
  chunk: 1,
  page: 1,
};

/**
 * 固定带上的第三组：批次比货架少的两种情况（§14 T6）。商品 1：进货 10 个（批次 10）→ 盘点到 8 → 盘点前卖的 2 个才到（被补偿，批次仍 8）
 * → 撤销这笔卖出（库存 10，批次加回到 10）→ 盘点到 12（盘盈 2，批次 12）。
 */
const T6_EXAMPLE: Scenario = {
  gens: [
    { kind: "stock_in", dev: 0, p: 1, packQty: 1, count: 10, unit: 100, expiry: "2026-12-01", atH: 30 },
    { kind: "count", dev: 0, p: 1, counted: 8, base: "current", atH: 10 },
    { kind: "sale", dev: 2, lines: [{ p: 1, packQty: 1, count: 2, price: 300 }], discount: 0, atH: 20 },
    { kind: "void", dev: 0, target: 2, line: null, recent: false, atH: 5 },
    { kind: "count", dev: 0, p: 1, counted: 12, base: "current", atH: 3 },
  ],
  delays: [0, 0, 0, 0, 0],
  replays: [],
  chunk: 1,
  page: 1,
};

describe("数据库层性质测试（I1–I8，§3.3）", () => {
  it(`随机多设备 op 序列 ${RUNS} 组，乱序到达、中途与最后重发：I1–I8 成立`, { timeout: 1_200_000 }, async () => {
    let applied = 0;
    let rejected = 0;
    let runs = 0;
    await fc.assert(
      fc.asyncProperty(scenarioArb, async (s) => {
        runs += 1;
        const first = await runScenario(s);
        for (const r of first.values()) {
          if (r.status === "applied") applied += 1;
          else rejected += 1;
        }
      }),
      { numRuns: RUNS, examples: [[LOT_EXAMPLE], [LATE_EXAMPLE], [T6_EXAMPLE]] },
    );
    console.log(`性质测试：${runs} 组，op 第一次结果 applied ${applied} / 其余 ${rejected}；流水 ${JSON.stringify(Object.fromEntries(coverage))}`);
    const must = ["sale冲销", "stock_in冲销", "opening冲销", "cost_fix", "cost_fix冲销", "cost_adjust", "count", "count冲销", "expire_loss", "expire_loss冲销", "supplier_return", "supplier_return冲销", "被补记的卖出", "时钟校正", "迟到补偿", "批次", "批次disposed", "批次voided", "批次处理后重开或推迟", "lot_moves", "盘盈加批次", "撤销迟到卖出加批次", "迟到进货补进价", "迟到进货补进价且库存为正", "迟到卖出", "迟到卖出（管保质期）", "count:applied", "count:stale", "product_review_complete:applied", "product_review_complete:stale", "expiry_dispose:applied", "expiry_dispose:stale", "lot_snooze:applied", "lot_snooze:stale"];
    for (const k of must) expect(coverage.get(k) ?? 0, `生成器没有覆盖到 ${k}`).toBeGreaterThan(0);
    expect(runs).toBeGreaterThanOrEqual(RUNS);
    // 序列不能退化成全被拒：大部分 op 真的写进了库
    expect(applied).toBeGreaterThan(rejected);
  });
});

// ---------- 并发 ----------

/** 三个独立的连接池（三个「服务器进程」），同一家店只靠库里的店铺锁互斥 */
let pools: Db[] = [];
let cluster: FastifyInstance[] = [];
describe("并发推送", () => {
  beforeAll(() => {
    pools = Array.from({ length: 3 }, () => createDb({ connectionString: process.env.DATABASE_URL!, searchPath: tdb.schema, max: 6 }));
    cluster = pools.map((db) => buildApp({ config: testConfig(), db, logger: false, clock: clock.now }));
  });
  afterAll(async () => {
    for (const a of cluster) await a.close();
    for (const p of pools) await p.close();
  });

  /**
   * 只用家用设备（并发下收银员的权限判定不是这里要测的）。处理批次的 op 不进并发组：批次 id 是服务器取的，
   * 下面「单线程重放到一家新店」时对不上；批次的乱序与重放由上面的组覆盖。
   */
  const famGen = genArb.filter((g) => g.kind !== "dispose" && g.kind !== "snooze").map((g) => ({ ...g, dev: g.dev % 2 === 0 ? 0 : 1 }) as Gen);
  const concArb = fc.record({
    perDevice: fc.array(fc.array(famGen, { minLength: 1, maxLength: 10 }), { minLength: 4, maxLength: 4 }),
    chunk: fc.integer({ min: 1, max: 4 }),
  });

  it(`四台设备经三个进程同时推（${CONCURRENT_RUNS} 组）：seq 不重不漏、rev 不重；投影 = 按 seq 顺序单线程重放的结果`, { timeout: 600_000 }, async () => {
    await fc.assert(
      fc.asyncProperty(concArb, async ({ perDevice, chunk }) => {
        const shop = await makeFastShop(tdb.kysely);
        const devs = [shop.family, ...(await Promise.all([1, 2, 3].map(() => makeTokenDevice(tdb.kysely, shop.storeId, shop.accountId, "family"))))];
        const ups = Array.from({ length: N_PRODUCTS }, (_, i) => upsertFull({ price: 100 * (i + 1) }));
        await syncOk(app, shop.family.token, { epoch: shop.epoch, ops: ups, pull: false });
        const w: World = { storeId: shop.storeId, epoch: shop.epoch, tokens: devs.map((d) => d.token), products: ups.map((u) => u.payload.product_id as string) };
        // 所有设备的 op 放进同一个 Materializer（撤销可以指向别的设备的卖出），每台设备按自己的顺序、按 chunk 分包
        const gens = perDevice.flat();
        const owner = perDevice.flatMap((xs, d) => xs.map(() => d));
        const m = new Materializer(w, gens);
        let n = 0;
        await Promise.all(
          perDevice.map(async (xs, d) => {
            const mine = owner.flatMap((o, i) => (o === d ? [i] : []));
            for (let i = 0; i < mine.length; i += chunk) {
              const ops = await Promise.all(mine.slice(i, i + chunk).map((j) => m.get(j)));
              const r = await sync(cluster[n++ % cluster.length]!, devs[d]!.token, { epoch: shop.epoch, ops, pull: false });
              expect(r.status, JSON.stringify(r.body)).toBe(200);
            }
          }),
        );
        const k = tdb.kysely;
        const es = await k.selectFrom("entries").selectAll().where("store_id", "=", shop.storeId).orderBy("seq").execute();
        expect(es.map((e) => Number(e.seq)), "seq 不重不漏").toEqual(es.map((_, i) => i + 1));
        const revs: number[] = [];
        for (const t of ["products", "product_barcodes", "removed", "entries", "sale_batches", "stock_lots"] as const) {
          revs.push(...(await k.selectFrom(t).select("rev").where("store_id", "=", shop.storeId).execute()).map((r) => Number(r.rev)));
        }
        expect(new Set(revs).size, "rev 重复").toBe(revs.length);
        const store = await k.selectFrom("stores").select("rev").where("id", "=", shop.storeId).executeTakeFirstOrThrow();
        expect(Math.max(0, ...revs)).toBeLessThanOrEqual(Number(store.rev));
        // 同一个 op 的流水 seq 连续（别的请求插不进来）
        const spans = new Map<string, number[]>();
        for (const e of es) spans.set(e.op_id, [...(spans.get(e.op_id) ?? []), Number(e.seq)]);
        for (const s of spans.values()) expect(s.at(-1)! - s[0]!).toBe(s.length - 1);

        const prods = await k.selectFrom("products").selectAll().where("store_id", "=", shop.storeId).orderBy("id").execute();
        // 按 seq 把流水重算一遍：Σ qty_delta = 库存，Σ value_delta = 货值，平均进价 = 货值 / 库存
        for (const p of prods) {
          const mine = es.filter((e) => e.product_id === p.id);
          const q = mine.reduce((x, e) => x + BigInt(e.qty_delta), 0n);
          const v = mine.reduce((x, e) => x + BigInt(e.value_delta_fen), 0n);
          expect([q, v]).toEqual([BigInt(p.stock_qty), BigInt(p.stock_value_fen)]);
          if (q > 0n) expect(roundDiv(v, q)).toBe(roundDiv(BigInt(p.stock_value_fen), BigInt(p.stock_qty)));
          await assertDbLedger(k, shop.storeId, p.id);
        }

        // 按 seq 顺序（每个 op 第一条流水的位置；没写流水的 op 按 ops 留档的先后）单线程重放到一家新店：投影和流水逐行相同
        const opRows = await k.selectFrom("ops").select(["id", "device_id"]).where("store_id", "=", shop.storeId).orderBy("received_at").execute();
        const firstSeq = new Map<string, number>();
        for (const e of es) if (!firstSeq.has(e.op_id)) firstSeq.set(e.op_id, Number(e.seq));
        // 落库顺序：有流水的按 seq；没流水的（被拒的）重放到哪里都不改库，放最后
        const ordered = [...m.made.values()].filter((o) => firstSeq.has(o.id)).sort((a, b) => firstSeq.get(a.id)! - firstSeq.get(b.id)!);
        const devOf = new Map(opRows.map((r) => [r.id, r.device_id]));
        const replay = await makeFastShop(tdb.kysely);
        const rdevs = new Map<string, string>([[devs[0]!.id, replay.family.token]]);
        for (const d of devs.slice(1)) rdevs.set(d.id, (await makeTokenDevice(tdb.kysely, replay.storeId, replay.accountId, "family")).token);
        await syncOk(app, replay.family.token, { epoch: replay.epoch, ops: ups, pull: false });
        for (const o of ordered) {
          const body = await syncOk(app, rdevs.get(devOf.get(o.id)!)!, { epoch: replay.epoch, ops: [o], pull: false });
          expect(body.results[0].status, `重放 ${o.type} 应当照样记上`).toBe("applied");
        }
        const rprods = await k.selectFrom("products").selectAll().where("store_id", "=", replay.storeId).orderBy("id").execute();
        const proj = (ps: typeof prods) => ps.map((p) => [p.id, p.stock_qty, p.stock_value_fen, p.last_cost_fen, p.cost_known, p.stock_ver]);
        expect(proj(rprods)).toEqual(proj(prods));
        const res = await k.selectFrom("entries").selectAll().where("store_id", "=", replay.storeId).orderBy("seq").execute();
        const line = (e: (typeof es)[number]) => [e.op_id, e.product_id, e.type, e.qty_delta, e.amount_fen, e.list_amount_fen, e.cogs_fen, e.value_delta_fen, e.unit_cost_fen, e.cost_missing, e.voided_at !== null];
        expect(res.map(line)).toEqual(es.map(line));
      }),
      { numRuns: CONCURRENT_RUNS },
    );
  });
});
