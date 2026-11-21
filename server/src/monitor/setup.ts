// 生产装配（server.ts 用）：按配置建通道、Alerter、LogTap、ServerMonitor。MONITOR_DIR 空 = 不监控（本机开发）。
import { join } from "node:path";
import type { Config } from "../config.ts";
import { Alerter, type AlerterLog, type AlertSink } from "./alerter.ts";
import { LogTap } from "./logtap.ts";
import { MultiSink, OutboxSink, WebhookSink } from "./sinks.ts";

export function sinkFromConfig(m: Config["monitor"], log?: AlerterLog): AlertSink | null {
  if (!m.dir) return null;
  const sinks: AlertSink[] = [new OutboxSink(join(m.dir, "outbox.jsonl"))];
  if (m.webhookUrl) sinks.push(new WebhookSink({ url: m.webhookUrl, token: m.webhookToken }));
  return new MultiSink(sinks, (e) => log?.warn({ err: e.message }, "有一个告警通道发送失败（outbox 已写）"));
}

export function monitorFromConfig(config: Config, clock: () => Date, log?: AlerterLog): { tap: LogTap; alerter: Alerter } | null {
  const sink = sinkFromConfig(config.monitor, log);
  if (!sink) return null;
  return { tap: new LogTap(clock), alerter: new Alerter({ sink, clock, log, statePath: join(config.monitor.dir, "state.json") }) };
}
