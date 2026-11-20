// S04：商品类 op（product_upsert / product_edit / barcode_link / barcode_unlink）、条码冲突与别名、单件卖价只有一处。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";
import { newBarcode, op, pullAll, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

const products = (storeId: string) => tdb.kysely.selectFrom("products").selectAll().where("store_id", "=", storeId).execute();
const barcodes = (storeId: string) => tdb.kysely.selectFrom("product_barcodes").selectAll().where("store_id", "=", storeId).execute();
const aliases = (storeId: string) => tdb.kysely.selectFrom("product_aliases").selectAll().where("store_id", "=", storeId).execute();

async function setup() {
  const shop = await makeLoginShop(tdb);
  const app = makeApp(tdb);
  const boss = await login(app, shop.username);
  return { shop, app, boss };
}

describe("product_upsert", () => {
  it("家用完整登记：建商品 + 一个单件码（单件码不存价），两行各占一个连续的 rev", async () => {
    const { shop, app, boss } = await setup();
    const o = upsertFull({
      name: "康师傅红烧牛肉面",
      price: 450,
      baseUnit: "桶",
      extra: { track_expiry: true, expiry_warn_days: 10, shelf_life_months: 6, low_at: 5 },
    });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(r.results[0]).toEqual({ id: o.id, status: "applied" });
    const [p] = await products(shop.storeId);
    expect(p).toMatchObject({
      id: o.payload.product_id,
      name: "康师傅红烧牛肉面",
      price_fen: "450",
      base_unit: "桶",
      track_expiry: true,
      expiry_warn_days: 10,
      shelf_life_months: 6,
      low_at: 5,
      needs_review: false,
      stock_qty: 0,
      stock_ver: "0",
      cost_known: false,
      created_by_device: boss.deviceId,
    });
    const [b] = await barcodes(shop.storeId);
    expect(b).toMatchObject({ barcode: o.payload.barcode, product_id: p!.id, pack_qty: 1, unit_name: "桶", pack_price_fen: null, deleted_at: null });
    expect([Number(p!.rev), Number(b!.rev)]).toEqual([1, 2]);
    const s = await tdb.kysely.selectFrom("stores").select("rev").where("id", "=", shop.storeId).executeTakeFirstOrThrow();
    expect(s.rev).toBe("2");
  });

  it("收银员 quick 登记：needs_review=true，基本单位默认「个」", async () => {
    const { shop, app, boss } = await setup();
    const cas = await pair(app, boss.token, "cashier", "小王");
    const o = upsertQuick({ name: "散装瓜子", price: 800 });
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(r.results[0]).toEqual({ id: o.id, status: "applied" });
    const [p] = await products(shop.storeId);
    expect(p).toMatchObject({ name: "散装瓜子", price_fen: "800", base_unit: "个", needs_review: true, created_by_device: cas.deviceId });
    const [b] = await barcodes(shop.storeId);
    expect(b).toMatchObject({ pack_qty: 1, unit_name: "个", pack_price_fen: null });
  });

  it("两台设备各自登记同一条码 → 一个商品 + 一条别名 + remap，赢家的名称和卖价不变", async () => {
    const { shop, app, boss } = await setup();
    const other = await login(app, shop.username);
    const code = newBarcode();
    const a = upsertFull({ barcode: code, name: "红牛", price: 600 });
    const b = upsertFull({ barcode: code, name: "红牛维生素饮料（改名）", price: 650, baseUnit: "瓶", extra: { low_at: 9 } });
    const ra = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [a] });
    const rb = await syncOk(app, other.token, { epoch: shop.epoch, ops: [b] });
    // 后到的设备又发了引用别名 id 的 op：都改写到赢家，并带 remap
    const edit = op("product_edit", { product_id: b.payload.product_id, low_at: 2 });
    const link = op("barcode_link", { barcode: newBarcode(), product_id: b.payload.product_id, pack_qty: 24, unit_name: "箱", pack_price_fen: 13000 });
    const rc = await syncOk(app, other.token, { epoch: shop.epoch, ops: [edit, link] });
    await app.close();

    expect(ra.results[0]).toEqual({ id: a.id, status: "applied" });
    const remap = { [b.payload.product_id as string]: a.payload.product_id };
    expect(rb.results[0]).toEqual({ id: b.id, status: "applied", remap });
    expect(rc.results).toEqual([
      { id: edit.id, status: "applied", remap },
      { id: link.id, status: "applied", remap },
    ]);
    const ps = await products(shop.storeId);
    expect(ps).toHaveLength(1);
    expect(ps[0]).toMatchObject({ id: a.payload.product_id, name: "红牛", price_fen: "600", base_unit: "罐", low_at: 2 });
    expect(await aliases(shop.storeId)).toEqual([{ store_id: shop.storeId, alias_id: b.payload.product_id, product_id: a.payload.product_id }]);
    const bs = await barcodes(shop.storeId);
    expect(bs.map((x) => [x.barcode, x.product_id]).sort()).toEqual(
      [
        [code, a.payload.product_id],
        [link.payload.barcode, a.payload.product_id],
      ].sort(),
    );
  });

  it("收银员对已有条码提交不同名称和卖价的 quick 登记 → 原值不变（needs_review 也不变），只返回 remap", async () => {
    const { shop, app, boss } = await setup();
    const cas = await pair(app, boss.token, "cashier", "小王");
    const code = newBarcode();
    const orig = upsertFull({ barcode: code, name: "中华（软）", price: 4500 });
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [orig] });
    const before = (await products(shop.storeId))[0]!;
    const q = upsertQuick({ barcode: code, name: "便宜烟", price: 100 });
    const r = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [q] });
    await app.close();
    expect(r.results[0]).toEqual({ id: q.id, status: "applied", remap: { [q.payload.product_id as string]: orig.payload.product_id } });
    const after = await products(shop.storeId);
    expect(after).toEqual([before]);
  });

  it("赢家的那个条码是整件码时也一样：不新建商品，remap 到它的商品", async () => {
    const { shop, app, boss } = await setup();
    const p = upsertFull({ name: "可乐" });
    const box = newBarcode();
    await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [p, op("barcode_link", { barcode: box, product_id: p.payload.product_id, pack_qty: 24, unit_name: "箱" })],
    });
    const q = upsertQuick({ barcode: box, name: "一箱可乐" });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [q] });
    await app.close();
    expect(r.results[0]!.remap).toEqual({ [q.payload.product_id as string]: p.payload.product_id });
    expect(await products(shop.storeId)).toHaveLength(1);
  });

  it("商品 id 已存在（同一商品再登记一个新条码）：不改商品，只挂上这个单件码", async () => {
    const { shop, app, boss } = await setup();
    const p = upsertFull({ name: "矿泉水", price: 200 });
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [p] });
    const before = (await products(shop.storeId))[0]!;
    const again = upsertFull({ productId: p.payload.product_id as string, name: "别的名字", price: 999 });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [again] });
    await app.close();
    expect(r.results[0]).toEqual({ id: again.id, status: "applied" });
    expect(await products(shop.storeId)).toEqual([before]);
    const bs = await barcodes(shop.storeId);
    expect(bs.map((b) => b.barcode).sort()).toEqual([p.payload.barcode, again.payload.barcode].sort());
    expect(bs.every((b) => b.product_id === p.payload.product_id && b.pack_qty === 1)).toBe(true);
  });
});

