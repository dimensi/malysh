# Сборка сайта в Cloudflare Pages

Проект `malysh` подключён к GitHub и обслуживает `malysh.dimensi.dev`. Отдельный GitHub Actions workflow для сайта не нужен: Cloudflare сам собирает изменения подключённой ветки.

В Settings → Builds & deployments укажите:

| Поле | Значение |
| --- | --- |
| Repository | `dimensi/malysh` |
| Framework preset | `None` |
| Root directory | `Website` |
| Build command | `npm ci && npm run build` |
| Build output directory | `dist` |
| Environment variable | `NODE_VERSION=24.21.0` |
| Production branch | `main` после слияния PR |

До слияния проверяйте preview ветки `nnafranets/feature/app-store-launch`. Слияние выполняется отдельно владельцем. В Build watch paths можно включить `Website/*`, чтобы изменения приложения не пересобирали сайт.

Локальная проверка:

```sh
npm --prefix Website ci
npm --prefix Website run build
npm --prefix Website run preview
```

Vite+ собирает три страницы (`/`, `/support`, `/privacy`) и добавляет хеши CSS и изображениям. Публичный адрес `/screens/social-cover.webp` сохранён для Open Graph. Manrope загружается через Google Fonts. Публикуется только `Website/dist`; папка `Publication`, исходники и зависимости на сайт не попадают. Генератор промоматериалов в Cloudflare не запускается.

Источники: [Cloudflare Git integration](https://developers.cloudflare.com/pages/configuration/git-integration/), [настройки сборки](https://developers.cloudflare.com/pages/configuration/build-configuration/), [Vite+](https://viteplus.dev/).
