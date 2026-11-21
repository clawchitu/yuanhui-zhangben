// 恢复命令行（由 deploy/restore.sh 调，在另一台机器上恢复演练或整机重建时用）。
//   node scripts/restore.ts fetch --backup <id|latest> --out <目录>   下载、解密、核对 sha256 → <目录>/db.dump、manifest.json
//   node scripts/restore.ts prepare --backup-id <id> [--execute]       检查目标库（DATABASE_URL）是空库或之前恢复的库；--execute 才清空、打标记
//   node scripts/restore.ts finish --manifest <文件> [--execute]       比对清单 → 重放删除记录 → 再比对 → 换 epoch；不带 --execute 只比对、列出要删的店
//   node scripts/restore.ts deletions                                  列出全部删除记录
// 环境变量：DATABASE_URL（目标库，prepare / finish）、BACKUP_PASSPHRASE（fetch）、备份存储见 src/backup/store.ts
import { createDb } from "../src/db.ts";
import { backupStoreFromEnv } from "../src/backup/store.ts";
import { fetchBackup, finishRestore, listDeletions, prepareTarget, readManifest, resolveBackup } from "../src/backup/restore.ts";

const log = (o: object) => console.log(JSON.stringify({ at: new Date().toISOString(), ...o }));
const [cmd, ...rest] = process.argv.slice(2);
const arg = (n: string) => {
  const i = rest.indexOf(n);
  return i >= 0 ? rest[i + 1] : undefined;
};
const execute = rest.includes("--execute");
const need = (v: string | undefined, what: string): string => {
  if (!v) {
    console.error(JSON.stringify({ event: "restore_usage", missing: what }));
    process.exit(2);
  }
  return v;
};
const withDb = async <T>(fn: (db: ReturnType<typeof createDb>) => Promise<T>) => {
  const db = createDb({ connectionString: need(process.env.DATABASE_URL, "DATABASE_URL"), max: 2, connectionTimeoutMillis: 10_000 });
  try {
    return await fn(db);
  } finally {
    await db.close();
  }
};

try {
  if (cmd === "fetch") {
    const store = backupStoreFromEnv();
    const id = await resolveBackup(store, need(arg("--backup"), "--backup"));
    const { manifest } = await fetchBackup(store, id, process.env.BACKUP_PASSPHRASE ?? "", need(arg("--out"), "--out"));
    log({ event: "restore_fetched", backup_id: id, taken_at: manifest.taken_at, stores: Object.keys(manifest.stores).length, dump_bytes: manifest.dump?.bytes });
  } else if (cmd === "prepare") {
    const r = await withDb((db) => prepareTarget(db.kysely, need(arg("--backup-id"), "--backup-id"), !execute));
    log({ event: "restore_target", state: r, dry_run: !execute });
  } else if (cmd === "finish") {
    const manifest = await readManifest(need(arg("--manifest"), "--manifest"));
    const r = await withDb((db) => finishRestore(db.kysely, backupStoreFromEnv(), manifest, { dryRun: !execute }));
    log({ event: execute ? "restore_done" : "restore_checked", ...r });
  } else if (cmd === "deletions") {
    for (const d of await listDeletions(backupStoreFromEnv())) log({ event: "deletion", store_id: d.storeId, purged_at: d.purgedAt.toISOString() });
  } else {
    need(undefined, "子命令：fetch | prepare | finish | deletions");
  }
} catch (e) {
  console.error(JSON.stringify({ at: new Date().toISOString(), event: `restore_${cmd}_failed`, alert: "restore_failed", message: (e as Error).message }));
  process.exit(1);
}
