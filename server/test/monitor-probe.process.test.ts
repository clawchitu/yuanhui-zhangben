// S10c：本机探测当成进程跑一遍（node scripts/probe.ts）——配置检查、真的连 TLS 读证书、真的探 /healthz、真的经 PROBE_NOTIFY_CMD 发出去。
// 服务器是本机起的 https（openssl 现签一张 1 天的 IP 证书，NODE_EXTRA_CA_CERTS 让探测信任它），不连任何外部地址。
import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:https";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

const PROBE = join(import.meta.dirname, "..", "scripts", "probe.ts");

function run(env: Record<string, string>, args: string[] = []): Promise<{ code: number; stderr: string }> {
  return new Promise((resolve) => {
    // 只给这几个变量：不继承本机的 PROBE_*（免得测试连到真地址）
    execFile(process.execPath, [PROBE, ...args], { env: { PATH: process.env.PATH ?? "", HOME: tmpdir(), ...env }, timeout: 30_000 }, (err, _out, stderr) =>
      resolve({ code: err ? ((err as { code?: number }).code ?? 1) : 0, stderr }),
    );
  });
}

describe("本机探测进程（scripts/probe.ts）", () => {
  const dir = mkdtempSync(join(tmpdir(), "yh-probe-"));
  let server: Server;
  let status = 200;
  let base = "";
  const sent = join(dir, "sent.txt");
  const env = () => ({
    PROBE_URL: base,
    PROBE_STATE_DIR: join(dir, "state"),
    PROBE_NOTIFY_CMD: `cat >> '${sent}'`,
    NODE_EXTRA_CA_CERTS: join(dir, "cert.pem"),
  });
  const text = () => (existsSync(sent) ? readFileSync(sent, "utf8") : "");

  beforeAll(async () => {
    execFileSync("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1", "-subj", "/CN=127.0.0.1", "-addext", "subjectAltName=IP:127.0.0.1", "-keyout", join(dir, "key.pem"), "-out", join(dir, "cert.pem")], { stdio: "ignore" });
    server = createServer({ key: readFileSync(join(dir, "key.pem")), cert: readFileSync(join(dir, "cert.pem")) }, (req, res) => {
      res.statusCode = req.url === "/healthz" ? status : 404;
      res.end("{}");
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    base = `https://127.0.0.1:${(server.address() as AddressInfo).port}`;
  });
  afterAll(() => {
    server?.close();
    rmSync(dir, { recursive: true, force: true });
  });

  it("配置不对退出码 2：没有 PROBE_URL、不是 https、一个通道都没配", async () => {
    expect((await run({ PROBE_NOTIFY_CMD: "cat" })).code).toBe(2);
    expect((await run({ PROBE_URL: "http://127.0.0.1", PROBE_NOTIFY_CMD: "cat" })).code).toBe(2);
    expect((await run({ PROBE_URL: "https://127.0.0.1" })).code).toBe(2);
    // PROBE_WEBHOOK_URL 同服务器侧：只许 https、不许带用户名口令（PR #25 返修）
    expect((await run({ PROBE_URL: "https://127.0.0.1", PROBE_WEBHOOK_URL: "http://hook.example" })).code).toBe(2);
    expect((await run({ PROBE_URL: "https://127.0.0.1", PROBE_WEBHOOK_URL: "https://u:p@hook.example" })).code).toBe(2);
  });

  it("证书剩 1 天 → 告警（经 PROBE_NOTIFY_CMD 发出）并记 first_seen；/healthz 连续 2 次 503 → 告警；恢复 200 → 已恢复", async () => {
    let r = await run(env());
    expect(r.code).toBe(0);
    expect(text()).toContain("IP 证书剩余有效期不到 48 小时");
    expect(text()).toMatch(/hours_left：2[0-4]/);
    expect(text()).not.toContain("服务探活");
    expect(readFileSync(join(dir, "state", "cert-renewals.jsonl"), "utf8")).toContain('"event":"first_seen"');

    status = 503;
    await run(env());
    expect(text()).not.toContain("服务探活");
    r = await run(env());
    expect(r.code).toBe(0);
    expect(text()).toContain("服务探活连续失败");
    expect(text()).toContain("status：503");

    status = 200;
    await run(env());
    expect(text()).toMatch(/\[已恢复\] 服务探活连续失败/);
    // 证书一直没换：不重复发（6 小时内）
    expect(text().match(/IP 证书剩余有效期不到 48 小时/g)).toHaveLength(1);
  });

  it("域名站点（PROBE_SITES）：带 SNI 读证书并校验域名——证书剩 1 天告警；证书上的域名对不上也告警；配置不是 https 退出码 2", async () => {
    // 两张证书：localhost 的（对得上）和 wrong.test 的（连 localhost 时对不上）；两张都放进信任列表，所以「对不上」只能是域名校验抓到的
    const mk = (name: string, san: string) =>
      execFileSync("openssl", ["req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes", "-days", "1", "-subj", `/CN=${san}`, "-addext", `subjectAltName=DNS:${san}`, "-keyout", join(dir, `${name}-key.pem`), "-out", join(dir, `${name}.pem`)], { stdio: "ignore" });
    mk("good", "localhost");
    mk("wrong", "wrong.test");
    writeFileSync(join(dir, "ca.pem"), ["cert", "good", "wrong"].map((n) => readFileSync(join(dir, `${n}.pem`), "utf8")).join(""));
    const serve = async (name: string) => {
      const srv = createServer({ key: readFileSync(join(dir, `${name}-key.pem`)), cert: readFileSync(join(dir, `${name}.pem`)) }, (req, res) => {
        res.statusCode = req.url === "/healthz" || req.url === "/" ? 200 : 404;
        res.end("ok");
      });
      await new Promise<void>((r) => srv.listen(0, "127.0.0.1", () => r()));
      return { srv, port: (srv.address() as AddressInfo).port };
    };
    const good = await serve("good");
    const wrong = await serve("wrong");
    const sent2 = join(dir, "sent2.txt");
    const envSites = (sites: string) => ({
      PROBE_URL: base,
      PROBE_STATE_DIR: join(dir, "state2"),
      PROBE_NOTIFY_CMD: `cat >> '${sent2}'`,
      PROBE_SITES: sites,
      NODE_EXTRA_CA_CERTS: join(dir, "ca.pem"),
    });
    try {
      // localhost 在有的机器上先解析成 ::1，两个服务只听 127.0.0.1：用 --dns-result-order 固定先 IPv4
      const sites = `https://localhost:${good.port}/healthz, https://localhost:${wrong.port}/`;
      expect((await run({ ...envSites("http://localhost/") })).code).toBe(2);
      const r = await run({ ...envSites(sites), NODE_OPTIONS: "--dns-result-order=ipv4first" });
      expect(r.code).toBe(0);
      const out = readFileSync(sent2, "utf8");
      const block = (port: number) => out.split("\n[").find((b) => b.includes(`键：site_cert:localhost:${port}`)) ?? "";
      // 对得上的那张：只因为剩 0 天告警，没有「不受信任」
      expect(block(good.port)).toContain(`域名 localhost:${good.port} 的证书剩余不到 14 天`);
      expect(block(good.port)).toContain("days_left：0");
      expect(block(good.port)).not.toContain("reason");
      // 对不上的那张：域名校验抓到
      expect(block(wrong.port)).toContain("证书链不受信任或域名对不上");
      // IP 那条照旧（信任列表里有它的证书）
      expect(out).not.toContain("reason：证书链不受信任\n");
      expect(out).not.toContain("连续探测失败");
      expect(readFileSync(join(dir, "state2", "cert-renewals.jsonl"), "utf8")).toContain(`"host":"localhost:${good.port}"`);
    } finally {
      good.srv.close();
      wrong.srv.close();
    }
  });

  it("--test-alert 发一条通道测试", async () => {
    await run(env(), ["--test-alert"]);
    expect(text()).toContain("告警通道测试");
  });
});
