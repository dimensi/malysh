# Подготовка схемы CloudKit

Команды запускаются из корня репозитория на Mac с Xcode и Python 3. Контейнер фиксирован: `iCloud.dev.dimensi.malysh`, Team `YBBAN7R28K`. Они управляют только схемой, не записями и не локальными базами приложения.

```sh
bash Scripts/cloudkit-schema.sh
```

По умолчанию `prepare` экспортирует живые Development и Production, разбирает CKDB, выполняет `cktool validate-schema` для Development и проверяет совместимость с Production. Только после успеха настоящий экспорт атомарно сохраняется в `CloudKit/development.ckdb`. Повторный запуск не перезаписывает файл при изменении только порядка или комментариев. Первый экспорт нужно добавить в Git вручную; выдуманного начального снимка в репозитории нет.

```sh
bash Scripts/cloudkit-schema.sh check
bash Scripts/cloudkit-schema.sh prepare --dry-run
```

Обе команды проверяют **живую Development** относительно живой Production, не импортируют схему и не изменяют версионируемые файлы. Временные экспорты удаляются. Отчёт и семантический diff сохраняются локально в исключённый из Git `Artifacts/CloudKit/report.json`. При неудаче до завершения проверки отчёт имеет статус `incomplete`; это не успешная проверка.

## Доступ

Создайте Management Token для нужной команды в CloudKit Console и сохраните через скрытый интерактивный ввод:

```sh
xcrun cktool save-token --type management --method keychain
```

Скрипт использует штатную авторизацию cktool: `CLOUDKIT_MANAGEMENT_TOKEN` либо ранее сохранённый токен, включая Keychain. Не передавайте токен в аргументах, не сохраняйте в репозитории и не вставляйте в чат. Скрипт не читает `.env`, не использует `--token` и не печатает вывод subprocess с возможными секретами. При ошибке он указывает операцию; её диагностику смотрите локально через cktool.

5 ноября 2026 проверены Xcode 27.2 (27B52), cktool 1.0.23001 и доступ к Team `YBBAN7R28K`. Живой `check` успешно экспортировал обе среды, выполнил validation и подтвердил семантическое совпадение Development и Production. Отдельная проверка заведомо неверной синтетической схемы завершилась ненулевым кодом validation. Импорт схем, прямой production-import и операции с записями не выполнялись.

## Перенос в Production

После `prepare` просмотрите diff, откройте CloudKit Console → нужный контейнер → Development → Deploy Schema Changes и подтвердите перенос в Production. Затем:

```sh
bash Scripts/cloudkit-schema.sh verify-production
```

Команда повторно экспортирует обе среды и сравнивает Production с версионируемым снимком. Успех означает совпадение схемы, а не доказанную синхронизацию двух устройств. Данные между средами не переносятся.

Импорт или автоматический deploy в Production намеренно отсутствует. Apple описывает импорт CKDB через CLI в sandbox/Development, а promotion в Production — через Console. Аргумент `--environment` в установленном man не доказывает поддержку production-import. См. [cktool](https://developer.apple.com/icloud/ck-tool/), [текстовую схему](https://developer.apple.com/documentation/cloudkit/integrating-a-text-based-schema-into-your-workflow) и [развёртывание контейнера](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema).

## Явный импорт Development

Для восстановления или применения **версионируемого** файла в Development:

```sh
bash Scripts/cloudkit-schema.sh import-development --confirm-import-development --dry-run
bash Scripts/cloudkit-schema.sh import-development --confirm-import-development
```

Импорт требует отдельного флага, validation и совместимости с обеими живыми средами. При совпадении с Development операция пропускается. После изменения Development повторно экспортируется и сверяется с файлом. Reset схемы и операции с записями не вызываются.

## Границы проверки

Локальная проверка запрещает удаление/переименование типов и полей, изменение типа или шифрования, удаление индексов и любые изменения прав существующего типа. Политика индексов и прав намеренно строже допустимого в Apple. Добавление типов, полей, индексов и ролей допускается, если cktool validation успешно.

Парсер понимает DEFINE SCHEMA, CREATE ROLE, RECORD TYPE, quoted identifiers, комментарии, примитивы, LIST, ENCRYPTED, NUMBER PREFERRED AS, индексы и GRANT. Неизвестная конструкция останавливает проверку; обхода нет. Порядок, комментарии и неявные системные поля/роли нормализуются. Проверка не анализирует Core Data модель: для новых её полей сначала выполните существующую DEBUG-подготовку Development из [CloudKit.md](CloudKit.md).

Без доступа к Apple можно запустить регрессии на синтетических схемах:

```sh
python3 -m unittest discover -s Scripts/tests -p test_cloudkit_schema.py
```
