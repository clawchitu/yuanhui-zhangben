// 本机定时探测（S10c，§9.5）：这台 Mac 上由 launchd 每 10 分钟跑一次（deploy/probe/，runbook「监控与告警」）。
//   1. 服务存活：GET <PROBE_URL>/healthz，连续 2 次失败告警，恢复后发「已恢复」。
//   2. IP 证书（方案 A）：连 443 读证书，剩余 < 48 小时或链不受信任告警；序列号变了记一笔「续期成功」，
//      剩余不到有效期 1/4 还没换记一笔「续期过期未续」，都写进 <状态目录>/cert-renewals.jsonl（§14 T19，供判定方案 A 是否稳定）。
//   3. 服务器告警转发：ssh 到 ECS 读 /data/monitor/outbox.jsonl，把没转过的发给 Chitu（ECS 出网不一定到得了 Chitu 的通道）。
//      连续 3 次（30 分钟）拉不到也告警。
// 发给 Chitu 的通道：PROBE_NOTIFY_CMD（消息正文从 stdin 给这个命令）和 / 或 PROBE_WEBHOOK_URL（+ PROBE_WEBHOOK_TOKEN），至少配一个。
// 只用 Node 自带模块：不用 npm ci，`node server/scripts/probe.ts` 直接跑。
// 环境变量：PROBE_URL（必填，https://<公网 IP>）、PROBE_STATE_DIR、PROBE_SSH_TARGET（root@<公网 IP>，空 = 不拉 outbox）、
//          PROBE_REMOTE_OUTBOX（默认 /data/monitor/outbox.jsonl）。
// 退出码：0 跑完（不论有没有告警）；2 配置不对。
import { execFile } from "node:child_process";
import { appendFileSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { connect } from "node:tls";
import { fileURLToPath } from "node:url";
import { buildMessage, formatText, sanitizeDetails, scrub, type AlertMessage } from "../src/monitor/alert.ts";
import { Alerter, type AlertSink } from "../src/monitor/alerter.ts";
import { certVerdict, renewalOverdue, THRESHOLDS, type CertInfo } from "../src/monitor/checks.ts";
import { CommandSink, MultiSink, WebhookSink, webhookConfigError } from "../src/monitor/sinks.ts";

export const OUTBOX_UNREACHABLE_AFTER = 3;

export interface ProbeDeps {
  alerter: Alerter;
  sink: AlertSink;
  clock: () => Date;
  stateDir: string;
  baseUrl: string;
  health: () => Promise<{ ok: boolean; status: number | string }>;
  cert: () => Promise<CertInfo>;
  /** 读远端 outbox 的全部行；null = 没配 ssh */
  pullOutbox: (() => Promise<string>) | null;
}

interface ProbeCursors {
  healthFailures?: number;
  cert?: { serial: string; notAfter: string; overdueLogged?: boolean };
  outboxId?: string;
  outboxFailures?: number;
}

export async function runProbe(d: ProbeDeps): Promise<void> {
  const a = d.alerter;
  const c = ((a.state.cursors as { probe?: ProbeCursors }).probe ??= {});
  await a.flush();
  try {
    // 1. 服务存活
    const h = await d.health().catch((e: Error) => ({ ok: false, status: scrub(e.message) }));
    c.healthFailures = h.ok ? 0 : (c.healthFailures ?? 0) + 1;
    await a.condition(c.healthFailures >= THRESHOLDS.healthzFailures, {
      key: "healthz_down",
      title: "服务探活连续失败（本机每 10 分钟探 /healthz）",
      severity: "critical",
      details: { url: `${d.baseUrl}/healthz`, failures: c.healthFailures, status: String(h.status) },
    });

    // 2. 证书
    const now = d.clock();
    const cert = await d.cert().catch(() => null);
    if (cert) {
      const v = certVerdict(cert, now);
      await a.condition(v.active, { key: "ip_cert_expiry", title: "IP 证书剩余有效期不到 48 小时或不受信任（方案 A）", severity: "critical", details: v.details });
      const log = (event: string, extra: Record<string, unknown> = {}) =>
        appendFileSync(
          join(d.stateDir, "cert-renewals.jsonl"),
          JSON.stringify({ at: now.toISOString(), event, serial: cert.serial, not_before: cert.notBefore.toISOString(), not_after: cert.notAfter.toISOString(), ...extra }) + "\n",
        );
      if (!c.cert) log("first_seen");
      else if (c.cert.serial !== cert.serial) log("renewed", { prev_not_after: c.cert.notAfter });
      const overdue = renewalOverdue(cert, now);
      const sameSerial = c.cert?.serial === cert.serial;
      if (overdue && !(sameSerial && c.cert?.overdueLogged)) log("renewal_overdue", { hours_left: v.hoursLeft });
      c.cert = { serial: cert.serial, notAfter: cert.notAfter.toISOString(), overdueLogged: overdue };
    }

    // 3. 转发服务器 outbox
    if (d.pullOutbox) {
      let raw: string | null = null;
      try {
        raw = await d.pullOutbox();
        c.outboxFailures = 0;
      } catch {
        c.outboxFailures = (c.outboxFailures ?? 0) + 1;
      }
      await a.condition((c.outboxFailures ?? 0) >= OUTBOX_UNREACHABLE_AFTER, {
        key: "outbox_unreachable",
        title: "连续 30 分钟拉不到服务器的告警 outbox（ssh 不通），服务器那边的告警可能没送到",
        severity: "critical",
        details: { failures: c.outboxFailures ?? 0 },
      });
      if (raw !== null) await forwardOutbox(raw, c, d);
    }
  } finally {
    a.prune();
    a.save();
  }
}

/** 按 id 转发没转过的；第一次跑（没有游标）只转最近 24 小时的。发不出去就停，游标停在最后一条发成功的 */
export async function forwardOutbox(raw: string, c: ProbeCursors, d: Pick<ProbeDeps, "sink" | "clock">): Promise<number> {
  const cutoff = new Date(d.clock().getTime() - 24 * 3600_000).toISOString();
  let n = 0;
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let m: AlertMessage;
    try {
      m = JSON.parse(line) as AlertMessage;
    } catch {
      continue;
    }
    if (typeof m.id !== "string" || (c.outboxId !== undefined && m.id <= c.outboxId)) continue;
    if (c.outboxId === undefined && !(m.at >= cutoff)) continue;
    // 本机再按白名单洗一遍（不完全信远端写的 text）
    const base = {
      at: String(m.at),
      kind: m.kind,
      key: scrub(String(m.key)),
      severity: m.severity === "critical" ? ("critical" as const) : ("warning" as const),
      title: `${scrub(String(m.title))}（来自服务器）`,
      details: sanitizeDetails(m.details),
      ...(m.suppressed ? { suppressed: Number(m.suppressed) } : {}),
    };
    try {
      await d.sink.send({ id: m.id, ...base, text: formatText(base) });
    } catch {
      break;
    }
    c.outboxId = m.id;
    n++;
  }
  return n;
}

