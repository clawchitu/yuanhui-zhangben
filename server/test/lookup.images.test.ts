// 商品图的下载与缩图（S08）：防 SSRF（协议、端口、内网地址、DNS 重绑定、跳转）、≤ 5 MB、超时、格式白名单、尺寸、元数据。
import http from "node:http";
import type { AddressInfo } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { crc32 } from "node:zlib";
import sharp from "sharp";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  DEFAULT_FETCH_POLICY,
  ImageCache,
  ImageRejected,
  MAX_IMAGE_BYTES,
  checkImageUrl,
  extractEmbeddedImage,
  fetchImage,
  isPublicAddress,
  makeThumbnail,
  sniffFormat,
  type FetchPolicy,
} from "../src/lookup/images.ts";
import { LocalDirObjectStore, MemoryObjectStore, imageKey, isImageKey, safeJoin } from "../src/lookup/oss.ts";

const reason = async (p: Promise<unknown>) => {
  try {
    await p;
  } catch (e) {
    if (e instanceof ImageRejected) return e.reason;
    return `other:${(e as Error).message}`;
  }
  return "ok";
};

const png = (w: number, h: number, alpha = false) =>
  sharp({ create: { width: w, height: h, channels: alpha ? 4 : 3, background: alpha ? { r: 255, g: 0, b: 0, alpha: 0.5 } : "#3366cc" } })
    .png()
    .toBuffer();

