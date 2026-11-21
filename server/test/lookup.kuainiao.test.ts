// 快鸟客户端：解析（用 test/fixtures/kuainiao 的样例）、请求格式、失败分类；AppCode 不进错误信息（S08）。
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

describe("parseKuainiao", () => {
  it("认出名称、规格、品牌、图片地址", () => {
    expect(parseKuainiao(fx("found"))).toMatchObject({
      kind: "found",
      hit: { name: "示例牌 矿泉水", spec: "550ml", brand: "示例牌", imageUrl: "https://img.example-cdn.com/goods/6901028075831.jpg" },
    });
  });
  it("没有图：hit 里没有 imageUrl", () => {
    const r = parseKuainiao(fx("found-no-image"));
    expect(r).toMatchObject({ kind: "found", hit: { name: "示例 薯片 原味", spec: "75g", brand: "示例" } });
    expect(r.kind === "found" && r.hit.imageUrl).toBeFalsy();
  });
  it("去掉控制字符和零宽字符；图片地址只取第一个 http(s) 的", () => {
    const r = parseKuainiao(fx("found-image-list"));
    expect(r).toMatchObject({ kind: "found", hit: { name: "示例 牙膏", imageUrl: "https://img.example-cdn.com/a.png" } });
  });
  // 真实格式要到 T9 才知道：认不出名称、业务状态不是成功的，一律抛 format（调用方不缓存），不当「没查到」（PR #19 审核，S08-6）
  const formatError = (json: unknown) => {
    try {
      parseKuainiao(json);
    } catch (e) {
      return e instanceof SourceError ? e.kind : "other";
    }
    return "parsed";
  };
  it("认不出名称 → 抛 format，不当「没查到」（手写的 not-found 样例也一样，等 T9 用真实录制件定判别字段）", () => {
    expect(formatError(fx("not-found"))).toBe("format");
    expect(formatError({})).toBe("format");
    expect(formatError(null)).toBe("format");
    expect(formatError({ code: "0", data: { goodsName: "   " } })).toBe("format");
  });
  it("HTTP 200 里的业务错误 → 抛 format，不缓存成「没查到」，也不把诊断性的 name 当商品名", () => {
    expect(formatError({ code: "500", msg: "系统繁忙" })).toBe("format");
    expect(formatError({ code: 403, name: "QuotaExhausted" })).toBe("format");
    expect(formatError({ status: 1, msg: "error", result: { name: "Internal" } })).toBe("format");
    expect(formatError({ showapi_res_code: -1, showapi_res_body: { goodsName: "x" } })).toBe("format");
    expect(formatError({ showapi_res_code: 0, showapi_res_body: { ret_code: -1, goodsName: "额度不足" } })).toBe("format");
    expect(formatError({ success: false, data: { goodsName: "x" } })).toBe("format");
    // 没有任何业务状态字段：认不出是不是成功，也不当商品
    expect(formatError({ name: "QuotaExhausted" })).toBe("format");
    expect(formatError({ data: { goodsName: "示例" } })).toBe("format");
  });
  it("format 错误带上原始响应（只给 barcode-trial --record 用，不进 message）", () => {
    let e: unknown;
    try {
      parseKuainiao({ code: "1", msg: `未查询到 ${APPCODE}` });
    } catch (x) {
      e = x;
    }
    expect(e).toBeInstanceOf(SourceError);
    expect((e as SourceError).raw).toEqual({ code: "1", msg: `未查询到 ${APPCODE}` });
    expect((e as SourceError).message).not.toContain(APPCODE);
    expect((e as SourceError).message).not.toContain("未查询到");
  });
  it("超长字段截断（名称 ≤ 200 字，与 op 的名称上限一致）", () => {
    const r = parseKuainiao({ code: 0, data: { goodsName: "长".repeat(500), spec: "x".repeat(500) } });
    expect(r.kind === "found" && [...r.hit.name].length).toBe(200);
    expect(r.kind === "found" && r.hit.spec!.length).toBe(100);
  });
});

describe("KuainiaoClient", () => {
  it("GET <endpoint>?Code=<条码>，Authorization: APPCODE <码>，不跟跳转", async () => {
    const { f, calls } = fakeFetch(() => Response.json(fx("found")));
    const c = new KuainiaoClient({ appCode: APPCODE, endpoint: "https://icode.market.alicloudapi.com/getBarcode", fetch: f });
    const r = await c.lookup("6901028075831", new AbortController().signal);
    expect(r.kind).toBe("found");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url.toString()).toBe("https://icode.market.alicloudapi.com/getBarcode?Code=6901028075831");
    expect((calls[0]!.init.headers as Record<string, string>).Authorization).toBe(`APPCODE ${APPCODE}`);
    expect(calls[0]!.init.redirect).toBe("error");
  });

  it("条码里的特殊字符按查询参数编码，不拼进路径", async () => {
    const { f, calls } = fakeFetch(() => Response.json(fx("found")));
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

  it("HTTP 200 但业务状态是错误 → format（真实客户端，调用方不缓存）", async () => {
    for (const body of [{ code: "500", msg: "系统繁忙" }, { code: 403, name: "QuotaExhausted" }]) {
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
