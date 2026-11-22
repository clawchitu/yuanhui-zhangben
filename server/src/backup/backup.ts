// 备份（§9.4）：快照 → 清单 → pg_dump（同一快照）→ 加密 → 上传 → 心跳。
// pg_dump 在 Postgres 容器里跑（版本和服务端一致），这里只负责快照、清单、加密、上传；编排在 deploy/backup.sh。
import { randomBytes } from "node:crypto";
import { open, stat } from "node:fs/promises";
import path from "node:path";
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { BACKUPS_PREFIX, HEARTBEAT_KEY, backupKeys, type ObjectStore } from "../lookup/oss.ts";
import { encryptBuffer, encryptFile } from "./crypto.ts";
import { computeManifest, type Manifest } from "./manifest.ts";

/**
 * 开一个可重复读的只读事务，导出快照、在同一快照里算清单，然后在 fn 里让 pg_dump --snapshot=<id> 去 dump。
 * fn 返回之前事务一直开着（快照有效）。
 */
export async function withBackupSnapshot<T>(db: Kysely<Database>, now: Date, fn: (snapshotId: string, manifest: Manifest) => Promise<T>): Promise<T> {
  return db
    .transaction()
    .setIsolationLevel("repeatable read")
    .setAccessMode("read only")
    .execute(async (trx) => {
      const snap = (await sql<{ id: string }>`SELECT pg_export_snapshot() AS id`.execute(trx)).rows[0]!.id;
      const manifest = await computeManifest(trx, now);
      return fn(snap, manifest);
    });
}

/** pg_dump 自定义格式的文件头是 PGDMP；不是就不上传（pg_dump 半路失败、输出了错误文字） */
export async function assertPgDump(file: string): Promise<void> {
  const fh = await open(file, "r");
  try {
    const b = Buffer.alloc(5);
    const { bytesRead } = await fh.read(b, 0, 5, 0);
    if (bytesRead < 5 || b.toString("ascii") !== "PGDMP") throw new Error("dump 文件不是 pg_dump 自定义格式（PGDMP）");
  } finally {
    await fh.close();
  }
}

export interface Heartbeat {
  at: string;
  backup_id: string;
  dump_bytes: number;
  stores: number;
}

export interface UploadResult {
  id: string;
  dumpKey: string;
  manifestKey: string;
  dumpBytes: number;
  encryptedBytes: number;
}

/** 加密并上传一份备份：先 dump，再清单，最后心跳。任何一步失败抛错，心跳不更新 */
export async function uploadBackup(
  store: ObjectStore,
  o: { dumpFile: string; manifest: Manifest; passphrase: string; now: Date; workDir: string; rand?: string },
): Promise<UploadResult> {
  await assertPgDump(o.dumpFile);
  const keys = backupKeys(new Date(o.manifest.taken_at), o.rand ?? randomBytes(8).toString("hex"));
  const enc = path.join(o.workDir, "db.dump.enc");
  const { sha256, bytes } = await encryptFile(o.dumpFile, enc, o.passphrase);
  const manifest: Manifest = { ...o.manifest, dump: { sha256, bytes } };
  await store.putFile(keys.dump, enc, "application/octet-stream");
  await store.put(keys.manifest, await encryptBuffer(Buffer.from(JSON.stringify(manifest)), o.passphrase), "application/octet-stream");
  const hb: Heartbeat = { at: o.now.toISOString(), backup_id: keys.id, dump_bytes: bytes, stores: Object.keys(manifest.stores).length };
  await store.put(HEARTBEAT_KEY, Buffer.from(`${JSON.stringify(hb)}\n`), "application/json");
  const encryptedBytes = (await stat(enc)).size;
  return { id: keys.id, dumpKey: keys.dump, manifestKey: keys.manifest, dumpBytes: bytes, encryptedBytes };
}

/** backups/ 下完整的备份（dump 和清单都在），按时间从旧到新 */
export async function listBackups(store: ObjectStore): Promise<Array<{ id: string; at: Date }>> {
  const keys = new Set(await store.list(BACKUPS_PREFIX));
  const out: Array<{ id: string; at: Date }> = [];
  for (const k of keys) {
    const m = /^backups\/(([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z-[0-9a-f]{16})\.dump\.enc$/.exec(k);
    if (!m || !keys.has(`backups/${m[1]}.manifest.enc`)) continue;
    out.push({ id: m[1]!, at: new Date(`${m[2]}-${m[3]}-${m[4]}T${m[5]}:${m[6]}:${m[7]}Z`) });
  }
  return out.sort((a, b) => a.at.getTime() - b.at.getTime() || a.id.localeCompare(b.id));
}

export const RETENTION_DAYS = 35;

/**
 * 生命周期正常时，最旧一份最多能活多久（PR #27 Fable，原来是 35 + 1 天，合规保留下 12/27 前后会误报）：
 * 合规保留恰好 35 天（到期前删不掉）；OSS 生命周期每天一轮（北京时间 0 点开始、24 小时内跑完、不保证准点），
 * 对象满 35 天之后的下一轮才删。最坏情况：满 35 天的时刻刚好错过当天那一轮的扫描 → 等下一轮（+1 天）→ 那一轮又拖到快结束（+1 天），
 * 再加按天对齐的零头，正常情况下最旧一份也可能活到 37 天多。阈值放到 35 + 3 = 38 天：超过它说明连续两轮以上没删，才是生命周期没生效。
 */
export const LIFECYCLE_GRACE_DAYS = 3;

/**
 * 备份桶的状态（给日志和 S10c 的告警）：份数、最新和最旧的时间、心跳。
 * 最旧的一份超过 RETENTION_DAYS + LIFECYCLE_GRACE_DAYS（38）天 → lifecycle_stale（生命周期规则没生效，「35 天内彻底清除」就不成立了）
 */
export async function backupStatus(store: ObjectStore, now: Date) {
  const list = await listBackups(store);
  const raw = await store.get(HEARTBEAT_KEY);
  const heartbeat = raw ? (JSON.parse(raw.toString("utf8")) as Heartbeat) : null;
  const oldest = list[0]?.at ?? null;
  const oldestAgeDays = oldest ? (now.getTime() - oldest.getTime()) / 86_400_000 : null;
  return {
    count: list.length,
    newest: list.at(-1)?.id ?? null,
    oldest: list[0]?.id ?? null,
    oldest_age_days: oldestAgeDays === null ? null : Math.round(oldestAgeDays * 10) / 10,
    lifecycle_stale: oldestAgeDays !== null && oldestAgeDays > RETENTION_DAYS + LIFECYCLE_GRACE_DAYS,
    heartbeat,
  };
}
