# Сайт «Малыша»

[malysh.dimensi.dev](https://malysh.dimensi.dev/) — лендинг, поддержка (`/support`) и политика конфиденциальности (`/privacy`). Исходники находятся в `Website/`.

## Локальная работа

Нужны Node.js 24.11+ в ветке 24.x и npm. Из корня репозитория:

```sh
npm --prefix Website ci
npm --prefix Website run dev
```

Проверка готовой сборки:

```sh
npm --prefix Website run build
npm --prefix Website run preview
```

Vite+ собирает три HTML-страницы в `Website/dist`, добавляет хеши CSS и изображениям. Обложка Open Graph сохраняет адрес `/screens/social-cover.webp`; её исходник лежит в `Website/public/screens/`. Manrope загружается через Google Fonts.

## Публикация

Cloudflare Pages, проект `malysh`, подключён к GitHub-репозиторию `dimensi/malysh`. Изменения `main` публикуются на основном домене, остальные ветки получают preview. Отдельного deploy workflow в GitHub Actions нет.

| Настройка Pages | Значение |
| --- | --- |
| Root directory | `Website` |
| Build command | `npm ci && npm run build` |
| Build output directory | `dist` |
| `NODE_VERSION` для production и preview | `24.21.0` |
| Production branch | `main` |

Публикуется только `dist`; генератор промоматериалов и исходники приложения в сборку сайта не входят. Домен и сертификат управляются в Cloudflare Pages → `malysh` → Custom domains.

## Обновление изображений

[Генератор](../Publication/AppStore/README.md) использует сохранённые снимки приложения и мокапы. После обновления кадров:

```sh
npm --prefix Publication/AppStore run render -- --device site
npm --prefix Publication/AppStore run site-assets
```

`site-assets` переносит изображения в `Website/screens/`, а обложку Open Graph — в `Website/public/screens/`. Готовые изображения сохраняются в Git; сборке Cloudflare не нужны Xcode или рендер промоматериалов.
