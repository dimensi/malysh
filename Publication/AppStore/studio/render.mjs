import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";
import sharp from "sharp";
import { buildJobs, jobFrames } from "./jobs.mjs";
import { renderHTML } from "./template.mjs";
import { headerReference, renderHeaderPreview } from "./header-preview.mjs";
import { galleryHTML } from "./gallery-template.mjs";
import { renderContactSheets } from "./contact-sheets.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const output = path.join(root, "output");
const lock = path.join(root, ".render.lock");
const staging = path.join(root, `.render-${process.pid}`);
const previous = path.join(root, `.render-previous-${process.pid}`);
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
const exists = async (filename) =>
  fs.access(filename).then(
    () => true,
    () => false,
  );
const readJSON = async (filename) =>
  JSON.parse(await fs.readFile(filename, "utf8"));
const jobKey = (job) => `${job.device}/${job.id}`;

function options() {
  const result = {};
  for (let index = 2; index < process.argv.length; index += 2) {
    const option = process.argv[index];
    if (!["--slide", "--device"].includes(option) || !process.argv[index + 1]) {
      throw new Error(
        "Используйте --slide <id> и/или --device <iphone-medium|iphone-large|watch|duo-outer|duo-inner|site|creative|social>.",
      );
    }
    result[option.slice(2)] = process.argv[index + 1];
  }
  return result;
}

async function validateArtwork(artwork, sourceHashes) {
  const artworkBytes = await fs.readFile(path.join(root, artwork.path));
  const provenanceBytes = await fs.readFile(path.join(root, artwork.provenance));
  const record = JSON.parse(provenanceBytes.toString("utf8"));
  const { width, height, hasAlpha } = await sharp(artworkBytes).metadata();
  const sha256 = hash(artworkBytes);
  if (
    record.kind !== "generated-illustration" ||
    !record.tool ||
    record.asset !== artwork.path ||
    record.sha256 !== sha256 ||
    record.dimensions?.[0] !== width ||
    record.dimensions?.[1] !== height ||
    record.transparentBackground !== hasAlpha
  ) {
    throw new Error(
      `${artwork.path}: файл иллюстрации не соответствует ${artwork.provenance}.`,
    );
  }
  sourceHashes.set(artwork.path, sha256);
  sourceHashes.set(artwork.provenance, hash(provenanceBytes));
  return {
    ...artwork,
    kind: record.kind,
    tool: record.tool,
    dimensions: [width, height],
    sha256,
  };
}

async function validateInput(job, frames, sourceHashes, provenance) {
  const missing = [];
  for (const filename of job.sources) {
    if (!filename || !(await exists(path.join(root, filename))))
      missing.push(filename || "(путь не задан)");
  }
  if (missing.length)
    return `Не хватает настоящих снимков: ${missing.join(", ")}`;
  for (const [sourceIndex, filename] of job.sources.entries()) {
    const absolute = path.join(root, filename);
    const bytes = await fs.readFile(absolute);
    sourceHashes.set(filename, hash(bytes));
    const metadata = await sharp(bytes).metadata();
    if (!metadata.width || !metadata.height)
      throw new Error(`${filename}: не удалось прочитать изображение.`);
    const statistics = await sharp(bytes).stats();
    if (statistics.channels.slice(0, 3).every((channel) => channel.max < 8))
      return `Чёрный кадр ${filename}. Повторите съёмку экрана.`;
    const capture = provenance.sources?.[filename];
    if (
      capture?.dimensions &&
      (capture.dimensions[0] !== metadata.width ||
        capture.dimensions[1] !== metadata.height)
    ) {
      throw new Error(
        `${filename}: ${metadata.width}×${metadata.height} не соответствует размерам из capture/provenance.json.`,
      );
    }
    if (capture?.sha256 && capture.sha256 !== hash(bytes)) {
      throw new Error(
        `${filename}: снимок изменён после записи provenance. Обновите capture/provenance.json.`,
      );
    }
    const isDocument =
      job.layout === "document" ||
      (job.layout === "report" && sourceIndex === 1);
    if (!isDocument) {
      const keys = jobFrames(job);
      const frame = frames[keys[Math.min(sourceIndex, keys.length - 1)]];
      if (frame?.screen) {
        const actualRatio = metadata.width / metadata.height;
        const screenRatio = frame.screen.width / frame.screen.height;
        if (Math.abs(actualRatio / screenRatio - 1) > 0.05) {
          throw new Error(
            `${filename}: ${metadata.width}×${metadata.height} не подходит к экрану ${frame.model} (${frame.screen.width}×${frame.screen.height}). Выберите настоящий снимок нужного устройства.`,
          );
        }
      }
    }

  }
  for (const key of jobFrames(job)) {
    const frame = frames[key];
    if (
      !frame?.screen ||
      !frame.file ||
      !(await exists(path.join(root, frame.file)))
    ) {
      throw new Error(
        `Мокап ${key} не подготовлен. Выполните npm run prepare-assets.`,
      );
    }
    if (
      frame.screen.x < 0 ||
      frame.screen.y < 0 ||
      frame.screen.x + frame.screen.width > frame.width ||
      frame.screen.y + frame.screen.height > frame.height
    ) {
      throw new Error(`Мокап ${key}: экран выходит за границы корпуса.`);
    }
  }
  return null;
}

