# Какие изображения загружать в App Store Connect

Готовые файлы находятся в `Publication/AppStore/output/`. Удобнее смотреть и скачивать их по одному в локальной галерее: `npm --prefix Publication/AppStore run gallery`. Исходники из `raw/` и изображения сайта из `site/` для этой загрузки не нужны.

## iPhone: начать с обязательного среднего размера

1. В русской локализации откройте **App Previews and Screenshots → iPhone with Dynamic Island (medium display)**.
2. Добавьте девять PNG из **`output/iphone-medium/`**: **1206 × 2622**.
3. Через **View All Sizes in Media Manager** откройте **iPhone with Dynamic Island (large display)** и добавьте ту же последовательность из **`output/iphone-large/`**: **1320 × 2868**.

| Позиция | Имя PNG в каждой папке | Сюжет |
| --- | --- | --- |
| 1 | `01-together.png` | Один дневник для двух родителей |
| 2 | `02-care.png` | Кормления, сон и подгузники |
| 3 | `03-day.png` | История и итоги дня |
| 4 | `04-growth.png` | Измерения и рост |
| 5 | `05-timers.png` | Кормление, сон и напоминание на экране блокировки |
| 6 | `07-widgets.png` | Виджет на главном экране |
| 7 | `08-watch.png` | Дневник на Apple Watch |
| 8 | `09-photos.png` | Фото первых месяцев |
| 9 | `10-report.png` | PDF-отчёт для педиатра |

Отсутствие файла с номером 06 намеренное: отдельный сюжет напоминания объединён с `05-timers`. В ASC после загрузки проверьте именно порядок карточек, поскольку порядок выбора файлов не всегда равен порядку на странице.

## Apple Watch и iPhone Duo

| Секция ASC | Папка в `output/` | Размер | Порядок |
| --- | --- | --- | --- |
| Apple Watch | `watch/` | 422 × 514 | `01-diary.png`, `02-feeding.png`, `03-sleep.png` |
| iPhone Duo, outer display | `duo-outer/` | 1398 × 2034 | `01-diary.png`, `02-history.png`, `03-statistics.png` |
| iPhone Duo, inner display | `duo-inner/` | 2853 × 2007 | `01-diary.png`, `02-history.png`, `03-statistics.png` |

Внутренний Duo снят в раскрытом горизонтальном состоянии. Не загружайте его в секцию iPad. Для iPad отдельный набор не требуется: приложение не объявляет нативную поддержку iPad.

## Header и Search Results

Эти изображения загружаются в **Header and Search Results**, отдельно от обычных скриншотов:

- **Header** → `output/creative/01-header.png`, **3840 × 1646**.
- **Search Results** → `output/creative/02-search-results.png`, **1920 × 1280**.

После загрузки откройте Preview в App Store Connect: Header кадрируется и перекрывается системными кнопками. Локальный preview помогает увидеть композицию, но не заменяет окончательное превью Apple.

## Социальные обложки

`output/social/` предназначена для анонсов, не для слотов App Store:

- `01-cover.png` — 1600 × 900, горизонтальная обложка.
- `02-feed.png` — 1080 × 1350, вертикальная публикация.
- `03-story.png` — 1080 × 1920, история.

Требования сверены 8 ноября 2026: [размеры скриншотов Apple](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications), [размеры Header/Search Results](https://developer.apple.com/help/app-store-connect/reference/app-information/creative-assets-specifications). PNG без прозрачности; от 1 до 10 скриншотов на размер устройства. Загрузка файлов не отправляет приложение на Review автоматически.
