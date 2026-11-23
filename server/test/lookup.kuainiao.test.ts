// 快鸟客户端：解析（用 test/fixtures/kuainiao 的真实录制件）、请求格式、失败分类；AppCode 不进错误信息（S08）。
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { KuainiaoClient, MAX_RESPONSE_BYTES, SourceError, parseKuainiao, sourceFromConfig } from "../src/lookup/kuainiao.ts";
import { testConfig } from "./helpers/db.ts";

const fx = (n: string) => JSON.parse(readFileSync(new URL(`./fixtures/kuainiao/${n}.json`, import.meta.url), "utf8"));
const APPCODE = "secret-appcode-0123456789abcdef";

function fakeFetch(handler: (url: URL, init: RequestInit) => Response | Promise<Response>) {
  const calls: { url: URL; init: RequestInit }[] = [];
  const f = (async (u: URL | string, init: RequestInit = {}) => {
    const url = new URL(String(u));
    calls.push({ url, init });
    return handler(url, init);
  }) as typeof fetch;
  return { f, calls };
}

// 五个真实录制件（test/fixtures/kuainiao/README.md）
const REC = {
  hongshuangxi: "6901028075831",
  wahaha: "6902083881405",
  kangshifu: "6920152400777",
  nongfu: "6921168509256",
  missing: "6970000000001",
} as const;
const rec = (code: string) => fx(`recorded-${code}`);
/** 以真实「查到」为底改几个字段 */
const foundWith = (patch: Record<string, unknown>) => ({ ...rec(REC.wahaha), ...patch });
const missingWith = (patch: Record<string, unknown>) => ({ ...rec(REC.missing), ...patch });
const formatError = (json: unknown, barcode?: string) => {
  try {
    parseKuainiao(json, barcode);
  } catch (e) {
    return e instanceof SourceError ? e.kind : "other";
  }
  return "parsed";
};

describe("parseKuainiao（真实录制件）", () => {
  it("红双喜：名称、规格、品牌按 ItemName / ItemSpecification / BrandName，一张图", () => {
    const r = parseKuainiao(rec(REC.hongshuangxi), REC.hongshuangxi);
    expect(r.kind).toBe("found");
    expect(r.kind === "found" && r.hit).toEqual({
      name: "红双喜（硬8mg）",
      spec: "20支",
      brand: "红双喜",
      imageUrl: "http://www.api-yun.cn/getPic/getPics/6901028075831/1795414922/792b1c17/0",
      imageUrls: ["http://www.api-yun.cn/getPic/getPics/6901028075831/1795414922/792b1c17/0"],
    });
    expect(r.raw).toEqual(rec(REC.hongshuangxi));
  });
  it("娃哈哈：中文规格原样保留", () => {
    expect(parseKuainiao(rec(REC.wahaha), REC.wahaha)).toMatchObject({ kind: "found", hit: { name: "娃哈哈饮用纯净水", spec: "596毫升", brand: "娃哈哈" } });
  });
  it("康师傅：Image 是空数组 → 查到、没有图（hit 里没有 imageUrl / imageUrls）", () => {
    const r = parseKuainiao(rec(REC.kangshifu), REC.kangshifu);
    expect(r).toMatchObject({ kind: "found", hit: { name: "康师傅红烧牛肉面碗装", spec: "面饼+配料106克", brand: "康师傅" } });
    expect(r.kind === "found" && "imageUrl" in r.hit).toBe(false);
    expect(r.kind === "found" && "imageUrls" in r.hit).toBe(false);
  });
  it("农夫山泉：4 张图全部保留（保序），imageUrl 取第一张；ImageStream 不用", () => {
    const r = parseKuainiao(rec(REC.nongfu), REC.nongfu);
    const base = "http://www.api-yun.cn/getPic/getPics/6921168509256/1795414922";
    expect(r).toMatchObject({
      kind: "found",
      hit: {
        name: "农夫山泉 饮用天然水550ml",
        spec: "550ml",
        brand: "农夫山泉",
        imageUrl: `${base}/cbebf251/0`,
        imageUrls: [`${base}/cbebf251/0`, `${base}/7a70d8ef/1`, `${base}/2f30fe09/2`, `${base}/e3308091/3`],
      },
    });
    expect(JSON.stringify(r.kind === "found" && r.hit)).not.toContain("getPicStream");
  });
  it("不存在的码：status 400 + 「暂无」 + ItemName null → 明确没查到（调用方负缓存 7 天）", () => {
    expect(parseKuainiao(rec(REC.missing), REC.missing)).toEqual({ kind: "not_found", raw: rec(REC.missing) });
  });
  it("五个录制件全都认得出（没有一个是 format）", () => {
    for (const code of Object.values(REC)) expect(formatError(rec(code), code), code).toBe("parsed");
  });
});

