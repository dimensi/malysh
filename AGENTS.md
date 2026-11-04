# Инструкции для агентов

@/Users/n.nafranets/.codex/RTK.md

## Нативные диалоги SwiftUI

- Для уточняющего выбора после действия и подтверждения удаления используйте системный `confirmationDialog`; для ошибок и важных уведомлений — `alert`. Отдельный `alert` допустим для подтверждения, которому нужна постоянно видимая кнопка отмены.
- Прикрепляйте `.confirmationDialog` непосредственно к вызвавшей его кнопке или карточке действия. Не размещайте его на общем `ScrollView`, `Form`, `NavigationStack` или другом контейнере всего экрана.
- Начиная с iOS 26, action sheets на iPhone, как и на iPad, показываются возле элемента-источника. Корректная привязка нужна для положения окна, стрелки и системной анимации. Положение выбирает система: не задавайте координаты и не имитируйте старую нижнюю шторку кастомным popover.
- Для нескольких независимых действий задавайте отдельный диалог на каждом элементе-источнике. Сохраняйте `role: .destructive` для удаления и `role: .cancel` для отмены; в привязанном action sheet система может скрывать кнопку отмены в пользу нажатия снаружи.
- При проверке UI смотрите, что окно появляется возле вызвавшего элемента, в том числе после прокрутки и с крупным Dynamic Type.
- Перед изменением API или поведения сверяйтесь с актуальной документацией через Context7 CLI: сначала `npx ctx7@latest library SwiftUI "<конкретный вопрос>"`, затем `npx ctx7@latest docs <полученный ID> "<конкретный вопрос>"`. Не более трёх запросов на вопрос; не передавайте секреты.

Источники Apple:

- [Human Interface Guidelines: Action sheets](https://developer.apple.com/design/human-interface-guidelines/action-sheets)
- [WWDC25: Build a UIKit app with the new design — Presentations](https://developer.apple.com/videos/play/wwdc2025/284/?time=811)
- [SwiftUI: confirmationDialog](https://developer.apple.com/documentation/swiftui/view/confirmationdialog(_:ispresented:titlevisibility:actions:))
