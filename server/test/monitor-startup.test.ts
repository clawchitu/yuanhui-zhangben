// S10c 返修（PR #25 两边必须改 1）：监控状态文件 state.json 坏了，api 照常启动（记一条警告、从空状态开始），
// 不能因为 server.ts 里 app 还没建好就记日志而崩溃、进重启循环。走真的 `node src/server.ts` 装配顺序。
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createTestDb, type TestDb } from "./helpers/db.ts";

const SERVER = join(import.meta.dirname, "..", "src", "server.ts");

describe("server.ts 启动：监控状态文件损坏", () => {
  let tdb: TestDb;
  const dir = mkdtempSync(join(tmpdir(), "yh-monstart-"));
  beforeAll(async () => {
    tdb = await createTestDb();
  });
  afterAll(async () => {
    await tdb.drop();
    rmSync(dir, { recursive: true, force: true });
  });

  it("坏的 state.json：记一条警告、重置为空状态、照常监听", async () => {
    writeFileSync(join(dir, "state.json"), '{"conditions":');
    const out = await new Promise<{ listening: boolean; code: number | null; log: string }>((resolve) => {
      const p = spawn(process.execPath, [SERVER], {
        env: { PATH: process.env.PATH ?? "", DATABASE_URL: tdb.url, HOST: "127.0.0.1", PORT: String(40000 + Math.floor(Math.random() * 20000)), MONITOR_DIR: dir },
        stdio: ["ignore", "pipe", "pipe"],
      });
      let log = "";
      let listening = false;
      const done = (code: number | null) => resolve({ listening, code, log });
      const onData = (b: Buffer) => {
        log += b.toString();
        if (!listening && /Server listening/.test(log)) {
          listening = true;
          p.kill("SIGTERM");
        }
      };
      p.stdout.on("data", onData);
      p.stderr.on("data", onData);
      p.on("close", done);
      setTimeout(() => p.kill("SIGKILL"), 20_000);
    });
    expect(out.log).not.toMatch(/ReferenceError/);
    expect(out.listening).toBe(true);
    expect(out.log).toContain("监控状态文件坏了，从空状态开始");
    // 空状态会在下一次保存时覆盖坏文件；这里只确认坏文件没让进程退出
    expect(readFileSync(join(dir, "state.json"), "utf8").length).toBeGreaterThan(0);
  }, 30_000);
});
