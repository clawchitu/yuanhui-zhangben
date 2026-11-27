// S25 联调：以「另一台手机」（B）的身份给本机服务端的测试店铺上商品，然后 B 断网（只记下它的游标）；
// 联调测试改完价、补完之后，`--check` 用 B 当时的令牌和游标再联网拉一次，核对 B 拿到的是新价。
// 用法：S25_BASE=http://localhost:8815 S25_USER=... S25_PASSWORD=... S25_STATE=<文件> node ios/scripts/s25-seed.ts [--sell-review | --check]
//   不带参数：铺商品、写 B 的令牌和游标到 S25_STATE（文件权限 600，联调脚本跑完删掉）
//   --check：B 联网拉一次，核对改价（扫任一单件码用新价、整箱码价不变）、旧流水原名原价、补全记成 opening、停用
// 只走 HTTP（登录、/v1/sync），和手机同一条路；密码只从环境变量读。
//
// 商品（条码 69700002500xx）：
//   A「S25 青岛啤酒 500ml」罐 ¥6.00，单件码 01、02，整箱码 03（24 罐，整箱 ¥132.00），期初 10 罐进价 4.20；B 卖了 1 罐（旧价 6.00）
//   L「S25 红牛 250ml」罐 ¥6.00，期初 2 罐进价 4.80 → 快没货（店里默认 3）
//   E「S25 伊利纯牛奶 250ml」盒 ¥3.50，管保质期提前 7 天，期初 6 盒进价 2.29、后天到期 → 快过期
//   Q「S25 白象 老母鸡汤面」收银员式临时登记（quick）¥4.50，单件码 31，卖出过 1 袋（账上 −1）→ 待确认
//   P 卖出引用了没登记的商品（整件行，6 个一件）→ 服务器自动建的待确认商品：卖价 0、没条码（§14 S05-9）
import { randomUUID } from "node:crypto";
import { chmodSync, readFileSync, writeFileSync } from "node:fs";

const base = process.env.S25_BASE ?? "http://localhost:8815";
const user = process.env.S25_USER;
const password = process.env.S25_PASSWORD;
const stateFile = process.env.S25_STATE;
if (!user || !password || !stateFile) throw new Error("要 S25_USER / S25_PASSWORD / S25_STATE");
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
const now = () => new Date(Date.now() - 60_000).toISOString();
const op = (type: string, payload: Record<string, unknown>): Op => ({ id: randomUUID(), type, occurred_at: now(), payload });
const C = (n: number) => `69700002500${String(n).padStart(2, "0")}`;
function fail(msg: string): never {
  console.error(`S25-SEED 核对失败：${msg}`);
  process.exit(1);
}
const eq = (a: unknown, b: unknown, what: string) => {
  if (JSON.stringify(a) !== JSON.stringify(b)) fail(`${what}：${JSON.stringify(a)} ≠ ${JSON.stringify(b)}`);
};

/** 带游标拉到底（B 联网时就是这样），返回这期间拉到的变更 */
async function pull(token: string, epoch: string, cursors: { catalog: number; ledger: number }) {
  const products = new Map<string, any>(), barcodes = new Map<string, any>(), entries: any[] = [];
  let store: any;
  for (let i = 0; i < 200; i++) {
    const r = await post("/v1/sync", { epoch, cursors, app_build: 1, pull: true, ops: [] }, token);
    for (const p of r.changes.products) products.set(p.id, p);
    for (const b of r.changes.barcodes) barcodes.set(b.barcode, b);
    entries.push(...r.changes.entries);
    cursors = r.cursors;
    store = r.store;
    if (!r.has_more.catalog && !r.has_more.ledger) break;
  }
  return { products, barcodes, entries, cursors, store };
}

