// CSV 的写法（注销导出包，S09）：RFC 4180，逗号分隔、CRLF 换行，含逗号 / 引号 / 换行的格子加双引号、引号写两遍。
// 文件开头带 UTF-8 BOM，Excel 直接双击打开中文不乱码。
// 金额：库里是整数分，导出成「元」的两位小数字符串，按整数运算拼出来，不经过浮点（123 分 → "1.23"，-5 分 → "-0.05"）。
// 公式注入：店主填的文本（商品名、单位、称呼）以 = + - @ 制表符 回车开头时前面加一个 '，Excel 不会把它当公式执行；数字列不加。

export const BOM = "﻿";

export function fenToYuan(fen: string | number | bigint | null | undefined): string {
  if (fen === null || fen === undefined) return "";
  const n = BigInt(fen);
  const neg = n < 0n;
  const a = neg ? -n : n;
  const s = `${a / 100n}.${String(a % 100n).padStart(2, "0")}`;
  return neg ? `-${s}` : s;
}

function quote(s: string): string {
  return /[",\r\n]/.test(s) ? `"${s.replaceAll('"', '""')}"` : s;
}

/** 店主填的文本：防公式注入后再按 CSV 转义 */
export function text(s: string | null | undefined): string {
  if (s === null || s === undefined) return "";
  return quote(/^[=+\-@\t\r]/.test(s) ? `'${s}` : s);
}

/** 服务器生成的值（id、数字、日期、固定的中文词）：只按 CSV 转义 */
export function plain(v: string | number | bigint | boolean | null | undefined): string {
  if (v === null || v === undefined) return "";
  if (typeof v === "boolean") return v ? "是" : "否";
  return quote(String(v));
}

export function row(cells: string[]): string {
  return `${cells.join(",")}\r\n`;
}

/** 解析（只给测试和核对脚本用）：按上面的写法反过来 */
export function parseCsv(s: string): string[][] {
  if (s.startsWith(BOM)) s = s.slice(1);
  const rows: string[][] = [];
  let cur: string[] = [];
  let cell = "";
  let i = 0;
  let inQ = false;
  while (i < s.length) {
    const ch = s[i]!;
    if (inQ) {
      if (ch === '"' && s[i + 1] === '"') {
        cell += '"';
        i += 2;
        continue;
      }
      if (ch === '"') {
        inQ = false;
        i++;
        continue;
      }
      cell += ch;
      i++;
      continue;
    }
    if (ch === '"') {
      inQ = true;
      i++;
    } else if (ch === ",") {
      cur.push(cell);
      cell = "";
      i++;
    } else if (ch === "\r" && s[i + 1] === "\n") {
      cur.push(cell);
      rows.push(cur);
      cur = [];
      cell = "";
      i += 2;
    } else {
      cell += ch;
      i++;
    }
  }
  if (cell !== "" || cur.length) {
    cur.push(cell);
    rows.push(cur);
  }
  return rows;
}
