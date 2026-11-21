// 测试辅助（S10c）：假告警通道
import type { AlertMessage } from "../../src/monitor/alert.ts";
import type { AlertSink } from "../../src/monitor/alerter.ts";

/** 假通道：记下发了什么；fail=true 时抛错 */
export class FakeSink implements AlertSink {
  sent: AlertMessage[] = [];
  fail = false;
  async send(m: AlertMessage): Promise<void> {
    if (this.fail) throw new Error("通道不通");
    this.sent.push(m);
  }
  kinds(): string[] {
    return this.sent.map((m) => `${m.kind}:${m.key}`);
  }
}

