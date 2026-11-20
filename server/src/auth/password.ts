// 密码：argon2id。账号只能用 scripts/create-account.ts 建（§3.1），改密码走 POST /v1/account/password。
import argon2 from "argon2";

/** 密码最短 8 位（§14 S02-6）；最长和契约 password maxLength 一致 */
export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 256;

export async function hashPassword(password: string): Promise<string> {
  return argon2.hash(password, { type: argon2.argon2id });
}

// 账号不存在时也算一次 argon2，响应时间不泄露「有没有这个账号」
let dummy: Promise<string> | undefined;

export async function verifyPassword(hash: string | undefined, password: string): Promise<boolean> {
  if (hash === undefined) {
    dummy ??= hashPassword("not-a-real-password");
    await argon2.verify(await dummy, password).catch(() => false);
    return false;
  }
  try {
    return await argon2.verify(hash, password);
  } catch {
    return false; // 库里的哈希格式坏了：按密码错处理
  }
}
