// S09：定时调度器 —— 可注入时钟和定时器；到点才跑、按间隔、不叠着跑、出错不影响别的任务、stop 等跑完；
// 接上真实任务后拨钟：演示店 16:00 重置、注销满 7 天后 1 小时内清除（§14 S03-4 要求 24 小时内）、导出包 1 分钟内生成。
import { randomUUID } from "node:crypto";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";
import { bearer, login, makeApp, makeLoginShop, PASSWORD, TestClock } from "./helpers/auth.ts";
import { defaultTasks, Scheduler, TASK_INTERVALS, type Task } from "../src/jobs/scheduler.ts";
import { MemoryObjectStore, deletionKey, storePrefix } from "../src/lookup/oss.ts";
import { DELETE_GRACE_MS } from "../src/auth/session.ts";
import { setupDemoStore } from "../src/demo/reset.ts";

let tdb: TestDb;
let cache: string;
beforeAll(async () => {
  tdb = await createTestDb();
  cache = await mkdtemp(path.join(tmpdir(), "yh-sched-"));
});
afterAll(async () => {
  await tdb.drop();
  await rm(cache, { recursive: true, force: true });
});

function fakeTimers() {
  const timers: Array<{ fn: () => void; ms: number; cleared: boolean }> = [];
  return {
    timers,
    setTimer: (fn: () => void, ms: number) => {
      const t = { fn, ms, cleared: false };
      timers.push(t);
      return t;
    },
    clearTimer: (h: unknown) => void ((h as { cleared: boolean }).cleared = true),
  };
}

describe("Scheduler", () => {
  it("启动后第一轮全跑；之后每个任务按自己的间隔；没到点不跑", async () => {
    const clock = new TestClock(0);
    const log: string[] = [];
    const t = (name: string, everyMs: number): Task => ({ name, everyMs, run: async (now) => void log.push(`${name}@${now.getTime()}`) });
    const s = new Scheduler({ clock: clock.now, tasks: [t("a", 1000), t("b", 3000)] });
    expect(await s.tick()).toEqual(["a", "b"]);
    clock.advance(999);
    expect(await s.tick()).toEqual([]);
    clock.advance(1);
    expect(await s.tick()).toEqual(["a"]);
    clock.advance(2000);
    expect(await s.tick()).toEqual(["a", "b"]);
    expect(log).toEqual(["a@0", "b@0", "a@1000", "a@3000", "b@3000"]);
    expect(s.nextRunAt("b")?.getTime()).toBe(6000);
  });

  it("出错只记日志，不影响别的任务和下一次", async () => {
    const clock = new TestClock(0);
    const warns: object[] = [];
    let n = 0;
    const s = new Scheduler({
      clock: clock.now,
      log: { warn: (o) => void warns.push(o) },
      tasks: [
        { name: "bad", everyMs: 10, run: async () => { throw new Error("坏了"); } },
        { name: "good", everyMs: 10, run: async () => void n++ },
      ],
    });
    expect(await s.tick()).toEqual(["bad", "good"]);
    clock.advance(10);
    expect(await s.tick()).toEqual(["bad", "good"]);
    expect([n, warns]).toEqual([2, [{ task: "bad", err: "坏了" }, { task: "bad", err: "坏了" }]]);
  });

  it("上一轮没跑完不叠着跑；stop 等正在跑的跑完、清掉定时器", async () => {
    const clock = new TestClock(0);
    let release!: () => void;
    let running = 0;
    let maxRunning = 0;
    const s = new Scheduler({
      clock: clock.now,
      ...fakeTimers(),
      tasks: [{ name: "slow", everyMs: 1, run: () => new Promise<void>((r) => { running++; maxRunning = Math.max(maxRunning, running); release = () => { running--; r(); }; }) }],
    });
    const first = s.tick();
    clock.advance(100);
    expect(await s.tick()).toEqual([]);
    let stopped = false;
    const stopping = s.stop().then(() => void (stopped = true));
    await new Promise((r) => setTimeout(r, 10));
    expect(stopped).toBe(false);
    release();
    await stopping;
    expect(await first).toEqual(["slow"]);
    expect(maxRunning).toBe(1);
  });

  it("start 用注入的定时器轮询，跑完一轮才排下一次；stop 之后不再排", async () => {
    const clock = new TestClock(0);
    const ft = fakeTimers();
    let n = 0;
    const s = new Scheduler({ clock: clock.now, pollMs: 5000, ...ft, tasks: [{ name: "x", everyMs: 5000, run: async () => void n++ }] });
    s.start();
    expect(ft.timers.map((t) => t.ms)).toEqual([5000]);
    ft.timers[0]!.fn();
    await new Promise((r) => setTimeout(r, 0));
    expect([n, ft.timers.length]).toEqual([1, 2]);
    await s.stop();
    expect(ft.timers[1]!.cleared).toBe(true);
  });

  it("任务重名、间隔不大于 0 → 报错", () => {
    const run = async () => {};
    expect(() => new Scheduler({ clock: () => new Date(), tasks: [{ name: "a", everyMs: 1, run }, { name: "a", everyMs: 1, run }] })).toThrow(/重名/);
    expect(() => new Scheduler({ clock: () => new Date(), tasks: [{ name: "a", everyMs: 0, run }] })).toThrow(/间隔/);
  });
});

