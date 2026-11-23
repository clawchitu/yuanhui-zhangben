-- 0005：商品图候选（S22d-server）。查码查到、有图片地址时，服务器把前 6 张转存成 200px 缩图，给手机选。
-- 全局、不分店（与 barcode_catalog 一致）；ready 的不按时间过期，与条码库那一行同寿（§14 S22d-1）。
-- 状态：pending 待下载（含失败待重试）→ ready 已转存（cid、object_key 必有）/ failed 放弃（last_error 只记原因代码）。
-- 重试共 3 次（attempts 是已领取次数），由进程内 worker 和调度器 images 任务领取；source_url 只在服务器内部用，不进日志、不下发。
CREATE TABLE catalog_image_candidates (
  barcode     text NOT NULL REFERENCES barcode_catalog (barcode) ON DELETE CASCADE,
  idx         integer NOT NULL CHECK (idx BETWEEN 0 AND 5),
  source_url  text NOT NULL,
  state       text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'ready', 'failed')),
  cid         text CHECK (cid ~ '^[0-9a-f]{16}$'),
  object_key  text,
  attempts    integer NOT NULL DEFAULT 0 CHECK (attempts BETWEEN 0 AND 3),
  next_try_at timestamptz NOT NULL DEFAULT now(),
  last_error  text,
  fetched_at  timestamptz,
  PRIMARY KEY (barcode, idx),
  CHECK (state <> 'ready' OR (cid IS NOT NULL AND object_key IS NOT NULL))
);
-- 同一条码内容相同的只留一张（后到的记 failed duplicate）
CREATE UNIQUE INDEX catalog_image_candidates_cid_key ON catalog_image_candidates (barcode, cid) WHERE state = 'ready';
CREATE INDEX catalog_image_candidates_due_idx ON catalog_image_candidates (next_try_at) WHERE state = 'pending';
