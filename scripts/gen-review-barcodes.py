#!/usr/bin/env python3
"""生成 deploy/site/review-barcodes.html（S30，plan-v2 §10「review-barcodes」、§14 S08-10）。

用法：python3 -I scripts/gen-review-barcodes.py > deploy/site/review-barcodes.html

- 条码是内联 SVG 画的 EAN-13（自己编码，不引外部字体、图片、脚本；站点 CSP 只放行内联 style 和同源图片）。
- 一个模块 = SVG 里 1 个单位，页面上按 3 CSS 像素一个模块显示（视网膜屏上 6 个物理像素），左右静区各 15 个模块
  （规范最少左 11、右 7），白底黑条，方便手机对着电脑屏幕扫。
- 码和名字必须和服务器一致：
  · 「店里还没有的」6 个码 = server/src/lookup/catalog.ts 的 DEMO_CATALOG（S08-10：不种成商品，留给审核员走登记）。
  · 「店里已有的」= server/src/demo/seed.ts 的 SEED_PRODUCTS 序号 i 对应 ean13("21000000" + (i+1) 补 4 位)、
    COLA_CASE_BARCODE、PENDING_BARCODE。改了种子要回来改这里。
- 页面上不许出现烟、酒、「烟酒店」字样和真实包装图（§10「内容」）；脚本最后自查一遍，违反就报错退出。
"""
import html
import sys

# (条码, 名称) —— 店里还没有的 6 个（DEMO_CATALOG，名称 + 规格）
NEW_CODES = [
    ("2000000000015", "演示可乐 330ml"),
    ("2000000000022", "演示矿泉水 550ml"),
    ("2000000000039", "演示薯片 75g"),
    ("2000000000046", "演示饼干 100g"),
    ("2000000000053", "演示纸巾 10包"),
    ("2000000000060", "演示牙膏 120g"),
]


def ean13(first12: str) -> str:
    s = sum(int(d) * (1 if i % 2 == 0 else 3) for i, d in enumerate(first12))
    return first12 + str((10 - s % 10) % 10)


def seed(i: int) -> str:
    """seed.ts 的 seedBarcode(i)，i 是 SEED_PRODUCTS 里的下标（从 0 起）"""
    return ean13("21000000" + str(i + 1).zfill(4))


# 店里已有的（SEED_PRODUCTS 下标见 seed.ts）。没挑打火机（日用品，但和吸烟沾边）。
SEEDED = [
    (seed(0), "可口可乐 330ml（单罐）"),
    (ean13("210000009001"), "可口可乐 330ml 整箱（1 箱 = 24 罐）"),
    (seed(2), "农夫山泉 550ml"),
    (seed(3), "康师傅冰红茶 500ml"),
    (seed(7), "蒙牛纯牛奶 250ml（管保质期，有一批 3 天后到期）"),
    (seed(10), "康师傅红烧牛肉面"),
    (seed(11), "乐事薯片 75g"),
    (seed(20), "清风抽纸"),
    (ean13("210000009002"), "散装辣条（待确认的商品）"),
]

L = ["0001101", "0011001", "0010011", "0111101", "0100011", "0110001", "0101111", "0111011", "0110111", "0001011"]
G = ["0100111", "0110011", "0011011", "0100001", "0011101", "0111001", "0000101", "0010001", "0001001", "0010111"]
R = ["".join("1" if b == "0" else "0" for b in c) for c in L]
PARITY = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG", "LGGLLG", "LGGGLG", "LGLGGL", "LGLGLG", "LGGLGL"]

QUIET = 15  # 静区（模块）
MODULE_PX = 3
BAR_H = 60  # 普通条高（模块）
GUARD_EXTRA = 6  # 起止符、中间分隔符往下长出来的部分


def modules(code: str) -> list[tuple[str, bool]]:
    """返回 95 个模块，每个是 ('1' 黑 / '0' 白, 是否护线)"""
    assert len(code) == 13 and code.isdigit() and ean13(code[:12]) == code, code
    out: list[tuple[str, bool]] = [(b, True) for b in "101"]
    par = PARITY[int(code[0])]
    for k, d in enumerate(code[1:7]):
        out += [(b, False) for b in (L if par[k] == "L" else G)[int(d)]]
    out += [(b, True) for b in "01010"]
    for d in code[7:]:
        out += [(b, False) for b in R[int(d)]]
    out += [(b, True) for b in "101"]
    assert len(out) == 95
    return out


