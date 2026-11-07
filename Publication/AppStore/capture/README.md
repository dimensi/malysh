# Настоящие экраны для промоматериалов

Текущий набор снят с релизного `v1.13.0`, commit `6001cb1bf6413e0ab7d9427ba4044ce96aaf73b5`. Источник каждого файла, модель и размер записаны в `capture/provenance.json`. `raw/iphone-medium` содержит предыдущую съёмку 1.12.0 и не используется как источник текущего набора. Рендер двух размеров iPhone использует целые новые снимки Pro Max с сохранением пропорций.

## Изоляция

`capture-iphone.sh` извлекает выбранный git ref в временную папку через `git archive`. Он подключает DEBUG-фикстуру только в эту копию, удаляет CloudKit/APNs entitlements, сохраняет локальную App Group для виджетов и запускает штатное UI-testing хранилище. Исходники релиза не меняются. Apple ID, iCloud и реальные дневники в съёмке не участвуют.

Семейный экран показывает настоящие представления приложения над локальными синтетическими данными общего store. Это демонстрация интерфейса совместного дневника, а не проверка межустройственной синхронизации iCloud. Watch использует штатную схему `WatchLocalState` внутри App Group только выделенного симулятора. WatchConnectivity этим не проверяется.

## Данные

- Ванечка, 107 дней, рождение в 08:26. Синтетические родители Лена (мама) и Миша (папа); авторство хранится в самих событиях.
- Семь дней кормлений грудью и сцеженным молоком, сна и подгузников. Будущие события отбрасываются. Для главного экрана последний сон завершён 70 минут назад, кормление — 40 минут назад, подгузник сменён 18 минут назад.
- Пять замеров: от 3380 г / 51 см / 35 см до 6340 г / 63 см / 41 см. Значения вымышлены и не являются медицинскими рекомендациями.
- Фотоальбом содержит четыре созданные локально иллюстрации игрушек из `album.py`; личные фотографии не используются.
- Напоминание снимается отдельным сценарием: последняя бутылочка была почти три часа назад, обычное системное напоминание наступает примерно через 52 секунды после запуска. Не используется поддельная карточка уведомления.
- PDF создаёт настоящий экран экспорта релиза. DEBUG-хук лишь копирует уже созданный файл в Documents, после чего `raster-pdf.swift` переводит его первую страницу в PNG без изменения содержания.

## Повторная съёмка iPhone

Требуются Xcode с соответствующими simulator runtimes, Python 3, Swift и ImageMagick для разрешённых иллюстраций. Перед созданием устройства проверьте `xcrun simctl list devices`: переиспользуйте свой экземпляр `Malysh – App Store Launch…`. Для этого worktree одновременно допускается один выделенный симулятор. При смене модели удалите только его по UDID. Чужие устройства не выключайте и не удаляйте.

```sh
# Пример для уже созданного/проверенного выделенного устройства.
export MALYSH_CAPTURE_REF=v1.13.0
export MALYSH_CAPTURE_BUILD_DIR=/tmp/malysh-storefront-build
# Если команда выполняется не из рабочего дерева репозитория:
# export MALYSH_CAPTURE_REPO=/absolute/path/to/Malysh
rtk proxy xcrun simctl bootstatus "$CAPTURE_UDID" -b
rtk proxy bash Publication/AppStore/capture/capture-iphone.sh "$CAPTURE_UDID"
rtk proxy bash Publication/AppStore/capture/capture-iphone.sh "$CAPTURE_UDID" \
  Publication/AppStore/raw MalyshUITests/WidgetSystemUITests/testStorefrontWidget \
  MalyshUITests/StorefrontFeatureScenes/testReminder
rtk proxy xcrun simctl shutdown "$CAPTURE_UDID"
```

Третий и последующие аргументы задают XCTest selection. Например, `MalyshUITests/StorefrontScenes/testToday` переснимает только главный экран. Размеры симуляторов: iPhone 18 Pro Max — 1320 × 2868; iPhone 18 Pro — 1206 × 2622. Для нового ref нужен осознанный просмотр результатов: драйвер не меняет production UI при изменении accessibility identifiers.

