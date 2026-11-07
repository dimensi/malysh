const escapeHTML = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (character) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        character
      ],
  );

export function deviceMarkup(frame, source, label = "", content = "") {
  const screen = frame.screen;
  const radii = Array.isArray(screen.radius)
    ? screen.radius
    : Array(4).fill(screen.radius || 0);
  const radius = `${radii.map((value) => `${(value / screen.width) * 100}%`).join(" ")} / ${radii.map((value) => `${(value / screen.height) * 100}%`).join(" ")}`;
  const style = `--device-ratio:${frame.width}/${frame.height};--screen-x:${(screen.x / frame.width) * 100}%;--screen-y:${(screen.y / frame.height) * 100}%;--screen-w:${(screen.width / frame.width) * 100}%;--screen-h:${(screen.height / frame.height) * 100}%;--screen-radius:${radius};`;
  const mask = frame.mask
    ? `mask-image:url('/${frame.mask}');mask-size:100% 100%;mask-repeat:no-repeat;`
    : "";
  return `<div class="device-unit" style="--body-ratio:${frame.width / frame.height}"><div class="device" style="${style}"><div class="device-screen" style="${mask}">${content || `<img src="/${source}" alt="" draggable="false">`}</div><img class="device-body" src="/${frame.file}" alt="" draggable="false"></div>${label ? `<span class="device-label">${escapeHTML(label)}</span>` : ""}</div>`;
}

export function renderHTML(job, frames, font) {
  const device = (source, type = job.frame || "iphone", label = "") =>
    deviceMarkup(frames[type], source, label);
  const texts = job.title
    ? `<div class="copy"><h1>${escapeHTML(job.title).replaceAll("\n", "<br>")}</h1>${job.description ? `<p>${escapeHTML(job.description)}</p>` : ""}${job.caption ? `<p class="caption">${escapeHTML(job.caption)}</p>` : ""}</div>`
    : "";
  let art;
  if (job.layout === "activities") {
    const composition = job.composition;
    const nativeCards = composition.crops
      .map((crop, index) => {
        const { rect, position } = crop;
        const style = `left:${position.left}%;top:${position.top}%;width:${position.width}%;aspect-ratio:${rect.width}/${rect.height};border-radius:${(crop.radius / rect.width) * 100}% / ${(crop.radius / rect.height) * 100}%;`;
        const imageStyle = `width:${(composition.sourceSize[0] / rect.width) * 100}%;left:${(-rect.x / rect.width) * 100}%;top:${(-rect.y / rect.height) * 100}%;`;
        return `<div class="native-crop" style="${style}"><img style="${imageStyle}" src="/${job.sources[index]}" alt="" draggable="false"></div>`;
      })
      .join("");
    const content = `<div class="activity-showcase" style="background:${composition.background}">${nativeCards}</div>`;
    art = deviceMarkup(frames.iphone, "", "", content);
  } else if (job.layout === "family") {
    art = job.sources
      .map((source, index) =>
        device(
          source,
          index ? "iphone-silver" : "iphone",
          job.labels?.[index] || "",
        ),
      )
      .join("");
  } else if (job.layout === "search") {
    art = `${device(job.sources[0])}${device(job.sources[1], "watch")}`;
  } else if (job.layout === "report") {
    art = `${device(job.sources[0])}<img class="report-page" src="/${job.sources[1]}" alt="">`;
  } else if (job.layout === "document") {
    art = `<img class="document" src="/${job.sources[0]}" alt="">`;
  } else {
    art = job.sources
      .map((source) =>
        device(
          source,
          job.layout === "watch" ? "watch" : job.frame || "iphone",
        ),
      )
      .join("");
  }
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8"><style>
  @font-face{font-family:Manrope;src:url('/${font}') format('truetype');font-style:normal;font-weight:200 800;font-display:block}

  </style><link rel="stylesheet" href="/studio/styles.css"></head><body><main class="kind-${job.kind} layout-${job.layout} tone-${job.tone || "lilac"}" style="--unit:${job.width / 1206}px;--frame-ratio:${frames[job.frame || (job.layout === "watch" ? "watch" : "iphone")]?.width || 1}/${frames[job.frame || (job.layout === "watch" ? "watch" : "iphone")]?.height || 1}">${texts}<div class="art">${art}</div></main></body></html>`;
}
