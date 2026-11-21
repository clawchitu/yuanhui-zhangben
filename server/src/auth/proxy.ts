// 反代后面取客户端 IP（§14 S03-6、S10a）：只信一跳，并且只信 Caddy 的地址。
// Fastify 5 对「跳数」形式的 trustProxy（数字）一律不信（它没法确认直接对端就是反代），所以这里按地址判断：
// - 第 0 项（TCP 对端）在 TRUSTED_PROXY 名单里 → 信它一次，req.ip 取 X-Forwarded-For 最右边那一项（Caddy 追加的、它看到的对端地址）；
// - 再往左的项（客户端自己带的）一律不信，伪造多少层都换不出新的限速额度；
// - 对端不在名单里（有人绕过 Caddy 直连 api 端口）→ 完全不看 X-Forwarded-For，req.ip 就是对端地址。
import { BlockList, isIP } from "node:net";

export class ProxyListError extends Error {}

/** 解析 TRUSTED_PROXY：逗号分隔的 IP 或 CIDR（如 `172.30.0.2` 或 `172.30.0.0/29`）。格式不对抛 ProxyListError */
export function parseProxyList(raw: string): string[] {
  const items = raw.split(",").map((s) => s.trim()).filter(Boolean);
  for (const it of items) {
    const [addr, bits, ...rest] = it.split("/");
    const fam = isIP(addr ?? "");
    if (!fam || rest.length) throw new ProxyListError(`不是合法的 IP / CIDR：${it}`);
    if (bits !== undefined && (!/^\d+$/.test(bits) || Number(bits) > (fam === 4 ? 32 : 128))) throw new ProxyListError(`前缀长度不对：${it}`);
    // 前缀长度 0（0.0.0.0/0、::/0）等于信所有对端，伪造的头又能换额度了（PR #22 Fable，§14 S03-6 补）
    if (bits !== undefined && Number(bits) === 0) throw new ProxyListError(`前缀长度不许是 0（等于信所有对端）：${it}`);
  }
  return items;
}

const unmap = (a: string) => (a.startsWith("::ffff:") && isIP(a.slice(7)) === 4 ? a.slice(7) : a);

/** 给 Fastify trustProxy 用的判断函数：只有第 0 跳、且地址在名单里才信 */
export function proxyTrust(list: string[]): (addr: string, hop: number) => boolean {
  const bl = new BlockList();
  for (const it of list) {
    const [addr, bits] = it.split("/") as [string, string | undefined];
    const type = isIP(addr) === 6 ? "ipv6" : "ipv4";
    if (bits === undefined) bl.addAddress(addr, type);
    else bl.addSubnet(addr, Number(bits), type);
  }
  return (addr, hop) => {
    if (hop !== 0 || !addr) return false;
    const a = unmap(addr);
    const fam = isIP(a);
    return fam !== 0 && bl.check(a, fam === 6 ? "ipv6" : "ipv4");
  };
}
