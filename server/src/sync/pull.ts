// 拉取（§4.2）：两条独立的流，各有游标。
// - catalog：商品、条码、墓碑；ledger：流水、批次头、保质期批次。
// - 每条流按 rev 升序，取 `rev > cursor` 的前 pageSize 行（几张表合起来算）。本店 rev 不重复（lock.ts），所以分页不会切在同一个号中间。
// - 这一页装满了：游标 = 本页最后一行的 rev，has_more=true；没装满：游标 = 同一快照里本店的 stores.rev（被裁掉的行、
//   另一条流的行占的号一并跳过），has_more=false。游标只进不退。
// - 整个拉取在一个 REPEATABLE READ 只读事务里：所有查询看到的是同一个快照，游标不会越过还没看到的行。
//   写入都在店铺锁里、提交后才放锁，所以快照里看得到的号是一段从 1 开始没有缺口的前缀。
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { shanghaiDay } from "../auth/guard.ts";
import { barcodeOut, batchOut, entryOut, int, LEDGER_DAYS, lotOut, productOut, removedOut, type Scope } from "./projection.ts";

/** 每页 500 行（§4.2） */
export const DEFAULT_PAGE_SIZE = 500;

export interface Cursors {
  catalog: number;
  ledger: number;
}

export interface PullInput {
  storeId: string;
  deviceId: string;
  scope: Scope;
  cursors: Cursors;
  pageSize: number;
  now: Date;
}

export type Changes = {
  products: unknown[];
  barcodes: unknown[];
  removed: unknown[];
  entries: unknown[];
  batches: unknown[];
  lots: unknown[];
};

export interface PullOutput {
  changes: Changes;
  cursors: Cursors;
  has_more: { catalog: boolean; ledger: boolean };
  total_products: number;
}

export const emptyChanges = (): Changes => ({ products: [], barcodes: [], removed: [], entries: [], batches: [], lots: [] });

/** 上海时区「含今天在内的最近 days 天」的起点 */
export function ledgerWindowStart(now: Date, days: number): Date {
  const today = shanghaiDay(now); // YYYY-MM-DD
  const start = new Date(`${today}T00:00:00+08:00`);
  return new Date(start.getTime() - (days - 1) * 86_400_000);
}

interface Tagged<K extends string> {
  key: K;
  rev: number;
  row: unknown;
}

/** 几张表各取 pageSize+1 行，按 rev 合起来取前 pageSize 行 */
function page<K extends string>(parts: Array<Tagged<K>[]>, pageSize: number, cursor: number, storeRev: number) {
  const all = parts.flat().sort((a, b) => a.rev - b.rev);
  const rows = all.slice(0, pageSize);
  const hasMore = all.length > pageSize;
  const next = hasMore ? rows[rows.length - 1]!.rev : Math.max(cursor, storeRev);
  return { rows, hasMore, next };
}

export async function pullChanges(db: Kysely<Database>, input: PullInput): Promise<PullOutput> {
  const { storeId, scope, cursors, pageSize, now } = input;
  const limit = pageSize + 1;
  return db
    .transaction()
    .setIsolationLevel("repeatable read")
    .setAccessMode("read only")
    .execute(async (trx) => {
      const store = await trx.selectFrom("stores").select("rev").where("id", "=", storeId).executeTakeFirstOrThrow();
      const storeRev = int(store.rev);

      // ── catalog ──
      const c = cursors.catalog;
      const products = await trx
        .selectFrom("products")
        .selectAll()
        .where("store_id", "=", storeId)
        .where("rev", ">", String(c))
        .orderBy("rev")
        .limit(limit)
        .execute();
      const barcodes = await trx
        .selectFrom("product_barcodes")
        .selectAll()
        .where("store_id", "=", storeId)
        .where("deleted_at", "is", null)
        .where("rev", ">", String(c))
        .orderBy("rev")
        .limit(limit)
        .execute();
      // 条码现在又挂着（解除后重新挂上）就不再下发它的旧墓碑：那一行会以更大的 rev 下发，手机先处理哪个数组都不会误删
      const removed = await trx
        .selectFrom("removed as r")
        .selectAll("r")
        .where("r.store_id", "=", storeId)
        .where("r.rev", ">", String(c))
        .where((eb) =>
          eb.or([
            eb("r.kind", "<>", "barcode"),
            eb.not(
              eb.exists(
                eb
                  .selectFrom("product_barcodes as b")
                  .select(sql`1`.as("one"))
                  .whereRef("b.store_id", "=", "r.store_id")
                  .whereRef("b.barcode", "=", "r.row_id")
                  .where("b.deleted_at", "is", null),
              ),
            ),
          ]),
        )
        .orderBy("r.rev")
        .limit(limit)
        .execute();
      const cat = page(
        [
          products.map((r) => ({ key: "products" as const, rev: int(r.rev), row: productOut(r, scope) })),
          barcodes.map((r) => ({ key: "barcodes" as const, rev: int(r.rev), row: barcodeOut(r) })),
          removed.map((r) => ({ key: "removed" as const, rev: int(r.rev), row: removedOut(r) })),
        ],
        pageSize,
        c,
        storeRev,
      );

      // ── ledger ──
      const l = cursors.ledger;
      const since = ledgerWindowStart(now, LEDGER_DAYS[scope]);
      let entriesQ = trx
        .selectFrom("entries as e")
        .leftJoin("devices as d", (j) => j.onRef("d.store_id", "=", "e.store_id").onRef("d.id", "=", "e.device_id"))
        .selectAll("e")
        .select("d.label as device_label")
        .where("e.store_id", "=", storeId)
        .where("e.rev", ">", String(l))
        .where("e.occurred_at", ">=", since);
      let batchesQ = trx
        .selectFrom("sale_batches")
        .selectAll()
        .where("store_id", "=", storeId)
        .where("rev", ">", String(l))
        .where("occurred_at", ">=", since);
      if (scope === "cashier_projection") {
        // 收银员：只有本机的卖出
        entriesQ = entriesQ.where("e.type", "=", "sale").where("e.device_id", "=", input.deviceId);
        batchesQ = batchesQ.where("device_id", "=", input.deviceId);
      }
      const entries = await entriesQ.orderBy("e.rev").limit(limit).execute();
      const batches = await batchesQ.orderBy("rev").limit(limit).execute();
      // 收银员不查保质期批次
      const lots =
        scope === "cashier_projection"
          ? []
          : await trx
              .selectFrom("stock_lots")
              .selectAll()
              .where("store_id", "=", storeId)
              .where("rev", ">", String(l))
              .orderBy("rev")
              .limit(limit)
              .execute();
      const led = page(
        [
          entries.map((r) => ({ key: "entries" as const, rev: int(r.rev), row: entryOut(r, scope) })),
          batches.map((r) => ({ key: "batches" as const, rev: int(r.rev), row: batchOut(r) })),
          lots.map((r) => ({ key: "lots" as const, rev: int(r.rev), row: lotOut(r) })),
        ],
        pageSize,
        l,
        storeRev,
      );

      const changes = emptyChanges();
      for (const t of [...cat.rows, ...led.rows]) changes[t.key].push(t.row);
      const total = await trx
        .selectFrom("products")
        .select((eb) => eb.fn.countAll<string>().as("n"))
        .where("store_id", "=", storeId)
        .executeTakeFirstOrThrow();
      return {
        changes,
        cursors: { catalog: cat.next, ledger: led.next },
        has_more: { catalog: cat.hasMore, ledger: led.hasMore },
        total_products: int(total.n),
      };
    });
}
