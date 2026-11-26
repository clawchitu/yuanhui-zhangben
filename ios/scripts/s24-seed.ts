// S24 联调：给本机服务端的测试店铺上 S07 的夹具（server/test/reports.test.ts 的 design10：设计稿 10 的那个月），再记几笔「今天」的账。
// 用法：S24_BASE=http://localhost:8814 S24_USER=... S24_PASSWORD=... node ios/scripts/s24-seed.ts [--today]
//   不带参数：铺 10–11 月的夹具；--today：再记「今天」的几笔（先核对完 2026-11 和设计稿逐分一致，再加今天的）
// 只走 HTTP（登录、/v1/sync），和手机同一条路；密码只从环境变量读。时间按真实时钟：夹具写在 2026 年 10–11 月（历史流水照收，§14 S05-4），
// 今天的几笔写在现在。一家店只铺一次（已经有商品就不铺）。
//
// 2026-11（和 S07 测试逐分相同）：卖了 23,474、赚了 5,487、月初 + 进货 41,595、卖掉的进价 17,987、盘点少 128、过期 58、退货 160、月末货值 23,262。
// 今天：卖红牛 3 罐（期初没填进价 → 库存 −1「没货了」、进价没填 1 样）；卖中华 2 包优惠 ¥1；双汇王中王期初 3 根（快没货「还剩 3 根」）。
import { randomUUID } from "node:crypto";

const base = process.env.S24_BASE ?? "http://localhost:8814";
const user = process.env.S24_USER;
const password = process.env.S24_PASSWORD;
if (!user || !password) throw new Error("要 S24_USER / S24_PASSWORD");
if (!/^http:\/\/(localhost|127\.0\.0\.1):\d+$/.test(base)) throw new Error(`只铺本机服务端：${base}`);

async function post(path: string, body: unknown, token?: string) {
  const r = await fetch(base + path, {
    method: "POST",
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  if (!r.ok) throw new Error(`${path} ${r.status} ${JSON.stringify(j)}`);
  return j;
}

type Op = { id: string; type: string; occurred_at: string; payload: Record<string, unknown> };
const SH = (local: string) => new Date(`${local}+08:00`).toISOString();
const op = (type: string, payload: Record<string, unknown>, at: string): Op => ({ id: randomUUID(), type, occurred_at: at, payload });

const login = await post("/v1/auth/login", { username: user, password, device_id: randomUUID(), label: "S24 铺账" });
const token = login.token as string, epoch = login.epoch as string;

async function send(...ops: Op[]) {
  const r = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: false, ops }, token);
  const bad = r.results.filter((x: { status: string }) => x.status !== "applied");
  if (bad.length) throw new Error(`被拒：${JSON.stringify(bad.slice(0, 3))}`);
}

/** 全量拉一遍，拿商品的账面数（盘点要 base_qty / base_ver）和批次（扔掉、退货要 lot_id / handle_ver） */
async function pullAll() {
  const products = new Map<string, any>(), lots = new Map<string, any>();
  let cursors = { catalog: 0, ledger: 0 };
  for (let i = 0; i < 200; i++) {
    const r = await post("/v1/sync", { epoch, cursors, app_build: 1, pull: true, ops: [] }, token);
    for (const p of r.changes.products) products.set(p.id, p);
    for (const l of r.changes.lots) lots.set(l.id, l);
    cursors = r.cursors;
    if (!r.has_more.catalog && !r.has_more.ledger) break;
  }
  return { products, lots };
}

if (process.argv.includes("--today")) {
  const { products } = await pullAll();
  const by = (name: string) => [...products.values()].find((p) => p.name === name)!.id as string;
  const [zh, rb, sh] = [by("S24 中华（硬）"), by("S24 红牛 250ml"), by("S24 双汇王中王 60g")];
  // 真实时钟，往前一分钟
  const now = new Date(Date.now() - 60_000).toISOString();
  await send(
    op("opening", { entry_id: randomUUID(), product_id: sh, counted_qty: 3, unit_cost_fen: 150 }, now),
    sale([{ pid: rb, n: 3, price: 600, name: "S24 红牛 250ml", unit: "罐" }], now).op,
    sale([{ pid: zh, n: 2, price: 600, name: "S24 中华（硬）", unit: "包" }], now, 100).op,
  );
  console.log(JSON.stringify({ today: true }));
  process.exit(0);
}

const first = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: true, ops: [] }, token);
if (first.total_products > 0) {
  console.log(JSON.stringify({ seeded: false, total_products: first.total_products }));
  process.exit(0);
}

