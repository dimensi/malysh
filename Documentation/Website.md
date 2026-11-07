# Сайт «Малыша»

Исходники лендинга, поддержки и политики лежат в `Website/`. Cloudflare Pages обслуживает их из проекта `malysh` в режиме Direct Upload. Для первой публикации использовался Wrangler. [Адрес проекта](https://malysh.pages.dev/)

## Автопубликация из GitHub

Workflow **Website** загружает `Website/` при изменениях сайта или его workflow в `main`. Ручной запуск с `main` доступен в **Actions → Website → Run workflow**.

В настройках GitHub Actions используется переменная `CLOUDFLARE_ACCOUNT_ID`. Для запуска добавьте секрет `CLOUDFLARE_API_TOKEN` с правом **Account → Cloudflare Pages → Edit**, ограниченным аккаунтом проекта. Локальный вход через Wrangler и cf для GitHub Actions не используется. [Настройки секретов репозитория](https://github.com/dimensi/malysh/settings/secrets/actions) · [Документация Cloudflare](https://developers.cloudflare.com/pages/how-to/use-direct-upload-with-continuous-integration/)

После первого запуска проверьте статус **Production** в Pages и адреса `/`, `/support` и `/privacy`. В Cloudflare Pages маршруты `/support.html` и `/privacy.html` перенаправляются на адреса без расширения.

## Локальная проверка и разовая публикация

Из корня репозитория запустите локальный сервер:

```sh
rtk proxy python3 -m http.server 8000 --directory Website
```

В уже авторизованной среде разовая публикация выполняется так:

```sh
rtk proxy npx --yes wrangler@4.158.0 pages deploy Website --project-name=malysh --branch=main
```

К проекту добавлен поддомен `malysh.dimensi.dev`. В зоне `dimensi.dev` для него задан отдельный CNAME на `malysh.pages.dev`. Состояние и сертификат управляются в **Cloudflare Pages → malysh → Custom domains**.
