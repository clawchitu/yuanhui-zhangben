// 从 api 自己的 pino 日志里取告警（S10c）。app.ts 把每一行日志在写到 stdout 的同时交给 LogTap.line()：
//   - 带 alert 字段的行（§14 T16：account_delete_export、account_delete_export_failed、export_no_archive、purge_no_archive、
//     object_discard_failed、export_discard_lost、purge_objects_failed；本段新加 login_locked、account_delete_request、kuainiao_quota）→ 事件类告警；
//   - Fastify 的「request completed」行里 res.statusCode ≥ 500 → 记一笔，检查任务按一小时窗口数（§9.5：每小时超过 20 次告警）。
// 这里只解析、攒着，不发；检查任务每轮 drain() 后交给 Alerter（日志回调是同步的，不在里面等网络）。
// 转进告警的只有白名单字段（alert.ts 的 DETAIL_KEYS），日志行里别的东西（请求头、错误栈）不会带出去。
import type { Alert, Severity } from "./alert.ts";

/** 已知告警名 → 标题、级别。不在表里的照样转，标题用日志的 msg */
export const LOG_ALERTS: Record<string, { title: string; severity: Severity }> = {
  account_delete_request: { title: "有人申请注销账号（导出包生成后另发一条，附位置）", severity: "warning" },
  account_delete_export: { title: "注销导出包已生成，请转交黄总", severity: "warning" },
  account_delete_export_failed: { title: "注销导出包连续生成失败", severity: "critical" },
  export_no_archive: { title: "有注销导出包要生成，但没配存档桶", severity: "critical" },
  purge_no_archive: { title: "有注销到期的店，但删除记录写不了（没配存档桶 / 对象存储），暂不清除", severity: "critical" },
  object_discard_failed: { title: "待删对象多次重试仍删不掉", severity: "warning" },
  purge_objects_failed: { title: "已清除店的对象清理连续失败（商品图桶不存在 / 配错？），导出包和图片可能还在", severity: "critical" },
  export_discard_lost: { title: "不该留的导出包没删掉，待删标记也没记上", severity: "critical" },
  login_locked: { title: "账号密码输错太多次，已锁定", severity: "warning" },
  kuainiao_quota: { title: "快鸟接口报额度用完 / 被限流", severity: "critical" },
  monitor_state_unwritable: { title: "监控状态文件写不进去", severity: "warning" },
};

export const ERROR_WINDOW_MS = 3600_000;

export class LogTap {
  private events: Alert[] = [];
  private errors: number[] = [];
  private droppedEvents = 0;
  private readonly maxEvents: number;
  private readonly clock: () => Date;
  constructor(clock: () => Date = () => new Date(), maxEvents = 500) {
    this.clock = clock;
    this.maxEvents = maxEvents;
  }

  line(raw: string): void {
    let o: Record<string, unknown>;
    try {
      o = JSON.parse(raw) as Record<string, unknown>;
    } catch {
      return;
    }
    if (!o || typeof o !== "object") return;
    const res = o.res as { statusCode?: unknown } | undefined;
    if (res && typeof res.statusCode === "number" && res.statusCode >= 500) {
      const t = typeof o.time === "number" ? o.time : this.clock().getTime();
      this.errors.push(t);
      if (this.errors.length > 10_000) this.errors.splice(0, this.errors.length - 10_000);
    }
    if (typeof o.alert === "string" && /^[a-z0-9_]{1,64}$/.test(o.alert)) {
      const known = LOG_ALERTS[o.alert];
      const storeId = typeof o.store_id === "string" ? o.store_id : "";
      if (this.events.length >= this.maxEvents) {
        this.droppedEvents++;
        return;
      }
      this.events.push({
        key: storeId ? `${o.alert}:${storeId}` : o.alert,
        title: known?.title ?? (typeof o.msg === "string" ? o.msg : o.alert),
        severity: known?.severity ?? (typeof o.level === "number" && o.level >= 50 ? "critical" : "warning"),
        details: o,
      });
    }
  }

  /** 取走攒下的事件（取完清空） */
  drain(): { events: Alert[]; dropped: number } {
    const out = { events: this.events, dropped: this.droppedEvents };
    this.events = [];
    this.droppedEvents = 0;
    return out;
  }

  /** 最近一小时的 5xx 次数（顺手丢掉更早的） */
  errorsLastHour(now: Date): number {
    const cutoff = now.getTime() - ERROR_WINDOW_MS;
    let i = 0;
    while (i < this.errors.length && this.errors[i]! <= cutoff) i++;
    if (i) this.errors.splice(0, i);
    return this.errors.length;
  }
}