if (process.argv.includes("--check")) {
  const st = JSON.parse(readFileSync(stateFile, "utf8"));
  const r = await pull(st.token, st.epoch, st.cursors);
  const A = r.products.get(st.ids.A), L = r.products.get(st.ids.L), Q = r.products.get(st.ids.Q), P = r.products.get(st.ids.P);
  if (!A || !L || !Q || !P) fail(`B 联网后没拉到改过的商品（A ${!!A} L ${!!L} Q ${!!Q} P ${!!P}）`);
  // 改卖价：商品上的价变了；单件码不存价（扫哪个单件码都读商品的价）；整箱码有自己的价，不变
  eq(A.price_fen, 650, "A 的卖价");
  for (const c of [C(1), C(2)]) {
    const b = r.barcodes.get(c);
    if (b) eq([b.pack_qty, b.pack_price_fen], [1, null], `单件码 ${c} 不带价`);
  }
  const all = await pull(st.token, st.epoch, { catalog: 0, ledger: 0 });
  eq([all.barcodes.get(C(1))?.product_id, all.barcodes.get(C(2))?.product_id], [st.ids.A, st.ids.A], "A 的两个单件码");
  eq([all.barcodes.get(C(3))?.pack_qty, all.barcodes.get(C(3))?.pack_price_fen], [24, 13200], "整箱码的价不变");
  // 旧流水保持原名称原价
  const old = all.entries.find((e) => e.id === st.oldSaleEntry);
  eq([old?.name_snapshot, old?.amount_fen], ["S25 青岛啤酒 500ml", 600], "B 改价前卖的那罐");
  // 补全：不再待确认，服务器记的是 opening（进价 3.20、数到 8）
  eq(Q.needs_review, false, "Q 补全后不再待确认");
  const qo = all.entries.filter((e) => e.product_id === st.ids.Q && e.type === "opening");
  eq(qo.map((e) => [e.qty_delta, e.unit_cost_fen]), [[9, 320]], "Q 的补全流水（opening，账上 −1 数到 8）");
  // 自动建的 P：先填卖价（product_edit）、挂单件码（barcode_link，不带价），再补全
  eq([P.needs_review, P.price_fen], [false, 450], "P 补全后");
  eq([all.barcodes.get(C(41))?.product_id, all.barcodes.get(C(41))?.pack_qty, all.barcodes.get(C(41))?.pack_price_fen],
    [st.ids.P, 1, null], "P 挂的单件码");
  // 不卖了
  eq(L.archived, true, "L 停用");
  eq(r.store?.low_stock_default, 3, "同步响应带店里的快没货提醒线");
  console.log(JSON.stringify({ checked: true, A: A.price_fen, Q: Q.needs_review, P: [P.price_fen, P.needs_review], L: L.archived }));
  process.exit(0);
}

const login = await post("/v1/auth/login", { username: user, password, device_id: randomUUID(), label: "S25 另一台" });
const token = login.token as string, epoch = login.epoch as string;
async function send(...ops: Op[]) {
  const r = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: false, ops }, token);
  const bad = r.results.filter((x: { status: string }) => x.status !== "applied");
  if (bad.length) throw new Error(`被拒：${JSON.stringify(bad.slice(0, 3))}`);
}
const upsert = (name: string, price: number, code: string, extra: Record<string, unknown> = { quick: false, base_unit: "罐" }) => {
  const id = randomUUID();
  return { id, op: op("product_upsert", { product_id: id, barcode: code, name, price_fen: price, ...extra }) };
};
const opening = (pid: string, qty: number, cost: number, extra: Record<string, unknown> = {}) =>
  op("opening", { entry_id: randomUUID(), product_id: pid, counted_qty: qty, unit_cost_fen: cost, ...extra });
const shDate = (days: number) => new Date(Date.now() + 8 * 3600_000 + days * 86400_000).toISOString().slice(0, 10);

const A = upsert("S25 青岛啤酒 500ml", 600, C(1));
const L = upsert("S25 红牛 250ml", 600, C(11));
const E = upsert("S25 伊利纯牛奶 250ml", 350, C(21), { quick: false, base_unit: "盒", track_expiry: true, expiry_warn_days: 7 });
const Q = upsert("S25 白象 老母鸡汤面", 450, C(31), { quick: true });
await send(A.op, L.op, E.op, Q.op);
await send(
  op("barcode_link", { barcode: C(2), product_id: A.id, pack_qty: 1, unit_name: "罐" }),
  op("barcode_link", { barcode: C(3), product_id: A.id, pack_qty: 24, unit_name: "箱", pack_price_fen: 13200 }),
  opening(A.id, 10, 420), opening(L.id, 2, 480), opening(E.id, 6, 229, { expiry_date: shDate(2) }),
);
const oldSaleEntry = randomUUID(), P = randomUUID();
await send(
  op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 600, lines: [
    { entry_id: oldSaleEntry, product_id: A.id, barcode: C(1), name: "S25 青岛啤酒 500ml", unit_name: "罐", pack_qty: 1, pack_count: 1, unit_price_fen: 600 }] }),
  // 收银员临时登记的白象也卖出过 1 袋（账上 −1，库存动过：stock_ver > 0）
  op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 450, lines: [
    { entry_id: randomUUID(), product_id: Q.id, barcode: C(31), name: "S25 白象 老母鸡汤面", unit_name: "个", pack_qty: 1, pack_count: 1, unit_price_fen: 450 }] }),
  // 卖出引用了没登记的商品（整件行）：服务器自动建待确认商品，卖价记 0、不挂码（§14 S05-9）
  op("sale_batch", { batch_id: randomUUID(), paid_total_fen: 1800, lines: [
    { entry_id: randomUUID(), product_id: P, barcode: C(42), name: "S25 散装方便面", unit_name: "包", pack_qty: 6, pack_count: 1, unit_price_fen: 1800 }] }),
);
// B 拉到底，记下游标，然后「断网」
const r = await pull(token, epoch, { catalog: 0, ledger: 0 });
eq(r.products.get(P)?.price_fen, 0, "自动建的商品卖价是 0");
writeFileSync(stateFile, JSON.stringify({ token, epoch, cursors: r.cursors, ids: { A: A.id, L: L.id, E: E.id, Q: Q.id, P }, oldSaleEntry }));
chmodSync(stateFile, 0o600);
console.log(JSON.stringify({ seeded: true, products: r.products.size, cursors: r.cursors }));
