// 备份用的对象存储：只认 BACKUP_* 变量，不回落到 api 的 OSS 凭据（§14 T21：备份单独一个 RAM 账号，
// backups/ 只写不删、删除靠生命周期；api 的账号不碰 backups/）。
//   BACKUP_STORE_DIR=<目录>         本机目录（测试、本机恢复演练把 OSS 上的对象下载下来时也可用）
//   否则阿里云：BACKUP_OSS_REGION、BACKUP_OSS_BUCKET（yuanhui-backup）、BACKUP_OSS_ACCESS_KEY_ID、BACKUP_OSS_ACCESS_KEY_SECRET，
//   可选 BACKUP_OSS_ENDPOINT（ECS 上用内网 https://oss-cn-shanghai-internal.aliyuncs.com，另一台机器上恢复用公网）
//   可选 BACKUP_OSS_ARCHIVE_BUCKET（S10 部署实测，负责人 11/22 决定）：备份桶开了 OSS 合规保留（WORM，35 天），
//   桶里的对象保留期内删不掉也覆盖不了，所以备份桶只放 backups/（键各不相同，只写不改）；
//   要覆盖的心跳 heartbeat/backup.json 和恢复要读的 deletions/ 走这个存档桶（就是 api 的 OSS_ARCHIVE_BUCKET）。
//   不配时和以前一样，全部键在 BACKUP_OSS_BUCKET。
//   恢复（restoreStoreFromEnv）不许不配：没配存档桶时 deletions/ 去备份桶里列，列出来是空的、不报错，已注销的店会被恢复回来
//   （PR #27 Fable S10r-8）。真是单桶老布局就显式写成和 BACKUP_OSS_BUCKET 同名。
import {
  AliOssObjectStore,
  BACKUPS_PREFIX,
  LocalDirObjectStore,
  type ObjectStore,
} from "../lookup/oss.ts";

type Env = Record<string, string | undefined>;

export function backupStoreFromEnv(env: Env = process.env): ObjectStore {
  if (env.BACKUP_STORE_DIR)
    return new LocalDirObjectStore(env.BACKUP_STORE_DIR);
  const need = [
    "BACKUP_OSS_REGION",
    "BACKUP_OSS_BUCKET",
    "BACKUP_OSS_ACCESS_KEY_ID",
    "BACKUP_OSS_ACCESS_KEY_SECRET",
  ] as const;
  const missing = need.filter((k) => !env[k]);
  if (missing.length)
    throw new Error(
      `备份存储没配：缺 ${missing.join("、")}（或设 BACKUP_STORE_DIR）`,
    );
  if (env.OSS_BUCKET && env.BACKUP_OSS_BUCKET === env.OSS_BUCKET)
    throw new Error("BACKUP_OSS_BUCKET 不能是商品图桶");
  const archive = env.BACKUP_OSS_ARCHIVE_BUCKET;
  if (env.OSS_BUCKET && archive === env.OSS_BUCKET)
    throw new Error("BACKUP_OSS_ARCHIVE_BUCKET 不能是商品图桶");
  const endpoint = env.BACKUP_OSS_ENDPOINT;
  if (endpoint && !/^https:\/\//.test(endpoint))
    throw new Error("BACKUP_OSS_ENDPOINT 必须以 https:// 开头");
  const make = (bucket: string) =>
    new AliOssObjectStore({
      kind: "aliyun",
      region: env.BACKUP_OSS_REGION!,
      bucket,
      accessKeyId: env.BACKUP_OSS_ACCESS_KEY_ID!,
      accessKeySecret: env.BACKUP_OSS_ACCESS_KEY_SECRET!,
      ...(endpoint ? { endpoint } : {}),
    } as ConstructorParameters<typeof AliOssObjectStore>[0]);
  const main = make(env.BACKUP_OSS_BUCKET!);
  return archive && archive !== env.BACKUP_OSS_BUCKET
    ? new SplitBackupStore(main, make(archive))
    : main;
}

/** 恢复的配置不对（没配存档桶）：scripts/restore.ts 按参数错误退出码 2 */
export class RestoreConfigError extends Error {}

/**
 * 恢复用的对象存储：和 backupStoreFromEnv 一样，但 OSS 跑法必须显式给 BACKUP_OSS_ARCHIVE_BUCKET（deletions/ 在那个桶）。
 * 本机目录跑法（BACKUP_STORE_DIR）不受影响：backups/、deletions/ 在同一个目录。
 */
export function restoreStoreFromEnv(env: Env = process.env): ObjectStore {
  if (!env.BACKUP_STORE_DIR && !env.BACKUP_OSS_ARCHIVE_BUCKET)
    throw new RestoreConfigError(
      "恢复要设 BACKUP_OSS_ARCHIVE_BUCKET（删除记录 deletions/ 在存档桶 yuanhui-archive）：不设就去备份桶里找删除记录，找到的是空的，已注销的店会被恢复回来。" +
        "单桶老布局请显式写成和 BACKUP_OSS_BUCKET 同名",
    );
  return backupStoreFromEnv(env);
}

/** backups/ 和 deletions/、心跳各从哪里读写（日志、dry-run 打印用；只有桶名或目录，不含凭据） */
export function backupStoreSource(env: Env = process.env): { backups: string; deletions: string } {
  if (env.BACKUP_STORE_DIR) return { backups: `dir:${env.BACKUP_STORE_DIR}`, deletions: `dir:${env.BACKUP_STORE_DIR}` };
  const main = env.BACKUP_OSS_BUCKET ?? "";
  return { backups: `oss://${main}`, deletions: `oss://${env.BACKUP_OSS_ARCHIVE_BUCKET || main}` };
}

/** backups/ 开头的键走备份桶（合规保留），其余（心跳、deletions/）走存档桶 */
export class SplitBackupStore implements ObjectStore {
  private readonly backups: ObjectStore;
  private readonly rest: ObjectStore;
  constructor(backups: ObjectStore, rest: ObjectStore) {
    this.backups = backups;
    this.rest = rest;
  }
  private pick(key: string): ObjectStore {
    return key.startsWith(BACKUPS_PREFIX) ? this.backups : this.rest;
  }
  put(key: string, body: Buffer, contentType: string) {
    return this.pick(key).put(key, body, contentType);
  }
  putFile(key: string, file: string, contentType: string) {
    return this.pick(key).putFile(key, file, contentType);
  }
  get(key: string) {
    return this.pick(key).get(key);
  }
  list(prefix: string) {
    return this.pick(prefix).list(prefix);
  }
  delete(key: string) {
    return this.pick(key).delete(key);
  }
  listUploads(prefix: string) {
    return this.pick(prefix).listUploads(prefix);
  }
  abortUpload(key: string, uploadId: string) {
    return this.pick(key).abortUpload(key, uploadId);
  }
}
