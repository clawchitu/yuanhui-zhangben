import { defineConfig } from "vitest/config";

export default defineConfig({
  // 登录类测试每次都算真实的 argon2id；机器忙的时候（共享的 Mac、2 核 CI）单条用例可能超过默认的 5 秒
  // setupFiles：设了 TEST_SHIFT_NOW 时把「现在」平移到那一天，验证测试不随真实日期推进而失败（见 test/setup/shift-now.ts）
  test: { include: ["test/**/*.test.ts"], testTimeout: 30_000, hookTimeout: 30_000, setupFiles: ["test/setup/shift-now.ts"] },
});