describe("defaultTasks 接真实任务，拨钟", () => {
  it("图片开关关着不登记图片任务；开着且有对象存储才登记", () => {
    const base = { db: tdb.kysely, clock: () => new Date(), images: new MemoryObjectStore(), archive: new MemoryObjectStore(), imageCacheDir: cache };
    expect(defaultTasks({ ...base, productImagesEnabled: false }).map((t) => t.name)).toEqual(["demo-reset", "account-exports", "account-purge"]);
    expect(defaultTasks({ ...base, productImagesEnabled: true }).map((t) => t.name)).toEqual(["images", "demo-reset", "account-exports", "account-purge"]);
    expect(defaultTasks({ ...base, productImagesEnabled: true, images: null }).map((t) => t.name)).not.toContain("images");
  });

  it("一小时一小时拨：导出包第一轮就生成；演示店 16:00 那轮重置；注销满 7 天后 1 小时内清除并写删除记录", async () => {
    const clock = new TestClock(Date.parse("2026-11-20T02:00:00Z")); // 北京 10:00
    const images = new MemoryObjectStore();
    const archive = new MemoryObjectStore();
    const demo = await setupDemoStore(tdb.kysely, { username: `rv_${randomUUID().slice(0, 6)}`, password: PASSWORD, now: clock.now() });
    const shop = await makeLoginShop(tdb, { name: "要注销的店" });
    const app = makeApp(tdb, { clock });
    const boss = await login(app, shop.username);
    expect((await app.inject({ method: "POST", url: "/v1/account/delete-request", headers: bearer(boss.token), payload: { password: PASSWORD } })).statusCode).toBe(200);
    const requestedAt = clock.t;
    // 演示店里改点东西，看重置有没有发生
    await tdb.kysely.updateTable("stores").set({ name: "被改了" }).where("id", "=", demo.storeId).execute();

    const s = new Scheduler({ clock: clock.now, tasks: defaultTasks({ db: tdb.kysely, clock: clock.now, productImagesEnabled: false, images, archive, imageCacheDir: cache }) });
    await s.tick();
    expect((await archive.list(storePrefix("exports", shop.storeId))).length).toBe(1);

    let resetAt: number | null = null;
    let purgedAt: number | null = null;
    for (let h = 0; h < 8 * 24 && purgedAt === null; h++) {
      clock.advance(3_600_000);
      await s.tick();
      if (resetAt === null && (await tdb.kysely.selectFrom("stores").select("name").where("id", "=", demo.storeId).executeTakeFirstOrThrow()).name === "演示小店") resetAt = clock.t;
      const gone = !(await tdb.kysely.selectFrom("stores").select("id").where("id", "=", shop.storeId).executeTakeFirst());
      if (gone) purgedAt = clock.t;
    }
    expect(new Date(resetAt!).toISOString()).toBe("2026-11-20T08:00:00.000Z");
    expect(purgedAt).not.toBeNull();
    expect(purgedAt! - requestedAt).toBeGreaterThan(DELETE_GRACE_MS);
    expect(purgedAt! - requestedAt - DELETE_GRACE_MS).toBeLessThanOrEqual(TASK_INTERVALS.accountPurge);
    expect(archive.objects.has(deletionKey(shop.storeId))).toBe(true);
    expect(await archive.list(storePrefix("exports", shop.storeId))).toEqual([]);
    await app.close();
  }, 120_000);
});
