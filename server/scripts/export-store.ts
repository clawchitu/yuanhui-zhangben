// 手动导出一家店的数据（CSV 压缩包，格式同注销导出包，见 src/export/store-export.ts）。停用账号前先导一份给黄总（§12、§9.4）。
// 用法：DATABASE_URL=... node scripts/export-store.ts --store <店 id> --out <文件.zip>
// 只导这一家店；输出文件已存在就拒绝（不覆盖）。成功后输出一行 JSON：{"out": "...", "products": N, "barcodes": N, "entries": N, "months": [...]}
// 这是运维脚本（要数据库连接串），App 里任何角色都调不到；收银员更不可能。
import { createWriteStream } from "node:fs";
import { once } from "node:events";
import { rm } from "node:fs/promises";
import { parseArgs } from "node:util";
import type { Kysely } from "kysely";
import { createDb, type Database } from "../src/db.ts";
import { writeStoreExport, type ExportSummary } from "../src/export/store-export.ts";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function exportStoreToFile(db: Kysely<Database>, storeId: string, file: string, now = new Date()): Promise<ExportSummary> {
  if (!UUID_RE.test(storeId)) throw new Error("店 id 格式不对");
  const out = createWriteStream(file, { flags: "wx", mode: 0o600 });
  await once(out, "open");
  let ok = false;
  try {
    const s = await writeStoreExport(db, storeId.toLowerCase(), out, now);
    ok = true;
    return s;
  } finally {
    const closed = once(out, "close");
    out.end();
    await closed;
    if (!ok) await rm(file, { force: true });
  }
}

if (import.meta.main) {
  const { values } = parseArgs({ options: { store: { type: "string" }, out: { type: "string" } } });
  const url = process.env.DATABASE_URL;
  if (!url || !values.store || !values.out) {
    console.error("用法：DATABASE_URL=... node scripts/export-store.ts --store <店 id> --out <文件.zip>");
    process.exit(2);
  }
  const db = createDb({ connectionString: url, max: 1 });
  try {
    const s = await exportStoreToFile(db.kysely, values.store, values.out);
    console.log(JSON.stringify({ out: values.out, ...s }));
  } catch (e) {
    console.error(`导出失败：${(e as Error).message}`);
    process.exitCode = 1;
  } finally {
    await db.close();
  }
}
