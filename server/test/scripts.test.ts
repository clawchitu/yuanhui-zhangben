// scripts/create-store.ts、create-account.ts：函数调用和命令行各测一遍。
import { execFile } from "node:child_process";
import { resolve } from "node:path";
import argon2 from "argon2";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { createStore } from "../scripts/create-store.ts";
import { createAccount } from "../scripts/create-account.ts";
import { createTestDb, type TestDb } from "./helpers/db.ts";

const SCRIPTS = resolve(import.meta.dirname, "../scripts");

let t: TestDb;
beforeAll(async () => {
  t = await createTestDb();
});
afterAll(() => t.drop());

function cli(script: string, args: string[], opts: { stdin?: string; env?: Record<string, string> } = {}) {
  return new Promise<{ code: number; stdout: string; stderr: string }>((res) => {
    const child = execFile(
      process.execPath,
      [resolve(SCRIPTS, script), ...args],
      { env: { PATH: process.env.PATH ?? "", DATABASE_URL: t.url, ...opts.env } },
      (err, stdout, stderr) => res({ code: err ? ((err as { code?: number }).code ?? 1) : 0, stdout, stderr }),
    );
    child.stdin?.end(opts.stdin ?? "");
  });
}

describe("createStore", () => {
  it("建店：默认非演示、低库存默认 3、rev 0、有 epoch", async () => {
    const s = await createStore(t.kysely, { name: " 江阴市周庄元辉烟酒店 " });
    const row = await t.kysely.selectFrom("stores").selectAll().where("id", "=", s.id).executeTakeFirstOrThrow();
    expect(row).toMatchObject({ name: "江阴市周庄元辉烟酒店", is_demo: false, low_stock_default: 3, rev: "0", epoch: s.epoch });
  });

  it("空店名、负的低库存默认值被拒", async () => {
    await expect(createStore(t.kysely, { name: "  " })).rejects.toThrow(/店名/);
    await expect(createStore(t.kysely, { name: "x", lowStockDefault: -1 })).rejects.toThrow();
  });
});

describe("createAccount", () => {
  it("建家用号：密码存 argon2id 哈希，能验证，库里没有明文", async () => {
    const s = await createStore(t.kysely, { name: "店A" });
    const a = await createAccount(t.kysely, { storeId: s.id, username: "HuangA", password: "correct horse 1" });
    const row = await t.kysely.selectFrom("accounts").selectAll().where("id", "=", a.id).executeTakeFirstOrThrow();
    expect(row.kind).toBe("family");
    expect(row.password_hash).toMatch(/^\$argon2id\$/);
    expect(row.password_hash).not.toContain("correct horse");
    expect(await argon2.verify(row.password_hash, "correct horse 1")).toBe(true);
    expect(await argon2.verify(row.password_hash, "wrong")).toBe(false);
  });

  it("用户名大小写不同也算重复", async () => {
    const s1 = await createStore(t.kysely, { name: "店B1" });
    const s2 = await createStore(t.kysely, { name: "店B2" });
    await createAccount(t.kysely, { storeId: s1.id, username: "dupuser", password: "12345678" });
    await expect(createAccount(t.kysely, { storeId: s2.id, username: "DupUser", password: "12345678" })).rejects.toMatchObject({
      code: "23505",
    });
  });

  it("审核号只能建在演示店，家用号只能建在非演示店", async () => {
    const demo = await createStore(t.kysely, { name: "演示小店", isDemo: true });
    const real = await createStore(t.kysely, { name: "店C" });
    await expect(createAccount(t.kysely, { storeId: real.id, username: "rv1", password: "12345678", kind: "review" })).rejects.toThrow(/演示店/);
    await expect(createAccount(t.kysely, { storeId: demo.id, username: "fm1", password: "12345678" })).rejects.toThrow(/演示店/);
    await expect(createAccount(t.kysely, { storeId: demo.id, username: "rv2", password: "12345678", kind: "review" })).resolves.toBeTruthy();
  });

  it("密码长度边界：7 位拒、8 位可以、256 位可以、257 位拒", async () => {
    const mk = async (len: number, u: string) =>
      createAccount(t.kysely, { storeId: (await createStore(t.kysely, { name: `长度${u}` })).id, username: u, password: "x".repeat(len) });
    await expect(mk(7, "len7")).rejects.toThrow(/密码长度/);
    await expect(mk(8, "len8")).resolves.toBeTruthy();
    await expect(mk(256, "len256")).resolves.toBeTruthy();
    await expect(mk(257, "len257")).rejects.toThrow(/密码长度/);
  });

  it("密码太短、用户名带空格、店不存在都被拒", async () => {
    const s = await createStore(t.kysely, { name: "店D" });
    await expect(createAccount(t.kysely, { storeId: s.id, username: "d1", password: "short" })).rejects.toThrow(/密码/);
    await expect(createAccount(t.kysely, { storeId: s.id, username: "a b", password: "12345678" })).rejects.toThrow(/空格/);
    await expect(
      createAccount(t.kysely, { storeId: "00000000-0000-4000-8000-000000000000", username: "d2", password: "12345678" }),
    ).rejects.toThrow(/店不存在/);
  });
});

