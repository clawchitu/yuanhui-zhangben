// 恢复（§9.4、§4.6、S10b）：取备份 → 解密、核对 sha256 → （pg_restore，由 deploy/restore.sh 调）→
// 按清单逐项比对 → 重放删除记录（§14 T14）→ 再比对（已删的店不在、其余的店不变）→ 全部店换新 epoch。
// 只往「新库」恢复：目标库必须是空的，或者是一次没做完的恢复留下的（数据库注释 `yuanhui-restoring <备份 id>`），否则拒绝。
// 恢复做完（finish 成功）注释改成 `yuanhui-restored <备份 id>`：这样的库可能已经接上 api、记了新账，再跑恢复不许清它——
// 同一个备份 id 报「已恢复完成」直接返回（幂等），别的 id 拒绝，要新建空库（PR #23 Codex 1、Fable 必须改 1，§14 S10b-5）。
import { mkdir, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { sql, type Kysely } from "kysely";
import type { Database } from "../db.ts";
import { DELETIONS_PREFIX, deletionStoreId, type ObjectStore } from "../lookup/oss.ts";
import { replayDeletion } from "../jobs/account-purge.ts";
import { decryptBuffer, decryptFile } from "./crypto.ts";
import { computeManifest, diffManifests, type Manifest } from "./manifest.ts";
import { listBackups } from "./backup.ts";

/** 恢复进行中（prepare 打上，可以清空重来） */
export const MARKER_RESTORING = "yuanhui-restoring";
/** 恢复已完成（finish 成功后改成这个，不再清库） */
export const MARKER_RESTORED = "yuanhui-restored";

export class RestoreError extends Error {}

/** id 或 latest → 备份 id */
export async function resolveBackup(store: ObjectStore, which: string): Promise<string> {
  const all = await listBackups(store);
  if (which === "latest") {
    const last = all.at(-1);
    if (!last) throw new RestoreError("备份桶里没有完整的备份");
    return last.id;
  }
  if (!all.some((b) => b.id === which)) throw new RestoreError(`找不到备份 ${which}`);
  return which;
}

/** 下载、解密到 outDir/db.dump 和 outDir/manifest.json（明文，权限 600），核对 dump 的 sha256 */
export async function fetchBackup(store: ObjectStore, id: string, passphrase: string, outDir: string): Promise<{ manifest: Manifest; dumpFile: string }> {
  await mkdir(outDir, { recursive: true, mode: 0o700 });
  const encM = await store.get(`backups/${id}.manifest.enc`);
  const encD = await store.get(`backups/${id}.dump.enc`);
  if (!encM || !encD) throw new RestoreError(`备份 ${id} 不完整`);
  const manifest = JSON.parse((await decryptBuffer(encM, passphrase)).toString("utf8")) as Manifest;
  if (manifest.format !== 1 || !manifest.dump) throw new RestoreError("清单格式不对");
  const encFile = path.join(outDir, "db.dump.enc");
  await writeFile(encFile, encD, { mode: 0o600 });
  const dumpFile = path.join(outDir, "db.dump");
  const { sha256 } = await decryptFile(encFile, dumpFile, passphrase);
  if (sha256 !== manifest.dump.sha256) throw new RestoreError("dump 的 sha256 和清单对不上");
  await writeFile(path.join(outDir, "manifest.json"), JSON.stringify(manifest), { mode: 0o600 });
  return { manifest, dumpFile };
}

export async function readManifest(file: string): Promise<Manifest> {
  return JSON.parse(await readFile(file, "utf8")) as Manifest;
}

/** 列出全部删除记录（deletions/<店>.json）。记录里的店 id 必须和键一致，否则拒绝（不按坏记录删店） */
export async function listDeletions(store: ObjectStore): Promise<Array<{ storeId: string; purgedAt: Date }>> {
  const out: Array<{ storeId: string; purgedAt: Date }> = [];
  for (const key of await store.list(DELETIONS_PREFIX)) {
    const id = deletionStoreId(key);
    if (!id) continue;
    const body = await store.get(key);
    if (!body) continue;
    const rec = JSON.parse(body.toString("utf8")) as { store_id?: string; purged_at?: string };
    const at = new Date(rec.purged_at ?? "");
    if (rec.store_id?.toLowerCase() !== id || Number.isNaN(at.getTime())) throw new RestoreError(`删除记录 ${key} 内容不对`);
    out.push({ storeId: id, purgedAt: at });
  }
  return out.sort((a, b) => a.storeId.localeCompare(b.storeId));
}

export type TargetState = "empty" | "restoring" | "restored" | "foreign";

/**
 * 目标库的状态：empty 没有任何用户表、也没有大对象；restoring / restored 看数据库注释（带备份 id）；
 * foreign 不空又没有恢复标记（可能是在用的库）。本项目不用大对象，有大对象一律当作不认识的库（Codex 2、Fable 建议 1）
 */
export async function inspectTarget(db: Kysely<Database>): Promise<{ state: TargetState; backupId: string | null; schemas: string[]; largeObjects: number }> {
  const t = await sql<{ s: string }>`
    SELECT DISTINCT n.nspname AS s FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'v', 'm', 'S') AND n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg_%'
    ORDER BY 1`.execute(db);
  const lo = await sql<{ n: string }>`SELECT count(*)::text AS n FROM pg_largeobject_metadata`.execute(db);
  const c = await sql<{ d: string | null }>`SELECT shobj_description(oid, 'pg_database') AS d FROM pg_database WHERE datname = current_database()`.execute(db);
  const note = (c.rows[0]?.d ?? "").trim();
  const m = /^(yuanhui-restoring|yuanhui-restored) (\S+)$/.exec(note);
  const largeObjects = Number(lo.rows[0]?.n ?? 0);
  const schemas = t.rows.map((r) => r.s);
  let state: TargetState;
  if (m) state = m[1] === MARKER_RESTORED ? "restored" : "restoring";
  else state = schemas.length === 0 && largeObjects === 0 ? "empty" : "foreign";
  return { state, backupId: m ? m[2]! : null, schemas, largeObjects };
}

async function setMarker(db: Kysely<Database>, note: string | null) {
  await sql`DO $$ BEGIN EXECUTE format('COMMENT ON DATABASE %I IS %L', current_database(), ${note === null ? sql`NULL::text` : sql.lit(note)}); END $$`.execute(db);
}

/**
 * 准备目标库：
 * - 空库 → 打上「恢复中」标记，返回 empty；
 * - 「恢复中」（上一次没做完）→ 清空里面的 schema 再打标记，返回 reset（重跑同一次恢复得到同样的结果）；
 * - 「已恢复」且是同一个备份 → 什么都不动，返回 done；别的备份 → 拒绝（这个库可能已经在用）；
 * - 不空又没标记、或有大对象 → 拒绝。
 * dryRun 只检查不改
 */
export async function prepareTarget(db: Kysely<Database>, backupId: string, dryRun: boolean): Promise<"empty" | "reset" | "done"> {
  const st = await inspectTarget(db);
  if (st.state === "restored") {
    if (st.backupId === backupId) return "done";
    throw new RestoreError(`目标库已经从备份 ${st.backupId ?? "?"} 恢复完成（可能已在用），拒绝再用 ${backupId} 覆盖。请新建一个空库`);
  }
  if (st.state === "foreign") throw new RestoreError(`目标库不是空的（${st.schemas.join(",") || `${st.largeObjects} 个大对象`}），也不是一次没做完的恢复，拒绝覆盖。请新建一个空库`);
  if (st.largeObjects > 0) throw new RestoreError(`目标库里有 ${st.largeObjects} 个大对象（本项目不用大对象），拒绝覆盖。请新建一个空库`);
  if (dryRun) return st.state === "empty" ? "empty" : "reset";
  for (const s of st.schemas) {
    if (!/^[a-z_][a-z0-9_]*$/.test(s)) throw new RestoreError(`schema 名不对：${s}`);
    await sql`DROP SCHEMA ${sql.id(s)} CASCADE`.execute(db);
    if (s === "public") await sql`CREATE SCHEMA public`.execute(db);
  }
  await setMarker(db, `${MARKER_RESTORING} ${backupId}`);
  return st.state === "empty" ? "empty" : "reset";
}

/** 整机重建：恢复完、把 api 指过去之前清掉标记（之后任何恢复都把它当作在用的库拒绝） */
export async function clearMarker(db: Kysely<Database>): Promise<TargetState> {
  const st = await inspectTarget(db);
  if (st.state !== "restored") throw new RestoreError(`目标库不是「已恢复」状态（${st.state}），不清标记`);
  await setMarker(db, null);
  return (await inspectTarget(db)).state;
}

export interface RestoreReport {
  backup_taken_at: string;
  stores_in_backup: number;
  deletions: number;
  /** 恢复出来的库里本来还在、被重放删掉的店 */
  replayed: string[];
  epochs_rotated: number;
  backup_id: string;
  dry_run: boolean;
}

/** pg_restore 之后：比对清单 → 重放删除记录 → 再比对 → 换 epoch。比对不一致 → RestoreError（不换 epoch，库留着排查） */
// 只对「恢复中」的库做：已恢复完成的库再跑一遍会把在用的店换 epoch、按删除记录删店，拒绝。
export async function finishRestore(db: Kysely<Database>, store: ObjectStore, manifest: Manifest, o: { dryRun: boolean }): Promise<RestoreReport> {
  const st = await inspectTarget(db);
  if (st.state !== "restoring" || !st.backupId) throw new RestoreError(`目标库不是「恢复中」状态（${st.state}），拒绝比对和换 epoch`);
  const backupId = st.backupId;
  const taken = new Date(manifest.taken_at);
  const snap = () => db.transaction().setIsolationLevel("repeatable read").execute((trx) => computeManifest(trx, taken));
  const before = await snap();
  const d1 = diffManifests(manifest, before);
  if (d1.length) throw new RestoreError(`恢复后和备份清单不一致：\n${d1.join("\n")}`);
  const deletions = await listDeletions(store);
  const present = deletions.filter((d) => before.stores[d.storeId]).map((d) => d.storeId);
  if (o.dryRun) {
    return { backup_taken_at: manifest.taken_at, stores_in_backup: Object.keys(manifest.stores).length, deletions: deletions.length, replayed: present, epochs_rotated: 0, backup_id: backupId, dry_run: true };
  }
  for (const d of deletions) await replayDeletion(db, d.storeId, d.purgedAt);
  const after = await snap();
  const d2 = diffManifests(manifest, after, { excludeStores: deletions.map((d) => d.storeId), skipTables: true });
  if (d2.length) throw new RestoreError(`重放删除记录后不一致：\n${d2.join("\n")}`);
  // 换 epoch 和改成「已恢复」在同一个事务里：要么都做了，要么还是「恢复中」可以重来
  const r = await db.transaction().execute(async (trx) => {
    const u = await trx.updateTable("stores").set({ epoch: sql`gen_random_uuid()` }).executeTakeFirst();
    await setMarker(trx, `${MARKER_RESTORED} ${backupId}`);
    return u;
  });
  return {
    backup_taken_at: manifest.taken_at,
    stores_in_backup: Object.keys(manifest.stores).length,
    deletions: deletions.length,
    replayed: present,
    epochs_rotated: Number(r.numUpdatedRows),
    backup_id: backupId,
    dry_run: false,
  };
}