/** 只有文件头的 PNG：IHDR 声明 w×h，像素数据只有一点（解压炸弹的样子） */
function pngHeaderOnly(w: number, h: number): Buffer {
  const chunk = (type: string, data: Buffer) => {
    const len = Buffer.alloc(4);
    len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(td) >>> 0);
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;
  ihdr[9] = 2;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", ihdr),
    chunk("IDAT", Buffer.from([0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const jpeg = (w: number, h: number) => sharp({ create: { width: w, height: h, channels: 3, background: "#cc6633" } }).jpeg().toBuffer();

/** 仿 api-yun getPic 的页面（结构照 2026-11-26 实测响应：__VIEWSTATE 里还有一份 base64 过的 data URI，图在 <img id="pictrue"> 的 src 里） */
const apiYunPage = (src: string) =>
  Buffer.from(
    `\r\n<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">\r\n` +
      `<html xmlns="http://www.w3.org/1999/xhtml">\r\n<head><title>\r\n\r\n</title></head>\r\n<body>\r\n` +
      `    <form name="form1" method="post" action="./0" id="form1">\r\n` +
      `<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="${Buffer.from(src).toString("base64")}" />\r\n` +
      `        <div>\r\n            <img id="pictrue" src="${src}" border="0" />\r\n        </div>\r\n    </form>\r\n</body>\r\n</html>\r\n`,
  );
const dataUri = (type: string, b: Buffer) => `data:image/${type};base64,${b.toString("base64")}`;
const rejectReason = (f: () => unknown) => {
  try {
    f();
  } catch (e) {
    if (e instanceof ImageRejected) return e.reason;
    return `other:${(e as Error).message}`;
  }
  return "ok";
};

describe("extractEmbeddedImage（getPic 返回 HTML 内嵌 base64 图）", () => {
  it("HTML 嵌 JPEG → 取出原样的 JPEG", async () => {
    const j = await jpeg(64, 48);
    expect(extractEmbeddedImage(apiYunPage(dataUri("jpeg", j))).equals(j)).toBe(true);
  });
  it("HTML 嵌 PNG → 取出原样的 PNG", async () => {
    const p = await png(64, 48);
    expect(extractEmbeddedImage(apiYunPage(dataUri("png", p))).equals(p)).toBe(true);
  });
  it("HTML 嵌 WebP；大写标签、单引号、没有 >；第一个 <img> 不是 data 图、第二个才是 → 都取得到", async () => {
    const w = await sharp({ create: { width: 40, height: 30, channels: 3, background: "#118844" } }).webp().toBuffer();
    expect(extractEmbeddedImage(apiYunPage(dataUri("webp", w))).equals(w)).toBe(true);
    const j = await jpeg(32, 32);
    expect(extractEmbeddedImage(Buffer.from(`<IMG ID=x SRC='${dataUri("JPEG", j)}'>`)).equals(j)).toBe(true);
    expect(extractEmbeddedImage(Buffer.from(`<img src="${dataUri("jpeg", j)}"`)).equals(j)).toBe(true);
    expect(extractEmbeddedImage(Buffer.from(`<img src="/logo.png"><p>x</p><img alt="a" src="${dataUri("jpeg", j)}" />`)).equals(j)).toBe(true);
  });
  it("恶意页面：大量 src=\"data:… 前缀而不在 <img> 里 → 线性时间内 bad_type（PR #52 评审）", () => {
    const unit = ' src="data:image/png;base64,';
    for (const page of [unit.repeat(200_000), "<img>" + unit.repeat(200_000), "<img a>".repeat(400_000), `<img ${"x".repeat(5_000_000)}`]) {
      const t0 = performance.now();
      expect(rejectReason(() => extractEmbeddedImage(Buffer.from(page, "latin1")))).toBe("bad_type");
      expect(performance.now() - t0).toBeLessThan(1000);
    }
  });
  it("HTML 里没有图（链接过期时 src 是空的）、只有 __VIEWSTATE、不在 <img> 里、data-src → bad_type", async () => {
    const j = await jpeg(32, 32);
    expect(rejectReason(() => extractEmbeddedImage(apiYunPage("")))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(Buffer.from("<html><body>请求超时</body></html>")))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(Buffer.from(`<a href="x" src="${dataUri("jpeg", j)}">x</a>`)))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(Buffer.from(`<p> src="${dataUri("jpeg", j)}"</p>`)))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(Buffer.from(`<img data-src="${dataUri("jpeg", j)}">`)))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(Buffer.from(`<img src="${dataUri("gif", j)}">`)))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(Buffer.from(`<img src="data:image/svg+xml;base64,PHN2Zz4=">`)))).toBe("bad_type");
  });
  it("base64 损坏（非法字符、长度不对、没结束引号、填充错）→ bad_type", async () => {
    const b = (await jpeg(32, 32)).toString("base64");
    for (const bad of [b.slice(0, 40) + "!@#$" + b.slice(44), b.slice(0, -1), b.slice(0, 8) + "=" + b.slice(9), "/9j/4AA=Q"]) {
      expect(rejectReason(() => extractEmbeddedImage(apiYunPage(`data:image/jpeg;base64,${bad}`)))).toBe("bad_type");
    }
    expect(rejectReason(() => extractEmbeddedImage(Buffer.from(`<img src="data:image/jpeg;base64,${b}`)))).toBe("bad_type");
  });
  it("解出来超过大小上限 → too_large（不先整段解码）", async () => {
    const j = await jpeg(32, 32);
    expect(rejectReason(() => extractEmbeddedImage(apiYunPage(dataUri("jpeg", j)), j.length - 1))).toBe("too_large");
    expect(extractEmbeddedImage(apiYunPage(dataUri("jpeg", j)), j.length).equals(j)).toBe(true);
    const big = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff]), Buffer.alloc(MAX_IMAGE_BYTES)]);
    expect(rejectReason(() => extractEmbeddedImage(apiYunPage(dataUri("jpeg", big))))).toBe("too_large");
  });
  it("魔数和声明的类型不一致 → bad_type", async () => {
    const j = await jpeg(32, 32);
    const p = await png(32, 32);
    expect(rejectReason(() => extractEmbeddedImage(apiYunPage(dataUri("png", j))))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(apiYunPage(dataUri("jpeg", p))))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(apiYunPage(dataUri("webp", p))))).toBe("bad_type");
    expect(rejectReason(() => extractEmbeddedImage(apiYunPage(dataUri("jpeg", Buffer.from("<svg onload=alert(1)>")))))).toBe("bad_type");
  });
});

describe("isPublicAddress", () => {
  it.each([
    "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "169.254.169.254", "100.100.100.200",
    "0.0.0.0", "100.64.0.1", "224.0.0.1", "255.255.255.255", "198.18.0.1",
    "::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "::ffff:10.0.0.1",
    "2001:db8::1", "2002:7f00:1::", "64:ff9b::7f00:1", "not-an-ip",
  ])("%s 不是公网", (ip) => {
    expect(isPublicAddress(ip)).toBe(false);
  });
  it.each(["1.1.1.1", "47.96.0.1", "8.8.8.8", "2400:3200::1", "2606:4700::1111", "::ffff:8.8.8.8"])("%s 是公网", (ip) => {
    expect(isPublicAddress(ip)).toBe(true);
  });
});

