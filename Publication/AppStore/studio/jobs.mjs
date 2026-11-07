export function buildJobs(catalog, frames) {
  const jobs = [];
  const sources = (slide) => slide.screens.map((key) => catalog.sources[key]);
  for (const [device, width, height] of [
    ["iphone-medium", 1206, 2622],
    ["iphone-large", 1320, 2868],
  ]) {
    for (const slide of catalog.slides)
      jobs.push({
        ...slide,
        device,
        width,
        height,
        kind: "iphone",
        sources: sources(slide),
      });
  }
  for (const slide of catalog.watchSlides)
    jobs.push({
      ...slide,
      device: "watch",
      width: 422,
      height: 514,
      kind: "watch",
      layout: "watch",
      frame: "watch",
      sources: sources(slide),
    });
  for (const [device, width, height] of [
    ["duo-outer", 1398, 2034],
    ["duo-inner", 2853, 2007],
  ]) {
    for (const slide of catalog.duoSlides)
      jobs.push({
        ...slide,
        device,
        width,
        height,
        kind: "duo",
        layout: "single",
        frame: device,
        optional: device === "duo-inner",
        sources: [`raw/${device}/${slide.filename}`],
      });
  }
  for (const [id, key] of Object.entries(catalog.site)) {
    const frame = key.startsWith("watch")
      ? "watch"
      : id === "dad-history"
        ? "iphone-silver"
        : "iphone";
    const geometry = frames[frame];
    const width = key === "pdf" ? 1200 : Math.min(1600, geometry.width);
    const height =
      key === "pdf"
        ? 1697
        : Math.round((width * geometry.height) / geometry.width);
    jobs.push({
      id,
      device: "site",
      width,
      height,
      kind: "site",
      layout: key === "pdf" ? "document" : "single",
      frame,
      sources: [catalog.sources[key]],
      extension: "webp",
      transparent: key !== "pdf",
    });
  }
  jobs.push({
    id: "01-header",
    device: "creative",
    width: 3840,
    height: 1646,
    kind: "header",
    layout: "family",
    tone: "lilac",
    title: "Один дневник.\nДва родителя.",
    description: "Кормления, сон и подгузники",
    sources: [catalog.sources.today, catalog.sources.family],
  });
  jobs.push({
    id: "02-search-results",
    device: "creative",
    width: 1920,
    height: 1280,
    kind: "search",
    layout: "search",
    tone: "cream",
    title: "Дневник младенца\nдля двоих",
    description: "Кормления, сон и подгузники",
    sources: [catalog.sources.today, catalog.sources.watchDiary],
  });
  jobs.push({
    id: "social-cover",
    device: "site",
    width: 1200,
    height: 630,
    kind: "creative",
    layout: "family",
    tone: "lilac",
    title: "Один дневник\nдля двух родителей",
    description: "Малыш · дневник младенца",
    sources: [catalog.sources.today, catalog.sources.family],
    extension: "webp",
  });
  for (const [id, width, height] of [
    ["01-cover", 1600, 900],
    ["02-feed", 1080, 1350],
    ["03-story", 1080, 1920],
  ]) {
    jobs.push({
      id,
      device: "social",
      width,
      height,
      kind: id === "01-cover" ? "creative" : "social",
      layout: "family",
      tone: "lilac",
      title: "Один дневник\nдля двух родителей",
      description: "Малыш · дневник младенца",
      sources: [catalog.sources.today, catalog.sources.family],
    });
  }
  return jobs;
}

export function jobFrames(job) {
  if (job.layout === "document") return [];
  if (job.layout === "watch") return ["watch"];
  if (job.layout === "family") return ["iphone", "iphone-silver"];
  if (job.layout === "search") return ["iphone", "watch"];
  return [job.frame || "iphone"];
}
