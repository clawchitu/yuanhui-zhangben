import { defineConfig } from "vitest/config";

export default defineConfig({
  // 登录类测试每次都算真实的 argon2id；机器忙的时候（共享的 Mac、2 核 CI）单条用例可能超过默认的 5 秒
  test: { include: ["test/**/*.test.ts"], testTimeout: 30_000, hookTimeout: 30_000 },
});
