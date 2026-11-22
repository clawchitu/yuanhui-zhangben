// S21：API_BASE 不在白名单时 `node src/server.ts` 拒绝启动：退出码非 0，日志说清是 API_BASE，不打印其他环境变量。
import { spawn } from "node:child_process";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const SERVER = join(import.meta.dirname, "..", "src", "server.ts");

function start(apiBase: string): Promise<{ code: number | null; listening: boolean; log: string }> {
  return new Promise((resolve) => {
    const p = spawn(process.execPath, [SERVER], {
      env: {
        PATH: process.env.PATH ?? "",
        // 连不上也没关系：校验在连库之前；口令用来检查日志不泄漏
        DATABASE_URL: "postgres://yuanhui:Sekr3tPw@127.0.0.1:1/yuanhui",
        KUAINIAO_APPCODE: "AppC0deSekr3t",
        HOST: "127.0.0.1",
        PORT: String(40000 + Math.floor(Math.random() * 20000)),
        API_BASE: apiBase,
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let log = "";
    let listening = false;
    const onData = (b: Buffer) => {
      log += b.toString();
      if (!listening && /Server listening/.test(log)) {
        listening = true;
        p.kill("SIGTERM");
      }
    };
    p.stdout.on("data", onData);
    p.stderr.on("data", onData);
    p.on("close", (code) => resolve({ code, listening, log }));
    setTimeout(() => p.kill("SIGKILL"), 20_000);
  });
}

describe("server.ts 启动：API_BASE 白名单（S21）", () => {
  const bad = [
    "https://evil.example",
    "https://api.yuanhuishop.cn.evil.example",
    "https://evil.api.yuanhuishop.cn",
    "https://evil.example@api.yuanhuishop.cn",
    "http://47.117.184.253",
    "https://api.yuanhuishop.cn:8443",
    "https://api.yuanhuishop.cn/x",
  ];
  it.each(bad)("拒绝启动：%s", async (b) => {
    const out = await start(b);
    expect(out.listening).toBe(false);
    expect(out.code).not.toBe(0);
    expect(out.log).toContain("API_BASE");
    expect(out.log).toContain("配置错误");
    expect(out.log).not.toContain("Sekr3tPw");
    expect(out.log).not.toContain("AppC0deSekr3t");
    // 一行 JSON，不是未捕获异常的堆栈
    expect(out.log).not.toMatch(/\n\s+at /);
  });
});
