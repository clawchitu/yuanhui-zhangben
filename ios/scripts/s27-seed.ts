// S27 联调：给本机服务端的测试店铺几样管保质期的货（按「今天」= 上海日期算到期日），以及「另一台手机」处理同一批。
// 用法：S27_BASE=http://localhost:8827 S27_USER=... S27_PASSWORD=... node ios/scripts/s27-seed.ts [--other-handles 名称]
//   不带参数：登记四样、各进一批货（铺一次，已有商品就不铺）
//     S27 光明鲜牛奶   2 盒，每盒 ¥9.80，到期 = 今天 − 2（已过期）
//     S27 桃李面包     4 袋，每袋 ¥5.00，到期 = 今天 + 2（快过期）
//     S27 伊利纯牛奶   3 盒，每盒 ¥2.29，到期 = 今天 + 5（快过期）
//     S27 可口可乐     24 罐，每罐 ¥2.00，到期 = 今天 + 120（还早，不提醒）；卖掉 1 罐 ¥3.00（本月赚了 ¥1.00）
//   --other-handles 名称：以另一台手机的身份把这个商品那批「还在卖，过几天再提醒」（实际数 1），
//     让手机上随后对同一批的处理被拒 stale（「这批已经处理过了」）
// 只走 HTTP（登录、/v1/sync），和手机同一条路；密码只从环境变量读。
import { randomUUID } from "node:crypto";

const base = process.env.S27_BASE ?? "http://localhost:8827";
const user = process.env.S27_USER;
const password = process.env.S27_PASSWORD;
if (!user || !password) throw new Error("要 S27_USER / S27_PASSWORD");
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

/** 上海的今天 ± n 天，YYYY-MM-DD */
function shanghaiDay(offset: number): string {
  const t = new Date(Date.now() + 8 * 3600_000 + offset * 86_400_000);
  return t.toISOString().slice(0, 10);
}

const login = await post("/v1/auth/login", { username: user, password, device_id: randomUUID(), label: "S27 另一台手机" });
const token = login.token as string, epoch = login.epoch as string;

async function send(...ops: Op[]) {
  const r = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: false, ops }, token);
  const bad = r.results.filter((x: { status: string }) => x.status !== "applied");
  if (bad.length) throw new Error(`被拒：${JSON.stringify(bad.slice(0, 3))}`);
}

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

const i = process.argv.indexOf("--other-handles");
if (i >= 0) {
  const name = process.argv[i + 1]!;
  const { products, lots } = await pullAll();
  const p = [...products.values()].find((x) => x.name === name);
  if (!p) throw new Error(`没有商品 ${name}`);
  const L = [...lots.values()].find((l) => l.product_id === p.id && l.closed_at === null);
  if (!L) throw new Error(`${name} 没有未关闭的批次`);
  await send(op("lot_snooze", { lot_id: L.id, handle_ver: L.handle_ver, actual_qty: 1, days: 3 }));
  console.log(JSON.stringify({ other_handled: name, lot_id: L.id, handle_ver_before: L.handle_ver }));
  process.exit(0);
}

const first = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: true, ops: [] }, token);
if (first.total_products > 0) {
  console.log(JSON.stringify({ seeded: false, total_products: first.total_products }));
  process.exit(0);
}

let code = 6970000270000;
const items: Array<[string, string, number, number, number, number]> = [
  // 名称, 单位, 售价, 进几个, 每个进价, 到期日 = 今天 + n
  ["S27 光明鲜牛奶", "盒", 1380, 2, 980, -2],
  ["S27 桃李面包", "袋", 800, 4, 500, 2],
  ["S27 伊利纯牛奶", "盒", 350, 3, 229, 5],
  ["S27 可口可乐", "罐", 300, 24, 200, 120],
];
const out: Record<string, string> = {};
for (const [name, unit, price, n, cost, days] of items) {
  const id = randomUUID();
  const barcode = String(code++);
  await send(
    op("product_upsert", { product_id: id, barcode, name, price_fen: price, quick: false, base_unit: unit, track_expiry: true, expiry_warn_days: 7 }),
    op("stock_in", { entry_id: randomUUID(), product_id: id, barcode, pack_qty: 1, pack_count: n, unit_cost_fen: cost, expiry_date: shanghaiDay(days) }),
  );
  out[name] = shanghaiDay(days);
  // 可乐卖 1 罐（¥3.00，进价 ¥2.00），让本月「赚了」不是 0，扔掉后核对它不变
  if (name === "S27 可口可乐") {
    await send(op("sale_batch", { batch_id: randomUUID(), paid_total_fen: price, lines: [{ entry_id: randomUUID(), product_id: id, barcode, name, unit_name: unit, pack_qty: 1, pack_count: 1, unit_price_fen: price }] }));
  }
}
console.log(JSON.stringify({ seeded: true, today: shanghaiDay(0), expiry: out }));
