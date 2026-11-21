// 演示小店的种子数据（S09，docs/plan-v2.md §8 S09、§14 S08-10）。
//
// - 约 30 个商品，全部是饮料、零食、日用品，没有烟和酒；不用任何第三方图（image_ver = 0，手机显示首字）。
// - 最近 7 天的流水，时间相对「现在」往前推（含一笔抹零、一笔撤销、一次进货）；一个 3 天后到期和一个已过期的批次；
//   一个待确认商品（quick 登记）；一个整箱码（可乐 1 箱 = 24 罐）。
// - S08-10：DEMO_CATALOG 里那 6 个条码不种成商品（留给审核员走「扫到新条码 → 查到名称 → 登记」），测试里核对。
//
// 种子不直接往表里写行，而是造一串 op，按 ops.schema.json 校验后交给和 /v1/sync 同一套处理函数（HANDLERS）应用：
// 库存、货值、批次、报表口径和真实记账完全一样，不会种出一份「规则里不可能出现」的账。
// 所有 id 都由（店 id, 种子里的名字）算出来，同一家店同一时刻种出的数据逐行相同（重置验收「与种子逐表一致」靠它）。
import { createHash } from "node:crypto";
import type { StoreTx } from "../sync/lock.ts";
import { HANDLERS, payloadHash, type IncomingOp } from "../sync/push.ts";
import { opSchemaValid } from "../sync/validate.ts";
import { addDay, today } from "../reports/common.ts";

export const DEMO_STORE_NAME = "演示小店";
/** 种子数据记在这台「设备」名下：服务器自己建的、已撤销的设备行，令牌是随机数、没人知道，不能登录 */
export const SEED_DEVICE_LABEL = "演示数据";

