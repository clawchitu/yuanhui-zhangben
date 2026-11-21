// 最小的流式 ZIP 写入器（注销导出包用，S09）。只做导出需要的：deflate、UTF-8 文件名、数据描述符（bit 3）。
// 每个文件的内容以异步迭代器给进来，边压缩边写出，不在内存里攒整份文件：3 年的流水几十万行也只占一页的内存。
// 不做 ZIP64：单个文件或整个包超过 4 GiB 直接报错（一家小店的账离这个量级差好几个数量级）。
import { createDeflateRaw, crc32 } from "node:zlib";
import { once } from "node:events";
import type { Writable } from "node:stream";

const MAX32 = 0xffffffff;

interface CentralEntry {
  name: Buffer;
  crc: number;
  csize: number;
  usize: number;
  offset: number;
  dosTime: number;
  dosDate: number;
}

/** 本地时间（导出时按北京时间写）→ DOS 时间 / 日期 */
function dos(d: Date): { time: number; date: number } {
  const sh = new Date(d.getTime() + 8 * 3_600_000);
  const time = (sh.getUTCHours() << 11) | (sh.getUTCMinutes() << 5) | Math.floor(sh.getUTCSeconds() / 2);
  const date = ((Math.max(sh.getUTCFullYear(), 1980) - 1980) << 9) | ((sh.getUTCMonth() + 1) << 5) | sh.getUTCDate();
  return { time, date };
}

export class ZipWriter {
  private readonly out: Writable;
  private readonly when: { time: number; date: number };
  private offset = 0;
  private readonly entries: CentralEntry[] = [];
  private finished = false;

  constructor(out: Writable, modified: Date) {
    this.out = out;
    this.when = dos(modified);
  }

  private async write(b: Buffer): Promise<void> {
    this.offset += b.length;
    if (this.offset > MAX32) throw new Error("导出包超过 4 GiB");
    if (!this.out.write(b)) await once(this.out, "drain");
  }

  /** 追加一个文件。content 逐块产出（字符串按 UTF-8） */
  async addFile(name: string, content: AsyncIterable<string | Buffer> | Iterable<string | Buffer>): Promise<void> {
    if (this.finished) throw new Error("已经写完了");
    const nameBuf = Buffer.from(name, "utf8");
    const offset = this.offset;
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4); // 解压所需版本 2.0
    local.writeUInt16LE(0x0808, 6); // bit 3 数据描述符 + bit 11 UTF-8 文件名
    local.writeUInt16LE(8, 8); // deflate
    local.writeUInt16LE(this.when.time, 10);
    local.writeUInt16LE(this.when.date, 12);
    // crc、两个大小留 0，写在数据描述符里
    local.writeUInt16LE(nameBuf.length, 26);
    await this.write(local);
    await this.write(nameBuf);

    let crc = 0;
    let usize = 0;
    let csize = 0;
    const deflate = createDeflateRaw({ level: 6 });
    const pending: Buffer[] = [];
    deflate.on("data", (c: Buffer) => pending.push(c));
    const flushOut = async () => {
      while (pending.length) {
        const c = pending.shift()!;
        csize += c.length;
        await this.write(c);
      }
    };
    for await (const part of content as AsyncIterable<string | Buffer>) {
      const b = typeof part === "string" ? Buffer.from(part, "utf8") : part;
      if (b.length === 0) continue;
      crc = crc32(b, crc);
      usize += b.length;
      if (usize > MAX32) throw new Error(`${name} 超过 4 GiB`);
      if (!deflate.write(b)) await once(deflate, "drain");
      await flushOut();
    }
    const ended = once(deflate, "end");
    deflate.end();
    await ended;
    await flushOut();

    const desc = Buffer.alloc(16);
    desc.writeUInt32LE(0x08074b50, 0);
    desc.writeUInt32LE(crc >>> 0, 4);
    desc.writeUInt32LE(csize, 8);
    desc.writeUInt32LE(usize, 12);
    await this.write(desc);
    this.entries.push({ name: nameBuf, crc: crc >>> 0, csize, usize, offset, dosTime: this.when.time, dosDate: this.when.date });
  }

  /** 写中央目录和结尾记录。不关闭 out（调用方负责） */
  async finish(): Promise<void> {
    if (this.finished) return;
    this.finished = true;
    const cdStart = this.offset;
    for (const e of this.entries) {
      const h = Buffer.alloc(46);
      h.writeUInt32LE(0x02014b50, 0);
      h.writeUInt16LE(0x0314, 4); // 制作者：Unix，2.0
      h.writeUInt16LE(20, 6);
      h.writeUInt16LE(0x0808, 8);
      h.writeUInt16LE(8, 10);
      h.writeUInt16LE(e.dosTime, 12);
      h.writeUInt16LE(e.dosDate, 14);
      h.writeUInt32LE(e.crc, 16);
      h.writeUInt32LE(e.csize, 20);
      h.writeUInt32LE(e.usize, 24);
      h.writeUInt16LE(e.name.length, 28);
      h.writeUInt32LE((0o100640 << 16) >>> 0, 38); // 外部属性：普通文件 0640
      h.writeUInt32LE(e.offset, 42);
      await this.write(h);
      await this.write(e.name);
    }
    const cdSize = this.offset - cdStart;
    const end = Buffer.alloc(22);
    end.writeUInt32LE(0x06054b50, 0);
    end.writeUInt16LE(this.entries.length, 8);
    end.writeUInt16LE(this.entries.length, 10);
    end.writeUInt32LE(cdSize, 12);
    end.writeUInt32LE(cdStart, 16);
    await this.write(end);
  }
}
