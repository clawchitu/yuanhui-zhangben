-- 0002：演示小店每日重置、账号注销的导出包与删除（S09，docs/plan-v2.md §8 S09、§9.4）。

-- 演示店的重置状态。审核号的原始密码哈希存在这里：每日重置把审核号密码恢复成它（审核员在 Review Notes 里拿到的那个）。
CREATE TABLE demo_stores (
  store_id             uuid PRIMARY KEY REFERENCES stores (id),
  review_password_hash text NOT NULL,
  -- 上一次重置（或建店种数据）的时间；种子里的「今天」就是它
  seeded_at            timestamptz NOT NULL,
  -- 下一次该重置的时间：北京时间 16:00；最近 60 分钟有人在用就顺延 1 小时
  next_reset_at        timestamptz NOT NULL
);

-- 注销申请生成的导出包（非演示店）。申请时插入一行（同一事务），由定时任务生成 CSV 压缩包、上传 OSS exports/、告警通知运维。
-- 撤回注销 → 记 cancelled_at，定时任务删掉 exports/<店>/ 下的包再删这一行；撤回后又申请 → 同一行重置成新的一次。
-- 到期清除 → 和店铺一起删（exports/<店>/ 在清除的对象清理里删）。
CREATE TABLE export_jobs (
  store_id      uuid PRIMARY KEY REFERENCES stores (id),
  -- 对应的注销申请时间（撤回后再申请是新的一次，键里带它）
  requested_at  timestamptz NOT NULL,
  object_key    text,
  done_at       timestamptz,
  attempts      integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  -- 下次可领的时间：领任务时推后（租约，进程崩了到点会被重新领）；失败后按次数退避
  next_try_at   timestamptz NOT NULL,
  -- 只记原因代码，不记业务数据
  last_error    text,
  cancelled_at  timestamptz,
  -- 生成和清理分开记（PR #20 Codex 4）：done_at 是这一版的包生成好了；stale_cleared_at 是 exports/<店>/ 里比这一版更早的包删完了。
  -- 清理失败只让 stale_cleared_at 留空、下一轮单独重试，不碰已完成的包
  stale_cleared_at timestamptz,
  CHECK ((done_at IS NULL) = (object_key IS NULL)),
  CHECK (stale_cleared_at IS NULL OR done_at IS NOT NULL)
);

-- 已清除的店：只记店 id 和时间（不含任何业务数据），用来在库里的行删掉之后继续重试删除记录、OSS 和本机缓存的清理。
-- 删除记录的正本在 OSS deletions/（不随备份回滚，§9.4）；这张表只是清理进度。
CREATE TABLE store_purges (
  store_id           uuid PRIMARY KEY,
  purged_at          timestamptz NOT NULL,
  -- 最近一次按前缀清理成功的时间。清除之后至少隔 1 小时（RESCAN_DELAY_MS）的那一遍做完才记 objects_cleared_at（§14 T17）：
  -- 在途的上传（图片、导出包）可能在第一遍之后才落地
  swept_at           timestamptz,
  objects_cleared_at timestamptz,
  attempts           integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  last_error         text,
  CHECK (objects_cleared_at IS NULL OR swept_at IS NOT NULL)
);

-- 存档桶里要删、但删除时失败了的对象（PR #20 Codex 第二轮 2）：作废的导出包（生成期间撤回或清除、写回没成）、生成失败时已经写进去的包。
-- 这些包没有任务行指向它，前缀清理也未必还会来，所以持久化一条待删标记，定时任务（runExportJobs 每轮）按退避重试，删掉才删这一行。
-- 只有店 id、对象键和原因代码，不含业务数据。
CREATE TABLE object_discards (
  object_key  text PRIMARY KEY,
  store_id    uuid NOT NULL,
  created_at  timestamptz NOT NULL,
  attempts    integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  next_try_at timestamptz NOT NULL,
  last_error  text
);
