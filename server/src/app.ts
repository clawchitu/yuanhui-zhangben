// Fastify 应用。只组装路由和公共错误格式，不在这里连数据库（由调用方传入，测试里每个文件一个独立 schema）。
import Fastify, { type FastifyInstance } from "fastify";
import type { Config } from "./config.ts";
import type { Db } from "./db.ts";
import { healthRoutes } from "./routes/health.ts";
import { configRoutes } from "./routes/config.ts";
import { authRoutes } from "./routes/auth.ts";
import { deviceRoutes } from "./routes/devices.ts";
import { accountRoutes } from "./routes/account.ts";
import { syncRoutes } from "./routes/sync.ts";
import { heldRoutes } from "./routes/held.ts";
import { reportRoutes } from "./routes/reports.ts";
import { DEFAULT_PAGE_SIZE } from "./sync/pull.ts";
import { Guard } from "./auth/guard.ts";
import { installGuard } from "./auth/plugin.ts";
import { DEFAULT_RATE_LIMITS, type RateLimits } from "./auth/ratelimit.ts";
import { verifyPassword } from "./auth/password.ts";
import { lookupRoutes } from "./routes/lookup.ts";
import { sourceFromConfig, type BarcodeSource } from "./lookup/kuainiao.ts";
import { objectStoreFromConfig, type ObjectStore } from "./lookup/oss.ts";
import { CatalogService } from "./lookup/catalog.ts";
import { CandidateWorker } from "./lookup/candidates.ts";
import { productImageRoutes } from "./routes/product-images.ts";
import { proxyTrust } from "./auth/proxy.ts";
import { SyncSeen } from "./monitor/server-monitor.ts";

/**
 * 请求体上限 1 MiB（§4.2）。最大的合法 op（200 行的卖出、每个字符串都写满、非 ASCII 全转义成 \uXXXX）约 0.75 MiB，
 * 单独一个总能发出去；手机按字节拆批（≤200 个 op 且 ≤ 1 MiB）。超过返回 413 invalid，一个 op 都不处理。
 */
export const BODY_LIMIT = 1024 * 1024;

export interface AppDeps {
  config: Config;
  db: Db;
  /** 测试里传 false 关日志 */
  logger?: boolean;
  /** 只给测试用：日志写到这里（逐行 JSON），用来断言某条路径记了日志。传了就忽略 logger: false */
  logStream?: { write(line: string): void };
  /** 服务器时钟（测试里拨钟测锁定、开通码过期） */
  clock?: () => Date;
  /** 按 IP 限速（测试里调小） */
  rateLimits?: Partial<RateLimits>;
  /** 验密码（测试里包一层，控制并发请求的交错顺序；照样调真实的 argon2id） */
  verifyPassword?: typeof verifyPassword;
  /**
   * 只给测试用：建设备拿到称呼锁之后、插入设备之前调用，用来在真实 Postgres 上做受控交错。
   * 生产不传，默认无操作；只能在 buildApp 时由代码传入，没有任何请求能触发或改它。
   */
  afterDeviceLabelLock?: () => Promise<void>;
  /** 同步每条流每页多少行（§4.2 默认 500；测试里调小测分页） */
  syncPageSize?: number;
  /** 外部条码库（默认按配置建快鸟客户端；没配 AppCode 是 null）。测试里传假实现 */
  barcodeSource?: BarcodeSource | null;
  /** 对象存储（默认按配置；none 是 null）。测试里传内存实现 */
  objectStore?: ObjectStore | null;
  /** 商品图候选下载（默认 lookup/images.ts 的 fetchImage + 默认安全策略）。测试里换成带放行策略或假实现的版本 */
  fetchImage?: (url: string) => Promise<Buffer>;
  /** 生产用：每行日志照常写 stdout，同时交给它（监控从日志里取告警、数 5xx，S10c）。测试里不用 logStream 时也可以传 */
  logTap?: (line: string) => void;
}

export interface ResolvedDeps extends AppDeps {
  clock: () => Date;
  rateLimits: RateLimits;
  verifyPassword: typeof verifyPassword;
  afterDeviceLabelLock: () => Promise<void>;
  syncPageSize: number;
  barcodeSource: BarcodeSource | null;
  objectStore: ObjectStore | null;
  /** 商品图功能真正开着：总开关开、对象存储也配了（S22d：查码候选、选图、拍照、读图、/v1/config 都看它） */
  imagesOn: boolean;
}

declare module "fastify" {
  interface FastifyInstance {
    deps: ResolvedDeps;
    /** 条码查询服务（测试里看额度用） */
    catalog: CatalogService;
    /** 商品图候选的进程内 worker（并发 1，S22d）；调度器 images 任务也用它 */
    candidates: CandidateWorker;
    /** 每家店最近一次同步成功（S10c 营业时间无同步告警） */
    syncSeen: SyncSeen;
  }
}