## Apple Watch

После удаления своего предыдущего симулятора создайте `com.apple.CoreSimulator.SimDeviceType.Apple-Watch-Ultra-4-49mm` в `com.apple.CoreSimulator.SimRuntime.watchOS-27-2` с именем `Malysh – App Store Launch Watch…`. Скрипт проверяет имя и путь App Group перед записью фикстуры.

```sh
export MALYSH_WATCH_CAPTURE_APP="$MALYSH_CAPTURE_BUILD_DIR/DerivedData/Build/Products/Debug-watchsimulator/MalyshWatch.app"
rtk proxy xcrun simctl bootstatus "$WATCH_UDID" -b
rtk proxy bash Publication/AppStore/capture/capture-watch.sh "$WATCH_UDID"
rtk proxy xcrun simctl shutdown "$WATCH_UDID"
```

Снимаются дневник, активное кормление и активный сон. Размер исходников 422 × 514. Перед запуском выберите этот временный Watch в Device Hub: у фонового watchOS compositor системный заголовок иногда появляется с задержкой. После съёмки обязательно проверьте имя ребёнка и часы в верхней части каждого кадра.

Обе команды автоматически обновляют `capture/provenance.json` только для реально экспортированных файлов: ref разрешается в commit, модель/runtime читаются по UDID, размеры и SHA-256 берутся из файлов. При съёмке `testPDFReport` основной скрипт также автоматически копирует `StorefrontReport.pdf` из Documents выделенного симулятора в `raw/15-pediatrician-report.pdf` и рендерит первую страницу в одноимённый PNG. Для повторной растеризации сохранённого PDF:

```sh
rtk proxy swift Publication/AppStore/capture/raster-pdf.swift \
  Publication/AppStore/raw/15-pediatrician-report.pdf \
  Publication/AppStore/raw/15-pediatrician-report.png
```

## iPhone Duo

Тип `com.apple.CoreSimulator.SimDeviceType.iPhone-Duo`, runtime `com.apple.CoreSimulator.SimRuntime.iOS-27-2-iPhone19-4`. В Device Hub выберите именно выделенный экземпляр. Состояние корпуса нужно менять штатным переключателем раскрытия Device Hub, а не только питание дисплея. Каждый экран сохраняйте из соответствующего активного дисплея; чёрный кадр нельзя объявлять готовым источником.

Для трёх сюжетов внешнего дисплея после выбора **Closed**:

```sh
rtk proxy bash Publication/AppStore/capture/capture-iphone.sh "$DUO_UDID" \
  Publication/AppStore/raw/duo-outer MalyshUITests/StorefrontScenes/testDuoScreens
```

После нажатия **Open** сначала сохраните диагностический `simctl io "$DUO_UDID" screenshot --display=3` вне `raw` и визуально проверьте, что он содержит приложение. Только после этого снимайте внутреннюю серию. Не копируйте внешние экраны в папку внутренних.

```sh
rtk proxy python3 Publication/AppStore/capture/capture-duo-inner.py "$DUO_UDID"
```

Эта обёртка нужна, потому что `XCUIScreen.main` в этой среде продолжает снимать выключенный внешний дисплей №1. XCTest открывает настоящие экраны и удерживает каждый пять секунд, а обёртка сохраняет именно дисплей №3 через `simctl`. Размер проверяется, чёрный кадр отклоняется, прежние источники заменяются только после проверки всех трёх результатов. Обычный рендер к симулятору не обращается.

В текущем прогоне 7 ноября 2026 штатная кнопка **Open** успешно включила внутренний экран: он показал настоящий UI, в отличие от прежней попытки одного переключения питания.

Точные результаты проверки текущего набора и идентификаторы симуляторов — в `provenance.json`. Необязательные наборы без настоящего источника остаются явно незавершёнными в генераторе. Изображения настоящего UI не ретушируются. Архивы ZIP не создаются.


## Один настоящий системный кадр Live Activities