def svg(code: str, label: str) -> str:
    w = QUIET * 2 + 95
    h = BAR_H + GUARD_EXTRA
    rects = []
    mods = modules(code)
    i = 0
    while i < 95:
        bit, guard = mods[i]
        if bit == "1":
            j = i
            while j < 95 and mods[j][0] == "1" and mods[j][1] == guard:
                j += 1
            rects.append(f'<rect x="{QUIET + i}" y="0" width="{j - i}" height="{h if guard else BAR_H}"/>')
            i = j
        else:
            i += 1
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w * MODULE_PX}" height="{h * MODULE_PX}"'
        f' shape-rendering="crispEdges" role="img" aria-label="EAN-13 {code} {html.escape(label)}">'
        f'<rect width="{w}" height="{h}" fill="#fff"/><g fill="#000">{"".join(rects)}</g></svg>'
    )


def card(code: str, label: str) -> str:
    return (
        '<figure class="bc">'
        + svg(code, label)
        + f'<figcaption><span class="num">{code}</span><span class="name">{html.escape(label)}</span></figcaption></figure>'
    )


def page() -> str:
    new_cards = "\n".join(card(c, n) for c, n in NEW_CODES)
    seeded_cards = "\n".join(card(c, n) for c, n in SEEDED)
    return f"""<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex">
<title>元辉账本 · 审核用条码 / Barcodes for App Review</title>
<link rel="icon" href="/favicon.svg" type="image/svg+xml">
<style>
  :root {{ color-scheme: light; }}
  * {{ box-sizing: border-box; }}
  html, body {{ margin: 0; }}
  body {{
    background: #f7f3ea; color: #2b2622;
    font-family: -apple-system, BlinkMacSystemFont, "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", "Noto Sans CJK SC", sans-serif;
    line-height: 1.7;
  }}
  main {{ width: 100%; max-width: 920px; margin: 0 auto; padding: 40px 24px 24px; }}
  h1 {{ margin: 0 0 12px; font-size: 1.75rem; color: #c8102e; }}
  h2 {{ margin: 32px 0 8px; font-size: 1.25rem; }}
  p {{ margin: 0 0 10px; font-size: 1rem; }}
  .en {{ color: #5c544c; }}
  .grid {{ display: flex; flex-wrap: wrap; gap: 20px; }}
  .bc {{ margin: 0; padding: 16px 0 12px; background: #fff; border-radius: 8px; text-align: center; }}
  .bc svg {{ display: block; max-width: 100%; height: auto; }}
  .bc figcaption {{ padding: 6px 12px 0; }}
  .num {{ display: block; font-family: ui-monospace, Menlo, Consolas, monospace; font-size: 1.125rem; letter-spacing: .12em; color: #000; }}
  .name {{ display: block; font-size: .9375rem; color: #2b2622; }}
  footer {{ padding: 24px 16px 32px; text-align: center; font-size: .875rem; color: #7a7168; }}
  footer p {{ margin: 4px 0; font-size: .875rem; }}
  footer a {{ color: #7a7168; text-decoration: none; }}
  footer a:hover {{ text-decoration: underline; }}
</style>
</head>
<body>
<main>
  <h1>元辉账本 · 审核用条码</h1>
  <p>给 App 审核用：用审核号登录「演示小店」后，在「卖出」或「进货」页把手机摄像头对准电脑屏幕上的条码即可扫入。扫不出时，点取景框下面的「手输条码」，输入条码下面的数字。</p>
  <p class="en">For App Review: sign in with the review account (it opens the demo store), go to “卖出” (Sell) or “进货” (Stock in) and point the phone camera at a barcode on this screen. If scanning is inconvenient, tap “手输条码” (Enter barcode) under the viewfinder and type the digits shown under the barcode.</p>

  <h2>店里还没有的商品（扫了会进「登记新商品」）</h2>
  <p class="en">Not yet in the demo store — scanning one opens the “new product” form with the name already filled in.</p>
  <div class="grid">
{new_cards}
  </div>

  <h2>店里已有的商品（扫了直接加进这一单）</h2>
  <p class="en">Already in the demo store — scanning adds the item to the current sale / stock-in.</p>
  <div class="grid">
{seeded_cards}
  </div>
  <p>这些都是店内自编码（2 开头），只在演示小店里有效。演示小店每天自动恢复成初始数据。</p>
  <p class="en">All codes are in-store codes (prefix 2) that only exist in the demo store. The demo store is reset to its initial data every day.</p>
</main>
<footer>
  <p><a href="/support">使用帮助 Support</a> · <a href="/privacy">隐私政策 Privacy</a></p>
  <p><a href="https://beian.miit.gov.cn/" target="_blank" rel="noopener">苏ICP备2026094233号-1</a></p>
</footer>
</body>
</html>
"""


if __name__ == "__main__":
    out = page()
    for bad in ("烟", "酒", "<script", 'href="http://', "src=", "<img", "url("):
        if bad in out:
            sys.exit(f"review-barcodes.html 里出现了不许出现的内容：{bad}")
    codes = [c for c, _ in NEW_CODES + SEEDED]
    if len(set(codes)) != len(codes):
        sys.exit("条码有重复")
    sys.stdout.write(out)