describe("parseKuainiao（清洗与图片）", () => {
  it("去掉控制字符、零宽字符和首尾空白；清洗后为空的规格、品牌不出现", () => {
    const r = parseKuainiao(foundWith({ ItemName: "  娃哈哈\u200b纯净水\u0007 ", ItemSpecification: " \u0000 ", BrandName: "\ufeff娃哈哈\n" }));
    expect(r.kind === "found" && r.hit).toMatchObject({ name: "娃哈哈纯净水", brand: "娃哈哈" });
    expect(r.kind === "found" && "spec" in r.hit).toBe(false);
  });
  it("规格、品牌是 null 也算查到", () => {
    const r = parseKuainiao(foundWith({ ItemSpecification: null, BrandName: null }));
    expect(r).toMatchObject({ kind: "found", hit: { name: "娃哈哈饮用纯净水" } });
  });
  it("超长字段截断（名称 ≤ 200 字，规格、品牌 ≤ 100 字）", () => {
    const r = parseKuainiao(foundWith({ ItemName: "长".repeat(500), ItemSpecification: "x".repeat(500), BrandName: "牌".repeat(500) }));
    expect(r.kind === "found" && [...r.hit.name].length).toBe(200);
    expect(r.kind === "found" && r.hit.spec!.length).toBe(100);
    expect(r.kind === "found" && [...r.hit.brand!].length).toBe(100);
  });
  it("图片：去重、只收 http/https、跳过空和坏地址、最多 10 张；没有可用的就当没图", () => {
    const img = (...us: unknown[]) => us.map((u) => ({ Imageurl: u }));
    const r = parseKuainiao(
      foundWith({
        Image: img("ftp://bad.example/x.jpg", "http://a.example/1.jpg", " http://a.example/1.jpg ", "", null, "javascript:alert(1)", "https://b.example/2.png", "http://", `http://c.example/${"x".repeat(2100)}`),
      }),
    );
    expect(r.kind === "found" && r.hit).toMatchObject({ imageUrl: "http://a.example/1.jpg", imageUrls: ["http://a.example/1.jpg", "https://b.example/2.png"] });
    const many = parseKuainiao(foundWith({ Image: img(...Array.from({ length: 15 }, (_, i) => `https://m.example/${i}.jpg`)) }));
    expect(many.kind === "found" && many.hit.imageUrls).toHaveLength(10);
    const none = parseKuainiao(foundWith({ Image: img("ftp://x.example/a", "") }));
    expect(none.kind === "found" && "imageUrl" in none.hit).toBe(false);
    expect(parseKuainiao(foundWith({ Image: null })).kind).toBe("found");
  });
});

