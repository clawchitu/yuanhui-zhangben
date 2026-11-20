// 同步测试辅助：发 /v1/sync、造 op、按契约校验响应，以及一个「模拟手机」把拉到的变更应用到本地副本上。
import { randomUUID } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { expect } from "vitest";
import { bearer } from "./auth.ts";
import { loadOpenApi, validatorFor } from "./contract.ts";

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type Any = any;

export interface Op {
  id: string;
  type: string;
  occurred_at: string;
  payload: Record<string, unknown>;
}

export function op(type: string, payload: Record<string, unknown>, o: { id?: string; at?: Date | string } = {}): Op {
  const at = o.at ?? new Date("2026-11-20T01:59:00Z");
  return { id: o.id ?? randomUUID(), type, occurred_at: typeof at === "string" ? at : at.toISOString(), payload };
}

let barcodeSeq = 0;
/** 测试里不重复的 13 位条码（每个测试用自己的店，同一进程内不重复就够） */
export function newBarcode(): string {
  barcodeSeq += 1;
  return `69${String(barcodeSeq).padStart(11, "0")}`;
}

/** 家用的完整登记 */
export function upsertFull(o: { productId?: string; barcode?: string; name?: string; price?: number; baseUnit?: string; extra?: Record<string, unknown> } = {}) {
  return op("product_upsert", {
    product_id: o.productId ?? randomUUID(),
    barcode: o.barcode ?? newBarcode(),
    name: o.name ?? "可口可乐 330ml",
    price_fen: o.price ?? 300,
    quick: false,
    base_unit: o.baseUnit ?? "罐",
    ...o.extra,
  });
}

/** 收银员的 quick 登记：只有名称和卖价 */
export function upsertQuick(o: { productId?: string; barcode?: string; name?: string; price?: number; extra?: Record<string, unknown> } = {}) {
  return op("product_upsert", {
    product_id: o.productId ?? randomUUID(),
    barcode: o.barcode ?? newBarcode(),
    name: o.name ?? "临时登记",
    price_fen: o.price ?? 500,
    quick: true,
    ...o.extra,
  });
}

export interface Cursors {
  catalog: number;
  ledger: number;
}

export interface SyncBody {
  epoch: string;
  cursors?: Cursors;
  ops?: Op[];
  app_build?: number;
  pull?: boolean;
}

export async function sync(app: FastifyInstance, token: string, body: SyncBody) {
  const res = await app.inject({
    method: "POST",
    url: "/v1/sync",
    headers: bearer(token),
    payload: { cursors: { catalog: 0, ledger: 0 }, ops: [], app_build: 1, ...body },
  });
  return { status: res.statusCode, body: res.json() as Any };
}

/** 发一次同步，期望 200，并按契约 SyncResponse 校验响应 */
export async function syncOk(app: FastifyInstance, token: string, body: SyncBody) {
  const r = await sync(app, token, body);
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  await expectContract("SyncResponse", r.body);
  return r.body;
}

const validators = new Map<string, ReturnType<typeof validatorFor>>();
export async function expectContract(schemaName: string, body: unknown) {
  let v = validators.get(schemaName);
  if (!v) {
    const api = await loadOpenApi();
    v = validatorFor(api.components.schemas[schemaName]);
    validators.set(schemaName, v);
  }
  const ok = v(body);
  expect(ok, `${schemaName} 不符合契约：${JSON.stringify(v.errors)}\n${JSON.stringify(body).slice(0, 2000)}`).toBe(true);
}

/** 递归收集 JSON 里出现的所有键 */
export function allKeys(v: unknown, out = new Set<string>()): Set<string> {
  if (Array.isArray(v)) for (const x of v) allKeys(x, out);
  else if (v && typeof v === "object") {
    for (const [k, x] of Object.entries(v)) {
      out.add(k);
      allKeys(x, out);
    }
  }
  return out;
}