// ── 生产实现 ──

export function readCert(host: string, port = 443, timeoutMs = 10_000): Promise<CertInfo> {
  return new Promise((resolve, reject) => {
    // IP 证书不发 SNI；先不拒绝，自己看 authorized（链不受信任也要告警，不是直接报错退出）
    const s = connect({ host, port, rejectUnauthorized: false, timeout: timeoutMs }, () => {
      const p = s.getPeerCertificate();
      s.end();
      if (!p || !p.valid_to) return reject(new Error("没拿到证书"));
      resolve({ notBefore: new Date(p.valid_from), notAfter: new Date(p.valid_to), serial: p.serialNumber, authorized: s.authorized });
    });
    s.on("timeout", () => s.destroy(new Error("超时")));
    s.on("error", reject);
  });
}

/**
 * 远端读 outbox 的命令：文件还没有（服务器还没发过告警）算拉到了空的；文件在但读不了（权限不对、是目录……）要失败，
 * 让连续拉不到的 outbox_unreachable 能响（以前 `|| true` 把读失败也当成功，PR #25 Codex 建议）
 */
export function outboxTailCmd(path: string): string {
  return `if [ -e ${path} ]; then tail -n 1000 ${path}; else exit 0; fi`;
}

function sshCat(target: string, path: string): () => Promise<string> {
  return () =>
    new Promise((resolve, reject) => {
      // BatchMode：没有密钥就失败，不卡在问口令；只读最后 1000 行
      execFile("ssh", ["-o", "BatchMode=yes", "-o", "ConnectTimeout=15", target, outboxTailCmd(path)], { timeout: 60_000, maxBuffer: 8 * 1024 * 1024 }, (err, out) =>
        err ? reject(new Error("ssh 失败")) : resolve(out),
      );
    });
}

