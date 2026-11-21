// 备份用的对象存储：只认 BACKUP_* 变量，不回落到 api 的 OSS 凭据（§14 T21：备份单独一个 RAM 账号，
// backups/ 只写不删、删除靠生命周期；api 的账号不碰 backups/）。
//   BACKUP_STORE_DIR=<目录>         本机目录（测试、本机恢复演练把 OSS 上的对象下载下来时也可用）
//   否则阿里云：BACKUP_OSS_REGION、BACKUP_OSS_BUCKET（yuanhui-backup）、BACKUP_OSS_ACCESS_KEY_ID、BACKUP_OSS_ACCESS_KEY_SECRET，
//   可选 BACKUP_OSS_ENDPOINT（ECS 上用内网 https://oss-cn-shanghai-internal.aliyuncs.com，另一台机器上恢复用公网）
import { AliOssObjectStore, LocalDirObjectStore, type ObjectStore } from "../lookup/oss.ts";

type Env = Record<string, string | undefined>;

export function backupStoreFromEnv(env: Env = process.env): ObjectStore {
  if (env.BACKUP_STORE_DIR) return new LocalDirObjectStore(env.BACKUP_STORE_DIR);
  const need = ["BACKUP_OSS_REGION", "BACKUP_OSS_BUCKET", "BACKUP_OSS_ACCESS_KEY_ID", "BACKUP_OSS_ACCESS_KEY_SECRET"] as const;
  const missing = need.filter((k) => !env[k]);
  if (missing.length) throw new Error(`备份存储没配：缺 ${missing.join("、")}（或设 BACKUP_STORE_DIR）`);
  if (env.OSS_BUCKET && env.BACKUP_OSS_BUCKET === env.OSS_BUCKET) throw new Error("BACKUP_OSS_BUCKET 不能是商品图桶");
  const endpoint = env.BACKUP_OSS_ENDPOINT;
  if (endpoint && !/^https:\/\//.test(endpoint)) throw new Error("BACKUP_OSS_ENDPOINT 必须以 https:// 开头");
  return new AliOssObjectStore({
    kind: "aliyun",
    region: env.BACKUP_OSS_REGION!,
    bucket: env.BACKUP_OSS_BUCKET!,
    accessKeyId: env.BACKUP_OSS_ACCESS_KEY_ID!,
    accessKeySecret: env.BACKUP_OSS_ACCESS_KEY_SECRET!,
    ...(endpoint ? { endpoint } : {}),
  } as ConstructorParameters<typeof AliOssObjectStore>[0]);
}
