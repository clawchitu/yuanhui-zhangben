// S10c 监控与告警：不连库的部分（告警洗字段、去重 / 静默期 / 恢复通知、日志解析、指标解析、阈值、通道、本机探测）。
import { mkdtempSync, readFileSync, writeFileSync, appendFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { buildMessage, sanitizeDetails, scrub } from "../src/monitor/alert.ts";
import { Alerter } from "../src/monitor/alerter.ts";
import { LogTap } from "../src/monitor/logtap.ts";
import { certVerdict, heartbeatVerdict, noSyncVerdict, parseMetrics, readNewLines, renewalOverdue, shanghaiAt, THRESHOLDS } from "../src/monitor/checks.ts";
import { CommandSink, MultiSink, OutboxSink, WebhookSink } from "../src/monitor/sinks.ts";
import { sinkFromConfig } from "../src/monitor/setup.ts";
import { forwardOutbox, runProbe, type ProbeDeps } from "../scripts/probe.ts";
import { loadConfig, ConfigError } from "../src/config.ts";
import { TestClock } from "./helpers/auth.ts";
import { FakeSink } from "./helpers/monitor.ts";

const tmp = () => mkdtempSync(join(tmpdir(), "yh-mon-"));
const H = 3600_000;
// 上海时间 = UTC + 8
const sh = (iso: string) => new Date(Date.parse(`${iso}+08:00`));

describe("告警内容不含密码、令牌、开通码（S10c 验收）", () => {
  const secrets = {
    password: "correct-horse-1",
    token: "4f1c0e9a8b7d6c5e4f3a2b1c0d9e8f7a6b5c4d3e2f1a0b9c8d7e6f5a4b3c2d1e",
    code: "PAIR-839201",
    authorization: "Bearer abc",
    err: "APPCODE 0123456789abcdef",
    headers: { authorization: "Bearer x" },
  };
  it("白名单外的字段整个丢掉，值里像凭据的长串换掉", () => {
    const d = sanitizeDetails({ ...secrets, store_id: "0b6c1234-5678-4abc-9def-0123456789ab", reason: `token=${secrets.token}`, count: 3 });
    expect(Object.keys(d).sort()).toEqual(["count", "reason", "store_id"]);
    expect(d.store_id).toBe("0b6c1234-5678-4abc-9def-0123456789ab"); // UUID 留着（每段短于 24）
    const text = buildMessage("event", { key: "k", title: `标题 APPCODE ${secrets.token}`, severity: "warning", details: { ...secrets, reason: `x ${secrets.token}` } }, new Date()).text;
    for (const s of [secrets.password, secrets.token, secrets.code, "0123456789abcdef", "Bearer abc"]) expect(text).not.toContain(s);
    expect(scrub("Bearer abc.def")).toBe("Bearer [已隐去]");
  });
  it("导出包位置原样保留（真实格式 exports/<uuid>/<13 位毫秒>-<16 位十六进制>.zip），带 / 的 base64 令牌仍隐去（PR #25 Fable 建议 2）", () => {
    const key = "exports/3f2a1b4c-1111-4222-8333-0123456789ab/1732000000000-0123456789abcdef.zip";
    expect(sanitizeDetails({ object_key: key }).object_key).toBe(key);
    expect(scrub(`deletions/3f2a1b4c-1111-4222-8333-0123456789ab/1732000000000-0123456789abcdef.zip`)).not.toContain("[已隐去]");
    const b64 = "q8Zr/3xWm9Kp2Lt7Vn4Ys1Hd6Jf0Bc5G";
    expect(scrub(`x ${b64} y`)).toBe("x [已隐去] y");
    expect(scrub("x 4f1c0e9a8b7d6c5e4f3a2b1c0d9e8f7a6b5c y")).toBe("x [已隐去] y");
  });
  it("从日志转来的告警同样洗过：日志行里带了令牌、口令、开通码也不会出现在消息里", async () => {
    const tap = new LogTap();
    tap.line(JSON.stringify({ level: 50, alert: "account_delete_export_failed", store_id: "s1", attempts: 3, ...secrets, req: { headers: { authorization: `Bearer ${secrets.token}` } }, msg: "导出包生成失败" }));
    const sink = new FakeSink();
    const a = new Alerter({ sink, clock: () => new Date() });
    for (const e of tap.drain().events) await a.event(e);
    const all = JSON.stringify(sink.sent);
    expect(sink.sent).toHaveLength(1);
    for (const s of [secrets.password, secrets.token, secrets.code]) expect(all).not.toContain(s);
    expect(sink.sent[0]!.details).toEqual({ alert: "account_delete_export_failed", store_id: "s1", attempts: "3" });
  });
});

describe("Alerter：去重、静默期、恢复通知", () => {
  const alert = { key: "disk_usage", title: "磁盘", severity: "critical" as const, details: { used_percent: 91 } };
  it("条件类：好→坏发一次，一直坏不重复，满 6 小时再提醒，坏→好发恢复", async () => {
    const clock = new TestClock();
    const sink = new FakeSink();
    const a = new Alerter({ sink, clock: clock.now });
    expect(await a.condition(false, alert)).toBeNull();
    await a.condition(true, alert);
    clock.advance(H);
    await a.condition(true, alert);
    clock.advance(5 * H - 1);
    await a.condition(true, alert);
    expect(sink.kinds()).toEqual(["fire:disk_usage"]);
    clock.advance(1);
    await a.condition(true, alert);
    expect(sink.kinds()).toEqual(["fire:disk_usage", "repeat:disk_usage"]);
    await a.condition(false, { ...alert, details: { used_percent: 60 } });
    await a.condition(false, alert);
    expect(sink.kinds()).toEqual(["fire:disk_usage", "repeat:disk_usage", "resolved:disk_usage"]);
    expect(sink.sent[2]!.text).toContain("已恢复");
    expect(sink.sent[2]!.details.since).toBeDefined();
  });
  it("事件类：静默期 30 分钟内同键只发第一条，之后的一条带上被压下的次数；不同键互不影响", async () => {
    const clock = new TestClock();
    const sink = new FakeSink();
    const a = new Alerter({ sink, clock: clock.now });
    const e = { key: "login_locked:s1", title: "锁定", severity: "warning" as const };
    await a.event(e);
    await a.event(e);
    clock.advance(29 * 60_000);
    await a.event(e);
    await a.event({ ...e, key: "login_locked:s2" });
    expect(sink.kinds()).toEqual(["event:login_locked:s1", "event:login_locked:s2"]);
    clock.advance(60_000);
    await a.event(e);
    expect(sink.sent.at(-1)!.suppressed).toBe(2);
    expect(sink.sent.at(-1)!.text).toContain("另有 2 次");
  });
  it("发送失败：条件类下一轮重试，事件类进待发队列，通道恢复后补发", async () => {
    const clock = new TestClock();
    const sink = new FakeSink();
    const a = new Alerter({ sink, clock: clock.now });
    sink.fail = true;
    await a.condition(true, alert);
    await a.event({ key: "backup_skipped", title: "跳过", severity: "warning" });
    expect(a.firing("disk_usage")).toBe(false);
    sink.fail = false;
    await a.flush();
    await a.condition(true, alert);
    expect(sink.kinds()).toEqual(["event:backup_skipped", "fire:disk_usage"]);
    // 恢复通知发不出去：保持「正在告警」，下一轮再发
    sink.fail = true;
    await a.condition(false, alert);
    expect(a.firing("disk_usage")).toBe(true);
    sink.fail = false;
    await a.condition(false, alert);
    expect(sink.kinds().at(-1)).toBe("resolved:disk_usage");
  });
  it("待发队列满了丢最旧的并计数，通道恢复后补一条「有告警被丢弃」", async () => {
    const sink = new FakeSink();
    const a = new Alerter({ sink, clock: () => new Date(), maxPending: 2 });
    sink.fail = true;
    for (const k of ["a", "b", "c"]) await a.event({ key: k, title: k, severity: "warning" });
    sink.fail = false;
    await a.flush();
    expect(sink.kinds()).toEqual(["event:b", "event:c", "event:alert_queue_overflow"]);
    expect(sink.sent[2]!.details.count).toBe("1");
  });
  it("状态存到文件：重启后不重发正在告警的，恢复通知照样发", async () => {
    const dir = tmp();
    const statePath = join(dir, "state.json");
    const clock = new TestClock();
    const sink = new FakeSink();
    const a1 = new Alerter({ sink, clock: clock.now, statePath });
    await a1.condition(true, alert);
    a1.save();
    const a2 = new Alerter({ sink, clock: clock.now, statePath });
    await a2.condition(true, alert);
    await a2.condition(false, alert);
    expect(sink.kinds()).toEqual(["fire:disk_usage", "resolved:disk_usage"]);
    writeFileSync(statePath, "{坏了");
    expect(new Alerter({ sink, clock: clock.now, statePath }).state.conditions).toEqual({});
  });
});

describe("LogTap：日志解析", () => {
  it("带 alert 字段的行转事件（键带店 id），没有 alert 的、alert 为空的、不是 JSON 的忽略", () => {
    const tap = new LogTap();
    tap.line(JSON.stringify({ level: 40, alert: "account_delete_export", store_id: "s1", object_key: "exports/s1/a.zip", msg: "x" }));
    tap.line(JSON.stringify({ level: 50, alert: "purge_no_archive", due: 2, msg: "x" }));
    tap.line(JSON.stringify({ level: 40, store_id: "s1", attempts: 1, msg: "导出包生成失败" })); // alert: undefined 序列化后没有这个键
    tap.line(JSON.stringify({ level: 50, alert: "未知 名字!", msg: "x" }));
    tap.line("不是 JSON");
    tap.line(JSON.stringify({ level: 50, alert: "something_new", msg: "新告警" }));
    const { events } = tap.drain();
    expect(events.map((e) => [e.key, e.severity])).toEqual([
      ["account_delete_export:s1", "warning"],
      ["purge_no_archive", "critical"],
      ["something_new", "critical"],
    ]);
    expect(events[2]!.title).toBe("新告警");
    expect(tap.drain().events).toEqual([]);
  });
  it("T16 的六个告警名都认得（有固定标题）", () => {
    const tap = new LogTap();
    const names = ["account_delete_export", "account_delete_export_failed", "export_no_archive", "purge_no_archive", "object_discard_failed", "export_discard_lost"];
    for (const n of names) tap.line(JSON.stringify({ level: 50, alert: n, msg: "日志原文" }));
    expect(tap.drain().events.every((e) => e.title !== "日志原文")).toBe(true);
  });
  it("5xx 按一小时滑动窗口数（只数 request completed 的 res.statusCode ≥ 500）", () => {
    const tap = new LogTap();
    const t0 = Date.parse("2026-11-20T02:00:00Z");
    for (let i = 0; i < 21; i++) tap.line(JSON.stringify({ time: t0 + i * 60_000, res: { statusCode: i === 0 ? 503 : 500 }, msg: "request completed" }));
    tap.line(JSON.stringify({ time: t0, res: { statusCode: 499 }, msg: "request completed" }));
    expect(tap.errorsLastHour(new Date(t0 + 30 * 60_000))).toBe(21);
    expect(tap.errorsLastHour(new Date(t0 + H))).toBe(20); // 第一条刚好出窗
    expect(tap.errorsLastHour(new Date(t0 + 2 * H))).toBe(0);
  });
  it("一分钟内事件太多：超过上限的计数，不撑爆内存", () => {
    const tap = new LogTap(() => new Date(), 3);
    for (let i = 0; i < 5; i++) tap.line(JSON.stringify({ alert: "login_locked", store_id: `s${i}` }));
    const d = tap.drain();
    expect(d.events).toHaveLength(3);
    expect(d.dropped).toBe(2);
  });
});

describe("阈值", () => {
  it("备份心跳：营业时间（8:00–22:59）2 小时，其余 6 小时；没有成功记录直接告警", () => {
    const at10 = sh("2026-11-20T10:30:00");
    const s = (d: Date) => d.getTime() / 1000;
    expect(heartbeatVerdict(s(new Date(at10.getTime() - 2 * H)), at10).active).toBe(false);
    expect(heartbeatVerdict(s(new Date(at10.getTime() - 2 * H - 1000)), at10).active).toBe(true);
    const at3 = sh("2026-11-20T03:00:00");
    expect(heartbeatVerdict(s(new Date(at3.getTime() - 5 * H)), at3).active).toBe(false);
    expect(heartbeatVerdict(s(new Date(at3.getTime() - 6 * H - 1000)), at3).active).toBe(true);
    // 7:59 还按 6 小时（02:30 那次到 8:00 有 5.5 小时）
    const at759 = sh("2026-11-20T07:59:00");
    expect(heartbeatVerdict(s(sh("2026-11-20T02:31:00")), at759).active).toBe(false);
    expect(heartbeatVerdict(null, at10)).toMatchObject({ active: true });
    // 8:00 切到 2 小时时不误报（PR #25 Fable 建议 1）：02:30 那份到 8:00 已 5.5 小时，8:00 的备份还在跑，
    // 营业时间的 2 小时只从 8:00 起算；8:00 那份没出来，到 08:30 由 6 小时上限报出来
    const night = s(sh("2026-11-20T02:30:00"));
    for (const t of ["08:00:00", "08:00:30", "08:15:00", "08:30:00"]) expect(heartbeatVerdict(night, sh(`2026-11-20T${t}`)).active, t).toBe(false);
    expect(heartbeatVerdict(night, sh("2026-11-20T08:30:01")).active).toBe(true);
    // 白天照旧 2 小时：08:01 那份之后到 10:01 没新的就报
    expect(heartbeatVerdict(s(sh("2026-11-20T08:01:00")), sh("2026-11-20T10:01:00")).active).toBe(false);
    expect(heartbeatVerdict(s(sh("2026-11-20T08:01:00")), sh("2026-11-20T10:01:01")).active).toBe(true);
    // 夜里那份也没有：6 小时规则在营业时间照样管（01:00 那份到 8:30 已 7.5 小时）
    expect(heartbeatVerdict(s(sh("2026-11-20T01:00:00")), sh("2026-11-20T08:30:00")).active).toBe(true);
  });
  it("营业时间无同步：只数 8:00 之后、21:00 之前；超过 3 小时才告警", () => {
    const last = sh("2026-11-19T20:30:00"); // 昨晚最后一次
    expect(noSyncVerdict(last, sh("2026-11-20T10:59:00")).active).toBe(false);
    expect(noSyncVerdict(last, sh("2026-11-20T11:00:01")).active).toBe(true);
    expect(noSyncVerdict(sh("2026-11-20T12:00:00"), sh("2026-11-20T15:00:00")).active).toBe(false);
    expect(noSyncVerdict(sh("2026-11-20T12:00:00"), sh("2026-11-20T15:00:01")).active).toBe(true);
    expect(noSyncVerdict(sh("2026-11-20T12:00:00"), sh("2026-11-20T21:30:00")).active).toBe(false); // 打烊后不报
    expect(noSyncVerdict(last, sh("2026-11-20T07:00:00")).active).toBe(false);
    expect(shanghaiAt(sh("2026-11-20T00:30:00"), 8).toISOString()).toBe("2026-11-20T00:00:00.000Z");
  });
  it("证书：剩余 < 48 小时或不受信任告警；剩余不到 1/4 有效期算该续没续", () => {
    const nb = new Date("2026-11-20T00:00:00Z");
    const na = new Date(nb.getTime() + 160 * H); // 短期证书约 6.6 天
    const c = { notBefore: nb, notAfter: na, serial: "AB", authorized: true };
    expect(certVerdict(c, new Date(na.getTime() - 48 * H)).active).toBe(false);
    expect(certVerdict(c, new Date(na.getTime() - 47 * H - 1)).active).toBe(true);
    expect(certVerdict({ ...c, authorized: false }, nb).active).toBe(true);
    expect(renewalOverdue(c, new Date(na.getTime() - 41 * H))).toBe(false);
    expect(renewalOverdue(c, new Date(na.getTime() - 39 * H))).toBe(true);
    expect(THRESHOLDS.kuainiaoStoreDaily).toBe(200);
    expect(THRESHOLDS.errorsPerHour).toBe(20);
  });
});

describe("文件解析", () => {
  it("metrics.prom：名字 数值，注释和坏行跳过", () => {
    expect(parseMetrics("# 注释\nyuanhui_backup_last_ok 0\nyuanhui_backup_consecutive_failures 3\n坏行 x\nfoo\n")).toEqual({
      yuanhui_backup_last_ok: 0,
      yuanhui_backup_consecutive_failures: 3,
    });
  });
  it("readNewLines：只读新的完整行，半行等下次，文件变小从头读", () => {
    const f = join(tmp(), "gate-skips.log");
    expect(readNewLines(f, 0)).toEqual({ lines: [], offset: 0 });
    writeFileSync(f, "一\n二\n半");
    const r1 = readNewLines(f, 0);
    expect(r1.lines).toEqual(["一", "二"]);
    appendFileSync(f, "行\n三\n");
    const r2 = readNewLines(f, r1.offset);
    expect(r2.lines).toEqual(["半行", "三"]);
    expect(readNewLines(f, r2.offset).lines).toEqual([]);
    writeFileSync(f, "新\n");
    expect(readNewLines(f, r2.offset).lines).toEqual(["新"]);
  });
});

describe("通道", () => {
  const m = () => buildMessage("event", { key: "k", title: "t", severity: "warning" }, new Date());
  it("WebhookSink：POST JSON，带 Bearer；非 2xx 抛错且错误信息不带地址和令牌", async () => {
    const calls: Array<{ url: string; headers: Record<string, string>; body: string }> = [];
    let status = 200;
    const s = new WebhookSink({ url: "https://hook.example/secret-path", token: "tok123", fetch: async (url, init) => (calls.push({ url, ...init }), { ok: status < 300, status }) });
    await s.send(m());
    expect(calls[0]!.headers.authorization).toBe("Bearer tok123");
    expect(JSON.parse(calls[0]!.body).key).toBe("k");
    status = 502;
    const err = await s.send(m()).catch((e: Error) => e.message);
    expect(err).toBe("webhook HTTP 502");
  });
  it("WebhookSink：请求本身抛错（连不上、超时、地址带凭据）时，错误信息只留主机名和错误类别，不带地址、令牌、原始异常（PR #25 返修）", async () => {
    const url = "https://user:pw-dummy-SECRET@notify.example/hook/PATHSECRET";
    const s = new WebhookSink({
      url,
      token: "TOKSECRET",
      fetch: async (u, init) => {
        throw Object.assign(new TypeError(`fetch failed ${u} ${init.headers.authorization}`), { cause: Object.assign(new Error(`connect ${u}`), { code: "ECONNREFUSED" }) });
      },
    });
    const err = await s.send(m()).catch((e: Error) => e.message);
    expect(err).toBe("webhook 请求失败（notify.example）：TypeError ECONNREFUSED");
    const t = new WebhookSink({ url: "https://notify.example/x", fetch: async () => { throw new Error("weird PATHSECRET"); } });
    expect(await t.send(m()).catch((e: Error) => e.message)).toBe("webhook 请求失败（notify.example）：Error");
  });
  it("生产装配：webhook 地址带凭据、令牌带换行时，「通道发送失败」那条日志里没有令牌和凭据（真 fetch，不出网）", async () => {
    const dir = tmp();
    const logged: string[] = [];
    const log = { warn: (o: object, msg: string) => logged.push(JSON.stringify({ ...o, msg })), error: (o: object, msg: string) => logged.push(JSON.stringify({ ...o, msg })) };
    for (const [webhookUrl, webhookToken] of [
      ["https://user:review-dummy-secret@notify.invalid/hook/PATHSECRET", "TOKSECRET"],
      ["https://notify.invalid/hook/PATHSECRET", "TOK\nSECRET"],
    ] as const) {
      const sink = sinkFromConfig({ dir, backupDir: "", diskPath: "", webhookUrl, webhookToken }, log)!;
      await sink.send(m());
    }
    expect(logged).toHaveLength(2);
    for (const l of logged) {
      expect(l).toContain("notify.invalid");
      for (const secret of ["review-dummy-secret", "user:", "PATHSECRET", "TOKSECRET", "SECRET"]) expect(l).not.toContain(secret);
    }
  });
  it("OutboxSink：一行一条；超过上限留后一半", async () => {
    const f = join(tmp(), "outbox.jsonl");
    const s = new OutboxSink(f, 2000);
    for (let i = 0; i < 20; i++) await s.send(m());
    const lines = readFileSync(f, "utf8").trim().split("\n");
    expect(lines.length).toBeLessThan(20);
    expect(lines.every((l) => JSON.parse(l).key === "k")).toBe(true);
  });
  it("CommandSink：正文走 stdin，退出码非 0 抛错；MultiSink 一个成功就算发出", async () => {
    const got: string[] = [];
    let code = 0;
    const c = new CommandSink("notify", async (cmd, stdin) => (got.push(`${cmd}|${stdin}`), code));
    await c.send(m());
    expect(got[0]).toMatch(/^notify\|\[元辉账本\]\[告警\] t/);
    code = 1;
    await expect(c.send(m())).rejects.toThrow("退出码 1");
    const bad = new FakeSink();
    bad.fail = true;
    const good = new FakeSink();
    const partial: string[] = [];
    await new MultiSink([bad, good], (e) => partial.push(e.message)).send(m());
    expect(good.sent).toHaveLength(1);
    expect(partial).toEqual(["通道不通"]);
    good.fail = true;
    await expect(new MultiSink([bad, good]).send(m())).rejects.toThrow();
  });
});

describe("配置", () => {
  const base = { DATABASE_URL: "postgres://x@localhost/x" };
  it("ALERT_WEBHOOK_URL 只许 https；只配令牌不配地址拒绝；默认不监控", () => {
    expect(loadConfig(base).monitor).toEqual({ dir: "", backupDir: "", diskPath: "", webhookUrl: "", webhookToken: "" });
    expect(() => loadConfig({ ...base, ALERT_WEBHOOK_URL: "http://hook.example" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, ALERT_WEBHOOK_TOKEN: "x" })).toThrow(ConfigError);
    expect(loadConfig({ ...base, ALERT_WEBHOOK_URL: "https://hook.example", MONITOR_DIR: "/data/monitor" }).monitor.webhookUrl).toBe("https://hook.example");
    // 地址里带用户名口令、令牌里有空白或控制字符：启动时拒绝（PR #25 返修）
    expect(() => loadConfig({ ...base, ALERT_WEBHOOK_URL: "https://u:p@hook.example" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, ALERT_WEBHOOK_URL: "https://hook.example", ALERT_WEBHOOK_TOKEN: "a\nb" })).toThrow(ConfigError);
    expect(() => loadConfig({ ...base, ALERT_WEBHOOK_URL: "https://hook.example", ALERT_WEBHOOK_TOKEN: "a b" })).toThrow(ConfigError);
    expect(loadConfig({ ...base, ALERT_WEBHOOK_URL: "https://hook.example", ALERT_WEBHOOK_TOKEN: "abc-123_x.y" }).monitor.webhookToken).toBe("abc-123_x.y");
  });
});

describe("本机探测（scripts/probe.ts）", () => {
  function setup(o: Partial<ProbeDeps> = {}) {
    const clock = new TestClock(Date.parse("2026-11-20T02:00:00Z"));
    const sink = new FakeSink();
    const stateDir = tmp();
    const alerter = new Alerter({ sink, clock: clock.now, statePath: join(stateDir, "state.json") });
    let health = { ok: true, status: 200 as number | string };
    let cert = { notBefore: new Date(clock.t - 24 * H), notAfter: new Date(clock.t + 136 * H), serial: "01", authorized: true };
    let outbox = "";
    let sshOk = true;
    const deps: ProbeDeps = {
      alerter,
      sink,
      clock: clock.now,
      stateDir,
      baseUrl: "https://203.0.113.1",
      health: async () => health,
      cert: async () => cert,
      pullOutbox: async () => {
        if (!sshOk) throw new Error("ssh 失败");
        return outbox;
      },
      ...o,
    };
    return {
      clock,
      sink,
      stateDir,
      deps,
      setHealth: (h: typeof health) => (health = h),
      setCert: (c: typeof cert) => (cert = c),
      setOutbox: (s: string) => (outbox = s),
      setSsh: (v: boolean) => (sshOk = v),
      renewals: () => (existsSync(join(stateDir, "cert-renewals.jsonl")) ? readFileSync(join(stateDir, "cert-renewals.jsonl"), "utf8").trim().split("\n").map((l) => JSON.parse(l).event) : []),
    };
  }
  it("/healthz 连续 2 次失败才告警（失败次数存在状态文件里，跨进程），恢复后发恢复", async () => {
    const t = setup();
    t.setHealth({ ok: false, status: 503 });
    await runProbe(t.deps);
    expect(t.sink.kinds()).toEqual([]);
    // 新进程（launchd 每次起一个）：从状态文件接着数
    const a2 = new Alerter({ sink: t.sink, clock: t.clock.now, statePath: join(t.stateDir, "state.json") });
    await runProbe({ ...t.deps, alerter: a2 });
    expect(t.sink.kinds()).toEqual(["fire:healthz_down"]);
    await runProbe({ ...t.deps, alerter: a2 });
    t.setHealth({ ok: true, status: 200 });
    await runProbe({ ...t.deps, alerter: a2 });
    expect(t.sink.kinds()).toEqual(["fire:healthz_down", "resolved:healthz_down"]);
  });
  it("连不上（抛错）也算失败，错误信息洗过", async () => {
    const t = setup({ health: async () => Promise.reject(new Error("connect ECONNREFUSED 9f3abcdefabcdefabcdefabcdefabcdef")) });
    await runProbe(t.deps);
    await runProbe(t.deps);
    expect(t.sink.sent[0]!.text).not.toContain("abcdefabcdefabcdefabcdef");
  });
  it("证书：< 48 小时告警，续期成功后恢复；续期 / 该续没续记进 cert-renewals.jsonl", async () => {
    const t = setup();
    await runProbe(t.deps);
    expect(t.renewals()).toEqual(["first_seen"]);
    t.clock.advance(100 * H); // 剩 36 小时：过了 1/4 线（40 小时），也过了 48 小时线
    await runProbe(t.deps);
    await runProbe(t.deps);
    expect(t.sink.kinds()).toEqual(["fire:ip_cert_expiry"]);
    expect(t.renewals()).toEqual(["first_seen", "renewal_overdue"]); // 同一张只记一次
    t.setCert({ notBefore: t.clock.now(), notAfter: new Date(t.clock.t + 160 * H), serial: "02", authorized: true });
    await runProbe(t.deps);
    expect(t.sink.kinds()).toEqual(["fire:ip_cert_expiry", "resolved:ip_cert_expiry"]);
    expect(t.renewals()).toEqual(["first_seen", "renewal_overdue", "renewed"]);
  });
  it("服务器 outbox：只转没转过的，第一次只转 24 小时内的；发不出去游标不前进", async () => {
    const t = setup();
    const at = (h: number) => new Date(t.clock.t - h * H);
    const old = buildMessage("event", { key: "old", title: "旧", severity: "warning" }, at(30));
    const m1 = buildMessage("event", { key: "backup_failed", title: "最近一次备份失败", severity: "warning", details: { token: "x1".repeat(20), consecutive_failures: 1 } }, at(1));
    const m2 = buildMessage("fire", { key: "disk_usage", title: "磁盘", severity: "critical" }, at(0.5));
    t.setOutbox([old, m1, m2].map((m) => JSON.stringify({ ...m, text: `${m.text} 令牌 ${"y2".repeat(20)}` })).join("\n") + "\n坏行\n");
    await runProbe(t.deps);
    expect(t.sink.kinds()).toEqual(["event:backup_failed", "fire:disk_usage"]);
    expect(t.sink.sent[0]!.title).toContain("（来自服务器）");
    expect(JSON.stringify(t.sink.sent)).not.toMatch(/(x1){20}|(y2){20}/); // 远端写的 text 不直接信
    await runProbe(t.deps);
    expect(t.sink.sent).toHaveLength(2);
    const m3 = buildMessage("event", { key: "k3", title: "三", severity: "warning" }, t.clock.now());
    const c: { outboxId?: string } = { outboxId: m2.id };
    const s2 = new FakeSink();
    s2.fail = true;
    expect(await forwardOutbox(JSON.stringify(m3), c, { sink: s2, clock: t.clock.now })).toBe(0);
    expect(c.outboxId).toBe(m2.id);
  });
  it("服务器 outbox 里的 details 不可信：本机按白名单再洗一遍（去掉 forwardOutbox 的 sanitizeDetails 这条就失败，PR #25 Fable 建议 5）", async () => {
    const t = setup();
    const tok = "4f1c0e9a8b7d6c5e4f3a2b1c0d9e8f7a6b5c4d3e";
    // 手写一行（不经 buildMessage）：模拟服务器侧白名单出错或 outbox 被改过
    const line = JSON.stringify({ id: "000001", at: t.clock.now().toISOString(), kind: "event", key: "backup_failed", severity: "warning", title: "备份失败", details: { password: "hunter2-pw", code: "PAIR-839201", reason: `token=${tok}`, nested: { a: 1 }, count: 2 }, text: "x" });
    const sink = new FakeSink();
    expect(await forwardOutbox(line, {}, { sink, clock: t.clock.now })).toBe(1);
    const sent = sink.sent[0]!;
    expect(Object.keys(sent.details).sort()).toEqual(["count", "reason"]);
    for (const secret of ["hunter2-pw", "PAIR-839201", tok, "nested"]) expect(JSON.stringify(sent)).not.toContain(secret);
  });
  it("ssh 连续 3 次拉不到 outbox 告警，拉到了恢复", async () => {
    const t = setup();
    t.setSsh(false);
    for (let i = 0; i < 3; i++) await runProbe(t.deps);
    expect(t.sink.kinds()).toEqual(["fire:outbox_unreachable"]);
    t.setSsh(true);
    await runProbe(t.deps);
    expect(t.sink.kinds()).toEqual(["fire:outbox_unreachable", "resolved:outbox_unreachable"]);
  });
});
