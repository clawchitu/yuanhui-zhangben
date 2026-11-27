// S26 联调：以「另一台手机」的身份给本机服务端的测试店铺三样货（经 /v1/sync，和手机同一条路）。
// 用法：S26_BASE=http://localhost:8926 S26_USER=... S26_PASSWORD=... node ios/scripts/s26-seed.ts
//   S26 红牛     账上 3 罐（码 6970000260001）：手机先离线卖 1 罐（留在 outbox），再盘点 → 先传完卖出、账上 2、数 1 → 盘亏 1
//   S26 可乐     账上 5 罐（码 6970000260002）：盘点时另一台手机卖 1 罐 →「账上现在是 4 罐，你数的还对吗」
//   S26 面包     账上 4 袋（码 6970000260003）：一直不扫，核对没扫的商品不变
// 铺一次；已有商品就不铺。密码只从环境变量读。
import { randomUUID } from "node:crypto";

const base = process.env.S26_BASE ?? "http://localhost:8926";
const user = process.env.S26_USER;
const password = process.env.S26_PASSWORD;
if (!user || !password) throw new Error("要 S26_USER / S26_PASSWORD");
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

const login = await post("/v1/auth/login", { username: user, password, device_id: randomUUID(), label: "S26 另一台手机" });
const token = login.token as string, epoch = login.epoch as string;

async function send(...ops: Op[]) {
  const r = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: false, ops }, token);
  const bad = r.results.filter((x: { status: string }) => x.status !== "applied");
  if (bad.length) throw new Error(`被拒：${JSON.stringify(bad.slice(0, 3))}`);
}

const first = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: true, ops: [] }, token);
if (first.total_products > 0) {
  console.log(JSON.stringify({ seeded: false, total_products: first.total_products }));
  process.exit(0);
}

const items: Array<[string, string, string, number, number, number]> = [
  // 名称, 码, 单位, 售价, 进几个, 每个进价
  ["S26 红牛", "6970000260001", "罐", 600, 3, 400],
  ["S26 可乐", "6970000260002", "罐", 300, 5, 200],
  ["S26 面包", "6970000260003", "袋", 800, 4, 500],
];
for (const [name, barcode, unit, price, n, cost] of items) {
  const id = randomUUID();
  await send(
    op("product_upsert", { product_id: id, barcode, name, price_fen: price, quick: false, base_unit: unit, track_expiry: false }),
    op("stock_in", { entry_id: randomUUID(), product_id: id, barcode, pack_qty: 1, pack_count: n, unit_cost_fen: cost }),
  );
}
console.log(JSON.stringify({ seeded: true, items: items.map(([name, code, , , n]) => `${name} ${code} ×${n}`) }));
