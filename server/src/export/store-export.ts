// 一家店的导出包（S09：注销申请时生成，交给黄总；也给 scripts/export-store.ts 停用前手动导出用）。
//
// 内容（CSV 压缩包，计划 §8 S09「商品、流水、月报」，另加条码和一页说明）：
//   说明.txt   店名、导出时间、各文件的口径
//   商品.csv   每个商品一行（含已停用的）：卖价、库存、货值、最近进价……
//   条码.csv   每个条码一行（含已解绑的，标出解绑时间）
//   流水.csv   全部流水（含冲销行、补记成本行），按记账顺序
//   月报.csv   从第一笔流水那个月到本月，每月一行，数字和 App 里「本月的账」同一套算法（reportMonthIn）
// 只导这一家店：每条查询都按 store_id 过滤。整份导出在一个可重复读的只读事务里读，流水和月报看到同一份快照，合计一定对得上。
// 大数据量：每张表按主键 / seq 分页（keyset，每页 pageSize 行），边读边压缩边写出（ZipWriter），内存里只有一页。
import type { Writable } from "node:stream";
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { readSnapshot, monthOf, nextMonth, type Q } from "../reports/common.ts";
import { reportMonthIn } from "../reports/month.ts";
import { BOM, fenToYuan, plain, row, text } from "./csv.ts";
import { ZipWriter } from "./zip.ts";

export const EXPORT_PAGE_SIZE = 1000;

export const EXPORT_FILES = ["说明.txt", "商品.csv", "条码.csv", "流水.csv", "月报.csv"] as const;

const ENTRY_TYPE: Record<string, string> = {
  sale: "卖出",
  stock_in: "进货",
  opening: "期初",
  count: "盘点",
  cost_adjust: "成本调整",
  cost_fix: "补记成本",
  expire_loss: "过期扔掉",
  supplier_return: "退给供货商",
};

export const PRODUCT_HEADER = ["商品id", "名称", "基本单位", "卖价(元)", "库存", "货值(元)", "最近进价(元)", "进价已知", "库存已知", "待确认", "管保质期", "低库存提醒", "已停用时间"];
export const BARCODE_HEADER = ["条码", "商品id", "商品名称", "每件数量", "单位", "整件卖价(元)", "解绑时间"];
export const ENTRY_HEADER = [
  "序号", "流水id", "时间(北京)", "类型", "冲销", "冲销的流水id", "商品id", "商品名称", "条码", "单位", "每件数量", "件数", "数量变化",
  "标价金额(元)", "实收金额(元)", "成本(元)", "货值变化(元)", "进价未知", "到期日", "卖出单id", "记账手机", "已撤销时间",
];
export const MONTH_HEADER = [
  "月份", "卖了(元)", "赚了(元)", "优惠(元)", "过期损耗(元)", "月初货值(元)", "进货(元)", "卖出(元)", "盘点(元)", "过期(元)", "退给供货商(元)", "期初和调整(元)",
  "月末货值(元)", "进价未知的商品数", "进价未知的损耗笔数",
];

const SH_TIME = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
});
/**
 * 北京时间 YYYY-MM-DD HH:MM:SS，按 Asia/Shanghai 的历史时区（1986–1991 年有夏令时），不是固定 +8（PR #20 Codex 7）。
 * 流水的发生时间不用这个，而是在 SQL 里由 Postgres 换算（OCCURRED_SH），和月报归日归月是同一份时区数据。
 */
function shTime(d: Date | null): string {
  if (!d) return "";
  const p = Object.fromEntries(SH_TIME.formatToParts(d).map((x) => [x.type, x.value]));
  return `${String(p.year).padStart(4, "0")}-${p.month}-${p.day} ${p.hour}:${p.minute}:${p.second}`;
}

/** 流水发生时间的北京时间写法：和 reports/common.ts 的 DAY_OF_SQL 一样用 `AT TIME ZONE 'Asia/Shanghai'`，按它归月的结果和月报恒一致 */
const OCCURRED_SH = sql<string>`to_char(e.occurred_at AT TIME ZONE 'Asia/Shanghai', 'YYYY-MM-DD HH24:MI:SS')`;