describe("checkImageUrl", () => {
  const P = DEFAULT_FETCH_POLICY;
  it.each([
    ["file:///etc/passwd", "bad_scheme"],
    ["ftp://img.example.com/a.jpg", "bad_scheme"],
    ["gopher://img.example.com/", "bad_scheme"],
    ["javascript:alert(1)", "bad_scheme"],
    ["data:image/png;base64,AAAA", "bad_scheme"],
    ["http://user:pass@img.example.com/a.jpg", "bad_url"],
    ["http://img.example.com:8080/a.jpg", "bad_port"],
    ["http://img.example.com:22/a.jpg", "bad_port"],
    ["http://127.0.0.1/a.jpg", "private_address"],
    ["http://2130706433/a.jpg", "private_address"],
    ["http://0x7f.1/a.jpg", "private_address"],
    ["http://0177.0.0.1/a.jpg", "private_address"],
    ["http://[::1]/a.jpg", "private_address"],
    ["http://[::ffff:127.0.0.1]/a.jpg", "private_address"],
    ["http://169.254.169.254/latest/meta-data/", "private_address"],
    ["http://100.100.100.200/latest/meta-data/", "private_address"],
    ["not a url", "bad_url"],
    [`https://img.example.com/${"a".repeat(2100)}`, "bad_url"],
  ])("%s → %s", (u, why) => {
    expect(() => checkImageUrl(u, P)).toThrow(ImageRejected);
    try {
      checkImageUrl(u, P);
    } catch (e) {
      expect((e as ImageRejected).reason).toBe(why);
    }
  });
  it("公网的 http/https 默认端口放行", () => {
    expect(checkImageUrl("https://img.example.com/a.jpg", P).hostname).toBe("img.example.com");
    expect(checkImageUrl("http://8.8.8.8:80/a.jpg", P).hostname).toBe("8.8.8.8");
  });
});

