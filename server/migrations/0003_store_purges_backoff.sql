-- 0003：已清除店的对象清理失败后退避（PR #27 Fable S10r-11）。
-- 连续失败（例如商品图桶不存在、配错桶名）时不再每一轮都重试：第 3 次起按次数退避，同时打 alert=purge_objects_failed。
-- 空表示「随时可以试」（清理成功后也清空）。
ALTER TABLE store_purges ADD COLUMN next_try_at timestamptz;