// 不把业务错误当「没查到」（PR #19 审核，§14 S08-6）：只有 status 400 + 「暂无」 + 没名称才是没查到，其余都是 format（不缓存）
describe("parseKuainiao（其余一律 format，不缓存）", () => {
  it("别的业务状态（额度、系统繁忙、参数错等）→ format，不当没查到", () => {
    expect(formatError({ status: "500", message: "系统繁忙" })).toBe("format");
    expect(formatError(missingWith({ status: "500" }))).toBe("format");
    expect(formatError(missingWith({ status: "401", message: "暂无权限" }))).toBe("format");
    expect(formatError(missingWith({ message: "参数错误" }))).toBe("format"); // 400 但不是「暂无」
    expect(formatError(missingWith({ message: "次数已用完" }))).toBe("format");
    expect(formatError(foundWith({ status: "201" }))).toBe("format");
    expect(formatError(foundWith({ status: "0" }))).toBe("format");
  });
  it("status 200 但 message 不含「成功」→ format", () => {
    expect(formatError(foundWith({ message: "查询失败" }))).toBe("format");
    expect(formatError(foundWith({ message: "" }))).toBe("format");
    expect(formatError(foundWith({ message: null }))).toBe("format");
  });
  it("「暂无」却带名称、「成功」却没名称 → format", () => {
    expect(formatError(missingWith({ ItemName: "某商品" }))).toBe("format");
    expect(formatError(foundWith({ ItemName: null }))).toBe("format");
    expect(formatError(foundWith({ ItemName: " \u200b " }))).toBe("format");
  });
  it("字段类型不对、Image 形态不对 → format", () => {
    expect(formatError(foundWith({ ItemName: { zh: "x" } }))).toBe("format");
    expect(formatError(foundWith({ ItemSpecification: ["a"] }))).toBe("format");
    expect(formatError(foundWith({ BrandName: 1 }))).toBe("format");
    expect(formatError(foundWith({ Image: "http://a.example/1.jpg" }))).toBe("format");
    expect(formatError(foundWith({ Image: ["http://a.example/1.jpg"] }))).toBe("format");
    expect(formatError(foundWith({ Image: [{ Imageurl: 1 }] }))).toBe("format");
    expect(formatError(missingWith({ ItemName: 0 }))).toBe("format");
  });
  it("传了所查的码：Barcode 对不上 → format（不把别的码的商品缓存到这个码下）", () => {
    expect(formatError(rec(REC.wahaha), REC.hongshuangxi)).toBe("format");
    expect(formatError(foundWith({ Barcode: null }), REC.wahaha)).toBe("format");
    expect(formatError(rec(REC.wahaha), REC.wahaha)).toBe("parsed");
    // 没查到的 Barcode 是 null，不核对
    expect(formatError(rec(REC.missing), REC.missing)).toBe("parsed");
  });
  it("不是对象、空对象、旧手写样例的嵌套形态 → format", () => {
    expect(formatError(null)).toBe("format");
    expect(formatError("ok")).toBe("format");
    expect(formatError([rec(REC.wahaha)])).toBe("format");
    expect(formatError({})).toBe("format");
    expect(formatError({ code: "0", msg: "查询成功", data: { goodsName: "x" } })).toBe("format");
    expect(formatError({ code: "1", msg: "未查询到该条码信息", data: null })).toBe("format");
    expect(formatError({ showapi_res_code: 0, showapi_res_body: { ret_code: 0, goodsName: "x" } })).toBe("format");
  });
  it("format 错误带原始响应（只给 barcode-trial --record 用），message 里没有响应内容", () => {
    const body = { status: "403", message: `额度不足 ${APPCODE}`, ItemName: `QuotaExhausted ${APPCODE}` };
    let e: unknown;
    try {
      parseKuainiao(body);
    } catch (x) {
      e = x;
    }
    expect(e).toBeInstanceOf(SourceError);
    expect((e as SourceError).kind).toBe("format");
    expect((e as SourceError).raw).toEqual(body);
    expect((e as SourceError).message).not.toContain(APPCODE);
    expect((e as SourceError).message).not.toContain("额度不足");
    expect(JSON.stringify(e)).not.toContain(APPCODE);
  });
});

