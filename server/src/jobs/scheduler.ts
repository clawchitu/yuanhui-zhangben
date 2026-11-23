// 定时调度器（S09）：一个进程里所有后台任务都从这里起，时钟和定时器都可注入（测试里拨钟、手动 tick）。
//
// 规则：
// - 每个任务有自己的间隔；tick() 时把到点的任务按登记顺序一个一个跑完（同一时刻只跑一个任务，不抢连接池）。
// - 一个任务的下一次 = 这次开始时间 + 间隔；跑得比间隔还久也不会叠着跑（tick 本身不重入：上一轮没跑完，新的一轮直接跳过）。
// - 任务抛错只记日志，不影响别的任务和下一次。
// - stop() 停掉定时器并等正在跑的那一轮跑完（收到 SIGTERM 时不把事务掐在半截）。
// 任务（defaultTasks）：商品图（S08 挪过来，开关和对象存储都有才登记；S22d 起先跑候选转存，另有每周的候选孤儿清扫）、演示店每日重置、注销导出包、注销到期清除、监控（S10c，配了才登记）。
// 到期清除每小时跑一次：S03-4 要求至少每天一次，把「满 7 天」到真正删除的空档压在 24 小时内，这里压到 1 小时内。
import type { Kysely } from "kysely";
import type { Database } from "../db.ts";
import type { ObjectStore } from "../lookup/oss.ts";
import { enqueueImageJobs, runImageJobs } from "./image-fetch.ts";
import { runCandidateJobs, sweepCandidateObjects, type CandidateWorker } from "../lookup/candidates.ts";
import { runDemoResets } from "../demo/reset.ts";
import { runAccountPurges, runExportJobs, type PurgeLog } from "./account-purge.ts";

export interface Task {
  name: string;
  everyMs: number;
  run(now: Date): Promise<unknown>;
}

export interface SchedulerLog {
  warn(obj: object, msg: string): void;
}

type TimerHandle = unknown;

export interface SchedulerOptions {
  tasks: Task[];
  clock: () => Date;
  log?: SchedulerLog;
  /** 多久看一次有没有到点的任务（默认 10 秒） */
  pollMs?: number;
  setTimer?: (fn: () => void, ms: number) => TimerHandle;
  clearTimer?: (h: TimerHandle) => void;
}

export class Scheduler {
  private readonly o: Required<Omit<SchedulerOptions, "log">> & { log?: SchedulerLog };
  private readonly nextAt = new Map<string, number>();
  private running: Promise<string[]> | null = null;
  private timer: TimerHandle | null = null;
  private stopped = true;

  constructor(o: SchedulerOptions) {
    const names = new Set<string>();
    for (const t of o.tasks) {
      if (names.has(t.name)) throw new Error(`任务重名：${t.name}`);
      if (!(t.everyMs > 0)) throw new Error(`任务 ${t.name} 的间隔必须大于 0`);
      names.add(t.name);
    }
    this.o = {
      pollMs: 10_000,
      setTimer: (fn, ms) => setTimeout(fn, ms),
      clearTimer: (h) => clearTimeout(h as NodeJS.Timeout),
      ...o,
    };
    // 启动后第一次 tick 就跑一遍所有任务
    const now = o.clock().getTime();
    for (const t of o.tasks) this.nextAt.set(t.name, now);
  }

  /** 下一次什么时候跑（测试看） */
  nextRunAt(name: string): Date | undefined {
    const t = this.nextAt.get(name);
    return t === undefined ? undefined : new Date(t);
  }

  /** 跑一轮到点的任务，返回这轮跑了哪些。上一轮还没跑完就什么都不做、返回 [] */
  tick(): Promise<string[]> {
    if (this.running) return Promise.resolve([]);
    const p = this.runDue().finally(() => {
      this.running = null;
    });
    this.running = p;
    return p;
  }

  private async runDue(): Promise<string[]> {
    const ran: string[] = [];
    for (const t of this.o.tasks) {
      const now = this.o.clock();
      if (now.getTime() < this.nextAt.get(t.name)!) continue;
      this.nextAt.set(t.name, now.getTime() + t.everyMs);
      try {
        await t.run(now);
      } catch (e) {
        this.o.log?.warn({ task: t.name, err: (e as Error)?.message }, "定时任务出错，下次照常再跑");
      }
      ran.push(t.name);
    }
    return ran;
  }

  start(): void {
    if (!this.stopped) return;
    this.stopped = false;
    const loop = () => {
      if (this.stopped) return;
      void this.tick().finally(() => {
        if (!this.stopped) this.timer = this.o.setTimer(loop, this.o.pollMs);
      });
    };
    this.timer = this.o.setTimer(loop, this.o.pollMs);
  }

  /** 停掉定时器，等正在跑的那一轮跑完 */
  async stop(): Promise<void> {
    this.stopped = true;
    if (this.timer !== null) this.o.clearTimer(this.timer);
    this.timer = null;
    if (this.running) await this.running.catch(() => {});
  }
}

export const TASK_INTERVALS = {
  images: 30_000,
  demoReset: 5 * 60_000,
  accountExports: 60_000,
  accountPurge: 60 * 60_000,
  monitor: 60_000,
  /** S22d：每周清一次 images/_catalog/ 下没有对应行、落地超过 1 小时的对象 */
  candidateSweep: 7 * 24 * 3600_000,
} as const;

export interface DefaultTaskDeps {
  db: Kysely<Database>;
  clock: () => Date;
  productImagesEnabled: boolean;
  images: ObjectStore | null;
  archive: ObjectStore | null;
  imageCacheDir: string;
  log?: PurgeLog & { info(obj: object, msg: string): void };
  /** 监控检查任务（S10c，monitor/server-monitor.ts）；没配 MONITOR_DIR 时不登记 */
  monitor?: { run(now: Date): Promise<void> } | null;
  /** 商品图候选的进程内 worker（app.candidates，S22d）：images 任务先补跑到期的候选（兜底重试），再跑图片任务；传了才登记每周清扫 */
  candidates?: CandidateWorker | null;
}

export function defaultTasks(d: DefaultTaskDeps): Task[] {
  const tasks: Task[] = [];
  if (d.productImagesEnabled && d.images) {
    const img = { db: d.db, store: d.images, enabled: true, clock: d.clock, log: d.log };
    tasks.push({
      name: "images",
      everyMs: TASK_INTERVALS.images,
      run: async () => {
        // 候选先跑：图片任务（只在 image_ver=0 时落第一张）优先复制已转存好的候选
        if (d.candidates) await d.candidates.drain();
        else await runCandidateJobs(img);
        await enqueueImageJobs(img);
        await runImageJobs(img);
      },
    });
    const cand = d.candidates;
    if (cand) tasks.push({ name: "image-candidates-sweep", everyMs: TASK_INTERVALS.candidateSweep, run: () => sweepCandidateObjects(cand.deps) });
  }
  tasks.push({ name: "demo-reset", everyMs: TASK_INTERVALS.demoReset, run: (now) => runDemoResets(d.db, now) });
  const acct = { db: d.db, images: d.images, archive: d.archive, imageCacheDir: d.imageCacheDir, clock: d.clock, log: d.log };
  tasks.push({ name: "account-exports", everyMs: TASK_INTERVALS.accountExports, run: () => runExportJobs(acct) });
  tasks.push({ name: "account-purge", everyMs: TASK_INTERVALS.accountPurge, run: () => runAccountPurges(acct) });
  const mon = d.monitor;
  if (mon) tasks.push({ name: "monitor", everyMs: TASK_INTERVALS.monitor, run: (now) => mon.run(now) });
  return tasks;
}
