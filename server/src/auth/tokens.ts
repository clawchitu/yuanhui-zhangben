// 设备令牌和开通码：256 位随机数，base64url；库里只存 sha256（十六进制）。原文只在生成的那一次响应里出现。
import { createHash, randomBytes } from "node:crypto";

export function newSecret(): string {
  return randomBytes(32).toString("base64url");
}

export function sha256Hex(s: string): string {
  return createHash("sha256").update(s, "utf8").digest("hex");
}

/** 二维码内容的前缀（§7）：`YHZB1:<code>`，接口里只传 `<code>` */
export const PAIRING_QR_PREFIX = "YHZB1:";
