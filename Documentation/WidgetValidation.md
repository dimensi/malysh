# Проверка обычных виджетов — 5 ноября 2026

Проверки выполнены в отдельном worktree на базе `20cceee`, Xcode 27.2, iPhone 18 Pro Simulator iOS 27.2. Релиз и загрузка в TestFlight не выполнялись.

- **86/86 unit-тестов:** в том числе 11 проверок снимка, CRUD/импорта, выбранного ребёнка, SQLite-рестарта без кэша, DST/timezone и уведомлений календаря с фоновой очереди. Регрессия защищает от Swift 6 actor trap при реальной смене суток.
- **Render-тест:** 48 PNG production view для всех шести семейств, заполненного/пустого/недоступного состояния, light/dark и дополнительных accented/accessibility-вариантов Home. Последняя правка убирает пустоту между заголовком и временем; [контентный preview](Widgets/compact-preview.jpg) не заменяет системную подложку WidgetKit.
- **4/4 cold URL UI-теста:** грудь и подтверждение стороны, подгузник и история, сон с подтверждением и восстановлением того же таймера, неверный ребёнок/неизвестный маршрут без записи событий.
- **Настоящий Medium в SpringBoard:** показал записанную бутылочку через App Group; нажатия по текстовым подписям открыли все три сценария. Проверены закрытие настроек перед диалогом, явное подтверждение запуска, отсутствие дубля сна и отображение последнего завершённого кормления при активном сне. Первый каталог WidgetKit на новом симуляторе может регистрироваться с задержкой; тест ограниченно повторяет открытие системного меню.
- Основные восемь UI-сценариев приложения прошли. Проверка автора старого события повторно прошла на актуальной базе `main`.
- **Signed Debug device build:** `codesign --verify --strict`, entitlements и embedded provisioning profiles обоих bundle ID проверены. Team `YBBAN7R28K`, minimum iOS 26.0, App Group `group.dev.dimensi.malysh`. У приложения сохранены CloudKit Development и APNs development, у extension нет CloudKit/APNs.
- SwiftFormat и SwiftLint проходят. Ревью кода выполнено GPT-6.1 medium; визуальное ревью подтвердило компактный Small/Medium в обеих темах.

## Границы доказательства

Существующий `LiveActivityUITests.testBreastSystemControlsSaveWhileAppStaysInBackground` не находит текст правой груди после нажатия в Dynamic Island; тот же результат воспроизведён на чистом `origin/main` без этих изменений. Проверка сна после завершения процесса нестабильна в полном UI-наборе на этом runtime, но повторный изолированный прогон прошёл. Assertions и код Live Activities не менялись.

App Group проверен настоящим системным Home-виджетом. Физический защищённый Lock Screen, фактическая системная композиция tinted/clear и доставка CloudKit между двумя Apple ID в этом прогоне не подтверждены; для accessory/тем есть production-view render-проверки и нативные WidgetKit modifiers. Системные задержки reload/import остаются ограничением iOS.

Development-профили обновлены и проверены. Перед будущим выпуском нужно обновить distribution profiles в CI под App Group; выпуск в этой задаче не запускался.

Локальные доказательства (каталог Artifacts исключён из Git): `FinalRegression.xcresult`, `CompactWidgetLayout.xcresult`, `WidgetHostVerified.xcresult`, `SleepActivityRegression.xcresult`, `device-signing-final.json`, журналы сборок. Исходный пользовательский worktree и базы не изменялись.
