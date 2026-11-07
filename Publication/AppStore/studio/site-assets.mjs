import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildJobs } from "./jobs.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const website = path.resolve(root, "../../Website");
try {
  const catalog = JSON.parse(
    await fs.readFile(path.join(root, "studio/catalog.json"), "utf8"),
  );
  const frames = JSON.parse(
    await fs.readFile(path.join(root, catalog.mockups), "utf8"),
  );
  const manifest = JSON.parse(
    await fs.readFile(path.join(root, "output/manifest.json"), "utf8"),
  );
  const jobs = buildJobs(catalog, frames).filter(
    (job) => job.device === "site",
  );
  const files = [];
  for (const job of jobs) {
    const entry = manifest.entries.find(
      (item) => item.device === "site" && item.id === job.id,
    );
    if (entry?.status !== "ready" || entry.release !== catalog.release)
      throw new Error(
        `${job.id}: сначала пересоберите сайт командой npm run render -- --device site.`,
      );
    const bytes = await fs.readFile(path.join(root, "output", entry.path));
    if (createHash("sha256").update(bytes).digest("hex") !== entry.sha256)
      throw new Error(`${entry.path}: файл изменён после рендера.`);
    files.push({ entry, bytes });
  }
  await fs.mkdir(path.join(website, "screens"), { recursive: true });
  await fs.mkdir(path.join(website, "public/screens"), { recursive: true });
  for (const { entry, bytes } of files)
    await fs.writeFile(
      path.join(
        website,
        path.basename(entry.path) === "social-cover.webp" ? "public/screens" : "screens",
        path.basename(entry.path),
      ),
      bytes,
    );
  console.log(
    `Скопировано ${files.length} изображений в ${website}. Публикация выполняется отдельно.`,
  );
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
