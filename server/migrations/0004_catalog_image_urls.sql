-- 0004：条码库保留快鸟返回的完整图片地址列表（PR #39，按真实录制件校准）。
-- 快鸟一条商品可能有多张图（Image[].Imageurl）；image_url 仍是第一张（图片任务照旧只下它），image_urls 留全部，给以后多图选择用。
-- 向前兼容：旧行是空数组（读的时候 image_urls 为空就退回 image_url）。只收 http/https、去重，由服务器写入。
ALTER TABLE barcode_catalog ADD COLUMN image_urls text[] NOT NULL DEFAULT '{}';
