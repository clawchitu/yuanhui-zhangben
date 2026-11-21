// S10c：本机探测当成进程跑一遍（node scripts/probe.ts）——配置检查、真的连 TLS 读证书、真的探 /healthz、真的经 PROBE_NOTIFY_CMD 发出去。
// 服务器是本机起的 https（openssl 现签一张 1 天的 IP 证书，NODE_EXTRA_CA_CERTS 让探测信任它），不连任何外部地址。
import { execFile, execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
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

  it("--test-alert 发一条通道测试", async () => {
    await run(env(), ["--test-alert"]);
    expect(text()).toContain("告警通道测试");
  });
});
