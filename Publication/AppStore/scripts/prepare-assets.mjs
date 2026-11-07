import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import sharp from 'sharp';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourcesPath = resolve(root, 'assets/mockup-sources.json');
const sources = JSON.parse(await readFile(sourcesPath, 'utf8'));
const cache = resolve(root, '.cache/mockups');
await mkdir(cache, { recursive: true });

function roundedPath(rect) {
  const { x, y, width: w, height: h } = rect;
  const radii = Array.isArray(rect.radius) ? rect.radius : Array(4).fill(rect.radius);
  const [tl, tr, br, bl] = radii;
  return `M${x + tl},${y} H${x + w - tr} A${tr},${tr} 0 0 1 ${x + w},${y + tr} V${y + h - br} A${br},${br} 0 0 1 ${x + w - br},${y + h} H${x + bl} A${bl},${bl} 0 0 1 ${x},${y + h - bl} V${y + tl} A${tl},${tl} 0 0 1 ${x + tl},${y} Z`;
}

const prepared = {};
for (const [id, device] of Object.entries(sources.devices)) {
  const rawPath = resolve(cache, `${id}.webp`);
  try {
    await access(rawPath);
  } catch {
    execFileSync('curl', ['-fL', '--retry', '2', '--max-time', '60', '-A', 'Mozilla/5.0', '-e', 'https://plinthmockups.com/', device.url, '-o', rawPath], { stdio: 'inherit' });
  }
  const bytes = await readFile(rawPath);
  const checksum = createHash('sha256').update(bytes).digest('hex');
  if (device.sha256 && device.sha256 !== checksum) throw new Error(`Unexpected mockup contents: ${id}. Remove the cache file and verify its source before changing the manifest.`);
  const { data, info } = await sharp(bytes).ensureAlpha().raw().toBuffer({ resolveWithObject: true });
  let left = info.width, top = info.height, right = 0, bottom = 0;
  for (let y = 0; y < info.height; y++) {
    for (let x = 0; x < info.width; x++) {
      if (data[(y * info.width + x) * 4 + 3] > 0) {
        left = Math.min(left, x); top = Math.min(top, y);
        right = Math.max(right, x + 1); bottom = Math.max(bottom, y + 1);
      }
    }
  }
  if (right <= left || bottom <= top) throw new Error(`Empty device image: ${id}`);
  const island = device.island ? `<path d="${roundedPath(device.island)}" fill="black"/>` : '';
  const mask = Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${info.width}" height="${info.height}"><defs><mask id="aperture"><path d="${roundedPath(device.screen)}" fill="white"/>${island}</mask></defs><rect width="100%" height="100%" fill="white" mask="url(#aperture)"/></svg>`);
  const cutout = await sharp(bytes).composite([{ input: mask, blend: 'dest-out' }]).png().toBuffer();
  const filename = `${id}-frame.png`;
  await sharp(cutout).extract({ left, top, width: right - left, height: bottom - top }).png().toFile(resolve(cache, filename));
  prepared[id] = {
    file: `.cache/mockups/${filename}`,
    width: right - left, height: bottom - top,
    screen: { ...device.screen, x: device.screen.x - left, y: device.screen.y - top },
    source: device.source, model: device.model, sha256: checksum,
  };
  console.log(`${device.model}: ${prepared[id].width} × ${prepared[id].height}`);
}
await writeFile(resolve(cache, 'manifest.json'), `${JSON.stringify(prepared, null, 2)}\n`);
