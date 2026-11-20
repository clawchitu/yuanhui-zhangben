// S04：幂等与重放（§4.2「结果可重放」，不变式 I5、I8）。
import { randomUUID } from "node:crypto";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { login, makeApp, makeLoginShop, pair } from "./helpers/auth.ts";
import { op, sync, syncOk, upsertFull, upsertQuick } from "./helpers/sync.ts";

let tdb: TestDb;
beforeAll(async () => {
  tdb = await createTestDb();
});
afterAll(() => tdb.drop());

/** 店里所有会被同步改到的表的完整内容（除了时间戳以外逐列比较） */
async function dump(storeId: string) {
  const k = tdb.kysely;
  return {
    store: await k.selectFrom("stores").select(["rev", "epoch"]).where("id", "=", storeId).executeTakeFirstOrThrow(),
    products: await k.selectFrom("products").selectAll().where("store_id", "=", storeId).orderBy("id").execute(),
    barcodes: await k.selectFrom("product_barcodes").selectAll().where("store_id", "=", storeId).orderBy("barcode").execute(),
    aliases: await k.selectFrom("product_aliases").selectAll().where("store_id", "=", storeId).orderBy("alias_id").execute(),
    removed: await k.selectFrom("removed").selectAll().where("store_id", "=", storeId).orderBy("rev").execute(),
    ops: await k
      .selectFrom("ops")
      .select(["id", "device_id", "type", "payload", "payload_hash", "occurred_at", "status", "reject_code", "result", "flags"])
      .where("store_id", "=", storeId)
      .orderBy("id")
      .execute(),
  };
}

const withoutReplayed = (rs: Array<Record<string, unknown>>) => rs.map(({ replayed: _r, ...rest }) => rest);

describe("同一批 op 发 3 次", () => {
  it("库里各一条，三次响应的结果相同（含 remap 和拒绝原因），后两次带 replayed", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");

    // 先让收银员登记一个条码，制造后面的冲突
    const shared = "6901234567892";
    const first = upsertQuick({ barcode: shared, name: "先到的", price: 450 });
    await syncOk(app, cas.token, { epoch: shop.epoch, ops: [first] });

    const pid = randomUUID();
    const batch = [
      // 新商品：应用
      upsertFull({ productId: pid, name: "雪碧", price: 300 }),
      // 同条码后到：applied + remap
      upsertFull({ barcode: shared, name: "后到的", price: 999 }),
      // 改刚建的商品：应用
      op("product_edit", { product_id: pid, price_fen: 350 }),
      // 格式不对（卖价超上限）：rejected invalid
      upsertFull({ price: 100_000_000 }),
      // 不存在的商品：rejected invalid
      op("product_edit", { product_id: randomUUID(), name: "没有这个" }),
    ];
    const r1 = await syncOk(app, boss.token, { epoch: shop.epoch, ops: batch, pull: false });
    const after1 = await dump(shop.storeId);
    const r2 = await syncOk(app, boss.token, { epoch: shop.epoch, ops: batch, pull: false });
    const r3 = await syncOk(app, boss.token, { epoch: shop.epoch, ops: batch, pull: false });
    const after3 = await dump(shop.storeId);
    await app.close();

    expect(r1.results.map((r: { status: string; code?: string }) => [r.status, r.code])).toEqual([
      ["applied", undefined],
      ["applied", undefined],
      ["applied", undefined],
      ["rejected", "invalid"],
      ["rejected", "invalid"],
    ]);
    const winner = after1.products.find((p) => p.name === "先到的")!;
    expect(r1.results[1].remap).toEqual({ [batch[1]!.payload.product_id as string]: winner.id });
    expect(r1.results.every((r: { replayed?: boolean }) => r.replayed === undefined)).toBe(true);
    expect(r2.results.every((r: { replayed?: boolean }) => r.replayed === true)).toBe(true);
    expect(r2.results).toEqual(r3.results);
    expect(withoutReplayed(r2.results)).toEqual(r1.results);

    // I5：重放不改库（rev 计数器也不动）
    expect(after3).toEqual(after1);
    // 每个 op 一条，被拒的也留档
    expect(after1.ops.filter((o) => batch.some((b) => b.id === o.id))).toHaveLength(5);
    expect(after1.products.filter((p) => p.name === "雪碧")).toHaveLength(1);
    expect(after1.products.find((p) => p.id === pid)!.price_fen).toBe("350");
  });

  it("一次请求里同一个 op 出现两次：第二次就是重放", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const o = upsertFull();
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o, o], pull: false });
    await app.close();
    expect(r.results[0]).toEqual({ id: o.id, status: "applied" });
    expect(r.results[1]).toEqual({ id: o.id, status: "applied", replayed: true });
  });

  it("重发时 id 大小写、键顺序、occurred_at 的写法不同，仍算同一个 op", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const o = upsertFull();
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o] });
    const reordered = Object.fromEntries(Object.entries(o.payload).reverse());
    const same = { ...o, id: o.id.toUpperCase(), occurred_at: "2026-11-20T09:59:00.000+08:00", payload: reordered };
    const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [same] });
    await app.close();
    expect(r.results[0]).toEqual({ id: same.id, status: "applied", replayed: true });
  });
});

