// 备份命令行（由 deploy/backup.sh 在 ECS 上通过 `docker compose run backup` 调；本机测试直接跑）。
//   node scripts/backup.ts snapshot --dir <工作目录>
//       开快照、算清单写 <dir>/manifest.json，快照 id 写 <dir>/snapshot，然后等 <dir>/dump.done（或 dump.failed）出现再结束事务
//   node scripts/backup.ts upload --dir <工作目录>
//       加密 <dir>/db.dump、上传 dump、清单、心跳；打印一行 JSON（event=backup_uploaded）
//   node scripts/backup.ts status        备份桶状态（实际用的两个桶 source、份数、最旧、心跳；lifecycle_stale = 生命周期没生效）
// 环境变量：DATABASE_URL（snapshot）、BACKUP_PASSPHRASE（upload）、备份存储见 src/backup/store.ts
// 日志一律一行 JSON；退出码 0 成功，1 失败，2 参数不对
import { access, rename, writeFile, readFile } from "node:fs/promises";
import path from "node:path";
import { setTimeout as sleep } from "node:timers/promises";
import { createDb } from "../src/db.ts";
import { backupStatus, uploadBackup, withBackupSnapshot } from "../src/backup/backup.ts";
import { backupStoreFromEnv, backupStoreSource } from "../src/backup/store.ts";
import type { Manifest } from "../src/backup/manifest.ts";

const log = (o: object) => console.log(JSON.stringify({ at: new Date().toISOString(), ...o }));
const fail = (o: object, code = 1): never => {
  console.error(JSON.stringify({ at: new Date().toISOString(), ...o }));
  process.exit(code);
};
const [cmd, ...rest] = process.argv.slice(2);
const arg = (n: string) => {
  const i = rest.indexOf(n);
  return i >= 0 ? rest[i + 1] : undefined;
};
const exists = (f: string) => access(f).then(() => true, () => false);

async function snapshot(dir: string) {
  const url = process.env.DATABASE_URL ?? fail({ event: "backup_snapshot_failed", code: "no_database_url" }, 2);
  const timeoutMs = Number(process.env.BACKUP_DUMP_TIMEOUT_S ?? 600) * 1000;
  const db = createDb({ connectionString: url, max: 1, connectionTimeoutMillis: 10_000 });
  try {
    await withBackupSnapshot(db.kysely, new Date(), async (snap, manifest) => {
      await writeFile(path.join(dir, "manifest.json"), JSON.stringify(manifest), { mode: 0o600 });
      await writeFile(path.join(dir, "snapshot.tmp"), `${snap}\n`, { mode: 0o600 });
      await rename(path.join(dir, "snapshot.tmp"), path.join(dir, "snapshot"));
      const until = Date.now() + timeoutMs;
      for (;;) {
        if (await exists(path.join(dir, "dump.done"))) return;
        if (await exists(path.join(dir, "dump.failed"))) throw new Error("pg_dump 失败");
        if (Date.now() > until) throw new Error("等 pg_dump 超时");
        await sleep(200);
      }
    });
  } finally {
    await db.close();
  }
}

async function upload(dir: string) {
  const passphrase = process.env.BACKUP_PASSPHRASE ?? "";
  const manifest = JSON.parse(await readFile(path.join(dir, "manifest.json"), "utf8")) as Manifest;
  const store = backupStoreFromEnv();
  const t0 = Date.now();
  const r = await uploadBackup(store, { dumpFile: path.join(dir, "db.dump"), manifest, passphrase, now: new Date(), workDir: dir });
  log({ event: "backup_uploaded", backup_id: r.id, dump_bytes: r.dumpBytes, encrypted_bytes: r.encryptedBytes, upload_ms: Date.now() - t0, stores: Object.keys(manifest.stores).length });
  const st = await backupStatus(store, new Date());
  log({ event: "backup_status", source: backupStoreSource(), count: st.count, oldest: st.oldest, oldest_age_days: st.oldest_age_days, ...(st.lifecycle_stale ? { alert: "backup_lifecycle_stale" } : {}) });
}

try {
  if (cmd === "snapshot" || cmd === "upload") {
    const dir = arg("--dir") ?? fail({ event: `backup_${cmd}_failed`, code: "usage" }, 2);
    await (cmd === "snapshot" ? snapshot(dir) : upload(dir));
  } else if (cmd === "status") {
    const st = await backupStatus(backupStoreFromEnv(), new Date());
    log({ event: "backup_status", source: backupStoreSource(), ...st, ...(st.lifecycle_stale ? { alert: "backup_lifecycle_stale" } : {}) });
  } else {
    fail({ event: "backup_usage", code: "usage", usage: "snapshot --dir D | upload --dir D | status" }, 2);
  }
} catch (e) {
  fail({ event: `backup_${cmd}_failed`, code: (e as { code?: string }).code ?? "error", message: (e as Error).message });
}