describe("fetchImage（本机假图床）", () => {
  let server: http.Server;
  let port = 0;
  let hits: string[] = [];
  let routes: Record<string, (req: http.IncomingMessage, res: http.ServerResponse) => void> = {};
  let goodPng: Buffer;

  beforeAll(async () => {
    goodPng = await png(400, 300);
    server = http.createServer((req, res) => {
      hits.push(req.url!);
      const h = routes[req.url!];
      if (h) return h(req, res);
      res.writeHead(404).end();
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
    port = (server.address() as AddressInfo).port;
  });
  afterAll(() => new Promise<void>((r) => server.close(() => r())));

  // 测试放行：只有 127.0.0.1 当作「公网」，端口放行假图床的端口；其余仍按真实规则
  const policy = (o: Partial<FetchPolicy> = {}): FetchPolicy => ({
    ...DEFAULT_FETCH_POLICY,
    allowAddress: (ip) => ip === "127.0.0.1",
    allowPorts: [port],
    resolve: async (h) => (h === "img.test" ? [{ address: "127.0.0.1", family: 4 }] : []),
    timeoutMs: 1500,
    ...o,
  });
  const reset = () => {
    hits = [];
    routes = {};
  };

  it("正常下载", async () => {
    reset();
    routes["/a.png"] = (_q, s) => s.writeHead(200, { "content-type": "image/png" }).end(goodPng);
    const b = await fetchImage(`http://img.test:${port}/a.png`, policy());
    expect(b.equals(goodPng)).toBe(true);
  });

  it("主机名解析到内网 → 拒，假图床一次请求都没收到", async () => {
    reset();
    routes["/a.png"] = (_q, s) => s.writeHead(200).end(goodPng);
    const p = policy({ allowAddress: isPublicAddress, resolve: async () => [{ address: "127.0.0.1", family: 4 }] });
    expect(await reason(fetchImage(`http://evil.test:${port}/a.png`, p))).toBe("private_address");
    expect(hits).toEqual([]);
  });

  it("DNS 重绑定：解析结果里混着一个内网地址 → 整个拒（连接只用校验过的地址）", async () => {
    reset();
    const p = policy({
      allowAddress: isPublicAddress,
      resolve: async () => [
        { address: "8.8.8.8", family: 4 },
        { address: "127.0.0.1", family: 4 },
      ],
    });
    expect(await reason(fetchImage(`http://evil.test:${port}/a.png`, p))).toBe("private_address");
    expect(hits).toEqual([]);
  });

  it("跳转到内网 / 元数据地址 / 非 http 协议 → 拒；跳转次数有上限", async () => {
    reset();
    routes["/r-meta"] = (_q, s) => s.writeHead(302, { location: "http://169.254.169.254/latest/meta-data/" }).end();
    routes["/r-file"] = (_q, s) => s.writeHead(301, { location: "file:///etc/passwd" }).end();
    routes["/r-loop"] = (_q, s) => s.writeHead(302, { location: "/r-loop" }).end();
    routes["/r-ok"] = (_q, s) => s.writeHead(307, { location: "/a.png" }).end();
    routes["/a.png"] = (_q, s) => s.writeHead(200, { "content-type": "image/png" }).end(goodPng);
    expect(await reason(fetchImage(`http://img.test:${port}/r-meta`, policy({ allowPorts: [port, 80] })))).toBe("private_address");
    expect(await reason(fetchImage(`http://img.test:${port}/r-file`, policy()))).toBe("bad_scheme");
    expect(await reason(fetchImage(`http://img.test:${port}/r-loop`, policy()))).toBe("too_many_redirects");
    expect(hits.filter((h) => h === "/r-loop")).toHaveLength(DEFAULT_FETCH_POLICY.maxRedirects + 1);
    expect((await fetchImage(`http://img.test:${port}/r-ok`, policy())).equals(goodPng)).toBe(true);
  });

  it("超过 5 MB：声明的长度超了直接拒；不声明长度的边读边数，超了就断", async () => {
    reset();
    routes["/big-declared"] = (_q, s) => {
      s.writeHead(200, { "content-type": "image/jpeg", "content-length": String(MAX_IMAGE_BYTES + 1) });
      s.write(Buffer.alloc(1024));
    };
    let sent = 0;
    routes["/big-chunked"] = (_q, s) => {
      s.writeHead(200, { "content-type": "image/jpeg" });
      const chunk = Buffer.alloc(256 * 1024);
      const pump = () => {
        while (sent < MAX_IMAGE_BYTES * 3) {
          sent += chunk.length;
          if (!s.write(chunk)) return void s.once("drain", pump);
        }
        s.end();
      };
      s.on("error", () => {});
      pump();
    };
    expect(await reason(fetchImage(`http://img.test:${port}/big-declared`, policy()))).toBe("too_large");
    expect(await reason(fetchImage(`http://img.test:${port}/big-chunked`, policy()))).toBe("too_large");
    // 没把 15 MB 全读完就断了
    expect(sent).toBeLessThan(MAX_IMAGE_BYTES * 3);
  });

  it("不响应 → 到时就放弃（timeout）", async () => {
    reset();
    routes["/hang"] = () => {};
    const t0 = Date.now();
    expect(await reason(fetchImage(`http://img.test:${port}/hang`, policy({ timeoutMs: 300 })))).toBe("timeout");
    expect(Date.now() - t0).toBeLessThan(1500);
  });

  it("非 200、明显不是图片的 Content-Type → 拒", async () => {
    reset();
    routes["/500"] = (_q, s) => s.writeHead(500).end();
    routes["/html"] = (_q, s) => s.writeHead(200, { "content-type": "text/html" }).end("<html>");
    expect(await reason(fetchImage(`http://img.test:${port}/500`, policy()))).toBe("bad_status");
    expect(await reason(fetchImage(`http://img.test:${port}/html`, policy()))).toBe("bad_type");
  });

  it("getPic 式响应：text/html 内嵌 base64 JPEG / PNG → 取出图；没图、超大照旧拒；原本就是图片的走原路径", async () => {
    reset();
    const j = await jpeg(300, 200);
    routes["/getPic-jpeg"] = (_q, s) => s.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(apiYunPage(dataUri("jpeg", j)));
    routes["/getPic-png"] = (_q, s) => s.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(apiYunPage(dataUri("png", goodPng)));
    routes["/getPic-expired"] = (_q, s) => s.writeHead(200, { "content-type": "text/html; charset=utf-8" }).end(apiYunPage(""));
    routes["/getPic-big"] = (_q, s) =>
      s.writeHead(200, { "content-type": "text/html", "content-length": String(MAX_IMAGE_BYTES * 4 + 1) }).end();
    routes["/getPic-big-chunked"] = (_q, s) => {
      s.writeHead(200, { "content-type": "text/html" });
      s.on("error", () => {});
      s.end(Buffer.alloc(MAX_IMAGE_BYTES * 4 + 1024, 0x20));
    };
    routes["/plain.png"] = (_q, s) => s.writeHead(200, { "content-type": "image/png" }).end(goodPng);
    routes["/png-as-html"] = (_q, s) => s.writeHead(200, { "content-type": "text/html" }).end(goodPng);
    expect((await fetchImage(`http://img.test:${port}/getPic-jpeg`, policy())).equals(j)).toBe(true);
    expect((await fetchImage(`http://img.test:${port}/getPic-png`, policy())).equals(goodPng)).toBe(true);
    expect((await sharp(await makeThumbnail(await fetchImage(`http://img.test:${port}/getPic-jpeg`, policy()))).metadata()).format).toBe("jpeg");
    expect(await reason(fetchImage(`http://img.test:${port}/getPic-expired`, policy()))).toBe("bad_type");
    expect(await reason(fetchImage(`http://img.test:${port}/getPic-big`, policy()))).toBe("too_large");
    expect(await reason(fetchImage(`http://img.test:${port}/getPic-big-chunked`, policy({ timeoutMs: 5000 })))).toBe("too_large");
    expect(await reason(fetchImage(`http://img.test:${port}/png-as-html`, policy()))).toBe("bad_type");
    expect((await fetchImage(`http://img.test:${port}/plain.png`, policy())).equals(goodPng)).toBe(true);
  });
});

describe("makeThumbnail", () => {
  it("长边 200 的 JPEG，等比；小图不放大；透明底垫白", async () => {
    const out = await makeThumbnail(await png(1000, 500));
    const m = await sharp(out).metadata();
    expect([m.format, m.width, m.height]).toEqual(["jpeg", 200, 100]);
    const tall = await sharp(await makeThumbnail(await png(300, 900))).metadata();
    expect([tall.width, tall.height]).toEqual([67, 200]);
    const small = await sharp(await makeThumbnail(await png(50, 40))).metadata();
    expect([small.width, small.height]).toEqual([50, 40]);
    const a = await sharp(await makeThumbnail(await png(100, 100, true))).metadata();
    expect([a.format, a.hasAlpha]).toEqual(["jpeg", false]);
  });

  it("JPEG / WebP / GIF 都收；输出不带 EXIF 等元数据", async () => {
    const jpeg = await sharp({ create: { width: 640, height: 480, channels: 3, background: "#888" } })
      .jpeg()
      .withExif({ IFD0: { Copyright: "secret-owner", Artist: "someone" } })
      .toBuffer();
    expect((await sharp(jpeg).metadata()).exif).toBeTruthy();
    const out = await makeThumbnail(jpeg);
    const m = await sharp(out).metadata();
    expect([m.width, m.height]).toEqual([200, 150]);
    expect(m.exif).toBeUndefined();
    expect(out.includes(Buffer.from("secret-owner"))).toBe(false);
    for (const b of [
      await sharp({ create: { width: 64, height: 64, channels: 3, background: "#123" } }).webp().toBuffer(),
      await sharp({ create: { width: 64, height: 64, channels: 3, background: "#123" } }).gif().toBuffer(),
    ]) {
      expect((await sharp(await makeThumbnail(b)).metadata()).format).toBe("jpeg");
    }
  });

  it("格式白名单按文件头认：SVG、HTML、BMP、空文件、截断的图 → 拒", async () => {
    const svg = Buffer.from('<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><image href="file:///etc/passwd"/></svg>');
    expect(sniffFormat(svg)).toBeNull();
    expect(await reason(makeThumbnail(svg))).toBe("bad_format");
    expect(await reason(makeThumbnail(Buffer.from("<html><body>hi</body></html>")))).toBe("bad_format");
    expect(await reason(makeThumbnail(Buffer.from("BM" + "\0".repeat(100))))).toBe("bad_format");
    expect(await reason(makeThumbnail(Buffer.alloc(0)))).toBe("empty");
    const full = await sharp({ create: { width: 300, height: 300, channels: 3, background: "#456" } }).jpeg().toBuffer();
    expect(await reason(makeThumbnail(full.subarray(0, 200)))).toBe("bad_format");
    // 文件头是 PNG、后面不是
    expect(await reason(makeThumbnail(Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(64)])))).toBe("bad_format");
  });

  it("尺寸：太小拒；单边超 8000 拒；像素总数超上限的（解压炸弹）只读文件头就拒，不解码", async () => {
    expect(await reason(makeThumbnail(await png(10, 10)))).toBe("too_small");
    expect(await reason(makeThumbnail(await png(8001, 16)))).toBe("too_big_dimensions");
    const bomb = pngHeaderOnly(6000, 6000);
    expect(bomb.length).toBeLessThan(200);
    expect(await reason(makeThumbnail(bomb))).toBe("too_big_dimensions");
    expect(await reason(makeThumbnail(pngHeaderOnly(100_000, 100_000)))).toMatch(/too_big_dimensions|bad_format/);
  });

  it("超过 5 MB 的输入直接拒", async () => {
    const b = Buffer.alloc(MAX_IMAGE_BYTES + 1);
    b.set([0xff, 0xd8, 0xff]);
    expect(await reason(makeThumbnail(b))).toBe("too_large");
  });
});

