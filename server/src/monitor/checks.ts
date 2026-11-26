// 监控里的纯判断（阈值都在这里，按 §9.5、§9.4、§14 S08-3、T3、T26 定）。不连库、不读文件，测试直接喂数。
import { closeSync, openSync, readSync, statSync } from "node:fs";

export const THRESHOLDS = {
  /** §9.4：营业时间内心跳超过 2 小时没更新；营业时间外按迁移前门禁的 6 小时（§14 S10b-3：02:30 → 8:00 最长 5.5 小时） */
  heartbeatBusinessMs: 2 * 3600_000,
  heartbeatOffHoursMs: 6 * 3600_000,
  /** 备份连续失败几次升级成严重（§14 T26） */
  backupConsecutiveFailures: 2,
  /** §9.5：元辉店 8:00–21:00 超过 3 小时没有设备同步成功 */
  noSyncMs: 3 * 3600_000,
  noSyncFromHour: 8,
  noSyncToHour: 21,
  /** §9.5：5xx 每小时超过 20 次 */
  errorsPerHour: 20,
  /** §14 S08-3 条件二：单店当天调快鸟到 700 次 */
  kuainiaoStoreDaily: 700,
  /** §9.5：被退出的手机暂存的账超过 24 小时没人处理 */
  heldMs: 24 * 3600_000,
  /** §14 T3：ops 表体积、24 小时增长、磁盘用量（磁盘和云监控的 80% 一致） */
  opsTableBytes: 512 * 1024 * 1024,
  opsGrowthBytesPerDay: 64 * 1024 * 1024,
  diskUsedPercent: 80,
  /** §9.5：IP 证书剩余有效期 < 48 小时 */
  certHoursLeft: 48,
  /** 域名站点（api.yuanhuishop.cn、yuanhuishop.cn）的证书：Let's Encrypt 90 天证书，Caddy 剩 1/3（约 30 天）时续；
   *  剩不到 14 天、且不到有效期 1/4 还没换就告警（取两者里小的：以后 LE 证书缩短到 45 天时，Caddy 约剩 15 天续，阈值跟着降到约 11 天，不误报） */
  domainCertDaysLeft: 14,
  /** §9.5：本机探 /healthz 连续 2 次失败 */
  healthzFailures: 2,
} as const;

/** 上海时间的小时（上海没有夏令时，固定 +8） */
export function shanghaiHour(now: Date): number {
  return (now.getUTCHours() + 8) % 24;
}

/** 上海时间当天 hh:00 的时刻 */
export function shanghaiAt(now: Date, hour: number): Date {
  const ms = now.getTime() + 8 * 3600_000;
  const day = Math.floor(ms / 86_400_000) * 86_400_000;
  return new Date(day + hour * 3600_000 - 8 * 3600_000);
}

/** Prometheus 文本格式（backup.sh 写的 metrics.prom）：「名字 数值」，# 开头是注释 */
export function parseMetrics(text: string): Record<string, number> {
  const out: Record<string, number> = {};
  for (const line of text.split("\n")) {
    const m = /^([a-zA-Z_:][a-zA-Z0-9_:]*)\s+(-?[0-9.eE+-]+)\s*$/.exec(line.trim());
    if (m && Number.isFinite(Number(m[2]))) out[m[1]!] = Number(m[2]);
  }
  return out;
}

export interface Verdict {
  active: boolean;
  details: Record<string, unknown>;
}

/** 备份心跳：last_success 是 Unix 秒；null = 一次成功都没有 */
export function heartbeatVerdict(lastSuccessS: number | null, now: Date): Verdict {
  const h = shanghaiHour(now);
  const business = h >= 8 && h <= 22;
  const max = business ? THRESHOLDS.heartbeatBusinessMs : THRESHOLDS.heartbeatOffHoursMs;
  if (!lastSuccessS) return { active: true, details: { reason: "没有任何成功的备份记录", max_minutes: max / 60_000 } };
  const last = lastSuccessS * 1000;
  const age = now.getTime() - last;
  // 营业时间的 2 小时只从当天 8:00 起算（同 noSyncVerdict）：8:00 那一刻上一份还是夜里 02:30 的，
  // 直接按 2 小时比会每天早上误报一条「严重」再跟一条「已恢复」（PR #25 Fable 建议 1）。6 小时的上限任何时候都管。
  const sinceOpen = now.getTime() - Math.max(last, shanghaiAt(now, 8).getTime());
  const active = age > THRESHOLDS.heartbeatOffHoursMs || (business && sinceOpen > THRESHOLDS.heartbeatBusinessMs);
  return {
    active,
    details: { last_success: new Date(last).toISOString(), age_minutes: Math.floor(age / 60_000), max_minutes: max / 60_000 },
  };
}

