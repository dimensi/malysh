const manifest = JSON.parse(document.getElementById("manifest").textContent);
const grid = document.getElementById("grid");
const dialog = document.getElementById("viewer");
let lastFocus;
const labels = {
  "iphone-medium": "iPhone · 6,3″",
  "iphone-large": "iPhone · 6,9″",
  watch: "Apple Watch",
  "duo-outer": "Duo · внешний экран",
  "duo-inner": "Duo · внутренний экран",
  site: "Сайт",
  creative: "App Store",
  social: "Соцсети",
};
const el = (tag, text, className) => {
  const node = document.createElement(tag);
  if (text) node.textContent = text;
  if (className) node.className = className;
  return node;
};
function show(entry, button) {
  lastFocus = button;
  document.getElementById("viewer-title").textContent = entry.title || entry.id;
  const image = document.getElementById("viewer-image");
  image.src = entry.path;
  image.alt = entry.title || entry.id;
  const download = document.getElementById("viewer-download");
  document.getElementById("viewer-original").href = entry.path;
  download.href = entry.path;
  download.download = entry.path.split("/").pop();
  document.getElementById("viewer-details").textContent =
    labels[entry.device] +
    " · " +
    entry.width +
    " × " +
    entry.height +
    " · версия " +
    entry.release +
    " · " +
    entry.path +
    (entry.artwork?.kind === "generated-illustration"
      ? " · Сгенерированная иллюстрация"
      : "");
  dialog.showModal();
}
function render(group) {
  grid.replaceChildren();
  const note = document.getElementById("group-note");
  note.replaceChildren();
  if (group === "creative") {
    note.append(
      document.createTextNode(
        "Header оформляет страницу приложения. Search Results создаёт первое впечатление в поиске. ",
      ),
    );
    const guidance = el("a", "Рекомендации Apple");
    guidance.href =
      "https://developer.apple.com/app-store/asset-best-practices/";
    guidance.target = "_blank";
    guidance.rel = "noopener";
    note.append(guidance);
  }
  const entries = manifest.entries.filter(
    (entry) =>
      group === "all" ||
      entry.device === group ||
      entry.device.startsWith(group + "-"),
  );
  for (const entry of entries) {
    const card = el("article", null, "card");
    if (entry.status === "ready") {
      const button = el(
        "button",
        null,
        "preview" + (entry.device === "site" ? " site-preview" : ""),
      );
      button.setAttribute("aria-label", "Открыть " + (entry.title || entry.id));
      const image = el("img");
      image.src = entry.thumbnail || entry.path;
      image.alt = entry.title || entry.id;
      image.loading = "lazy";
      button.append(image);
      button.onclick = () => show(entry, button);
      card.append(button);
    } else {
      const pending = el("div", null, "pending");
      pending.append(
        el(
          "strong",
          entry.status === "pending"
            ? entry.device.startsWith("duo")
              ? "Duo доснимается"
              : "Набор готовится"
            : "Нужен исходный кадр",
        ),
        el("p", entry.reason || "Этот материал ещё не готов."),
      );
      card.append(pending);
    }
    card.append(
      el("h2", (entry.title || entry.id).replaceAll("\n", " ")),
      el(
        "div",
        labels[entry.device] + " · " + entry.width + " × " + entry.height,
        "meta",
      ),
    );
    if (entry.status === "ready") {
      card.append(
        el(
          "div",
          "Версия " + entry.release + " · " + entry.format.toUpperCase(),
          "meta",
        ),
      );
      const actions = el("div", null, "actions");
      const link = el("a", "Скачать " + entry.format.toUpperCase(), "download");
      link.href = entry.path;
      link.download = entry.path.split("/").pop();
      actions.append(link);
      card.append(actions);
    }
    if (entry.status !== "ready")
      card.append(el("span", "Набор не завершён", "badge"));
    grid.append(card);
  }
  const ready = entries.filter((e) => e.status === "ready").length;
  document.getElementById("summary").textContent =
    ready +
    " готово" +
    (entries.length - ready
      ? " · " + (entries.length - ready) + " ожидают съёмки"
      : "") +
    " · версия " +
    manifest.release;
}
document.querySelectorAll("[data-group]").forEach((button) => {
  const group = button.dataset.group;
  const entries = manifest.entries.filter(
    (entry) =>
      group === "all" ||
      entry.device === group ||
      entry.device.startsWith(group + "-"),
  );
  const ready = entries.filter((entry) => entry.status === "ready").length;
  button.append(
    el(
      "span",
      ready === entries.length ? String(ready) : ready + "/" + entries.length,
      "nav-count",
    ),
  );
});
document.querySelectorAll("[data-group]").forEach(
  (button) =>
    (button.onclick = () => {
      document
        .querySelectorAll("[data-group]")
        .forEach((other) =>
          other.setAttribute("aria-pressed", String(other === button)),
        );
      render(button.dataset.group);
    }),
);
document.getElementById("close").onclick = () => dialog.close();
dialog.addEventListener("close", () => lastFocus?.focus());
dialog.addEventListener("click", (event) => {
  if (event.target === dialog) dialog.close();
});
render("all");
