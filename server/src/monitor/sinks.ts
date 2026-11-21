// 告警通道（S10c，§9.5「所有告警发给 Chitu」）。都实现 AlertSink，测试里换成假实现。
//
// 服务器上：
//   - OutboxSink：追加到 /data/monitor/outbox.jsonl（一行一条）。这是主通道：ECS 出网不一定到得了 Chitu 那边，
//     本机探测（scripts/probe.ts，每 10 分钟）用部署用的 ssh 把新行拉回来，再从本机发给 Chitu。
//   - WebhookSink：配了 ALERT_WEBHOOK_URL 才有，立刻推一份（POST JSON，可带 Bearer 令牌）。推不出去不影响 outbox。
// 本机探测上：
//   - CommandSink：PROBE_NOTIFY_CMD，消息正文从 stdin 喂给这个命令（Chitu 接收消息的那个命令）；
//   - WebhookSink：PROBE_WEBHOOK_URL / PROBE_WEBHOOK_TOKEN。
// 只用 Node 自带模块（本机探测不装依赖）。
import { appendFileSync, mkdirSync, readFileSync, statSync, writeFileSync, renameSync } from "node:fs";
import { dirname } from "node:path";
import { spawn } from "node:child_process";
import type { AlertMessage } from "./alert.ts";
import type { AlertSink } from "./alerter.ts";

export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body: string; signal: AbortSignal }) => Promise<{ ok: boolean; status: number }>;

function hostOf(url: string): string {
  try {
    return new URL(url).hostname || "?";
  } catch {
    return "?";
  }
}

/** 只留异常的类名和系统错误码（ECONNREFUSED、UND_ERR_CONNECT_TIMEOUT 这种全大写的），不留 message */
function errorClass(e: unknown): string {
  const name = e instanceof Error && /^[A-Za-z]{1,40}$/.test(e.name) ? e.name : "Error";
  const code = (x: unknown) => {
    const c = (x as { code?: unknown } | null)?.code;
    return typeof c === "string" && /^[A-Z0-9_]{1,40}$/.test(c) ? c : "";
  };
  const c = code(e) || code((e as { cause?: unknown } | null)?.cause);
  return c ? `${name} ${c}` : name;
}

/** webhook 配置检查（服务器 ALERT_WEBHOOK_*、本机 PROBE_WEBHOOK_* 共用）：只许 https、地址里不许带用户名口令、令牌只许可见 ASCII。返回错误文字，没问题返回 null */
export function webhookConfigError(url: string, token: string): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return "不是合法 URL";
  }
  // 告警正文要出公网：只许 https
  if (u.protocol !== "https:") return "只能是 https";
  if (u.username || u.password) return "地址里不能带用户名口令（令牌放 *_WEBHOOK_TOKEN）";
  if (token && !/^[\x21-\x7e]+$/.test(token)) return "令牌里有空白或控制字符";
  return null;
}

export class WebhookSink implements AlertSink {
  private readonly url: string;
  private readonly token: string;
  private readonly fetch: FetchLike;
  private readonly timeoutMs: number;
  constructor(o: { url: string; token?: string; fetch?: FetchLike; timeoutMs?: number }) {
    this.url = o.url;
    this.token = o.token ?? "";
    this.fetch = o.fetch ?? (globalThis.fetch as unknown as FetchLike);
    this.timeoutMs = o.timeoutMs ?? 10_000;
  }
  async send(m: AlertMessage): Promise<void> {
    const headers: Record<string, string> = { "content-type": "application/json" };
    if (this.token) headers.authorization = `Bearer ${this.token}`;
    let res: { ok: boolean; status: number };
    try {
      res = await this.fetch(this.url, { method: "POST", headers, body: JSON.stringify(m), signal: AbortSignal.timeout(this.timeoutMs) });
    } catch (e) {
      // fetch 的异常（连不上、超时、地址带凭据、请求头非法）里会原样带出地址和令牌：一律换成固定文字，只留主机名和错误类别
      throw new Error(`webhook 请求失败（${hostOf(this.url)}）：${errorClass(e)}`);
    }
    // 错误信息里不带地址（地址里可能带令牌）
    if (!res.ok) throw new Error(`webhook HTTP ${res.status}`);
  }
}

/** 一行一条 JSON。超过 maxBytes 时只留后一半（本机探测每 10 分钟拉一次，留下的远多于两次之间产生的） */
export class OutboxSink implements AlertSink {
  readonly path: string;
  private readonly maxBytes: number;
  constructor(path: string, maxBytes = 2 * 1024 * 1024) {
    this.path = path;
    this.maxBytes = maxBytes;
  }
  async send(m: AlertMessage): Promise<void> {
    mkdirSync(dirname(this.path), { recursive: true });
    appendFileSync(this.path, JSON.stringify(m) + "\n", { mode: 0o640 });
    let size = 0;
    try {
      size = statSync(this.path).size;
    } catch {
      return;
    }
    if (size > this.maxBytes) {
      const lines = readFileSync(this.path, "utf8").split("\n").filter(Boolean);
      const keep = lines.slice(Math.floor(lines.length / 2));
      writeFileSync(`${this.path}.tmp`, keep.join("\n") + "\n", { mode: 0o640 });
      renameSync(`${this.path}.tmp`, this.path);
    }
  }
}

export type Runner = (cmd: string, stdin: string) => Promise<number>;

/** 用 sh -c 跑命令，消息正文走 stdin（不拼进命令行，ps 里看不到） */
export const shRunner: Runner = (cmd, stdin) =>
  new Promise((resolve, reject) => {
    const p = spawn("/bin/sh", ["-c", cmd], { stdio: ["pipe", "ignore", "inherit"] });
    const t = setTimeout(() => p.kill("SIGKILL"), 30_000);
    p.on("error", reject);
    p.on("close", (code) => {
      clearTimeout(t);
      resolve(code ?? 1);
    });
    p.stdin.end(stdin);
  });

export class CommandSink implements AlertSink {
  private readonly cmd: string;
  private readonly run: Runner;
  constructor(cmd: string, run: Runner = shRunner) {
    this.cmd = cmd;
    this.run = run;
  }
  async send(m: AlertMessage): Promise<void> {
    const code = await this.run(this.cmd, m.text + "\n");
    if (code !== 0) throw new Error(`通知命令退出码 ${code}`);
  }
}

/** 发给每一个通道；至少一个成功就算发出去了，全失败才抛 */
export class MultiSink implements AlertSink {
  private readonly sinks: AlertSink[];
  private readonly onPartial?: (err: Error) => void;
  constructor(sinks: AlertSink[], onPartial?: (err: Error) => void) {
    if (!sinks.length) throw new Error("至少要一个告警通道");
    this.sinks = sinks;
    this.onPartial = onPartial;
  }
  async send(m: AlertMessage): Promise<void> {
    const rs = await Promise.allSettled(this.sinks.map((s) => s.send(m)));
    const bad = rs.filter((r): r is PromiseRejectedResult => r.status === "rejected");
    if (bad.length === rs.length) throw bad[0]!.reason as Error;
    for (const b of bad) this.onPartial?.(b.reason as Error);
  }
}
