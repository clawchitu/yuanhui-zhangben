#!/usr/bin/env python3
"""S15 对照图：左边设计稿（docs/design/png），右边实拍，等高缩放后并排，中间留 20px 白缝。
用法：scripts/compare-s15.py <截图目录>（shots-s15.sh 拍完自动调用）"""
import sys
from pathlib import Path
from PIL import Image

PAIRS = [  # (对照图名, 设计稿, 实拍)
    ("compare-01-home", "01-home", "home-family-large"),
    ("compare-02-cashier-home", "02-cashier-home", "home-cashier-large"),
    ("compare-24a-std-home", "24a-std-home", "home-family-standard"),
    ("compare-25a-home-unsynced", "25a-home-unsynced", "home-unsynced-family-large"),
    ("compare-16-font-pick", "16-font-pick", "onboarding-family-large"),
    ("compare-16b-font-pick-cashier", "16b-font-pick-cashier", "onboarding-cashier-large"),
    ("compare-21a-settings", "21a-settings", "settings-family-large"),
    ("compare-21b-cashier-settings", "21b-cashier-settings", "settings-cashier-large"),
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
    main(Path(sys.argv[1] if len(sys.argv) > 1 else "../docs/screenshots/s15").resolve())