async function renderOne(
  browser,
  job,
  frames,
  catalog,
  sourceHashes,
  provenance,
  mockupSources,
) {
  // A document's white margins are part of the page, not padding to trim.
  // Render it at the source size so future page formats stay intact too.
  if (job.layout === "document") {
    const { width, height } = await sharp(
      path.join(root, job.sources[0]),
    ).metadata();
    job = { ...job, width, height, transparent: false };
  }
  const page = await browser.newPage({
    viewport: { width: job.width, height: job.height },
    deviceScaleFactor: 1,
    locale: catalog.locale,
    colorScheme: "light",
    reducedMotion: "reduce",
  });
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await page.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.origin !== "https://malysh-studio.invalid") return route.abort();
    if (url.pathname === "/")
      return route.fulfill({
        body: renderHTML(job, frames, catalog.font),
        contentType: "text/html; charset=utf-8",
      });
    const filename = path.resolve(root, `.${decodeURIComponent(url.pathname)}`);
    if (!filename.startsWith(`${root}${path.sep}`)) return route.abort();
    try {
      await route.fulfill({ path: filename });
    } catch {
      errors.push(`Не загрузился ${path.relative(root, filename)}`);
      await route.abort();
    }
  });
  try {
    await page.goto("https://malysh-studio.invalid/");
    const audit = await page.evaluate(async () => {
      await document.fonts.load("700 40px Manrope", "Малыш");
      await document.fonts.ready;
      await Promise.all([...document.images].map((image) => image.decode()));
      const title = document.querySelector("h1");
      const copy = document.querySelector(".copy");
      const copyRect = copy?.getBoundingClientRect();
      const deviceRects = [
        ...document.querySelectorAll(".device,.report-page"),
      ].map((element) => element.getBoundingClientRect());
      return {
        font: document.fonts.check("700 40px Manrope", "Малыш"),
        overflowing: [...document.querySelectorAll(".copy h1,.copy p")].filter(
          (element) => element.scrollWidth > element.clientWidth + 1,
        ).length,
        copyOverlapsArt: Boolean(
          copyRect &&
            deviceRects.some(
              (rect) =>
                copyRect.right > rect.left + 1 &&
                copyRect.left < rect.right - 1 &&
                copyRect.bottom > rect.top + 1 &&
                copyRect.top < rect.bottom - 1,
            ),
        ),
        clippedDevices: [
          ...document.querySelectorAll(".device,.report-page,.device-label"),
        ].filter((element) => {
          const rect = element.getBoundingClientRect();
          return (
            rect.left < -1 ||
            rect.top < -1 ||
            rect.right > innerWidth + 1 ||
            rect.bottom > innerHeight + 1
          );
        }).length,
        title: title?.textContent || "",
      };
    });
    if (
      !audit.font ||
      audit.overflowing ||
      audit.clippedDevices ||
      errors.length
    )
      throw new Error(
        `${jobKey(job)}: ошибка вёрстки ${JSON.stringify({ ...audit, errors })}`,
      );
    if (audit.copyOverlapsArt)
      throw new Error(`${jobKey(job)}: подпись перекрывает зону устройств.`);
    const screenshot = await page.screenshot({
      animations: "disabled",
      omitBackground: Boolean(job.transparent),
      type: "png",
    });
    const format = job.extension || "png";
    const relative = `${job.device}/${job.id}.${format}`;
    const absolute = path.join(staging, relative);
    await fs.mkdir(path.dirname(absolute), { recursive: true });
    let pipeline = sharp(screenshot).toColourspace("srgb");
    if (job.transparent) pipeline = pipeline.trim({ threshold: 2 });
    else pipeline = pipeline.removeAlpha();
    const image = await (
      format === "webp"
        ? pipeline.webp({ quality: 93, alphaQuality: 100, effort: 6 })
        : pipeline.png({ compressionLevel: 9 })
    ).toBuffer();
    await fs.writeFile(absolute, image);
    const metadata = await sharp(image).metadata();
    if (
      !job.transparent &&
      (metadata.width !== job.width ||
        metadata.height !== job.height ||
        metadata.hasAlpha)
    )
      throw new Error(`${relative}: неверные размеры или прозрачность.`);
    if (job.kind === "header") {
      const preview = path.join(staging, "header-preview.png");
      if (await exists(headerReference)) {
        await renderHeaderPreview(absolute, preview);
      } else {
        await fs.rm(preview, { force: true });
      }
    }
    const thumbnail = `thumbnails/${job.device}-${job.id}.webp`;
    await sharp(image)
      .resize({
        width: 440,
        height: 680,
        fit: "inside",
        withoutEnlargement: true,
      })
      .webp({ quality: 85 })
      .toFile(path.join(staging, thumbnail));
    return {
      id: job.id,
      device: job.device,
      title: job.title || job.id,
      status: "ready",
      path: relative,
      thumbnail,
      width: metadata.width,
      height: metadata.height,
      format,
      bytes: image.length,
      sha256: hash(image),
      release: catalog.release,
      commit: catalog.commit,
      ...(job.artwork
        ? { artwork: job.artwork }
        : {
            sources: job.sources.map((filename) => ({
              path: filename,
              ...(provenance.sources?.[filename] || {
                release: "unknown",
                verification: "provenance missing",
              }),
              sha256: sourceHashes.get(filename),
            })),
            mockups: jobFrames(job).map((key) => ({
              key,
              source: frames[key].source,
              model: frames[key].model,
              frameSHA256: frames[key].frameSHA256,
              originalSHA256:
                mockupSources.devices?.[key]?.sha256 || frames[key].sha256,
              originalURL: mockupSources.devices?.[key]?.url,
              license: mockupSources.license,
              screen: frames[key].screen,
              screenshotFit: "contain",
            })),
          }),
    };
  } finally {
    await page.close();
  }
}

