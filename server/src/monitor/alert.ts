// 告警消息（S10c，§9.5）：所有告警发给 Chitu，由 Chitu 转告，不直接发给黄总。
// 这个文件和 alerter.ts、sinks.ts 只用 Node 自带模块：本机探测脚本（scripts/probe.ts）不装依赖也能直接 import。
//
// 告警内容不含密码、令牌、开通码（S10c 验收）。做法是白名单，不是黑名单：
//   - details 只留 DETAIL_KEYS 里的键，别的键（password、token、code、err、headers……）整个丢掉；
//   - 留下的值一律转成短字符串，再把看着像凭据的长串（≥ 24 位的十六进制 / base64 片段）换成「[已隐去]」。
// 标题是代码里写死的固定文字，或者日志里的 msg（也是代码里写死的）；同样过一遍 scrub。

export type Severity = "warning" | "critical";

export interface Alert {
  /** 去重键：同一个键在静默期内只发一次；条件类告警按键记「正在告警」 */
  key: string;
  title: string;
  severity: Severity;
  details?: Record<string, unknown>;
}

export type AlertKind = "fire" | "repeat" | "resolved" | "event";

/** 真正发出去的一条（发给 Chitu 的通道、本机 outbox 都是这个形状） */
export interface AlertMessage {
  id: string;
  at: string;
  kind: AlertKind;
  key: string;
  severity: Severity;
  title: string;
  details: Record<string, string>;
  /** 静默期里被压下去的同键事件数（只在 kind=event 时可能有） */
  suppressed?: number;
  text: string;
}

/** 允许出现在告警里的字段。加字段之前想一想：它会不会带出口令、令牌、开通码 */
export const DETAIL_KEYS = new Set([
  "alert",
  "store_id",
  "object_key",
  "attempts",
  "pending",
  "due",
  "count",
  "threshold",
  "value",
  "used",
  "limit",
  "since",
  "last_success",
  "age_minutes",
  "max_minutes",
  "consecutive_failures",
  "stage",
  "reason",
  "lines",
  "line",
  "hours_left",
  "not_after",
  "serial",
  "status",
  "failures",
  "url",
  "path",
  "used_percent",
  "bytes",
  "growth_bytes",
  "locked_until",
  "backup_id",
  "why",
  "kind",
  "task",
  "source",
]);

const MAX_VALUE = 300;
// 看着像凭据的串：连续 24 位以上的十六进制 / base64 / base64url 字符（UUID 有连字符，每段都短于 24，不受影响）
const SECRETISH = /[A-Za-z0-9+/_=]{24,}/g;
// 「APPCODE xxx」「Bearer xxx」这种带前缀的，不论长短都隐去
const AUTH_PREFIX = /\b(appcode|bearer|basic|token|password|passwd|secret)\b\s*[:=]?\s*\S+/gi;

export function scrub(s: string): string {
  return s.replace(AUTH_PREFIX, "$1 [已隐去]").replace(SECRETISH, "[已隐去]").slice(0, MAX_VALUE);
}

export function sanitizeDetails(d: Record<string, unknown> | undefined): Record<string, string> {
  const out: Record<string, string> = {};
  if (!d) return out;
  for (const [k, v] of Object.entries(d)) {
    if (!DETAIL_KEYS.has(k) || v === undefined || v === null) continue;
    const s = typeof v === "string" ? v : typeof v === "number" || typeof v === "boolean" ? String(v) : v instanceof Date ? v.toISOString() : null;
    if (s === null) continue; // 对象、数组不展开（可能藏着别的字段）
    out[k] = scrub(s);
  }
  return out;
}

const KIND_LABEL: Record<AlertKind, string> = { fire: "告警", repeat: "仍未恢复", resolved: "已恢复", event: "告警" };

export function formatText(m: Omit<AlertMessage, "text" | "id">): string {
  const head = `[元辉账本][${KIND_LABEL[m.kind]}${m.severity === "critical" && m.kind !== "resolved" ? "·严重" : ""}] ${m.title}`;
  const lines = [head, `键：${m.key}`, `时间：${m.at}`];
  for (const [k, v] of Object.entries(m.details)) lines.push(`${k}：${v}`);
  if (m.suppressed) lines.push(`静默期内另有 ${m.suppressed} 次同类事件`);
  return lines.join("\n");
}

let seq = 0;
export function buildMessage(kind: AlertKind, a: Alert, now: Date, suppressed?: number): AlertMessage {
  const base = {
    at: now.toISOString(),
    kind,
    key: scrub(a.key),
    severity: a.severity,
    title: scrub(a.title),
    details: sanitizeDetails(a.details),
    ...(suppressed ? { suppressed } : {}),
  };
  seq = (seq + 1) % 1_000_000;
  // id 按字典序递增（毫秒时间戳补零 + 进程内序号），本机探测按它记读到哪儿了
  const id = `${String(now.getTime()).padStart(15, "0")}-${String(seq).padStart(6, "0")}`;
  return { id, ...base, text: formatText(base) };
}