/** 由店 id 和名字算出固定的 UUID（v4 格式位），同一家店每次种出来一样 */
export function seedId(storeId: string, name: string): string {
  const h = createHash("sha256").update(`demo-seed:${storeId.toLowerCase()}:${name}`).digest();
  h[6] = (h[6]! & 0x0f) | 0x40;
  h[8] = (h[8]! & 0x3f) | 0x80;
  const x = h.subarray(0, 16).toString("hex");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20, 32)}`;
}

/** EAN-13 校验位 */
export function ean13(first12: string): string {
  let s = 0;
  for (let i = 0; i < 12; i++) s += Number(first12[i]) * (i % 2 === 0 ? 1 : 3);
  return first12 + String((10 - (s % 10)) % 10);
}

interface SeedProduct {
  key: string;
  name: string;
  unit: string;
  price: number;
  cost: number;
  qty: number;
  kind: "饮料" | "零食" | "日用品";
}

/** 30 个商品。条码用店内码段 21…（DEMO_CATALOG 用的是 20…，两段不重叠） */
export const SEED_PRODUCTS: readonly SeedProduct[] = [
  { key: "cola", name: "可口可乐 330ml", unit: "罐", price: 300, cost: 200, qty: 0, kind: "饮料" },
  { key: "sprite", name: "雪碧 500ml", unit: "瓶", price: 350, cost: 230, qty: 30, kind: "饮料" },
  { key: "water", name: "农夫山泉 550ml", unit: "瓶", price: 200, cost: 120, qty: 48, kind: "饮料" },
  { key: "tea", name: "康师傅冰红茶 500ml", unit: "瓶", price: 350, cost: 220, qty: 24, kind: "饮料" },
  { key: "greentea", name: "统一绿茶 500ml", unit: "瓶", price: 350, cost: 220, qty: 20, kind: "饮料" },
  { key: "juice", name: "美汁源果粒橙 450ml", unit: "瓶", price: 450, cost: 300, qty: 12, kind: "饮料" },
  { key: "redbull", name: "红牛 250ml", unit: "罐", price: 650, cost: 480, qty: 18, kind: "饮料" },
  { key: "milk", name: "蒙牛纯牛奶 250ml", unit: "盒", price: 350, cost: 250, qty: 0, kind: "饮料" },
  { key: "yogurt", name: "伊利优酸乳 250ml", unit: "盒", price: 300, cost: 200, qty: 16, kind: "饮料" },
  { key: "coffee", name: "雀巢咖啡 268ml", unit: "瓶", price: 600, cost: 420, qty: 10, kind: "饮料" },
  { key: "noodle", name: "康师傅红烧牛肉面", unit: "桶", price: 450, cost: 300, qty: 24, kind: "零食" },
  { key: "chips", name: "乐事薯片 75g", unit: "袋", price: 750, cost: 520, qty: 15, kind: "零食" },
  { key: "biscuit", name: "奥利奥饼干 116g", unit: "盒", price: 800, cost: 560, qty: 12, kind: "零食" },
  { key: "bread", name: "桃李面包", unit: "袋", price: 500, cost: 350, qty: 0, kind: "零食" },
  { key: "sausage", name: "双汇火腿肠", unit: "根", price: 150, cost: 90, qty: 40, kind: "零食" },
  { key: "gum", name: "绿箭口香糖", unit: "条", price: 200, cost: 130, qty: 30, kind: "零食" },
  { key: "candy", name: "大白兔奶糖 114g", unit: "袋", price: 1200, cost: 850, qty: 6, kind: "零食" },
  { key: "seeds", name: "洽洽瓜子 160g", unit: "袋", price: 800, cost: 560, qty: 10, kind: "零食" },
  { key: "choco", name: "德芙巧克力 43g", unit: "条", price: 900, cost: 640, qty: 8, kind: "零食" },
  { key: "nuts", name: "旺旺雪饼 84g", unit: "袋", price: 600, cost: 400, qty: 2, kind: "零食" },
  { key: "tissue", name: "清风抽纸", unit: "包", price: 400, cost: 260, qty: 20, kind: "日用品" },
  { key: "paper", name: "维达卷纸", unit: "卷", price: 300, cost: 190, qty: 24, kind: "日用品" },
  { key: "toothpaste", name: "中华牙膏 120g", unit: "支", price: 900, cost: 620, qty: 6, kind: "日用品" },
  { key: "brush", name: "高露洁牙刷", unit: "支", price: 800, cost: 520, qty: 6, kind: "日用品" },
  { key: "soap", name: "舒肤佳香皂", unit: "块", price: 650, cost: 450, qty: 8, kind: "日用品" },
  { key: "shampoo", name: "海飞丝洗发水 200ml", unit: "瓶", price: 2500, cost: 1800, qty: 4, kind: "日用品" },
  { key: "battery", name: "南孚电池 5号 2粒", unit: "板", price: 600, cost: 400, qty: 10, kind: "日用品" },
  { key: "lighter", name: "一次性打火机", unit: "个", price: 100, cost: 50, qty: 20, kind: "日用品" },
  { key: "umbrella", name: "折叠雨伞", unit: "把", price: 2500, cost: 1500, qty: 3, kind: "日用品" },
  { key: "bag", name: "背心塑料袋", unit: "个", price: 20, cost: 10, qty: 200, kind: "日用品" },
];

/** 单件码 */
export function seedBarcode(i: number): string {
  return ean13(`21000000${String(i + 1).padStart(4, "0")}`);
}
/** 可乐的整箱码（1 箱 = 24 罐） */
export const COLA_CASE_BARCODE = ean13("210000009001");
/** 待确认商品（quick 登记，等家用号补全）的码 */
export const PENDING_BARCODE = ean13("210000009002");

type SeedOp = IncomingOp;

/**
 * 造种子 op（按应用顺序）。now 是种子的「现在」：流水落在最近 7 天，到期日按上海的「今天」算。
 */
export function buildSeedOps(storeId: string, now: Date): SeedOp[] {
  const id = (n: string) => seedId(storeId, n);
  const at = (daysAgo: number, hoursAgo: number) => new Date(now.getTime() - daysAgo * 86_400_000 - hoursAgo * 3_600_000).toISOString();
  const day = today(now);
  const ops: SeedOp[] = [];
  const push = (key: string, type: IncomingOp["type"], occurred_at: string, payload: Record<string, unknown>) =>
    ops.push({ id: id(`op:${key}`), type, occurred_at, payload });
  const P = new Map(SEED_PRODUCTS.map((p, i) => [p.key, { ...p, id: id(`product:${p.key}`), barcode: seedBarcode(i) }]));
  const get = (k: string) => P.get(k)!;

  // 7 天前：登记全部商品、录期初
  for (const p of P.values()) {
    const expiry = p.key === "milk" || p.key === "bread";
    push(`upsert:${p.key}`, "product_upsert", at(7, 3), {
      product_id: p.id,
      barcode: p.barcode,
      name: p.name,
      price_fen: p.price,
      quick: false,
      base_unit: p.unit,
      ...(expiry ? { track_expiry: true, expiry_warn_days: 7 } : {}),
      ...(p.key === "nuts" ? { low_at: 3 } : {}),
    });
    if (p.qty > 0) {
      push(`opening:${p.key}`, "opening", at(7, 2), { entry_id: id(`entry:opening:${p.key}`), product_id: p.id, counted_qty: p.qty, unit_cost_fen: p.cost });
    }
  }
  // 两个保质期批次：牛奶 3 天后到期，面包已过期 2 天（期初时带到期日）
  push("opening:milk", "opening", at(7, 2), {
    entry_id: id("entry:opening:milk"),
    product_id: get("milk").id,
    counted_qty: 12,
    unit_cost_fen: get("milk").cost,
    expiry_date: addDay(day, 3),
  });
  push("opening:bread", "opening", at(7, 2), {
    entry_id: id("entry:opening:bread"),
    product_id: get("bread").id,
    counted_qty: 5,
    unit_cost_fen: get("bread").cost,
    expiry_date: addDay(day, -2),
  });
  // 整箱码：可乐 1 箱 = 24 罐，整箱卖 66 元
  const cola = get("cola");
  push("link:cola-case", "barcode_link", at(7, 1), { barcode: COLA_CASE_BARCODE, product_id: cola.id, pack_qty: 24, unit_name: "箱", pack_price_fen: 6600 });
  // 一次进货：6 天前进可乐 2 箱，每箱 48 元
  push("stock_in:cola", "stock_in", at(6, 5), {
    entry_id: id("entry:stock_in:cola"),
    product_id: cola.id,
    barcode: COLA_CASE_BARCODE,
    pack_qty: 24,
    pack_count: 2,
    unit_cost_fen: 4800,
  });

  // 卖出：最近 7 天每天几笔
  const line = (batch: string, n: number, k: string, count: number) => {
    const p = get(k);
    return {
      entry_id: id(`entry:sale:${batch}:${n}`),
      product_id: p.id,
      barcode: p.barcode,
      name: p.name,
      unit_name: p.unit,
      pack_qty: 1,
      pack_count: count,
      unit_price_fen: p.price,
    };
  };
  const sale = (batch: string, daysAgo: number, hoursAgo: number, items: Array<[string, number]>, paid?: number) => {
    const lines = items.map(([k, c], i) => line(batch, i, k, c));
    const list = lines.reduce((s, l) => s + l.unit_price_fen * l.pack_count, 0);
    push(`sale:${batch}`, "sale_batch", at(daysAgo, hoursAgo), { batch_id: id(`batch:${batch}`), paid_total_fen: paid ?? list, lines });
  };
  const plan: Array<[number, Array<Array<[string, number]>>]> = [
    [6, [[["water", 2], ["noodle", 1]], [["cola", 3]], [["tissue", 1], ["gum", 1]]]],
    [5, [[["tea", 2]], [["chips", 1], ["cola", 2]], [["sausage", 3], ["noodle", 2]]]],
    [4, [[["redbull", 1]], [["paper", 4], ["soap", 1]], [["water", 3]]]],
    [3, [[["yogurt", 2], ["biscuit", 1]], [["cola", 6]], [["battery", 1]]]],
    [2, [[["greentea", 2], ["seeds", 1]], [["juice", 1], ["choco", 1]], [["lighter", 2], ["bag", 2]]]],
    [1, [[["coffee", 1], ["milk", 2]], [["sprite", 2], ["sausage", 2]], [["nuts", 1], ["water", 2]]]],
    [0, [[["cola", 2], ["chips", 1]], [["tea", 1], ["noodle", 1]]]],
  ];
  for (const [d, batches] of plan) batches.forEach((items, i) => sale(`d${d}-${i}`, d, 3 + i * 0.5, items));
  // 一笔抹零：14.2 元收 14 元
  sale("round-off", 1, 1, [["candy", 1], ["bag", 1], ["gum", 1]], 1400);
  // 一笔撤销：昨天卖错了一瓶洗发水，撤掉
  sale("voided", 1, 2, [["shampoo", 1]]);
  push("void:voided", "void", at(1, 1.5), { target: { batch_id: id("batch:voided") } });
  // 一个待确认商品：收银员临时登记的（quick），等家用号补全进价和库存
  push("upsert:pending", "product_upsert", at(0, 2), {
    product_id: id("product:pending"),
    barcode: PENDING_BARCODE,
    name: "散装辣条",
    price_fen: 100,
    quick: true,
  });
  return ops;
}

/**
 * 在店铺锁内应用种子：建（或复用）种子设备，逐个 op 写留档、调处理函数。任何一个没被应用就抛错（整个事务回滚）。
 * 调用方保证这家店的业务数据已经清空。
 */
export async function applySeed(tx: StoreTx, accountId: string, now: Date): Promise<void> {
  const storeId = tx.storeId;
  const deviceId = seedId(storeId, "device:seed");
  await tx.trx
    .insertInto("devices")
    .values({
      id: deviceId,
      store_id: storeId,
      account_id: accountId,
      role: "family",
      label: SEED_DEVICE_LABEL,
      // 随机令牌的哈希：没有原文，不能登录
      token_hash: createHash("sha256").update(`seed:${storeId}:${now.getTime()}:${Math.random()}`).digest("hex"),
      created_at: now,
      last_seen_at: null,
      revoked_at: now,
      revoke_reason: "demo_reset",
    })
    .execute();
  for (const op of buildSeedOps(storeId, now)) {
    if (!opSchemaValid(op)) throw new Error(`演示种子的 op 不合 ops.schema.json：${op.type} ${op.id}`);
    const occurredAt = new Date(op.occurred_at);
    await tx.trx
      .insertInto("ops")
      .values({
        id: op.id,
        store_id: storeId,
        device_id: deviceId,
        type: op.type,
        payload: JSON.stringify(op.payload),
        payload_hash: payloadHash(op),
        occurred_at: occurredAt,
        received_at: now,
        status: "applied",
        reject_code: null,
        result: JSON.stringify({ id: op.id, status: "applied" }),
        flags: "{}",
      })
      .execute();
    const out = await HANDLERS[op.type](tx, { deviceId, now, occurredAt, opId: op.id, flags: {} }, op.payload as never);
    if (out.status !== "applied") throw new Error(`演示种子的 op 没被应用：${op.type} ${op.id} → ${JSON.stringify(out)}`);
  }
}
