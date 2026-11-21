// 条码库实测（S08 人工项一）：用快鸟的免费额度查一批真实条码，统计命中率、有图率（按类别分开算）。
// 用法：KUAINIAO_APPCODE=... node scripts/barcode-trial.ts [--record test/fixtures/kuainiao] 条码[:类别] ...
//   或  KUAINIAO_APPCODE=... node scripts/barcode-trial.ts --file barcodes.txt   （每行「条码 类别」，# 开头是注释）
// 类别随便写（例如 烟、本地、日用）。一次最多 30 个，免得误把付费额度用掉。不经过缓存、不写数据库。
// --record：把每个条码的原始响应存成 <目录>/recorded-<条码>.json，作为 kuainiao.ts 的真实夹具（先人工看一遍，没有敏感信息再提交）。
// AppCode 只从环境变量读，不打印。
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { parseArgs } from "node:util";
import { KuainiaoClient, SourceError, type BarcodeSource } from "../src/lookup/kuainiao.ts";

export const MAX_TRIAL = 30;

export interface TrialItem {
  barcode: string;
  category: string;
}
export interface TrialRow extends TrialItem {
  found: boolean;
  hasImage: boolean;
  name?: string;
  error?: string;
  raw?: unknown;
}

export function parseItems(args: string[], fileText?: string): TrialItem[] {
  const out: TrialItem[] = [];
  const lines = fileText !== undefined ? fileText.split(/\r?\n/) : args;
  for (const line of lines) {
    const s = line.trim();
    if (!s || s.startsWith("#")) continue;
    const [barcode, category = "未分类"] = s.split(/[\s:：]+/);
    if (!/^[0-9A-Za-z._-]{1,64}$/.test(barcode!)) throw new Error(`条码不合法：${barcode}`);
    out.push({ barcode: barcode!, category });
  }
  if (out.length === 0) throw new Error("没有条码");
  if (out.length > MAX_TRIAL) throw new Error(`一次最多 ${MAX_TRIAL} 个`);
  return out;
}

export async function runTrial(source: BarcodeSource, items: TrialItem[], timeoutMs = 5000): Promise<TrialRow[]> {
  const rows: TrialRow[] = [];
  for (const it of items) {
    try {
      const r = await source.lookup(it.barcode, AbortSignal.timeout(timeoutMs));
      rows.push(
        r.kind === "found"
          ? { ...it, found: true, hasImage: !!r.hit.imageUrl, name: r.hit.name, raw: r.raw }
          : { ...it, found: false, hasImage: false, raw: r.raw },
      );
    } catch (e) {
      rows.push({ ...it, found: false, hasImage: false, error: e instanceof SourceError ? `${e.kind}: ${e.message}` : "unexpected" });
    }
  }
  return rows;
}

const pct = (a: number, b: number) => (b === 0 ? "—" : `${a}/${b}（${Math.round((a / b) * 100)}%）`);

export function summarize(rows: TrialRow[]): string {
  const lines = ["| 条码 | 类别 | 查到 | 有图 | 名称 / 错误 |", "|---|---|---|---|---|"];
  for (const r of rows) lines.push(`| ${r.barcode} | ${r.category} | ${r.found ? "是" : "否"} | ${r.hasImage ? "是" : "否"} | ${r.error ?? r.name ?? ""} |`);
  lines.push("", "| 类别 | 命中率 | 有图率（占全部） |", "|---|---|---|");
  const cats = [...new Set(rows.map((r) => r.category))];
  for (const c of [...cats, "合计"]) {
    const rs = c === "合计" ? rows : rows.filter((r) => r.category === c);
    lines.push(`| ${c} | ${pct(rs.filter((r) => r.found).length, rs.length)} | ${pct(rs.filter((r) => r.hasImage).length, rs.length)} |`);
  }
  const all = rows.length;
  const img = rows.filter((r) => r.hasImage).length;
  lines.push("", all > 0 && img / all < 0.5 ? "有图率 < 50%：按 S08 验收，商品图降级到第二版。" : "有图率 ≥ 50%。");
  return lines.join("\n");
}

if (import.meta.main) {
  const { values, positionals } = parseArgs({ allowPositionals: true, options: { file: { type: "string" }, record: { type: "string" } } });
  const appCode = process.env.KUAINIAO_APPCODE;
  if (!appCode) {
    console.error("缺少 KUAINIAO_APPCODE（只从环境变量读）");
    process.exit(2);
  }
  const items = parseItems(positionals, values.file ? readFileSync(values.file, "utf8") : undefined);
  const client = new KuainiaoClient({ appCode, endpoint: process.env.KUAINIAO_ENDPOINT || "https://icode.market.alicloudapi.com/getBarcode" });
  const rows = await runTrial(client, items);
  if (values.record) {
    mkdirSync(values.record, { recursive: true });
    for (const r of rows) if (r.raw !== undefined) writeFileSync(path.join(values.record, `recorded-${r.barcode}.json`), JSON.stringify(r.raw, null, 2) + "\n");
  }
  console.log(summarize(rows));
}