describe("product_edit", () => {
  it("只改带了的字段；停用 / 恢复；改基本单位时单件码的单位名跟着改，整件码不动", async () => {
    const { shop, app, boss } = await setup();
    const p = upsertFull({ name: "啤酒", price: 500, baseUnit: "瓶", extra: { low_at: 6 } });
    const box = newBarcode();
    const second = newBarcode();
    await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [
        p,
        op("barcode_link", { barcode: box, product_id: p.payload.product_id, pack_qty: 12, unit_name: "箱", pack_price_fen: 5400 }),
        op("barcode_link", { barcode: second, product_id: p.payload.product_id, pack_qty: 1, unit_name: "瓶" }),
      ],
    });
    const pid = p.payload.product_id as string;
    const before = (await products(shop.storeId))[0]!;
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: pid, name: "青岛啤酒", base_unit: "罐" })] });
    const mid = (await products(shop.storeId))[0]!;
    expect(mid).toMatchObject({ name: "青岛啤酒", base_unit: "罐", price_fen: "500", low_at: 6, archived_at: null });
    expect(Number(mid.rev)).toBeGreaterThan(Number(before.rev));
    const bs = Object.fromEntries((await barcodes(shop.storeId)).map((b) => [b.barcode, b]));
    expect(bs[p.payload.barcode as string]!.unit_name).toBe("罐");
    expect(bs[second]!.unit_name).toBe("罐");
    expect(bs[box]!.unit_name).toBe("箱");

    const at = new Date("2026-11-20T01:30:00Z");
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: pid, archived: true, low_at: null }, { at })] });
    expect((await products(shop.storeId))[0]).toMatchObject({ archived_at: at, low_at: null });
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: pid, archived: false })] });
    await app.close();
    expect((await products(shop.storeId))[0]).toMatchObject({ archived_at: null, name: "青岛啤酒" });
  });

  it("逐字段后写者赢：两台手机分别改名称和卖价，两个改动都留下；同一字段以后到服务器的为准", async () => {
    const { shop, app, boss } = await setup();
    const other = await login(app, shop.username);
    const p = upsertFull({ name: "旧名", price: 100 });
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [p] });
    const pid = p.payload.product_id as string;
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: pid, name: "新名" })] });
    await syncOk(app, other.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: pid, price_fen: 150 })] });
    await syncOk(app, other.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: pid, price_fen: 180 })] });
    await app.close();
    expect((await products(shop.storeId))[0]).toMatchObject({ name: "新名", price_fen: "180" });
  });

  it("不存在的商品、别的店的商品：rejected invalid，什么都不改", async () => {
    const { shop, app, boss } = await setup();
    const s2 = await makeLoginShop(tdb);
    const b2 = await login(app, s2.username);
    const foreign = upsertFull();
    await syncOk(app, b2.token, { epoch: s2.epoch, ops: [foreign] });
    const r = await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [
        op("product_edit", { product_id: randomUUID(), name: "x" }),
        op("product_edit", { product_id: foreign.payload.product_id, name: "抢别的店" }),
        op("barcode_link", { barcode: newBarcode(), product_id: foreign.payload.product_id, pack_qty: 6, unit_name: "提" }),
      ],
    });
    await app.close();
    expect(r.results.map((x: { status: string; code?: string }) => [x.status, x.code])).toEqual([
      ["rejected", "invalid"],
      ["rejected", "invalid"],
      ["rejected", "invalid"],
    ]);
    expect((await products(s2.storeId))[0]!.name).toBe("可口可乐 330ml");
    expect(await products(shop.storeId)).toHaveLength(0);
  });
});