async function main() {
  const filters = options();
  const catalog = await readJSON(path.join(root, "studio/catalog.json"));
  if (!(await exists(path.join(root, catalog.mockups))))
    throw new Error("Выполните npm run prepare-assets перед первым рендером.");
  const frames = await readJSON(path.join(root, catalog.mockups));
  const provenance = await readJSON(
    path.join(root, "capture/provenance.json"),
  ).catch(() => ({ sources: {} }));
  const mockupSources = await readJSON(
    path.join(root, "assets/mockup-sources.json"),
  );
  const allJobs = buildJobs(catalog, frames);
  const jobs = allJobs.filter(
    (job) =>
      (!filters.device || job.device === filters.device) &&
      (!filters.slide || job.id === filters.slide),
  );
  if (!jobs.length)
    throw new Error(
      "По выбранным фильтрам нет материалов. Проверьте id слайда и имя устройства в studio/catalog.json.",
    );
  if (!(await exists(path.join(root, catalog.font))))
    throw new Error(`Шрифт ${catalog.font} отсутствует.`);
  if (jobs.some((job) => !job.artwork)) {
    for (const frame of Object.values(frames)) {
      frame.frameSHA256 = hash(await fs.readFile(path.join(root, frame.file)));
    }
  }
  const sourceHashes = new Map();
  const pending = new Map();
  for (const job of jobs) {
    if (job.artwork) {
      job.artwork = await validateArtwork(job.artwork, sourceHashes);
      continue;
    }
    const problem = await validateInput(job, frames, sourceHashes, provenance);
    if (!problem) continue;
    if (!job.optional) throw new Error(`${jobKey(job)}: ${problem}`);
    pending.set(jobKey(job), problem);
  }
  let lockHandle;
  try {
    lockHandle = await fs.open(lock, "wx");
  } catch (error) {
    if (error.code === "EEXIST")
      throw new Error("Уже идёт рендер. Дождитесь его завершения.");
    throw error;
  }
  let browser;
  let movedPrevious = false;
  try {
    await lockHandle.writeFile(String(process.pid));
    const oldManifest = (await exists(path.join(output, "manifest.json")))
      ? await readJSON(path.join(output, "manifest.json"))
      : { entries: [] };
    if (await exists(output)) await fs.cp(output, staging, { recursive: true });
    else await fs.mkdir(staging, { recursive: true });
    await fs.mkdir(path.join(staging, "thumbnails"), { recursive: true });
    const activeKeys = new Set(allJobs.map(jobKey));
    for (const entry of oldManifest.entries) {
      if (activeKeys.has(jobKey(entry))) continue;
      for (const relative of [entry.path, entry.thumbnail]) {
        if (!relative) continue;
        const filename = path.resolve(staging, relative);
        if (!filename.startsWith(`${staging}${path.sep}`)) continue;
        await fs.rm(filename, { force: true });
      }
    }
    browser = await chromium.launch({ headless: true });
    const records = new Map(
      oldManifest.entries.map((entry) => [jobKey(entry), entry]),
    );
    for (const job of jobs) {
      const problem = pending.get(jobKey(job));
      if (problem) {
        const old = records.get(jobKey(job));
        records.set(jobKey(job), {
          id: job.id,
          device: job.device,
          title: job.title,
          status: "incomplete",
          width: job.width,
          height: job.height,
          reason: problem,
          previousPath: old?.path || old?.previousPath,
          release: catalog.release,
          commit: catalog.commit,
        });
        console.log(`Ожидает съёмки · ${jobKey(job)} · ${problem}`);
      } else {
        records.set(
          jobKey(job),
          await renderOne(
            browser,
            job,
            frames,
            catalog,
            sourceHashes,
            provenance,
            mockupSources,
          ),
        );
        console.log(`Готово · ${jobKey(job)}`);
      }
    }
    for (const [filename, checksum] of sourceHashes) {
      if (hash(await fs.readFile(path.join(root, filename))) !== checksum)
        throw new Error(
          `Исходник ${filename} изменился во время рендера. Повторите команду.`,
        );
    }
    const manifest = {
      schemaVersion: 1,
      release: catalog.release,
      commit: catalog.commit,
      locale: catalog.locale,
      browser: browser.version(),
      entries: allJobs.map(
        (job) =>
          records.get(jobKey(job)) || {
            id: job.id,
            device: job.device,
            title: job.title || job.id,
            status: "pending",
            width: job.width,
            height: job.height,
            reason: job.device.startsWith("duo")
              ? "Duo доснимается. Здесь появятся настоящие экраны в готовых мокапах."
              : "Этот набор ожидает рендера.",
            release: catalog.release,
            commit: catalog.commit,
          },
      ),
    };
    await fs.writeFile(
      path.join(staging, "manifest.json"),
      `${JSON.stringify(manifest, null, 2)}\n`,
    );
    await fs.writeFile(path.join(staging, "index.html"), galleryHTML(manifest));
    await fs.copyFile(
      path.join(root, "studio/gallery.css"),
      path.join(staging, "gallery.css"),
    );
    await fs.copyFile(
      path.join(root, "studio/gallery.js"),
      path.join(staging, "gallery.js"),
    );
    await fs.copyFile(
      path.join(root, catalog.font),
      path.join(staging, "manrope.ttf"),
    );
    await renderContactSheets(
      browser,
      manifest,
      staging,
      path.join(root, catalog.font),
    );
    await browser.close();
    browser = null;
    if (await exists(output)) {
      await fs.rename(output, previous);
      movedPrevious = true;
    }
    try {
      await fs.rename(staging, output);
    } catch (error) {
      if (movedPrevious) await fs.rename(previous, output);
      throw error;
    }
    await fs.rm(previous, { recursive: true, force: true });
    console.log(
      `\nГалерея · ${path.join(output, "index.html")}\nОткрыть в браузере · npm run gallery`,
    );
  } finally {
    if (browser) await browser.close();
    await fs.rm(staging, { recursive: true, force: true });
    await lockHandle.close();
    await fs.rm(lock, { force: true });
  }
}

main().catch((error) => {
  console.error(`Рендер остановлен. ${error.message}`);
  process.exitCode = 1;
});