let code = 6970000240000;
const upsert = (name: string, price: number, unit: string, extra: Record<string, unknown> = {}) => {
  const id = randomUUID();
  return { id, op: op("product_upsert", { product_id: id, barcode: String(code++), name, price_fen: price, quick: false, base_unit: unit, ...extra }, SH("2026-10-01T09:00:00")) };
};
const stockIn = (pid: string, n: number, unit: number, at: string, expiry?: string) =>
  op("stock_in", { entry_id: randomUUID(), product_id: pid, barcode: "6900000000001", pack_qty: 1, pack_count: n, unit_cost_fen: unit, ...(expiry ? { expiry_date: expiry } : {}) }, at);
function sale(lines: Array<{ pid: string; n: number; price: number; name: string; unit: string }>, at: string, discount = 0) {
  const ls = lines.map((l) => ({ entry_id: randomUUID(), product_id: l.pid, barcode: "6900000000001", name: l.name, unit_name: l.unit, pack_qty: 1, pack_count: l.n, unit_price_fen: l.price }));
  const list = ls.reduce((s, l) => s + l.unit_price_fen * l.pack_count, 0);
  const batch_id = randomUUID();
  return { batch_id, entryIds: ls.map((l) => l.entry_id), op: op("sale_batch", { batch_id, paid_total_fen: list - discount, lines: ls }, at) };
}
const voidOp = (target: { entry_id: string } | { batch_id: string }, at: string) => op("void", { target }, at);

const zh = upsert("S24 中华（硬）", 600, "包");
const nf = upsert("S24 农夫山泉 550ml", 150, "瓶", { track_expiry: true });
const rb = upsert("S24 红牛 250ml", 600, "罐");
const sh = upsert("S24 双汇王中王 60g", 250, "根");
await send(zh.op, nf.op, rb.op, sh.op);
const Z = (n: number, price: number) => ({ pid: zh.id, n, price, name: "S24 中华（硬）", unit: "包" });
const N = (n: number, price: number) => ({ pid: nf.id, n, price, name: "S24 农夫山泉 550ml", unit: "瓶" });

// 10 月
await send(stockIn(zh.id, 4100, 500, SH("2026-10-05T10:00:00")), stockIn(nf.id, 5675, 100, SH("2026-10-05T10:05:00"), "2026-11-05"));
await send(op("opening", { entry_id: randomUUID(), product_id: rb.id, counted_qty: 2 }, SH("2026-10-06T10:00:00")));
await send(sale([Z(100, 650)], SH("2026-10-20T15:00:00")).op);
// 11 月
await send(
  stockIn(zh.id, 2000, 500, SH("2026-11-01T09:00:00")),
  stockIn(nf.id, 58, 100, SH("2026-11-01T09:05:00"), "2026-11-12"),
  stockIn(nf.id, 160, 100, SH("2026-11-01T09:10:00"), "2026-11-18"),
  stockIn(nf.id, 5702, 100, SH("2026-11-01T09:15:00"), "2027-06-30"),
);
let extra!: ReturnType<typeof sale>;
for (let d = 1; d <= 20; d++) {
  const day = `2026-11-${String(d).padStart(2, "0")}`;
  const last = d === 20;
  const b1 = sale([Z(140, 600), N(last ? 133 : 125, 150)], SH(`${day}T12:00:00`), last ? 800 : 200);
  const b2 = sale([N(last ? 73 : 74, 200)], SH(`${day}T12:30:00`));
  await send(b1.op, b2.op);
  if (d === 5) {
    extra = sale([Z(10, 600)], SH("2026-11-05T15:00:00"));
    await send(extra.op);
  }
  if (d === 6) await send(voidOp({ entry_id: extra.entryIds[0]! }, SH("2026-11-06T09:00:00")));
  if (d === 10) {
    const x = sale([N(5, 150)], SH("2026-11-10T15:00:00"));
    await send(x.op, voidOp({ batch_id: x.batch_id }, SH("2026-11-10T15:05:00")));
  }
  if (d === 13 || d === 18) {
    const { lots } = await pullAll();
    const exp = d === 13 ? "2026-11-12" : "2026-11-18";
    const L = [...lots.values()].find((l) => l.product_id === nf.id && l.expiry_date === exp);
    const qty = d === 13 ? 58 : 160;
    await send(op("expiry_dispose", { lot_id: L.id, handle_ver: L.handle_ver, actual_qty: qty, action: d === 13 ? "discard" : "return", entry_id: randomUUID() }, SH(`${day}T10:00:00`)));
  }
  if (d === 19) {
    const { products } = await pullAll();
    const p = products.get(nf.id).private;
    await send(op("count", { entry_id: randomUUID(), product_id: nf.id, counted_qty: p.stock_qty - 128, base_qty: p.stock_qty, base_ver: p.stock_ver }, SH("2026-11-19T20:00:00")));
  }
}

console.log(JSON.stringify({ seeded: true }));