describe("barcode_link / barcode_unlink", () => {
  it("整件码可以带价，也可以不带（§14 S02-5 / S12-1）；单件码带价被拒 invalid", async () => {
    const { shop, app, boss } = await setup();
    const p = upsertFull({ price: 300 });
    const pid = p.payload.product_id as string;
    const withPrice = op("barcode_link", { barcode: newBarcode(), product_id: pid, pack_qty: 24, unit_name: "箱", pack_price_fen: 6500 });
    const noPrice = op("barcode_link", { barcode: newBarcode(), product_id: pid, pack_qty: 6, unit_name: "提" });
    const singleWithPrice = op("barcode_link", { barcode: newBarcode(), product_id: pid, pack_qty: 1, unit_name: "罐", pack_price_fen: 300 });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [p, withPrice, noPrice, singleWithPrice] });
    await app.close();
    expect(r.results.map((x: { status: string; code?: string }) => x.code ?? x.status)).toEqual(["applied", "applied", "applied", "invalid"]);
    const bs = Object.fromEntries((await barcodes(shop.storeId)).map((b) => [b.barcode, b]));
    expect(bs[withPrice.payload.barcode as string]!.pack_price_fen).toBe("6500");
    expect(bs[noPrice.payload.barcode as string]!.pack_price_fen).toBeNull();
    expect(bs[singleWithPrice.payload.barcode as string]).toBeUndefined();
  });

  it("条码已挂在别的商品上：rejected invalid，原来的挂法不变；挂在同一商品上：改换算和价", async () => {
    const { shop, app, boss } = await setup();
    const a = upsertFull({ name: "A" });
    const b = upsertFull({ name: "B" });
    const box = newBarcode();
    await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [a, b, op("barcode_link", { barcode: box, product_id: a.payload.product_id, pack_qty: 24, unit_name: "箱", pack_price_fen: 6000 })],
    });
    const steal = op("barcode_link", { barcode: box, product_id: b.payload.product_id, pack_qty: 12, unit_name: "箱" });
    const fix = op("barcode_link", { barcode: box, product_id: a.payload.product_id, pack_qty: 20, unit_name: "件" });
    const stealSingle = op("barcode_link", { barcode: a.payload.barcode, product_id: b.payload.product_id, pack_qty: 1, unit_name: "罐" });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [steal, fix, stealSingle] });
    await app.close();
    expect(r.results.map((x: { status: string; code?: string }) => x.code ?? x.status)).toEqual(["invalid", "applied", "invalid"]);
    const bs = Object.fromEntries((await barcodes(shop.storeId)).map((x) => [x.barcode, x]));
    expect(bs[box]).toMatchObject({ product_id: a.payload.product_id, pack_qty: 20, unit_name: "件", pack_price_fen: null });
    expect(bs[a.payload.barcode as string]!.product_id).toBe(a.payload.product_id);
  });

  it("解除：写墓碑；再解除一次无操作；解除后可以重新挂（挂到别的商品也行）", async () => {
    const { shop, app, boss } = await setup();
    const a = upsertFull({ name: "A" });
    const b = upsertFull({ name: "B" });
    const box = newBarcode();
    await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [a, b, op("barcode_link", { barcode: box, product_id: a.payload.product_id, pack_qty: 24, unit_name: "箱" })],
    });
    const unlink = op("barcode_unlink", { barcode: box, product_id: a.payload.product_id });
    const unlinkAgain = op("barcode_unlink", { barcode: box, product_id: a.payload.product_id });
    const unlinkMissing = op("barcode_unlink", { barcode: newBarcode(), product_id: a.payload.product_id });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [unlink, unlinkAgain, unlinkMissing] });
    expect(r.results.map((x: { status: string }) => x.status)).toEqual(["applied", "applied", "applied"]);
    const tomb = await tdb.kysely.selectFrom("removed").selectAll().where("store_id", "=", shop.storeId).execute();
    expect(tomb.map((t) => [t.kind, t.row_id])).toEqual([["barcode", box]]);
    const row = (await barcodes(shop.storeId)).find((x) => x.barcode === box)!;
    expect(row.deleted_at).not.toBeNull();

    // 解除别的商品的条码：invalid
    const wrong = op("barcode_unlink", { barcode: a.payload.barcode, product_id: b.payload.product_id });
    const relink = op("barcode_link", { barcode: box, product_id: b.payload.product_id, pack_qty: 6, unit_name: "提" });
    const r2 = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [wrong, relink] });
    await app.close();
    expect(r2.results.map((x: { status: string; code?: string }) => x.code ?? x.status)).toEqual(["invalid", "applied"]);
    const again = (await barcodes(shop.storeId)).find((x) => x.barcode === box)!;
    expect(again).toMatchObject({ product_id: b.payload.product_id, pack_qty: 6, unit_name: "提", deleted_at: null });
    expect(Number(again.rev)).toBeGreaterThan(Number(tomb[0]!.rev));
  });

  it("解除过的条码再被 product_upsert 登记：算空闲条码，建新商品", async () => {
    const { shop, app, boss } = await setup();
    const a = upsertFull({ name: "A" });
    await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [a, op("barcode_unlink", { barcode: a.payload.barcode, product_id: a.payload.product_id })],
    });
    const n = upsertFull({ barcode: a.payload.barcode as string, name: "新商品" });
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [n] });
    await app.close();
    expect(r.results[0]).toEqual({ id: n.id, status: "applied" });
    const row = (await barcodes(shop.storeId)).find((x) => x.barcode === a.payload.barcode)!;
    expect(row).toMatchObject({ product_id: n.payload.product_id, deleted_at: null });
  });
});