export function sinkFromEnv(env: NodeJS.ProcessEnv): AlertSink | null {
  const sinks: AlertSink[] = [];
  if (env.PROBE_NOTIFY_CMD) sinks.push(new CommandSink(env.PROBE_NOTIFY_CMD));
  if (env.PROBE_WEBHOOK_URL) sinks.push(new WebhookSink({ url: env.PROBE_WEBHOOK_URL, token: env.PROBE_WEBHOOK_TOKEN ?? "" }));
  return sinks.length ? new MultiSink(sinks) : null;
}

async function main(): Promise<void> {
  const env = process.env;
  const base = (env.PROBE_URL ?? "").replace(/\/+$/, "");
  let u: URL;
  try {
    u = new URL(base);
    if (u.protocol !== "https:") throw new Error();
  } catch {
    console.error("PROBE_URL 必填，形如 https://47.117.184.253");
    process.exit(2);
  }
  if (env.PROBE_WEBHOOK_URL) {
    const bad = webhookConfigError(env.PROBE_WEBHOOK_URL, env.PROBE_WEBHOOK_TOKEN ?? "");
    if (bad) {
      console.error(`PROBE_WEBHOOK_URL / PROBE_WEBHOOK_TOKEN ${bad}`);
      process.exit(2);
    }
  }
  const sink = sinkFromEnv(env);
  if (!sink) {
    console.error("至少配一个通道：PROBE_NOTIFY_CMD 或 PROBE_WEBHOOK_URL");
    process.exit(2);
  }
  const stateDir = env.PROBE_STATE_DIR || join(homedir(), "Library", "Application Support", "yuanhui-probe");
  mkdirSync(stateDir, { recursive: true, mode: 0o700 });
  const clock = () => new Date();
  const log = { warn: (o: object, m: string) => console.error(m, JSON.stringify(o)), error: (o: object, m: string) => console.error(m, JSON.stringify(o)) };
  const alerter = new Alerter({ sink, clock, log, statePath: join(stateDir, "state.json") });
  await runProbe({
    alerter,
    sink,
    clock,
    stateDir,
    baseUrl: base,
    health: async () => {
      const r = await fetch(`${base}/healthz`, { signal: AbortSignal.timeout(10_000) });
      return { ok: r.status === 200, status: r.status };
    },
    cert: () => readCert(u.hostname.replace(/^\[|\]$/g, ""), Number(u.port || 443)),
    pullOutbox: env.PROBE_SSH_TARGET ? sshCat(env.PROBE_SSH_TARGET, env.PROBE_REMOTE_OUTBOX || "/data/monitor/outbox.jsonl") : null,
  });
  // 测试告警通道用：node scripts/probe.ts --test-alert
  if (process.argv.includes("--test-alert")) await sink.send(buildMessage("event", { key: "probe_test", title: "告警通道测试（手动触发）", severity: "warning" }, clock()));
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) await main();
