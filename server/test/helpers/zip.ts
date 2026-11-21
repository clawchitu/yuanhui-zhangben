// 测试用的 ZIP 读取：按中央目录找每个文件，核对本地头、数据描述符、CRC32，解压出内容。
// 只认 src/export/zip.ts 写出的那种包（deflate + 数据描述符），写错了这里会抛错。
import { crc32, inflateRawSync } from "node:zlib";

export function readZip(buf: Buffer): Map<string, Buffer> {
  const eocd = buf.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  if (eocd < 0 || eocd !== buf.length - 22) throw new Error("没有结尾记录");
  const count = buf.readUInt16LE(eocd + 10);
  const cdSize = buf.readUInt32LE(eocd + 12);
  let p = buf.readUInt32LE(eocd + 16);
  if (p + cdSize !== eocd) throw new Error("中央目录位置不对");
  const out = new Map<string, Buffer>();
  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error("中央目录项签名不对");
    const flags = buf.readUInt16LE(p + 8);
    const method = buf.readUInt16LE(p + 10);
    const crc = buf.readUInt32LE(p + 16);
    const csize = buf.readUInt32LE(p + 20);
    const usize = buf.readUInt32LE(p + 24);
    const nlen = buf.readUInt16LE(p + 28);
    const elen = buf.readUInt16LE(p + 30);
    const clen = buf.readUInt16LE(p + 32);
    const off = buf.readUInt32LE(p + 42);
    const name = buf.subarray(p + 46, p + 46 + nlen).toString("utf8");
    if (!(flags & 0x0800)) throw new Error("文件名没标 UTF-8");
    if (method !== 8) throw new Error("不是 deflate");
    if (buf.readUInt32LE(off) !== 0x04034b50) throw new Error("本地头签名不对");
    const lnlen = buf.readUInt16LE(off + 26);
    const lelen = buf.readUInt16LE(off + 28);
    if (buf.subarray(off + 30, off + 30 + lnlen).toString("utf8") !== name) throw new Error("本地头文件名不一致");
    const dataStart = off + 30 + lnlen + lelen;
    const data = inflateRawSync(buf.subarray(dataStart, dataStart + csize));
    if (data.length !== usize) throw new Error(`${name} 大小不对`);
    if (crc32(data) >>> 0 !== crc) throw new Error(`${name} CRC 不对`);
    const d = dataStart + csize;
    if (buf.readUInt32LE(d) !== 0x08074b50 || buf.readUInt32LE(d + 4) !== crc || buf.readUInt32LE(d + 8) !== csize || buf.readUInt32LE(d + 12) !== usize) {
      throw new Error(`${name} 数据描述符不对`);
    }
    out.set(name, data);
    p += 46 + nlen + elen + clen;
  }
  return out;
}
