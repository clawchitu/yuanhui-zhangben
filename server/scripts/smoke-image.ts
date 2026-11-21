// 镜像冒烟（S08 sharp 要求 5、S10a）：在镜像里真缩一张图，确认 sharp 能加载、libvips 的 JPEG / PNG / WebP / GIF 编解码器都在。
//   docker run --rm <镜像> node scripts/smoke-image.ts
import sharp from "sharp";

const src = await sharp({ create: { width: 640, height: 480, channels: 3, background: { r: 200, g: 80, b: 40 } } }).png().toBuffer();
for (const fmt of ["jpeg", "png", "webp", "gif"] as const) {
  const input = await sharp(src).toFormat(fmt).toBuffer();
  const out = await sharp(input).resize(256, 256, { fit: "inside" }).webp().toBuffer();
  const meta = await sharp(out).metadata();
  if (meta.format !== "webp" || Math.max(meta.width ?? 0, meta.height ?? 0) !== 256) throw new Error(`${fmt} 缩图结果不对：${JSON.stringify(meta)}`);
  console.log(`${fmt} → webp ${meta.width}x${meta.height} 正常`);
}
console.log(`sharp ${sharp.versions.sharp}，libvips ${sharp.versions.vips}，平台 ${process.platform}-${process.arch}`);
