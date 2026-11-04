# Малыш

Приложение для iPhone: кормление грудью и из бутылочки, подгузники и сон. Записи сохраняются локально; синхронизация через iCloud включается отдельно. Минимальная система — iOS 26, язык — Swift 6.

## Сборка

Для запуска готового проекта нужен Xcode с поддержкой Swift 6 и iOS 26+. Для перегенерации проекта и проверок нужны Tuist, SwiftFormat и SwiftLint. Готовый `Malysh.xcworkspace` уже включён в исходники. Для запуска откройте его в Xcode, выберите схему `Malysh` и любой iPhone Simulator, затем нажмите Run (⌘R). Для запуска на физическом устройстве выберите свою Team в Signing & Capabilities.

Команды выполняются из этой папки. `Project.swift` описывает проект; Tuist создаёт `Malysh.xcworkspace` со схемой `Malysh`.

```sh
tuist generate --no-open
xcodebuild -workspace Malysh.xcworkspace -scheme Malysh -destination 'platform=iOS Simulator,name=iPhone 16 Pro' CODE_SIGNING_ALLOWED=NO -derivedDataPath DerivedData -resultBundlePath Artifacts/Tests.xcresult test
```

Указанный симулятор — iPhone 16 Pro. На другом Mac выберите имя установленного симулятора или передайте его идентификатор через `DESTINATION`. Перед повторным запуском выберите новый путь результата или удалите предыдущий `Artifacts/Tests.xcresult`.

Полная проверка форматирования, правил и тестов:

```sh
bash Scripts/check.sh
```

Для другого устройства или каталога результатов:

```sh
DESTINATION='platform=iOS Simulator,name=iPhone 16 Pro' RESULT_BUNDLE_PATH=Artifacts/Tests-repeat.xcresult bash Scripts/check.sh
```

## Данные и iCloud

По умолчанию iCloud выключен. После переключения требуется перезапуск приложения. Локальный режим и режим iCloud используют тот же SQLite-файл; переключение не создаёт отдельную локальную базу. Включение iCloud разрешает передачу записей в настроенный контейнер Apple.

Настройка подписания, схемы и проверки двух устройств описана в [CloudKit](Documentation/CloudKit.md). Симулятор без настроенной команды разработчика не подтверждает работоспособность синхронизации на устройствах.

## Структура

- `Sources` — интерфейс, модель и хранение данных.
- `Resources` — ресурсы приложения.
- `Tests` и `UITests` — автоматические проверки.
- `Documentation` — настройка и результаты проверок.
- `Scripts` — команды проверки проекта.

Фактические результаты и ограничения проверок приведены в [Validation.md](Documentation/Validation.md). Подтверждены 35 тестов (29 unit + 6 UI), подписанные Debug/Release-сборки и автоматическая публикация 1.0.6 (1) внутренней группе TestFlight. Пользователь подтвердил успешный приём нового Production-приглашения вторым родителем. Пустой стартовый профиль скрывается после подключения к семейному; реальные записи сохраняются. Подробные журналы и локальные сборки хранятся в исключённой из Git папке `Artifacts`; краткая сводка доступна в `Documentation/test-summary.json`.

Правила хранения, миграций и конфликтов описаны в [Data.md](Documentation/Data.md). Иконка подготовлена по приложенному референсу; исходник и промпт — [Branding.md](Documentation/Branding.md).

RTK необязателен: скрипт проверок использует его только при наличии в системе.

В Info.plist задано `ITSAppUsesNonExemptEncryption = false`: текущий MVP использует только системное шифрование Apple. При добавлении собственной криптографии или сторонних криптобиблиотек декларацию необходимо пересмотреть.

Автозагрузка в TestFlight по тегам `vX.Y.Z` проверена [полным выпуском v1.0.6](https://github.com/dimensi/malysh/actions/runs/41877293626); запуск, секреты и ограничения описаны в [TestFlight.md](Documentation/TestFlight.md).
