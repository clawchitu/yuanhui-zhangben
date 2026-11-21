// 去重、静默期、恢复通知（S10c）。服务器里的检查任务和本机探测脚本共用这一份。
//
// 两类告警：
//   - 条件类（condition）：每轮检查报「现在是不是坏的」。好 → 坏：立刻发一条；一直坏：每 repeatMs（默认 6 小时）再提醒一次；
//     坏 → 好：发一条「已恢复」。同一个键正在告警时不重复发。
//   - 事件类（event）：日志里的 alert 字段、备份被跳过、门禁被跳过……发生一次算一次。同一个键在 silenceMs（默认 30 分钟）
//     内只发第一条，后面的计数，静默期过后的下一条带上「另有 N 次」。
// 发送失败：条件类不记成「已发」，下一轮重试；事件类进待发队列（最多 100 条，超了丢最旧的并计数），下一轮重试。
// 状态（谁在告警、上次什么时候发的、待发队列、调用方自己的游标）可以存到一个 JSON 文件里（服务器挂 /data/monitor），
// 重启后不会把正在告警的再发一遍，也不会漏掉恢复通知。
import { mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { buildMessage, type Alert, type AlertMessage } from "./alert.ts";

export interface AlertSink {
  send(m: AlertMessage): Promise<void>;
}

export interface AlerterLog {
  warn(obj: object, msg: string): void;
  error(obj: object, msg: string): void;
}

interface CondState {
  since: string;
  lastSent: string;
  alert: Alert;
}
interface EventState {
  lastSent: string;
  suppressed: number;
}
export interface AlerterState {
  conditions: Record<string, CondState>;
  events: Record<string, EventState>;
  pending: AlertMessage[];
  dropped: number;
  /** 调用方自己用的游标和样本（读到日志第几个字节、上次的证书序列号……） */
  cursors: Record<string, unknown>;
}

export interface AlerterOptions {
  sink: AlertSink;
  clock: () => Date;
  log?: AlerterLog;
  /** 状态文件；不给 = 只在内存里 */
  statePath?: string;
  repeatMs?: number;
  silenceMs?: number;
  maxPending?: number;
}

export const DEFAULT_REPEAT_MS = 6 * 3600_000;
export const DEFAULT_SILENCE_MS = 30 * 60_000;

export function emptyState(): AlerterState {
  return { conditions: {}, events: {}, pending: [], dropped: 0, cursors: {} };
}

export class Alerter {
  readonly state: AlerterState;
  private readonly o: Required<Omit<AlerterOptions, "log" | "statePath">> & Pick<AlerterOptions, "log" | "statePath">;

  constructor(o: AlerterOptions) {
    this.o = { repeatMs: DEFAULT_REPEAT_MS, silenceMs: DEFAULT_SILENCE_MS, maxPending: 100, ...o };
    this.state = o.statePath ? loadState(o.statePath, o.log) : emptyState();
  }

  /** 这个键现在是不是正在告警 */
  firing(key: string): boolean {
    return key in this.state.conditions;
  }

  /** 条件类：active=true 表示现在是坏的。返回这次发出去的消息（没发就是 null） */
  async condition(active: boolean, a: Alert): Promise<AlertMessage | null> {
    const now = this.o.clock();
    const cur = this.state.conditions[a.key];
    if (active) {
      if (cur && now.getTime() - Date.parse(cur.lastSent) < this.o.repeatMs) {
        cur.alert = a; // 详情（剩几小时、超了多少）跟着最新的走，恢复通知里用
        return null;
      }
      const m = buildMessage(cur ? "repeat" : "fire", a, now);
      if (!(await this.trySend(m))) return null;
      this.state.conditions[a.key] = { since: cur?.since ?? now.toISOString(), lastSent: now.toISOString(), alert: a };
      return m;
    }
    if (!cur) return null;
    const m = buildMessage("resolved", { ...cur.alert, details: { ...a.details, since: cur.since } }, now);
    if (!(await this.trySend(m))) return null; // 恢复通知没发出去：留着「正在告警」，下一轮再发
    delete this.state.conditions[a.key];
    return m;
  }

  /** 事件类：发生了一次 */
  async event(a: Alert): Promise<AlertMessage | null> {
    const now = this.o.clock();
    const cur = this.state.events[a.key];
    if (cur && now.getTime() - Date.parse(cur.lastSent) < this.o.silenceMs) {
      cur.suppressed++;
      return null;
    }
    const m = buildMessage("event", a, now, cur?.suppressed);
    this.state.events[a.key] = { lastSent: now.toISOString(), suppressed: 0 };
    if (!(await this.trySend(m))) this.enqueue(m);
    return m;
  }

  /** 把上一轮没发出去的事件再发一次（每轮检查开头调） */
  async flush(): Promise<void> {
    const q = this.state.pending.splice(0);
    for (let i = 0; i < q.length; i++) {
      if (!(await this.trySend(q[i]!))) {
        this.state.pending.unshift(...q.slice(i));
        break;
      }
    }
    if (this.state.dropped > 0) {
      const n = this.state.dropped;
      const m = buildMessage("event", { key: "alert_queue_overflow", title: "告警通道长时间不通，有告警没发出去被丢弃", severity: "critical", details: { count: n } }, this.o.clock());
      if (await this.trySend(m)) this.state.dropped = 0;
    }
  }

  /** 静默期过了很久的事件键清掉，免得状态文件越长越大 */
  prune(): void {
    const cutoff = this.o.clock().getTime() - 7 * 86_400_000;
    for (const [k, v] of Object.entries(this.state.events)) if (Date.parse(v.lastSent) < cutoff && v.suppressed === 0) delete this.state.events[k];
  }

  save(): void {
    if (!this.o.statePath) return;
    try {
      mkdirSync(dirname(this.o.statePath), { recursive: true });
      const tmp = `${this.o.statePath}.tmp`;
      writeFileSync(tmp, JSON.stringify(this.state), { mode: 0o600 });
      renameSync(tmp, this.o.statePath);
    } catch (e) {
      this.o.log?.error({ alert: "monitor_state_unwritable", err: (e as Error).message }, "监控状态写不进去，重启后可能重发或漏发恢复通知");
    }
  }

  private enqueue(m: AlertMessage): void {
    this.state.pending.push(m);
    while (this.state.pending.length > this.o.maxPending) {
      this.state.pending.shift();
      this.state.dropped++;
    }
  }

  private async trySend(m: AlertMessage): Promise<boolean> {
    try {
      await this.o.sink.send(m);
      return true;
    } catch (e) {
      // 通道本身坏了：只记日志（不带 alert 字段，免得日志转告警再进来一圈）
      this.o.log?.warn({ key: m.key, err: (e as Error).message }, "告警发送失败，下一轮重试");
      return false;
    }
  }
}

function loadState(path: string, log?: AlerterLog): AlerterState {
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return emptyState();
  }
  try {
    const s = JSON.parse(raw) as Partial<AlerterState>;
    return { ...emptyState(), ...s };
  } catch {
    log?.warn({ path }, "监控状态文件坏了，从空状态开始");
    return emptyState();
  }
}