export interface ExportSummary {
  products: number;
  barcodes: number;
  entries: number;
  months: string[];
}

/**
 * 把一家店的导出包写到 out（ZIP）。不关闭 out。店不存在抛错。
 * pageSize 只给测试调小（测分页）。
 */
export async function writeStoreExport(db: Kysely<Database>, storeId: string, out: Writable, now: Date, o: { pageSize?: number } = {}): Promise<ExportSummary> {
  const pageSize = o.pageSize ?? EXPORT_PAGE_SIZE;
  return readSnapshot(db, async (trx) => {
    const store = await trx.selectFrom("stores").select(["id", "name", "is_demo"]).where("id", "=", storeId).executeTakeFirst();
    if (!store) throw new Error(`店 ${storeId} 不存在`);
    const zip = new ZipWriter(out, now);
    const summary: ExportSummary = { products: 0, barcodes: 0, entries: 0, months: [] };
    const months = await monthsOf(trx, storeId, now);
    summary.months = months;

    await zip.addFile("说明.txt", [
      BOM,
      [
        `店名：${store.name}`,
        `店 id：${store.id}`,
        `导出时间（北京时间）：${shTime(now)}`,
        "",
        "文件：",
        "  商品.csv  每个商品一行（含已停用的）。库存按基本单位计；货值 = 按移动加权平均算的库存成本。",
        "  条码.csv  每个条码一行（含已解绑的）。整件码的「每件数量」是一件里有几个基本单位。",
        "  流水.csv  全部流水，按记账顺序（序号）。撤销不删原行，而是多一行「冲销」行，金额和数量取反。",
        "  月报.csv  每月一行，和 App 里「本月的账」同一套算法：卖了 = 当月卖出行实收之和（含冲销行）。",
        "",
        "金额单位是元（两位小数）；时间是北京时间。以 ' 开头的文字是为了防止 Excel 把它当公式，' 本身不是内容。",
        "",
      ].join("\r\n"),
    ]);

    await zip.addFile("商品.csv", (async function* () {
      yield BOM + row(PRODUCT_HEADER);
      let after: string | null = null;
      for (;;) {
        let q = trx
          .selectFrom("products")
          .select(["id", "name", "base_unit", "price_fen", "stock_qty", "stock_value_fen", "last_cost_fen", "cost_known", "stock_known", "needs_review", "track_expiry", "low_at", "archived_at"])
          .where("store_id", "=", storeId);
        if (after !== null) q = q.where("id", ">", after);
        const page = await q.orderBy("id").limit(pageSize).execute();
        let chunk = "";
        for (const p of page) {
          chunk += row([
            plain(p.id), text(p.name), text(p.base_unit), fenToYuan(p.price_fen), plain(p.stock_qty), fenToYuan(p.stock_value_fen),
            fenToYuan(p.last_cost_fen), plain(p.cost_known), plain(p.stock_known), plain(p.needs_review), plain(p.track_expiry), plain(p.low_at), plain(shTime(p.archived_at)),
          ]);
        }
        summary.products += page.length;
        if (chunk) yield chunk;
        if (page.length < pageSize) return;
        after = page[page.length - 1]!.id;
      }
    })());

    await zip.addFile("条码.csv", (async function* () {
      yield BOM + row(BARCODE_HEADER);
      let after: string | null = null;
      for (;;) {
        let q = trx
          .selectFrom("product_barcodes as b")
          .innerJoin("products as p", (j) => j.onRef("p.store_id", "=", "b.store_id").onRef("p.id", "=", "b.product_id"))
          .select(["b.barcode", "b.product_id", "p.name", "b.pack_qty", "b.unit_name", "b.pack_price_fen", "b.deleted_at"])
          .where("b.store_id", "=", storeId);
        if (after !== null) q = q.where("b.barcode", ">", after);
        const page = await q.orderBy("b.barcode").limit(pageSize).execute();
        let chunk = "";
        for (const b of page) {
          chunk += row([text(b.barcode), plain(b.product_id), text(b.name), plain(b.pack_qty), text(b.unit_name), fenToYuan(b.pack_price_fen), plain(shTime(b.deleted_at))]);
        }
        summary.barcodes += page.length;
        if (chunk) yield chunk;
        if (page.length < pageSize) return;
        after = page[page.length - 1]!.barcode;
      }
    })());

    await zip.addFile("流水.csv", (async function* () {
      yield BOM + row(ENTRY_HEADER);
      let after = "0";
      for (;;) {
        const page = await trx
          .selectFrom("entries as e")
          .leftJoin("devices as d", (j) => j.onRef("d.store_id", "=", "e.store_id").onRef("d.id", "=", "e.device_id"))
          .select([
            "e.seq", "e.id", "e.occurred_at", "e.type", "e.reverses_entry_id", "e.product_id", "e.name_snapshot", "e.barcode", "e.unit_name", "e.pack_qty", "e.pack_count",
            "e.qty_delta", "e.list_amount_fen", "e.amount_fen", "e.cogs_fen", "e.value_delta_fen", "e.cost_missing", "e.expiry_date", "e.batch_id", "d.label", "e.voided_at",
            OCCURRED_SH.as("occurred_sh"),
          ])
          .where("e.store_id", "=", storeId)
          .where("e.seq", ">", after)
          .orderBy("e.seq")
          .limit(pageSize)
          .execute();
        let chunk = "";
        for (const e of page) {
          chunk += row([
            plain(e.seq), plain(e.id), plain(e.occurred_sh), plain(ENTRY_TYPE[e.type] ?? e.type), plain(e.reverses_entry_id !== null), plain(e.reverses_entry_id),
            plain(e.product_id), text(e.name_snapshot), text(e.barcode), text(e.unit_name), plain(e.pack_qty), plain(e.pack_count), plain(e.qty_delta),
            fenToYuan(e.list_amount_fen), fenToYuan(e.amount_fen), fenToYuan(e.cogs_fen), fenToYuan(e.value_delta_fen), plain(e.cost_missing),
            plain(e.expiry_date as unknown as string | null), plain(e.batch_id), text(e.label), plain(shTime(e.voided_at)),
          ]);
        }
        summary.entries += page.length;
        if (chunk) yield chunk;
        if (page.length < pageSize) return;
        after = String(page[page.length - 1]!.seq);
      }
    })());

    await zip.addFile("月报.csv", (async function* () {
      yield BOM + row(MONTH_HEADER);
      for (const m of months) {
        const r = await reportMonthIn(trx, storeId, m, now);
        const recon = (k: string) => r.reconciliation.rows.find((x) => x.key === k)?.amount_fen ?? 0;
        yield row([
          plain(m), fenToYuan(r.sold_fen), fenToYuan(r.profit_fen), fenToYuan(r.discount_fen), fenToYuan(r.expire_loss_fen), fenToYuan(r.reconciliation.stock_value_start_fen),
          fenToYuan(recon("stock_in")), fenToYuan(recon("sale")), fenToYuan(recon("count")), fenToYuan(recon("expire_loss")), fenToYuan(recon("supplier_return")),
          fenToYuan(recon("opening_and_adjust")), fenToYuan(r.stock_value_end_fen), plain(r.cost_missing_count), plain(r.loss_cost_missing_count),
        ]);
      }
    })());

    await zip.finish();
    return summary;
  });
}

/** 第一笔流水所在的月到「本月」与最后一笔流水所在的月中较晚的一个；没有流水就只有本月 */
async function monthsOf(trx: Q, storeId: string, now: Date): Promise<string[]> {
  const r = await sql<{ lo: Date | null; hi: Date | null }>`SELECT MIN(occurred_at) AS lo, MAX(occurred_at) AS hi FROM entries WHERE store_id = ${storeId}`.execute(trx);
  const cur = monthOf(now);
  const lo = r.rows[0]?.lo ? monthOf(new Date(r.rows[0].lo)) : cur;
  const hiE = r.rows[0]?.hi ? monthOf(new Date(r.rows[0].hi)) : cur;
  const hi = hiE > cur ? hiE : cur;
  const out: string[] = [];
  for (let m = lo; m <= hi; m = nextMonth(m)) out.push(m);
  return out;
}