export function buildApp(input: AppDeps): FastifyInstance {
  const deps: ResolvedDeps = {
    ...input,
    clock: input.clock ?? (() => new Date()),
    rateLimits: { ...DEFAULT_RATE_LIMITS, ...input.rateLimits },
    verifyPassword: input.verifyPassword ?? verifyPassword,
    afterDeviceLabelLock: input.afterDeviceLabelLock ?? (async () => {}),
    syncPageSize: input.syncPageSize ?? DEFAULT_PAGE_SIZE,
    barcodeSource: input.barcodeSource !== undefined ? input.barcodeSource : sourceFromConfig(input.config),
    objectStore: input.objectStore !== undefined ? input.objectStore : objectStoreFromConfig(input.config),
    imagesOn: false,
  };
  deps.imagesOn = deps.config.productImagesEnabled && deps.objectStore !== null;
  if (!Number.isInteger(deps.syncPageSize) || deps.syncPageSize < 1) throw new Error("syncPageSize 必须是正整数");
  const app = Fastify({
    // 前面有 Caddy 反代时打开，只信一跳、只信 Caddy 的地址（§14 S03-6、S10a，见 auth/proxy.ts）：
    // req.ip 取 X-Forwarded-For 最右边那一项；客户端自带的更左边的项一律不信。关着时 req.ip 就是 TCP 对端地址。
    trustProxy: deps.config.trustProxy ? proxyTrust(deps.config.trustedProxies) : false,
    logger:
      deps.logger === false && !deps.logStream
        ? false
        : {
            level: deps.logStream ? "info" : deps.config.logLevel,
            ...(deps.logStream ? { stream: deps.logStream } : deps.logTap ? { stream: tee(deps.logTap) } : {}),
            // 令牌、口令、开通码不进日志
            redact: {
              paths: ["req.headers.authorization", "req.headers.cookie", "body.password", "body.code", "body.token"],
              remove: true,
            },
          },
    bodyLimit: BODY_LIMIT,
  });
  app.decorate("deps", deps);
  app.decorate("syncSeen", new SyncSeen());
  app.decorate(
    "catalog",
    new CatalogService({
      db: deps.db.kysely,
      source: deps.barcodeSource,
      timeoutMs: deps.config.barcodeLookupTimeoutMs,
      dailyLimit: deps.config.barcodeDailyLimit,
      clock: deps.clock,
    }),
  );

  app.decorate(
    "candidates",
    new CandidateWorker({
      db: deps.db.kysely,
      store: deps.objectStore,
      enabled: deps.imagesOn,
      clock: deps.clock,
      ...(deps.fetchImage ? { fetchImage: deps.fetchImage } : {}),
      log: { warn: (o, m) => app.log.warn(o, m), info: (o, m) => app.log.info(o, m) },
    }),
  );

  // 关服务时等在跑的候选转存做完（不把它掐在半截、也不在库关掉之后再查库）
  app.addHook("onClose", async () => {
    await app.candidates.idle();
  });

  // 统一错误格式：契约 components/schemas/Error，{ code, message? }
  app.setNotFoundHandler((_req, reply) => {
    reply.code(404).send({ code: "not_found" });
  });
  app.setErrorHandler((err: { validation?: unknown; statusCode?: number; message: string }, req, reply) => {
    if (err.validation) {
      reply.code(400).send({ code: "invalid", message: err.message });
      return;
    }
    const status = err.statusCode && err.statusCode >= 400 && err.statusCode < 500 ? err.statusCode : 500;
    if (status >= 500) req.log.error({ err }, "未处理的错误");
    if (status === 413) {
      // 拍照上传（PUT /v1/images/:id）的上限同是 1 MiB，但不是「拆批」的事（PR #42 Fable 可选 6）
      const upload = req.method === "PUT" && req.url.startsWith("/v1/images/");
      reply.code(413).send({ code: "invalid", message: upload ? "图片超过 1 MB，压小一点再传" : `请求体超过 ${BODY_LIMIT} 字节，拆成几批再发` });
      return;
    }
    reply.code(status).send(status === 400 ? { code: "invalid" } : status === 404 ? { code: "not_found" } : { code: "unavailable" });
  });

  // guard 必须在注册路由之前装上：onRoute 要检查每个路由都在 permissions.json 里
  installGuard(app, new Guard());
  app.register(healthRoutes);
  app.register(configRoutes);
  app.register(authRoutes);
  app.register(deviceRoutes);
  app.register(accountRoutes);
  app.register(syncRoutes);
  app.register(heldRoutes);
  app.register(reportRoutes);
  app.register(lookupRoutes);
  app.register(productImageRoutes);
  return app;
}

/** 日志照常写 stdout，同时交给 tap；tap 出错不影响写日志 */
function tee(tap: (line: string) => void): { write(line: string): void } {
  return {
    write(line: string) {
      process.stdout.write(line);
      try {
        tap(line);
      } catch {
        // 监控解析出错不能把请求日志弄丢
      }
    },
  };
}