/** 营业时间内没有同步：只数 8:00 以后的时间（7 点同步过、11 点前不算超时） */
export function noSyncVerdict(lastOk: Date, now: Date): Verdict {
  const h = shanghaiHour(now);
  const inHours = h >= THRESHOLDS.noSyncFromHour && h < THRESHOLDS.noSyncToHour;
  const from = Math.max(lastOk.getTime(), shanghaiAt(now, THRESHOLDS.noSyncFromHour).getTime());
  const gap = now.getTime() - from;
  return { active: inHours && gap > THRESHOLDS.noSyncMs, details: { since: lastOk.toISOString(), age_minutes: Math.floor((now.getTime() - lastOk.getTime()) / 60_000) } };
}

/** 从 offset 起读到文件尾的完整行。文件变小了（被截断、换了文件）从头读 */
export function readNewLines(path: string, offset: number, maxBytes = 64 * 1024): { lines: string[]; offset: number } {
  let size: number;
  try {
    size = statSync(path).size;
  } catch {
    return { lines: [], offset: 0 };
  }
  let start = size < offset ? 0 : offset;
  if (size === start) return { lines: [], offset: start };
  if (size - start > maxBytes) start = size - maxBytes; // 一下子多出很多：只看最后一段
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(size - start);
    readSync(fd, buf, 0, buf.length, start);
    const text = buf.toString("utf8");
    const end = text.lastIndexOf("\n");
    if (end < 0) return { lines: [], offset: start }; // 还没写完一整行
    return { lines: text.slice(0, end).split("\n").filter((l) => l.trim()), offset: start + Buffer.byteLength(text.slice(0, end + 1)) };
  } finally {
    closeSync(fd);
  }
}

export interface CertInfo {
  notBefore: Date;
  notAfter: Date;
  serial: string;
  authorized: boolean;
}

/** IP 证书：剩余 < 48 小时告警；不受信任（链不对、过期）也告警 */
export function certVerdict(c: CertInfo, now: Date): Verdict & { hoursLeft: number } {
  const hoursLeft = Math.floor((c.notAfter.getTime() - now.getTime()) / 3600_000);
  return {
    active: hoursLeft < THRESHOLDS.certHoursLeft || !c.authorized,
    hoursLeft,
    details: { hours_left: hoursLeft, not_after: c.notAfter.toISOString(), serial: c.serial.slice(-16), ...(c.authorized ? {} : { reason: "证书链不受信任" }) },
  };
}

/** 域名证书：剩余不到 min(14 天, 有效期 1/4)，或链不受信任 / 域名对不上（authorized 已含域名校验） */
export function domainCertVerdict(c: CertInfo, now: Date): Verdict & { daysLeft: number } {
  const leftMs = c.notAfter.getTime() - now.getTime();
  const daysLeft = Math.floor(leftMs / 86_400_000);
  const life = c.notAfter.getTime() - c.notBefore.getTime();
  const limitMs = Math.min(THRESHOLDS.domainCertDaysLeft * 86_400_000, life > 0 ? life / 4 : Infinity);
  return {
    active: leftMs < limitMs || !c.authorized,
    daysLeft,
    details: { days_left: daysLeft, not_after: c.notAfter.toISOString(), serial: c.serial.slice(-16), ...(c.authorized ? {} : { reason: "证书链不受信任或域名对不上" }) },
  };
}

/** 续期过了该续的点还没续（剩余不到总有效期的 1/4，Caddy 默认剩 1/3 时续）——只留记录，48 小时告警兜底 */
export function renewalOverdue(c: CertInfo, now: Date): boolean {
  const life = c.notAfter.getTime() - c.notBefore.getTime();
  return life > 0 && c.notAfter.getTime() - now.getTime() < life / 4;
}

/**
 * ops 表体积样本（T3 的 24 小时增长）：每 10 分钟最多记一条，留 25 小时（约 150 条）。返回约 24 小时前的那条（没有就 undefined）。
 * 以前每分钟记一条、只留 200 条，永远凑不到 24 小时前的样本，增长告警不会响（PR #25 Codex 建议）。
 */
export function recordOpsSample(samples: Array<[number, number]>, now: Date, bytes: number): [number, number] | undefined {
  const t = now.getTime();
  const lastT = samples.length ? samples[samples.length - 1]![0] : -Infinity;
  if (t - lastT >= 10 * 60_000) samples.push([t, bytes]);
  while (samples.length > 1 && samples[0]![0] < t - 25 * 3600_000) samples.shift();
  if (samples.length > 200) samples.splice(0, samples.length - 200);
  // 24 小时前（容差 1 分钟）以前的最近一条；只差一点点（≥ 23 小时）也算，免得刚好错过
  for (let i = samples.length - 1; i >= 0; i--) if (samples[i]![0] <= t - 24 * 3600_000 + 60_000) return samples[i];
  return samples[0] && samples[0][0] <= t - 23 * 3600_000 ? samples[0] : undefined;
}
