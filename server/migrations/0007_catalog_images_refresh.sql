-- 0007（真机 11/26 修复 2）：换商品图时候选为空（S22d 之前查过的老条码），或候选全部失败（#52 之前 bad_type、链接过期）时，
-- 服务器重新问一次快鸟、刷新条码库并重新登记候选。快鸟按次计费，这一列记上一次刷新的时间，每个条码一天最多一次。
-- 回滚：ALTER TABLE barcode_catalog DROP COLUMN images_refreshed_at;（只是节流记录，删了最多当天多刷新一次）
ALTER TABLE barcode_catalog ADD COLUMN images_refreshed_at timestamptz;