describe("KuainiaoClient", () => {
  it("GET <endpoint>?Code=<条码>，Authorization: APPCODE <码>，不跟跳转", async () => {
    const { f, calls } = fakeFetch(() => Response.json(rec(REC.hongshuangxi)));
    const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://icode.market.alicloudapi.com/getBarcode", fetch: f });
    const r = await c.lookup("6901028075831", new AbortController().signal);
    expect(r.kind).toBe("found");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url.toString()).toBe("https://icode.market.alicloudapi.com/getBarcode?Code=6901028075831");
    expect((calls[0]!.init.headers as Record<string, string>).Authorization).toBe(`APPCODE ${APPCODE}`);
    expect(calls[0]!.init.redirect).toBe("error");
  });

  it("条码里的特殊字符按查询参数编码，不拼进路径", async () => {
    const { f, calls } = fakeFetch(() => Response.json(rec(REC.missing)));
    const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/getBarcode", fetch: f });
    await c.lookup("1&x=2", new AbortController().signal);
    expect(calls[0]!.url.pathname).toBe("/getBarcode");
    expect(calls[0]!.url.searchParams.get("Code")).toBe("1&x=2");
  });

  it("网关 4xx/5xx → http 错误；错误信息不带 AppCode", async () => {
    const { f } = fakeFetch(() => new Response(`bad appcode ${APPCODE}`, { status: 403, headers: { "X-Ca-Error-Message": "Invalid AppCode" } }));
    const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: f });
    const e = await c.lookup("1", new AbortController().signal).catch((x) => x);
    expect(e).toBeInstanceOf(SourceError);
    expect(e.kind).toBe("http");
    expect(e.message).toContain("403");
    expect(e.message).not.toContain(APPCODE);
  });

  it("网关错误头里回显 AppCode：错误信息只有状态码和固定分类，不带头的内容", async () => {
    for (const [header, cls] of [
      [`Invalid AppCode \`${APPCODE}\``, "auth"],
      [`Quota Exhausted for ${APPCODE}`, "quota"],
      [`something else`, "other"],
    ] as const) {
      const { f } = fakeFetch(() => new Response("x", { status: 403, headers: { "X-Ca-Error-Message": header } }));
      const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: f });
      const e = await c.lookup("1", new AbortController().signal).catch((x) => x);
      expect(e).toBeInstanceOf(SourceError);
      expect(e.kind).toBe("http");
      expect(e.message).toBe(`快鸟 HTTP 403（${cls}）`);
      expect(e.message).not.toContain(APPCODE);
      expect(JSON.stringify(e)).not.toContain(APPCODE);
      expect(String(e.stack)).not.toContain(APPCODE);
    }
  });

  it("真实录制件经客户端：查到 / 明确没查到；返回的 Barcode 和所查的码对不上 → format", async () => {
    for (const code of Object.values(REC)) {
      const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: fakeFetch(() => Response.json(rec(code))).f });
      expect((await c.lookup(code, new AbortController().signal)).kind).toBe(code === REC.missing ? "not_found" : "found");
    }
    const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: fakeFetch(() => Response.json(rec(REC.wahaha))).f });
    expect((await c.lookup(REC.hongshuangxi, new AbortController().signal).catch((x) => x)).kind).toBe("format");
  });

  it("HTTP 200 但业务状态是错误 → format（真实客户端，调用方不缓存）", async () => {
    for (const body of [{ status: "500", message: "系统繁忙" }, missingWith({ message: "次数已用完" }), { code: 403, name: "QuotaExhausted" }]) {
      const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: fakeFetch(() => Response.json(body)).f });
      expect((await c.lookup("1", new AbortController().signal).catch((x) => x)).kind).toBe("format");
    }
  });

  it("不是 JSON → format；响应超过上限 → format（不整个读进内存）", async () => {
    const c1 = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: fakeFetch(() => new Response("<html>")).f });
    expect((await c1.lookup("1", new AbortController().signal).catch((x) => x)).kind).toBe("format");
    const big = new Uint8Array(MAX_RESPONSE_BYTES + 10).fill(32);
    const c2 = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: fakeFetch(() => new Response(big)).f });
    expect((await c2.lookup("1", new AbortController().signal).catch((x) => x)).kind).toBe("format");
  });

  it("中止信号 → timeout；连不上 → network（错误信息不带 AppCode）", async () => {
    const hang = fakeFetch(
      (_u, init) =>
        new Promise<Response>((_, rej) => init.signal!.addEventListener("abort", () => rej(new DOMException("aborted", "AbortError")))),
    );
    const ac = new AbortController();
    const p = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: hang.f }).lookup("1", ac.signal);
    ac.abort();
    expect((await p.catch((x) => x)).kind).toBe("timeout");
    const down = fakeFetch(() => {
      throw new TypeError(`fetch failed ${APPCODE}`);
    });
    const e = await new KuainiaoClient({ appCode: APPCODE, endpoint: "https://h.example/x", fetch: down.f })
      .lookup("1", new AbortController().signal)
      .catch((x) => x);
    expect(e.kind).toBe("network");
    expect(e.message).not.toContain(APPCODE);
  });

  it("AppCode 只从配置（环境变量）来：没配就不建客户端", () => {
    expect(sourceFromConfig(testConfig())).toBeNull();
    expect(sourceFromConfig(testConfig({ kuainiao: { appCode: "x", endpoint: "https://h.example/x" } }))).toBeInstanceOf(KuainiaoClient);
  });
});