describe("同 id 不同内容", () => {
  it("rejected: id_conflict，不应用、不覆盖原来的留档；原 op 再重发仍返回原结果", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const o = upsertFull({ name: "原来的" });
    await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o] });
    const before = await dump(shop.storeId);

    const variants = [
      { ...o, payload: { ...o.payload, name: "改过的" } },
      { ...o, occurred_at: "2026-11-20T01:58:00.000Z" },
      { ...o, type: "product_edit", payload: { product_id: o.payload.product_id, name: "改过的" } },
    ];
    for (const v of variants) {
      const r = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [v] });
      expect(r.results[0]).toEqual({ id: o.id, status: "rejected", code: "id_conflict" });
    }
    // id_conflict 不进库：再发一次还是 id_conflict，原 op 重发还是原结果
    expect(await dump(shop.storeId)).toEqual(before);
    const again = await syncOk(app, boss.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(again.results[0]).toEqual({ id: o.id, status: "applied", replayed: true });
  });

  it("别的设备用同一个 id 发同样的内容（恢复后重新开通的设备补交）：返回当初的结果", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const a = await login(app, shop.username);
    const b = await login(app, shop.username);
    const o = upsertFull();
    await syncOk(app, a.token, { epoch: shop.epoch, ops: [o] });
    const r = await syncOk(app, b.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(r.results[0]).toEqual({ id: o.id, status: "applied", replayed: true });
  });

  it("A 店的 op id 不挡 B 店（幂等按 (store_id, id)）", async () => {
    const s1 = await makeLoginShop(tdb);
    const s2 = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const t1 = await login(app, s1.username);
    const t2 = await login(app, s2.username);
    const o = upsertFull();
    const r1 = await syncOk(app, t1.token, { epoch: s1.epoch, ops: [o] });
    const r2 = await syncOk(app, t2.token, { epoch: s2.epoch, ops: [o] });
    await app.close();
    expect(r1.results[0]).toEqual({ id: o.id, status: "applied" });
    // 不是重放：B 店自己也建了这个商品
    expect(r2.results[0]).toEqual({ id: o.id, status: "applied" });
    const n = await tdb.kysely.selectFrom("products").select("store_id").where("id", "=", o.payload.product_id as string).execute();
    expect(n.map((x) => x.store_id).sort()).toEqual([s1.storeId, s2.storeId].sort());
  });
});

describe("被拒的结果也可重放", () => {
  it("收银员的越权 op：每次都是 forbidden，库里一条 rejected 留档", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const cas = await pair(app, boss.token, "cashier", "小王");
    const o = upsertFull();
    const r1 = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [o] });
    const r2 = await syncOk(app, cas.token, { epoch: shop.epoch, ops: [o] });
    await app.close();
    expect(r1.results[0]).toEqual({ id: o.id, status: "rejected", code: "forbidden" });
    expect(r2.results[0]).toEqual({ id: o.id, status: "rejected", code: "forbidden", replayed: true });
    const rows = await tdb.kysely.selectFrom("ops").selectAll().where("store_id", "=", shop.storeId).where("id", "=", o.id).execute();
    expect(rows).toHaveLength(1);
    expect([rows[0]!.status, rows[0]!.reject_code]).toEqual(["rejected", "forbidden"]);
  });

  it("op 整体格式不对（id 不是 uuid、type 不认识）：整个请求 400，什么都不应用", async () => {
    const shop = await makeLoginShop(tdb);
    const app = makeApp(tdb);
    const boss = await login(app, shop.username);
    const good = upsertFull();
    for (const bad of [
      { ...good, id: "not-a-uuid" },
      { ...good, id: randomUUID(), type: "drop_table" },
      { ...good, id: randomUUID(), occurred_at: "昨天" },
      { ...good, id: randomUUID(), payload: "x" },
    ]) {
      const r = await sync(app, boss.token, { epoch: shop.epoch, ops: [good, bad as never] });
      expect([r.status, r.body.code]).toEqual([400, "invalid"]);
    }
    await app.close();
    const n = await tdb.kysely.selectFrom("ops").select("id").where("store_id", "=", shop.storeId).execute();
    expect(n).toHaveLength(0);
  });
});