describe("命令行", () => {
  it("create-store → create-account（密码从标准输入读，不出现在输出里）", async () => {
    const s = await cli("create-store.ts", ["--name", "命令行店"]);
    expect(s.code, s.stderr).toBe(0);
    const { id } = JSON.parse(s.stdout);
    const a = await cli("create-account.ts", ["--store", id, "--username", "cliuser"], { stdin: "s3cret-pass-xyz\n" });
    expect(a.code, a.stderr).toBe(0);
    expect(a.stdout + a.stderr).not.toContain("s3cret-pass-xyz");
    const row = await t.kysely.selectFrom("accounts").selectAll().where("username", "=", "cliuser").executeTakeFirstOrThrow();
    expect(row.store_id).toBe(id);
    expect(await argon2.verify(row.password_hash, "s3cret-pass-xyz")).toBe(true);
  });

  it("重复用户名时退出码非 0，提示中文原因", async () => {
    const s = JSON.parse((await cli("create-store.ts", ["--name", "命令行店2"])).stdout);
    const a = await cli("create-account.ts", ["--store", s.id, "--username", "CLIUSER"], { stdin: "another-pass\n" });
    expect(a.code).not.toBe(0);
    expect(a.stderr).toContain("用户名已被占用");
  });

  it("密码也可以从环境变量 ACCOUNT_PASSWORD 读；失败时输出里不带密码", async () => {
    const s = JSON.parse((await cli("create-store.ts", ["--name", "命令行店3"])).stdout);
    const ok = await cli("create-account.ts", ["--store", s.id, "--username", "envuser"], { env: { ACCOUNT_PASSWORD: "env-pass-12345" } });
    expect(ok.code, ok.stderr).toBe(0);
    const row = await t.kysely.selectFrom("accounts").selectAll().where("username", "=", "envuser").executeTakeFirstOrThrow();
    expect(await argon2.verify(row.password_hash, "env-pass-12345")).toBe(true);
    // 太短被拒，错误信息里不回显密码
    const s2 = JSON.parse((await cli("create-store.ts", ["--name", "命令行店4"])).stdout);
    const bad = await cli("create-account.ts", ["--store", s2.id, "--username", "short1"], { stdin: "pw7char\n" });
    expect(bad.code).not.toBe(0);
    expect(bad.stdout + bad.stderr).not.toContain("pw7char");
    expect(bad.stderr).toContain("密码长度");
  });

  it("缺参数时打印用法，退出码 2", async () => {
    const r = await cli("create-store.ts", []);
    expect(r.code).toBe(2);
    expect(r.stderr).toContain("用法");
  });
});

