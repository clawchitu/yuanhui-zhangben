// 备份加密（§9.4「用口令加密」）：scrypt 从口令派生 256 位密钥，AES-256-GCM 流式加密，认证标签放在文件末尾。
// 文件格式：'YHBK' | 版本 1 | log2(N) | r | p | 盐 16 字节 | IV 12 字节 | 密文 | 标签 16 字节。头部整体作为附加认证数据，
// 改了参数、盐、IV、密文或标签任何一个字节，解密都失败（不会吐出半截明文：先写临时文件，标签验过才改名）。
// 解开只需要这个仓库的 restore 和另存两处的口令（§9.1），不依赖 ECS 上的任何东西。
import { createCipheriv, createDecipheriv, createHash, randomBytes, scrypt } from "node:crypto";
import { createReadStream, createWriteStream } from "node:fs";
import { open, rename, rm, stat } from "node:fs/promises";
import { Readable, Transform } from "node:stream";
import { pipeline } from "node:stream/promises";

const MAGIC = Buffer.from("YHBK", "ascii");
const VERSION = 1;
const HEADER_LEN = 4 + 1 + 3 + 16 + 12;
const TAG_LEN = 16;
const LOG_N = 15;
const R = 8;
const P = 1;

export class BackupCryptoError extends Error {}

export function assertPassphrase(p: string | undefined): asserts p is string {
  if (!p || p.length < 20) throw new BackupCryptoError("BACKUP_PASSPHRASE 至少 20 位（openssl rand -base64 32）");
}

function deriveKey(passphrase: string, salt: Buffer, logN: number, r: number, p: number): Promise<Buffer> {
  if (logN < 14 || logN > 20 || r < 1 || r > 16 || p < 1 || p > 4) return Promise.reject(new BackupCryptoError("加密参数不对"));
  return new Promise((resolve, reject) =>
    scrypt(passphrase, salt, 32, { N: 2 ** logN, r, p, maxmem: 256 * 1024 * 1024 }, (e, k) => (e ? reject(e) : resolve(k))),
  );
}

function header(): Buffer {
  return Buffer.concat([MAGIC, Buffer.from([VERSION, LOG_N, R, P]), randomBytes(16), randomBytes(12)]);
}

function parseHeader(h: Buffer): { logN: number; r: number; p: number; salt: Buffer; iv: Buffer } {
  if (h.length < HEADER_LEN || !h.subarray(0, 4).equals(MAGIC)) throw new BackupCryptoError("不是元辉账本的备份文件");
  if (h[4] !== VERSION) throw new BackupCryptoError(`不认识的备份格式版本 ${h[4]}`);
  return { logN: h[5]!, r: h[6]!, p: h[7]!, salt: h.subarray(8, 24), iv: h.subarray(24, 36) };
}

/** 加密一个文件。返回明文的 sha256（写进清单，恢复时核对）和明文字节数 */
export async function encryptFile(src: string, dst: string, passphrase: string): Promise<{ sha256: string; bytes: number }> {
  assertPassphrase(passphrase);
  const h = header();
  const { logN, r, p, salt, iv } = parseHeader(h);
  const c = createCipheriv("aes-256-gcm", await deriveKey(passphrase, salt, logN, r, p), iv);
  c.setAAD(h);
  const sha = createHash("sha256");
  let bytes = 0;
  const tap = new Transform({
    transform(chunk: Buffer, _e, cb) {
      sha.update(chunk);
      bytes += chunk.length;
      cb(null, chunk);
    },
  });
  const out = createWriteStream(dst, { mode: 0o600 });
  out.write(h);
  await pipeline(createReadStream(src), tap, c, out, { end: false });
  await new Promise<void>((res, rej) => out.end(c.getAuthTag(), (e?: Error | null) => (e ? rej(e) : res())));
  return { sha256: sha.digest("hex"), bytes };
}

/** 解密到 dst；口令不对或文件被改过 → BackupCryptoError，dst 不会出现。返回明文的 sha256 */
export async function decryptFile(src: string, dst: string, passphrase: string): Promise<{ sha256: string; bytes: number }> {
  assertPassphrase(passphrase);
  const size = (await stat(src)).size;
  if (size < HEADER_LEN + TAG_LEN) throw new BackupCryptoError("备份文件太短");
  const fh = await open(src, "r");
  const h = Buffer.alloc(HEADER_LEN);
  const tag = Buffer.alloc(TAG_LEN);
  try {
    await fh.read(h, 0, HEADER_LEN, 0);
    await fh.read(tag, 0, TAG_LEN, size - TAG_LEN);
  } finally {
    await fh.close();
  }
  const { logN, r, p, salt, iv } = parseHeader(h);
  const d = createDecipheriv("aes-256-gcm", await deriveKey(passphrase, salt, logN, r, p), iv);
  d.setAAD(h);
  d.setAuthTag(tag);
  const sha = createHash("sha256");
  let bytes = 0;
  const tap = new Transform({
    transform(chunk: Buffer, _e, cb) {
      sha.update(chunk);
      bytes += chunk.length;
      cb(null, chunk);
    },
  });
  const tmp = `${dst}.${randomBytes(6).toString("hex")}.part`;
  try {
    const body = size - TAG_LEN - HEADER_LEN;
    const input = body > 0 ? createReadStream(src, { start: HEADER_LEN, end: size - TAG_LEN - 1 }) : Readable.from([]);
    await pipeline(input, d, tap, createWriteStream(tmp, { mode: 0o600 }));
  } catch (e) {
    await rm(tmp, { force: true });
    if (e instanceof BackupCryptoError) throw e;
    throw new BackupCryptoError(`解密失败（口令不对或文件被改过）：${(e as Error).message}`);
  }
  await rename(tmp, dst);
  return { sha256: sha.digest("hex"), bytes };
}

/** 小块数据（清单）：同一格式，整块在内存里 */
export async function encryptBuffer(plain: Buffer, passphrase: string): Promise<Buffer> {
  assertPassphrase(passphrase);
  const h = header();
  const { logN, r, p, salt, iv } = parseHeader(h);
  const c = createCipheriv("aes-256-gcm", await deriveKey(passphrase, salt, logN, r, p), iv);
  c.setAAD(h);
  return Buffer.concat([h, c.update(plain), c.final(), c.getAuthTag()]);
}

export async function decryptBuffer(enc: Buffer, passphrase: string): Promise<Buffer> {
  assertPassphrase(passphrase);
  if (enc.length < HEADER_LEN + TAG_LEN) throw new BackupCryptoError("备份文件太短");
  const h = enc.subarray(0, HEADER_LEN);
  const { logN, r, p, salt, iv } = parseHeader(h);
  const d = createDecipheriv("aes-256-gcm", await deriveKey(passphrase, salt, logN, r, p), iv);
  d.setAAD(h);
  d.setAuthTag(enc.subarray(enc.length - TAG_LEN));
  try {
    return Buffer.concat([d.update(enc.subarray(HEADER_LEN, enc.length - TAG_LEN)), d.final()]);
  } catch (e) {
    throw new BackupCryptoError(`解密失败（口令不对或文件被改过）：${(e as Error).message}`);
  }
}
