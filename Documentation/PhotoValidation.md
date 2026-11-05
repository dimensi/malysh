# Проверки семейных фотографий — PR2

Дата: 5 ноября 2026. Xcode 27.2 (27B52), Swift 6. Рабочая ветка `nnafranets/feature/kid-photos` перебазирована на актуальный `main` `6e99701` с PR1 и PR #4 (CloudKit schema tooling). Исходники приложения, модели и тесты при rebase не изменились. Ни релиз, ни тег, ни TestFlight, ни развёртывание Production-схемы в эту проверку не входят.

## Автоматические результаты

| Проверка | Результат |
| --- | --- |
| `Scripts/check.sh`, iPhone 17 Pro / iOS Simulator 26.0.1 (23A8464) | **144/144**, 0 ошибок, 0 пропусков: 111 unit, 2 render-теста виджетов, 31 UI |
| Дополнительный последний unit-набор, iPhone 18 Pro / iOS Simulator 27.2 | **112/112 unit + 2/2 render**, включая исключение локального журнала из backup |
| Отдельный набор `PhotoGalleryUITests`, iOS 26.0.1 | **8/8**: светлая/тёмная темы, крупный Dynamic Type, аватар, источник, просмотр, повторы и ошибки |
| SwiftFormat / `swiftlint lint --strict` | Без замечаний |
| `xcodebuild`, `Release`, `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO` | Успешная сборка приложения и расширения; без подписи и распространения |
| `momc`, старые модели V2/V3 и аддитивная V4 | Компиляция успешна; V2/V3 сохранены |
| `python3 -m unittest discover -s Scripts/tests -p test_cloudkit_schema.py`, после rebase | **14/14**, без ошибок |
| `bash Scripts/cloudkit-schema.sh check`, живые схемы | Совместимы, семантический diff пуст; проверка read-only, это проверка предыдущей схемы, не готовности V4 |
| Дополнительный прогон после rebase на `6e99701`, iOS 26.0.1 | **122/122**: 112 unit + 2 render + 8 фото UI, 0 ошибок/пропусков |

Полный прогон включает существующие четыре сценария Live Activities, установку настоящего системного Medium-виджета и его действия, переходы из виджетов, профиль/измерения и авторство событий. После небольших заключительных изменений журнала и интерфейса дополнительно запущены последние unit- и фото-UI-наборы. Основной результат не заменён суммой повторных прогонов.

## Что проверено

- Сначала подтверждённая запись в Photos, затем запись галереи; отказ оставляет незавершённый исходник и явную ошибку. Подтверждение Photos плюс ошибка семейного сохранения, перезапуск и повтор не вызывают ещё одну системную запись.
- Повтор импорта, импорт без локального asset ID, импорт собственного ранее снятого снимка и повторный импорт после удаления из галереи; два разных ресурса без asset ID остаются разными фотографиями.
- Очередь одновременных операций, отключённое по умолчанию автосохранение, повторная синхронизация без второй копии, повреждённый журнал и неопределённый результат записи без слепого повтора.
- Оригинальные размеры/дата со смещением часового пояса и отсутствие GPS в семейной копии. JPEG/превью — отдельные ресурсы, не JSON.
- Миграция V3→V4 отдельно для private/shared stores с сохранением ребёнка, событий и измерений; расположение новых фото в store ребёнка, обратное отношение и cascade. Записи двух родителей сохраняются независимо.
- Повторное открытие дисковой базы без CloudKit с сохранением байтов изображений и превью. Удаление семейного ресурса не вызывает API удаления Photos.
- Последнее фото по дате, закрепление **более старого** снимка, немедленная смена аватара и сохранение после перезапуска; удаление закреплённого, переход к последнему и возврат логотипа после удаления всех фото.
- Галерея из профиля и аватара, группы дат, полноэкранное пролистывание, избранное, системный share sheet, непосредственная привязка диалога к камере, явное закрытие галереи и ошибки отказа/повтора.

## Граница симуляторных доказательств

Workflow unit-тесты внедряют `PhotoLibraryWriting`. DEBUG UI fixtures включаются только с `--ui-testing`: синтетический encoded-снимок и mock writer проверяют интерфейс, очередь и момент добавления в галерею. Это **не подтверждение реальной камеры, TCC-диалогов, успешной системной записи PhotoKit, переживания удаления приложения или доставки CloudKit между Apple ID**.

Физический iPhone в рамках PR2 не использовался. Проверено на реальном iPhone: **ни одного сценария**. Два Apple ID, действующий CKShare после обновления, одновременные сетевые добавления, реальное удаление приложения, изменение разрешений и настройки iCloud/Shared Library остаются аппаратной приёмкой из [Photos.md](Photos.md#приёмка-на-физических-устройствах). Локальный shared store не выдаётся за успешную сетевую синхронизацию.

После подключения инструментов из свежего `main` запуск существующего изолированного DEBUG-инициализатора V4 на iOS Simulator 27.2 (`-cloudEnabled YES --initialize-cloudkit-schema`) завершился `SCHEMA_INITIALIZATION_FAILED: NSCocoaErrorDomain 134060`. Unified logs подтвердили первопричину: `134400`, `CKAccountStatusNoAccount`, затем `134406` (mirroring не инициализирован), `success=0`, `madeChanges=0`. Это не успешная подготовка Development. Повторный read-only `check` подтвердил пустой семантический diff. Снимок `CloudKit/development.ckdb` не подменён шаблоном и не изменён; Production не развёртывалась. Для подготовки V4 остаётся подписанный DEBUG-запуск с доступом к iCloud, затем существующий workflow `prepare`, проверка реального экспорта и ручной promotion перед будущим распространением.

## Воспроизведение

```sh
DESTINATION='platform=iOS Simulator,id=4649F571-1CAC-4A7D-AB10-8C44CA08362A' \
DERIVED_DATA_PATH=DerivedData/Photos26 \
RESULT_BUNDLE_PATH=Artifacts/Photos/Full-final26.xcresult bash Scripts/check.sh

xcodebuild -workspace Malysh.xcworkspace -scheme Malysh \
  -destination 'platform=iOS Simulator,id=CF83A3ED-A2AC-481F-A433-F9BC1C5D7CB3' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -derivedDataPath DerivedData \
  -parallel-testing-enabled NO -only-testing:MalyshTests -only-testing:MalyshWidgetTests \
  -resultBundlePath Artifacts/Photos/Unit-final27.xcresult test

xcodebuild -workspace Malysh.xcworkspace -scheme Malysh \
  -destination 'platform=iOS Simulator,id=4649F571-1CAC-4A7D-AB10-8C44CA08362A' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -derivedDataPath DerivedData/Photos26 \
  -parallel-testing-enabled NO -only-testing:MalyshUITests/PhotoGalleryUITests \
  -resultBundlePath Artifacts/Photos/PhotoUI-final26.xcresult test
```

UDID относятся к машине проверки; для повторного запуска выберите доступный симулятор и новые пути `.xcresult`. Логи, результаты и keepAlways-скриншоты светлой/тёмной галереи и шапки находятся локально в исключённом из Git `Artifacts/Photos`. Диагностические прогоны до исправлений сохранены отдельно и не считаются успешными проверками.
