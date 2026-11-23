// S22a 联调：给本机服务端（或线上测试店）的店铺铺 312 样商品，和 ¥40.05 用例的起始状态。
// 用法：S22A_BASE=http://localhost:8787 S22A_USER=... S22A_PASSWORD=... node ios/scripts/s22a-seed.ts [--generic N]
// 已经铺过（商品总数 ≥ 312）就不再铺。密码只从环境变量读（线上测试店的密码运行时从钥匙串取，不写文件）。
//
// 铺的东西：
// - 310 样「S22A 测试商品 n」（条码 6970000000001 起）
// - 「S22A 中华（软）」：包码 6970000099001、条码 6970000099002（1 条 = 10 包）；进 2 包 × ¥40.46 + 4 包 × ¥40.47
//   → 库存 6 包、货值 ¥242.80（cost.json 第一条的起始状态，再进 5 条 × ¥400 → 平均 ¥40.05）
// - 「S22A 测试啤酒」：码 6970000099010，卖价 ¥5，期初 1000 瓶 × ¥3（断网卖三笔、强杀用）
import { randomUUID } from "node:crypto";
import { parseArgs } from "node:util";

const base = process.env.S22A_BASE ?? "http://localhost:8787";
const user = process.env.S22A_USER;
const password = process.env.S22A_PASSWORD;
if (!user || !password) throw new Error("要 S22A_USER / S22A_PASSWORD");
const { values } = parseArgs({ options: { generic: { type: "string", default: "310" } } });
const generic = Number(values.generic);

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

const at = new Date().toISOString();
const op = (type: string, payload: Record<string, unknown>) => ({ id: randomUUID(), type, occurred_at: at, payload });

const login = await post("/v1/auth/login", { username: user, password, device_id: randomUUID(), label: "S22A 铺货" });
const token = login.token as string, epoch = login.epoch as string;
const first = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: true, ops: [] }, token);
if (first.total_products >= 312) {
  console.log(JSON.stringify({ seeded: false, total_products: first.total_products }));
  process.exit(0);
}

const ops: ReturnType<typeof op>[] = [];
for (let i = 1; i <= generic; i++) {
  ops.push(op("product_upsert", { product_id: randomUUID(), barcode: `697${String(i).padStart(10, "0")}`, name: `S22A 测试商品 ${i}`, price_fen: 100 + i, quick: false, base_unit: "个" }));
}
const zh = randomUUID(), beer = randomUUID();
ops.push(op("product_upsert", { product_id: zh, barcode: "6970000099001", name: "S22A 中华（软）", price_fen: 4500, quick: false, base_unit: "包" }));
ops.push(op("barcode_link", { barcode: "6970000099002", product_id: zh, pack_qty: 10, unit_name: "条", pack_price_fen: 45000 }));
ops.push(op("stock_in", { entry_id: randomUUID(), product_id: zh, barcode: "6970000099001", pack_qty: 1, pack_count: 2, unit_cost_fen: 4046 }));
ops.push(op("stock_in", { entry_id: randomUUID(), product_id: zh, barcode: "6970000099001", pack_qty: 1, pack_count: 4, unit_cost_fen: 4047 }));
ops.push(op("product_upsert", { product_id: beer, barcode: "6970000099010", name: "S22A 测试啤酒", price_fen: 500, quick: false, base_unit: "瓶" }));
ops.push(op("opening", { entry_id: randomUUID(), product_id: beer, counted_qty: 1000, unit_cost_fen: 300 }));

for (let i = 0; i < ops.length; i += 150) {
  const r = await post("/v1/sync", { epoch, cursors: { catalog: 0, ledger: 0 }, app_build: 1, pull: false, ops: ops.slice(i, i + 150) }, token);
  const bad = r.results.filter((x: { status: string }) => x.status !== "applied");
  if (bad.length) throw new Error(`铺货被拒：${JSON.stringify(bad.slice(0, 3))}`);
}
console.log(JSON.stringify({ seeded: true, ops: ops.length }));
