// roundDiv（§5.0，规则）：四舍五入到整数，恰好一半时远离零；对负数对称 roundDiv(−a, b) = −roundDiv(a, b)。
// 服务器上凡是金额相乘的中间运算一律用 BigInt，所以这里只收 BigInt。向量：contracts/vectors/rounddiv.json。

export function roundDiv(a: bigint, b: bigint): bigint {
  if (b <= 0n) throw new RangeError(`roundDiv 的除数必须为正：${b}`);
  const q = a / b; // BigInt 除法向零截断
  const r = a % b; // 与 a 同号，|r| < b
  const absR = r < 0n ? -r : r;
  if (2n * absR >= b) return a < 0n ? q - 1n : q + 1n;
  return q;
}
