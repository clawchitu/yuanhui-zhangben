// 服务器自己生成的行 id（补偿 / 冲销流水、保质期批次）：由店 id 和来源算出来，不用随机数。
// 同一家店、同一串 op 按同样顺序应用，得到逐行相同的 id —— 演示店每日重置「与种子逐表一致」（S09）靠它；
// 平时也让同一份账重放出来一模一样。来源本身在店内唯一（op id + seq、来源流水 id），算出来的 id 在店内也唯一
// （SHA-256 截 122 位，与手机生成的随机 UUID 撞上的概率可以忽略；主键是 (store_id, id)，撞上会报错而不是静默覆盖）。
import { createHash } from "node:crypto";

export function derivedId(storeId: string, ...parts: string[]): string {
  const h = createHash("sha256").update(["derived", storeId.toLowerCase(), ...parts].join(":")).digest();
  h[6] = (h[6]! & 0x0f) | 0x40;
  h[8] = (h[8]! & 0x3f) | 0x80;
  const x = h.subarray(0, 16).toString("hex");
  return `${x.slice(0, 8)}-${x.slice(8, 12)}-${x.slice(12, 16)}-${x.slice(16, 20)}-${x.slice(20, 32)}`;
}
