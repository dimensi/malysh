import { createServer } from "node:http";
import { promises as fs } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const output = path.resolve(
  path.dirname(fileURLToPath(import.meta.url)),
  "../output",
);
await fs.access(path.join(output, "index.html")).catch(() => {
  throw new Error("Сначала выполните npm run render.");
});
const mime = {
  ".html": "text/html; charset=utf-8",
  ".json": "application/json",
  ".png": "image/png",
  ".webp": "image/webp",
  ".ttf": "font/ttf",
  ".css": "text/css",
  ".js": "text/javascript",
};
const server = createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(
      new URL(request.url, "http://127.0.0.1").pathname,
    );
    const filename = path.resolve(
      output,
      `.${pathname === "/" ? "/index.html" : pathname}`,
    );
    if (!filename.startsWith(`${output}${path.sep}`)) {
      response.writeHead(403).end();
      return;
    }
    const content = await fs.readFile(filename);
    response.writeHead(200, {
      "Content-Type":
        mime[path.extname(filename)] || "application/octet-stream",
      "Cache-Control": "no-store",
    });
    response.end(content);
  } catch {
    response
      .writeHead(404, { "Content-Type": "text/plain; charset=utf-8" })
      .end("Файл не найден.");
  }
});
server.listen(0, "127.0.0.1", () => {
  const url = `http://127.0.0.1:${server.address().port}/`;
  console.log(`Галерея «Малыша» · ${url}\nCtrl+C закрывает локальный сервер.`);
  if (process.platform === "darwin")
    spawn("open", [url], { stdio: "ignore" }).on("error", () => {});
});