/**
 * 模拟手机的本地副本：按 §4.2 应用拉到的变更（按主键覆盖、墓碑删除），游标前进。
 * 用它来断言「分页拉取的结果 = 一次拉完的结果」「拉取中途有新写入也不漏不重」。
 */
export class Replica {
  products = new Map<string, Any>();
  barcodes = new Map<string, Any>();
  entries = new Map<string, Any>();
  batches = new Map<string, Any>();
  lots = new Map<string, Any>();
  cursors: Cursors = { catalog: 0, ledger: 0 };
  /** 每个 (类型, 主键, rev) 收到的次数：同一个版本收到两次 = 重 */
  seen = new Map<string, number>();
  pages = 0;

  apply(body: Any) {
    const c = body.changes;
    // 墓碑和行的先后无关紧要：服务器不会为当前还在的条码下发墓碑
    for (const r of c.removed) {
      this.note("removed", `${r.kind}:${r.row_id}`, r.rev);
      if (r.kind === "barcode") this.barcodes.delete(r.row_id);
    }
    for (const p of c.products) this.put(this.products, "product", p.id, p);
    for (const b of c.barcodes) this.put(this.barcodes, "barcode", b.barcode, b);
    for (const e of c.entries) this.put(this.entries, "entry", e.id, e);
    for (const b of c.batches) this.put(this.batches, "batch", b.id, b);
    for (const l of c.lots) this.put(this.lots, "lot", l.id, l);
    expect(body.cursors.catalog).toBeGreaterThanOrEqual(this.cursors.catalog);
    expect(body.cursors.ledger).toBeGreaterThanOrEqual(this.cursors.ledger);
    this.cursors = body.cursors;
    this.pages += 1;
  }

  private put(m: Map<string, Any>, kind: string, key: string, row: Any) {
    this.note(kind, key, row.rev);
    const prev = m.get(key);
    // 同一行的新版本 rev 一定更大
    if (prev) expect(row.rev, `${kind} ${key} 收到了旧版本`).toBeGreaterThan(prev.rev);
    m.set(key, row);
  }

  private note(kind: string, key: string, rev: number) {
    const k = `${kind}|${key}|${rev}`;
    this.seen.set(k, (this.seen.get(k) ?? 0) + 1);
  }

  duplicates(): string[] {
    return [...this.seen].filter(([, n]) => n > 1).map(([k]) => k);
  }

  snapshot() {
    const sorted = (m: Map<string, Any>) => [...m.entries()].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)).map(([, v]) => v);
    return {
      products: sorted(this.products),
      barcodes: sorted(this.barcodes),
      entries: sorted(this.entries),
      batches: sorted(this.batches),
      lots: sorted(this.lots),
    };
  }

  /** 按条码查卖价：单件码读商品的 price_fen；整件码有自己的价就用，没有就是单件价 × 换算（§3.2、§14 S02-5） */
  priceOfBarcode(code: string): number | undefined {
    const b = this.barcodes.get(code);
    if (!b) return undefined;
    const p = this.products.get(b.product_id);
    if (b.pack_qty === 1) {
      expect(b).not.toHaveProperty("pack_price_fen");
      return p.price_fen;
    }
    return b.pack_price_fen ?? p.price_fen * b.pack_qty;
  }

  /** 按名称搜（手机本地的名称搜索） */
  searchByName(q: string) {
    return [...this.products.values()].filter((p) => p.name.includes(q));
  }
}

/** 用同一个令牌一直拉到两条流都没有更多（不推 op） */
export async function pullAll(app: FastifyInstance, token: string, epoch: string, replica = new Replica(), maxPages = 10_000) {
  for (let i = 0; i < maxPages; i++) {
    const body = await syncOk(app, token, { epoch, cursors: replica.cursors });
    replica.apply(body);
    if (!body.has_more.catalog && !body.has_more.ledger) return replica;
  }
  throw new Error("拉不完");
}
