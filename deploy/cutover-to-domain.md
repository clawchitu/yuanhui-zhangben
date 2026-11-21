# 备案通过后切换到域名

步骤以 docs/plan-v2.md §9.3 为准，这里只记操作细节：

1. 在阿里云备案控制台确认网站备案和 App 备案**都已通过**，记下备案号；30 天内做公安备案。
2. 这时才给 `yuanhuishop.cn`、`api.yuanhuishop.cn` 加 A 记录指向 47.117.184.253（备案通过前两个域名都不解析到这台 ECS，§14 S10a-4）。
3. 把 `deploy/Caddyfile.domain` 的两个站点追加进 `deploy/Caddyfile.ip`（`(common)` 片段共用），IP 站点保留；静态页放 `/srv/site`（compose.yml 加只读挂载 `deploy/site`）。
4. `deploy/deploy.sh <当前标签> --execute`：校验新 Caddyfile 后 `caddy reload`（失败自动换回上一份配置）；`docker logs yuanhui-caddy-1 2>&1 | grep 'certificate obtained'` 看到两张证书签发成功。
5. 从本机和手机蜂窝网络验证 `https://api.yuanhuishop.cn/healthz`；NAT64 下再验一次。
6. 之后按 §9.3 第 4–8 步。
