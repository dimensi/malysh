# Подключение сайта к Cloudflare Pages через GitHub

Проверено 8 ноября 2026: проект `malysh` обслуживает `malysh.pages.dev` и `malysh.dimensi.dev`, поле Git Provider — No. Это существующий Direct Upload проект; ручные обновления работают через уже авторизованный Wrangler.

## Форма Connect to a repository

Для Git integration отдельный GitHub Actions workflow и секрет Cloudflare в GitHub не нужны. Используйте:

| Поле | Значение |
| --- | --- |
| Git account | `dimensi` |
| Repository | `malysh` |
| Framework preset | `None` |
| Build command | `exit 0` |
| Build output directory | `Website` |
| Root directory | оставить пустым — корень репозитория |
| Production branch после слияния PR #32 | `main` |
| Ветка для предварительной проверки до слияния | `nnafranets/feature/app-store-launch` |

`Website` содержит уже готовые HTML/CSS, шрифты и изображения; запускать генератор промо в Cloudflare не нужно. В `main` на момент проверки этой папки ещё нет. При выборе main до слияния PR сборка не найдёт каталог. Рабочая ветка подходит для проверки в новом Pages-проекте; основной домен переносится только после проверки успешного деплоя.

## Ограничение существующего проекта

По действующей документации Cloudflare Direct Upload проект нельзя переключить на Git integration. Для этого нужен новый **Pages-проект в том же аккаунте и с тем же репозиторием**. Существующий `malysh` и действующий домен сохраняются до готовности замены. После успешной проверки нового проекта можно перенести `malysh.dimensi.dev` в его Custom domains и переключить production branch на main после разрешённого слияния.

До перехода действующий workflow `.github/workflows/website.yml` остаётся альтернативой для текущего проекта. Он требует `CLOUDFLARE_API_TOKEN` (Pages Edit) и `CLOUDFLARE_ACCOUNT_ID`. После подключения Git integration второй параллельный production-deploy workflow следует отключить, чтобы не поддерживать два конкурирующих способа публикации. Этот документ не выполняет перенос домена и не сливает PR.

Источники: [Direct Upload — ограничение переключения](https://developers.cloudflare.com/pages/get-started/direct-upload/), [Git integration](https://developers.cloudflare.com/pages/configuration/git-integration/), [Static HTML](https://developers.cloudflare.com/pages/framework-guides/deploy-anything/).