describe("单件卖价只有一处", () => {
  it("改商品卖价后：该商品所有单件码、名称搜索得到的都是新价；带价的整件码不变，不带价的整件码 = 新单价 × 换算", async () => {
    const { shop, app, boss } = await setup();
    const p = upsertFull({ name: "百事可乐", price: 300 });
    const pid = p.payload.product_id as string;
    const single2 = newBarcode();
    const boxPriced = newBarcode();
    const pack6 = newBarcode();
    await syncOk(app, boss.token, {
      epoch: shop.epoch,
      ops: [
        p,
        op("barcode_link", { barcode: single2, product_id: pid, pack_qty: 1, unit_name: "罐" }),
        op("barcode_link", { barcode: boxPriced, product_id: pid, pack_qty: 24, unit_name: "箱", pack_price_fen: 6500 }),
        op("barcode_link", { barcode: pack6, product_id: pid, pack_qty: 6, unit_name: "提" }),
      ],
    });
    const phone = await pullAll(app, boss.token, shop.epoch);
    expect([phone.priceOfBarcode(p.payload.barcode as string), phone.priceOfBarcode(single2), phone.priceOfBarcode(boxPriced), phone.priceOfBarcode(pack6)]).toEqual([300, 300, 6500, 1800]);
    const boxRevBefore = phone.barcodes.get(boxPriced).rev;

    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [op("product_edit", { product_id: pid, price_fen: 350 })] });
    // 增量拉：只有商品这一行变了，条码一行都没动
    const before = phone.pages;
    const delta = await syncOk(app, boss.token, { epoch: shop.epoch, cursors: phone.cursors });
    phone.apply(delta);
    expect(phone.pages).toBe(before + 1);
    expect(delta.changes.products.map((x: { id: string }) => x.id)).toEqual([pid]);
    expect(delta.changes.barcodes).toEqual([]);
    await app.close();

    expect([phone.priceOfBarcode(p.payload.barcode as string), phone.priceOfBarcode(single2)]).toEqual([350, 350]);
    expect(phone.searchByName("百事").map((x) => x.price_fen)).toEqual([350]);
    expect(phone.priceOfBarcode(boxPriced)).toBe(6500);
    expect(phone.barcodes.get(boxPriced).rev).toBe(boxRevBefore);
    expect(phone.priceOfBarcode(pack6)).toBe(2100);
    // 库里单件码一律没有价
    const singles = (await barcodes(shop.storeId)).filter((b) => b.pack_qty === 1);
    expect(singles).toHaveLength(2);
    expect(singles.every((b) => b.pack_price_fen === null)).toBe(true);
  });
});
