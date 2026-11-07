import { promises as fs } from "node:fs";
import path from "node:path";
import sharp from "sharp";

const escapeHTML = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (char) =>
      ({
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;",
      })[char],
  );

const groups = {
  "iphone-medium": "iPhone · 1206 × 2622",
  "iphone-large": "iPhone · 1320 × 2868",
  watch: "Apple Watch · 422 × 514",
  "duo-outer": "iPhone Duo · внешний экран",
  "duo-inner": "iPhone Duo · внутренний экран",
  site: "Сайт",
  creative: "App Store · рекламные изображения",
  social: "Социальные сети",
};

export async function renderContactSheets(
  browser,
  manifest,
  staging,
  fontPath,
) {
  const font = (await fs.readFile(fontPath)).toString("base64");
  const sections = [];
  for (const [device, label] of Object.entries(groups)) {
    const entries = manifest.entries.filter((entry) => entry.device === device);
    if (!entries.length) continue;
    const cards = await Promise.all(
      entries.map(async (entry) => {
        const image =
          entry.status === "ready"
            ? `<img src="data:image/webp;base64,${(await fs.readFile(path.join(staging, entry.thumbnail))).toString("base64")}" alt="">`
            : `<div class="pending">Ожидает съёмки</div>`;
        return `<figure>${image}<figcaption>${escapeHTML(entry.id)}<br><span>${entry.width} × ${entry.height}</span></figcaption></figure>`;
      }),
    );
    sections.push(
      `<section data-device="${device}"><h2>${escapeHTML(label)}</h2><div class="grid">${cards.join("")}</div></section>`,
    );
  }
  const page = await browser.newPage({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 1,
  });
  try {
    await page.setContent(`<!doctype html><html lang="ru"><head><meta charset="utf-8"><style>
      @font-face{font-family:Manrope;src:url(data:font/ttf;base64,${font});font-weight:200 800}
      *{box-sizing:border-box}body{margin:0;padding:32px;background:#fcf9f3;color:#30243d;font-family:Manrope,sans-serif}
      h1{font-size:32px;margin:0 0 28px;letter-spacing:-.04em}h2{font-size:22px;margin:0 0 18px}
      section{margin-bottom:32px}.grid{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:20px}
      figure{margin:0;min-width:0}img,.pending{display:block;width:100%;height:400px;object-fit:contain;object-position:center;background:#f1eaf6}
      figcaption{font-size:14px;line-height:1.5;padding-top:8px}span{color:#6a5c75}.pending{display:grid;place-items:center}
    </style></head><body><h1>Малыш · ${escapeHTML(manifest.release)}</h1>${sections.join("")}</body></html>`);
    await page.evaluate(async () => {
      await document.fonts.load("700 32px Manrope", "Малыш");
      await document.fonts.ready;
      await Promise.all([...document.images].map((image) => image.decode()));
    });
    await sharp(await page.screenshot({ fullPage: true }))
      .removeAlpha()
      .png()
      .toFile(path.join(staging, "contact-sheet.png"));
    const iphone = page.locator('[data-device="iphone-medium"]');
    if (await iphone.count()) {
      await sharp(await iphone.screenshot())
        .removeAlpha()
        .png()
        .toFile(path.join(staging, "iphone-contact.png"));
    }
  } finally {
    await page.close();
  }
}