Проверенное условие автоматического повтора — **чистый запуск выделенного симулятора**: выключите его по `CAPTURE_UDID`, если он ещё запущен, затем выполните `xcrun simctl boot` и `xcrun simctl bootstatus "$CAPTURE_UDID" -b`. Устройства пользователя не перезапускайте.

```sh
rtk proxy bash Publication/AppStore/capture/capture-iphone.sh "$CAPTURE_UDID" \
  Publication/AppStore/raw MalyshUITests/StorefrontLiveActivityScenes/testNativeLockScreenStates
```

`LiveActivityScene.swift` существует только в временной DEBUG-сборке для симулятора. Флаг `--storefront-live-states` напрямую запрашивает настоящие `CareActivityAttributes` (кормление 12 минут, сон 43 минуты) и `FeedingReminderActivityAttributes` (3 часа). Штатное расширение рисует карточки, а SpringBoard выбирает раскладку и фон. Снимок `raw/16-live-activities-lock-screen.png` сохраняется целиком, без вырезания и перестановки частей.

Это демонстрация системных состояний: обычное приложение отменяет напоминание при старте кормления. Только эта фикстура отключает автоматическое согласование активностей, чтобы проверить возможности нативной презентации. Не следует описывать кадр как обычный одновременный режим дневника. Результаты каждого системного запроса, включая возможный `targetMaximumExceeded`, сохраняются в `raw/16-live-activities-state.json` и учитываются при визуальной проверке. Код production-приложения и WidgetKit UI не меняются; CloudKit/APNs удалены из временных entitlements, личные Apple ID не используются.

### Проверенный системный способ и предел автоматизации

Готовый исходник от 8 ноября 2026 получен через прямой запуск изолированной сборки и штатное раскрытие группы в Device Hub. iOS 27.2 действительно отрисовала все три карточки одновременно. Автоматический XCTest-сценарий дополнительно проверяет `isHittable` контролов всех трёх карточек и не сохраняет неполный кадр. Проверка 8 ноября 2026 после перезапуска выделенного симулятора успешна: **1 сценарий, 0 ошибок**, автоматически раскрыты три настоящие карточки. Промоисточник при проверке не перезаписывался. На этой версии симулятора повторный XCTest-запуск после ручного взаимодействия иногда возвращал онбординг вместо подготовленного дневника; чистый перезапуск устранил сбой. У свёрнутой группы accessibility-позиция оказалась `y=0`, поэтому сценарий нажимает на наблюдаемое тело группы, не на кнопки действий. Если пойман повторный сбой старта, перезапустите только выделенный симулятор и повторите эту съёмку, либо используйте проверенный способ ниже.

Если автоматическая съёмка остановилась, установленную временную сборку можно запустить прямо:

```sh
rtk proxy xcrun simctl launch --terminate-running-process "$CAPTURE_UDID" dev.dimensi.malysh \
  --ui-testing --reset-data --storefront-fixture --storefront-live-states --light-mode \
  -AppleLanguages '(ru)' -AppleLocale ru_RU
```

В Device Hub выберите **только выделенный** `Malysh – App Store Launch…`, дождитесь главного экрана Ванечки, затем **Controls → Lock**, **Home**. Нажмите на группу активностей, разрешите их показ, если iOS спросит, и убедитесь, что видны кормление, сон и напоминание. Ничего не вырезайте: сохраняется полный кадр.

```sh
rtk proxy xcrun simctl io "$CAPTURE_UDID" screenshot Publication/AppStore/raw/16-live-activities-lock-screen.png
CAPTURE_DATA=$(rtk proxy xcrun simctl get_app_container "$CAPTURE_UDID" dev.dimensi.malysh data)
rtk proxy cp "$CAPTURE_DATA/Documents/StorefrontLiveActivities.json" Publication/AppStore/raw/16-live-activities-state.json
rtk proxy python3 Publication/AppStore/capture/record-provenance.py --repo "$PWD" --release v1.13.0 --udid "$CAPTURE_UDID" \
  Publication/AppStore/raw/16-live-activities-lock-screen.png Publication/AppStore/raw/16-live-activities-state.json
rtk proxy xcrun simctl shutdown "$CAPTURE_UDID"
```
