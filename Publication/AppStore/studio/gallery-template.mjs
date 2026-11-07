const escapeHTML = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (character) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        character
      ],
  );

export function galleryHTML(manifest) {
  const data = JSON.stringify(manifest).replaceAll("<", "\\u003c");
  const groups = [
    ["all", "Все"],
    ["iphone", "iPhone"],
    ["watch", "Apple Watch"],
    ["duo", "iPhone Duo"],
    ["site", "Сайт"],
    ["creative", "App Store"],
    ["social", "Соцсети"],
  ];
  return `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Малыш — студия материалов</title><link rel="stylesheet" href="gallery.css"></head><body><header><h1>Материалы «Малыша»</h1><p>Готовые изображения для App Store, сайта и анонсов. Откройте кадр в полном размере или скачайте нужный файл отдельно.</p><nav aria-label="Тип материалов">${groups.map(([id, label]) => `<button data-group="${id}" aria-pressed="${id === "all"}">${label}</button>`).join("")}</nav><div class="summary" id="summary"></div><p class="group-note" id="group-note"></p></header><main class="grid" id="grid"></main><dialog id="viewer"><div class="dialog-bar"><strong id="viewer-title"></strong><a class="download" id="viewer-original" target="_blank" rel="noopener">Открыть оригинал</a><a class="download" id="viewer-download" download>Скачать оригинал</a><button class="close" id="close">Закрыть</button></div><img class="full-image" id="viewer-image" alt=""><div class="dialog-details" id="viewer-details"></div></dialog><footer><a href="contact-sheet.png" target="_blank" rel="noopener">Все материалы одним листом</a><a href="manifest.json" download>Манифест файлов</a><span>Версия приложения ${escapeHTML(manifest.release)} · ${escapeHTML(manifest.commit)}</span></footer><script type="application/json" id="manifest">${data}</script><script src="gallery.js" defer></script></body></html>`;
}
