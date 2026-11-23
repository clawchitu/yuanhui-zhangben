#!/usr/bin/env python3
"""扫码页布局方案对照图：左边设计稿（docs/design/png），右边实拍，等高缩放后并排，中间留 20px 白缝。
用法：scripts/compare-scan-layout.py <截图目录>（shots-scan-layout.sh 拍完自动调用）"""
import sys
from pathlib import Path
from PIL import Image

PAIRS = [  # (对照图名, 设计稿, 实拍)
    ("compare-03-sell", "03-sell", "sell-three-large"),
    ("compare-03b-sell-discounted", "03b-sell-discounted", "sell-discounted-large"),
    ("compare-03c-sell-empty", "03c-sell-empty", "sell-empty-large"),
    ("compare-03d-sell-done", "03d-sell-done", "sell-done-large"),
    ("compare-27a-sell-nocam", "27a-sell-nocam", "sell-nocam-large"),
    ("compare-06a-stock-card", "06a-stock-in", "stock-card-large"),
    ("compare-06a-stock-keypad", "06a-stock-in", "stock-keypad-large"),
    ("compare-06b-stock-expiry", "06b-stock-in-expiry", "stock-expiry-large"),
    ("compare-14-scan-login", "14-scan-login", "scan-login-14-large"),
]
HEIGHT, GAP = 1266, 20

def main(out: Path) -> None:
    design = Path(__file__).resolve().parents[2] / "docs/design/png"
    for name, d, shot in PAIRS:
        imgs = [Image.open(design / f"{d}.png").convert("RGB"), Image.open(out / f"{shot}.png").convert("RGB")]
        imgs = [im.resize((round(im.width * HEIGHT / im.height), HEIGHT), Image.LANCZOS) for im in imgs]
        canvas = Image.new("RGB", (imgs[0].width + GAP + imgs[1].width, HEIGHT), "white")
        canvas.paste(imgs[0], (0, 0))
        canvas.paste(imgs[1], (imgs[0].width + GAP, 0))
        canvas.save(out / f"{name}.png", optimize=True)
        print(f"对照图 {out / name}.png", file=sys.stderr)

if __name__ == "__main__":
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "../docs/screenshots/scan-layout").resolve())
