-- 0006（S22d-server 第二轮返修）：商品图内容的 sha256，选图 / 拍照上传按它判幂等（同一张不升版本），不再比对对象键。
-- 对象键改成每次请求独有（带随机后缀），任何两路请求不共用键；image_sha256 由服务器在店铺锁里和 image_key 一起写。旧行为空。
ALTER TABLE products ADD COLUMN image_sha256 text CHECK (image_sha256 ~ '^[0-9a-f]{64}$');
