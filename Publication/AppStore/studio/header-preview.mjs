import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import sharp from "sharp";

export const headerReference = fileURLToPath(
  new URL("../.cache/header-reference.png", import.meta.url),
);
const output = fileURLToPath(new URL("../output/", import.meta.url));
const referenceSize = { width: 912, height: 802 };
const screen = { left: 133, top: 84, width: 601, height: 398 };
const buttons = [193, 674];
const buttonY = 213;
// Stay inside the disc so no pixels from the old artwork enter at the edge.
const buttonRadius = 35;

const svg = (width, height, body) =>
  Buffer.from(
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">${body}</svg>`,
  );

export async function renderHeaderPreview(
  artwork,
  preview,
  referencePath = headerReference,
) {
  const referenceBytes = await fs.readFile(referencePath).catch((error) => {
    if (error.code !== "ENOENT") throw error;
    throw new Error(
      `Референс не найден: ${referencePath}. Укажите --reference <PNG 912 × 802>.`,
    );
  });
  const reference = sharp(referenceBytes);
  const { width, height } = await reference.metadata();
  if (width !== referenceSize.width || height !== referenceSize.height) {
    throw new Error("Для этого макета нужен референс iPhone размером 912 × 802 px.");
  }

  const artworkMask = svg(
    screen.width,
    screen.height,
    '<path d="M0 99C0 44 44 0 99 0H502C557 0 601 44 601 99V398H0Z" fill="white"/>',
  );
  const header = await sharp(artwork)
    .resize(screen.width, screen.height, { fit: "cover", position: "centre" })
    .ensureAlpha()
    .composite([{ input: artworkMask, blend: "dest-in" }])
    .png()
    .toBuffer();

  const shadows = buttons.map(
    (x) => `<circle cx="${x}" cy="${buttonY + 2}" r="${buttonRadius}" fill="#241a32" opacity=".16" filter="url(#shadow)"/>`,
  );
  const overlays = [
    { input: header, left: screen.left, top: screen.top },
    {
      input: svg(
        width,
        height,
        `<defs><filter id="shadow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="5"/></filter></defs>${shadows.join("")}<text x="113" y="38" font-family="Helvetica, sans-serif" font-weight="600" font-size="15" fill="#30213e">Локальный предпросмотр · кадрирование по вашему примеру</text>`,
      ),
    },
  ];

  async function copyMaskedRegion(bounds, shape) {
    const input = await reference
      .clone()
      .extract(bounds)
      .ensureAlpha()
      .composite([
        { input: svg(bounds.width, bounds.height, shape), blend: "dest-in" },
      ])
      .png()
      .toBuffer();
    overlays.push({ input, left: bounds.left, top: bounds.top });
  }

  for (const x of buttons) {
    const diameter = 2 * buttonRadius;
    await copyMaskedRegion(
      {
        left: x - buttonRadius,
        top: buttonY - buttonRadius,
        width: diameter,
        height: diameter,
      },
      `<circle cx="${buttonRadius}" cy="${buttonRadius}" r="${buttonRadius}" fill="white"/>`,
    );
  }
  await copyMaskedRegion(
    { left: 336, top: 100, width: 194, height: 58 },
    '<rect width="194" height="58" rx="29" fill="white"/>',
  );
  const bytes = await reference.composite(overlays).png().toBuffer();
  const temporary = `${preview}.tmp-${process.pid}`;
  try {
    await fs.writeFile(temporary, bytes);
    await fs.rename(temporary, preview);
  } finally {
    await fs.rm(temporary, { force: true });
  }
}

async function main() {
  const args = process.argv.slice(2);
  if (args.length && (args.length !== 2 || args[0] !== "--reference" || !args[1])) {
    throw new Error("Используйте npm run preview:header -- --reference <путь>.");
  }
  const referencePath = args[1]
    ? path.resolve(process.env.INIT_CWD || process.cwd(), args[1])
    : headerReference;
  const preview = path.join(output, "header-preview.png");
  await renderHeaderPreview(
    path.join(output, "creative/01-header.png"),
    preview,
    referencePath,
  );
  if (referencePath !== headerReference) {
    await fs.mkdir(path.dirname(headerReference), { recursive: true });
    await fs.copyFile(referencePath, headerReference);
  }
  console.log(`Готово · ${preview}`);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  await main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