describe("scripts/barcode-trial.ts", () => {
  it("按类别算命中率和有图率；有图率 < 50% 提示降级；一次最多 30 个", async () => {
    const { parseItems, runTrial, summarize, MAX_TRIAL } = await import("../scripts/barcode-trial.ts");
    const items = parseItems([], "# 注释\n6901 烟\n6902 烟\n6903 日用\n6904:本地\n");
    expect(items).toEqual([
      { barcode: "6901", category: "烟" },
      { barcode: "6902", category: "烟" },
      { barcode: "6903", category: "日用" },
      { barcode: "6904", category: "本地" },
    ]);
    const src = {
      name: "fake",
      lookup: async (b: string) => {
        if (b === "6901") return { kind: "not_found" as const, raw: {} };
        if (b === "6904") throw new SourceError("timeout", "超时");
        return { kind: "found" as const, hit: { name: `n${b}`, ...(b === "6903" ? { imageUrl: "https://x.example/a.jpg" } : {}) }, raw: {} };
      },
    };
    const rows = await runTrial(src, items);
    expect(rows.map((r) => [r.found, r.hasImage])).toEqual([[false, false], [true, false], [true, true], [false, false]]);
    const text = summarize(rows);
    expect(text).toContain("| 烟 | 1/2（50%） | 0/2（0%） |");
    expect(text).toContain("| 合计 | 2/4（50%） | 1/4（25%） |");
    expect(text).toContain("降级到第二版");
    expect(() => parseItems(Array.from({ length: MAX_TRIAL + 1 }, (_, i) => String(i)))).toThrow();
    expect(() => parseItems(["../x"])).toThrow();
  });
  it("认不出的响应（format）也把原始响应留给 --record：T9 要靠它定「没查到」的判别字段", async () => {
    const { runTrial } = await import("../scripts/barcode-trial.ts");
    const c = new KuainiaoClient({
      appCode: APPCODE,
      endpoint: "https://h.example/x",
      fetch: fakeFetch(() => Response.json({ code: "1", msg: "未查询到该条码信息", data: null })).f,
    });
    const rows = await runTrial(c, [{ barcode: "6901", category: "烟" }]);
    expect(rows[0]).toMatchObject({ found: false, error: expect.stringContaining("format"), raw: { code: "1", msg: "未查询到该条码信息", data: null } });
  });
});
