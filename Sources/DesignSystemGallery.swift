#if DEBUG
    import SwiftUI

    /// Deterministic component specimen for render tests; never reads personal data or starts a timer.
    struct DesignSystemGallery: View {
        @Environment(\.dynamicTypeSize) private var dynamicTypeSize

        private let referenceDate = Date(timeIntervalSince1970: 1_735_732_800)
        private let babyID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))

        var body: some View {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
                lastFeeding
                LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize
                    ? [GridItem(.flexible())]
                    : [GridItem(.flexible()), GridItem(.flexible())], spacing: AppDesign.Spacing.row)
                {
                    ActionTile(title: "Кормление", subtitle: "Грудь или бутылочка", symbol: "heart.fill",
                               color: AppDesign.Palette.feeding, id: "gallery.feed") {}
                    ActionTile(title: "Подгузник", subtitle: "Записать смену", symbol: "drop.fill",
                               color: AppDesign.Palette.diaper, id: "gallery.diaper") {}
                    ActionTile(title: "Сон", subtitle: "Начать таймер", symbol: "moon.zzz.fill",
                               color: AppDesign.Palette.sleep, id: "gallery.sleep") {}
                    ActionTile(title: "Сводка", subtitle: "Как прошёл день", symbol: "chart.bar.fill",
                               color: AppDesign.Palette.cardBackground, id: "gallery.summary") {}
                }
                sleepCard
                VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
                    Text("Последние события").font(.title3.bold())
                    EventRow(event: event(kind: .bottle, index: 2), authorLabel: "Автор: Анна · Мама") {}
                    Divider()
                    EventRow(event: event(kind: .diaper, index: 3)) {}
                    Divider()
                    EventRow(event: event(kind: .sleep, index: 4), authorLabel: "Автор: Алексей · Папа") {}
                }
            }
            .padding(AppDesign.Spacing.contentInset)
            .background(AppDesign.Palette.groupedBackground)
            .tint(AppDesign.Palette.accent)
            .environment(\.locale, Locale(identifier: "ru_RU"))
            .environment(\.calendar, Calendar(identifier: .gregorian))
            .environment(\.timeZone, .gmt)
        }

        private var lastFeeding: some View {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.cardContent) {
                Label("Последнее кормление", systemImage: "heart.fill").font(AppDesign.Typography.itemTitle)
                Text("35 мин назад").font(.title.bold()).monospacedDigit()
                Text("Бутылочка · 12:00 · Смесь · 60 мл").font(AppDesign.Typography.detail)
            }
            .foregroundStyle(AppDesign.Palette.primaryText)
            .diaryCard(color: AppDesign.Palette.feeding)
        }

        private var sleepCard: some View {
            VStack(alignment: .leading, spacing: 14) {
                Label("Малыш спит", systemImage: "moon.zzz.fill").font(AppDesign.Typography.itemTitle)
                Text("00:25:00").font(.largeTitle.bold()).monospacedDigit()
                Button("Завершить сон") {}
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .foregroundStyle(AppDesign.Palette.onAccent)
            }
            .diaryCard(color: AppDesign.Palette.sleep)
        }

        private func event(kind: EventKind, index: UInt8) -> CareEvent {
            CareEvent(
                id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, index)),
                babyID: babyID,
                kind: kind,
                start: referenceDate,
                end: kind == .sleep ? referenceDate.addingTimeInterval(3600) : referenceDate,
                createdAt: referenceDate,
                modifiedAt: referenceDate,
                volumeML: 60,
                note: kind == .diaper ? "После прогулки" : ""
            )
        }
    }
#endif