describe("对象键与本机目录（防路径穿越）", () => {
  const S = "11111111-1111-4111-8111-111111111111";
  const P = "22222222-2222-4222-8222-222222222222";
  it("键只能是服务器生成的格式", () => {
    const k = imageKey(S, P, 1, "ab".repeat(32));
    expect(k).toBe(`images/${S}/${P}/1-${"ab".repeat(8)}.jpg`);
    for (const bad of [
      "../../etc/passwd",
      `images/${S}/${P}/../../../etc/passwd`,
      `images/${S}/${P}/1-abababababababab.jpg/../x`,
      `/images/${S}/${P}/1-abababababababab.jpg`,
      `images/${S}/${P}/1-abababababababab.jpg\0`,
      `images\\${S}\\${P}\\1-abababababababab.jpg`,
      `images/${S}/${P}/0-abababababababab.jpg`,
    ])
      expect(isImageKey(bad), bad).toBe(false);
    expect(() => safeJoin("/tmp/x", "../../etc/passwd")).toThrow();
    expect(() => imageKey("../x", P, 1, "ab".repeat(32))).toThrow();
  });

  it("本机目录存取；ImageCache 先读磁盘，缺了回源并落盘", async () => {
    const dir = await mkdtemp(path.join(tmpdir(), "yh-s08-img-"));
    try {
      const k = imageKey(S, P, 1, "cd".repeat(32));
      const local = new LocalDirObjectStore(path.join(dir, "oss"));
      await local.put(k, Buffer.from("x"), "image/jpeg");
      expect((await local.get(k))?.toString()).toBe("x");
      expect(await local.get(imageKey(S, P, 2, "cd".repeat(32)))).toBeNull();
      await expect(local.get("../../etc/passwd")).rejects.toThrow();

      const mem = new MemoryObjectStore();
      await mem.put(k, Buffer.from("y"), "image/jpeg");
      let gets = 0;
      const counted = { put: mem.put.bind(mem), putFile: mem.putFile.bind(mem), get: (key: string) => (gets++, mem.get(key)), list: mem.list.bind(mem), delete: mem.delete.bind(mem), listUploads: mem.listUploads.bind(mem), abortUpload: mem.abortUpload.bind(mem) };
      const cache = new ImageCache(path.join(dir, "cache"), counted);
      const [a, b] = await Promise.all([cache.get(k), cache.get(k)]);
      expect([a?.toString(), b?.toString(), gets]).toEqual(["y", "y", 1]); // 同时缺的只回源一次
      mem.objects.clear();
      expect((await cache.get(k))?.toString()).toBe("y"); // 落盘了，不再回源
      expect(gets).toBe(1);
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
});
