import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";

const output = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../output",
);
try {
  const manifest = JSON.parse(
    await fs.readFile(path.join(output, "manifest.json"), "utf8"),
  );
  let ready = 0;
  for (const entry of manifest.entries) {
    if (entry.status !== "ready") {
      console.log(`Ожидает съёмки · ${entry.device}/${entry.id}`);
      continue;
    }
    const bytes = await fs.readFile(path.join(output, entry.path));
    const info = await sharp(bytes).metadata();
    if (info.width !== entry.width || info.height !== entry.height)
      throw new Error(`${entry.path}: размеры не соответствуют манифесту.`);
    if (info.space !== "srgb")
      throw new Error(`${entry.path}: требуется цветовое пространство sRGB.`);
    if (entry.device !== "site" && info.hasAlpha)
      throw new Error(`${entry.path}: альфа-канал запрещён.`);
    if (createHash("sha256").update(bytes).digest("hex") !== entry.sha256)
      throw new Error(`${entry.path}: файл изменён после рендера.`);
    ready++;
  }
  console.log(
    `Проверено ${ready} готовых изображений. Галерея ${path.join(output, "index.html")}`,
  );
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
