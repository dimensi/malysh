import SwiftUI
import WidgetKit

struct DiaryWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    var summary: WidgetSummary? {
        snapshot?.summary(at: date)
    }
}

struct DiaryWidgetProvider: TimelineProvider {
    func placeholder(in _: Context) -> DiaryWidgetEntry {
        DiaryWidgetEntry(date: .now, snapshot: nil)
    }

    func getSnapshot(in _: Context, completion: @escaping (DiaryWidgetEntry) -> Void) {
        completion(DiaryWidgetEntry(date: .now, snapshot: try? WidgetSnapshotStore().read()))
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<DiaryWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = try? WidgetSnapshotStore().read()
        let calendar = Calendar.current
        var dates = [now]
        // Entries survive a missed midnight refresh: every day gets its own local-day totals.
        for offset in 1 ... 7 {
            if let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)) {
                dates.append(day)
            }
        }
        completion(Timeline(entries: dates.map { DiaryWidgetEntry(date: $0, snapshot: snapshot) },
                            policy: .after(now.addingTimeInterval(1800))))
    }
}

struct DiaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetSnapshotStore.widgetKind, provider: DiaryWidgetProvider()) { entry in
            DiaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Дневник малыша")
        .description("Последнее кормление и события за сегодня.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct DiaryWidgetView: View {
    let entry: DiaryWidgetEntry
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var environmentRenderingMode
    var familyOverride: WidgetFamily?
    var renderingModeOverride: WidgetRenderingMode?

    private var family: WidgetFamily {
        familyOverride ?? environmentFamily
    }

    private var renderingMode: WidgetRenderingMode {
        renderingModeOverride ?? environmentRenderingMode
    }

    private var maximumTypeSize: DynamicTypeSize {
        switch family {
        case .systemMedium, .systemLarge: .xxxLarge
        default: .large
        }
    }

    private var summary: WidgetSummary? {
        entry.summary
    }

    private var babyID: UUID? {
        summary?.babyID
    }

    private var isReady: Bool {
        babyID != nil
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline: inline
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .systemMedium: medium
            case .systemLarge: large
            default: small
            }
        }
        // Widget families have fixed system bounds. Keep large text readable within
        // those bounds; VoiceOver still reads the full semantic content.
        .dynamicTypeSize(...maximumTypeSize)
        .privacySensitive()
        .widgetURL(WidgetRoute(.today, babyID: babyID).url)
        .containerBackground(for: .widget) {
            if family == .systemSmall, renderingMode == .fullColor {
                AppDesign.Palette.feeding
            } else {
                AppDesign.Palette.cardBackground
            }
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Label("Кормление", systemImage: "heart.fill")
                .font(AppDesign.Typography.note.weight(.semibold)).widgetAccentable()
            VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                feedElapsed.font(AppDesign.Typography.itemTitle.bold())
                feedDetail.font(AppDesign.Typography.note)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: AppDesign.Spacing.row) {
            small.frame(maxWidth: .infinity)
            VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                shortcut("Грудь", symbol: "heart.fill", destination: .breast, kind: .breast)
                shortcut("Подгузник", symbol: "drop.fill", destination: .diaper, kind: .diaper)
                shortcut("Сон", symbol: "moon.zzz.fill", destination: .sleep, kind: .sleep)
            }.font(AppDesign.Typography.note.weight(.semibold))
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.cardContent) {
            HStack {
                Text("Сегодня").font(AppDesign.Typography.itemTitle)
                Spacer()
                Text(entry.date, format: .dateTime.day().month()).font(AppDesign.Typography.note)
            }
            HStack(alignment: .top, spacing: AppDesign.Spacing.row) {
                metric("Кормлений", value: isReady ? String(summary?.feeds ?? 0) : "—", kind: .breast)
                metric("Мокрых", value: isReady ? String(summary?.wetDiapers ?? 0) : "—", kind: .diaper)
                metric("Сон", value: isReady ? duration(summary?.sleepSeconds ?? 0) : "—", kind: .sleep)
            }
            Divider()
            HStack(spacing: AppDesign.Spacing.group) {
                Image(systemName: "heart.fill").widgetAccentable()
                feedElapsed.font(AppDesign.Typography.detail.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text("Последние события").font(AppDesign.Typography.detail.weight(.semibold))
            if let events = summary?.recentEvents, !events.isEmpty {
                ForEach(events) { event in
                    HStack(spacing: AppDesign.Spacing.group) {
                        Image(systemName: symbol(event.kind)).frame(width: 20).widgetAccentable()
                        Text(event.kind.label).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(event.start, format: .dateTime.hour().minute()).monospacedDigit()
                    }.font(AppDesign.Typography.note)
                }
            } else {
                Text(isReady ? "Пока нет завершённых событий" : "Откройте «Малыш», чтобы увидеть дневник")
                    .font(AppDesign.Typography.note)
            }
            Spacer(minLength: 0)
            if let generatedAt = summary?.generatedAt {
                Text("Обновлено \(generatedAt, format: .dateTime.day().month().hour().minute())")
                    .font(.caption2).lineLimit(1)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Кормление", systemImage: "heart.fill").font(AppDesign.Typography.note.weight(.semibold))
            feedElapsed.font(AppDesign.Typography.itemTitle)
            feedDetail.font(AppDesign.Typography.note)
        }
    }

    private var circular: some View {
        VStack(spacing: 1) {
            Image(systemName: "drop.fill").font(AppDesign.Typography.note).widgetAccentable()
            Text(isReady ? String(summary?.wetDiapers ?? 0) : "—").font(.title2.bold()).monospacedDigit()
            Text("сегодня").font(.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isReady ? "Мокрых подгузников сегодня: \(summary?.wetDiapers ?? 0)" : "Откройте дневник")
    }

    private var inline: some View {
        HStack {
            Image(systemName: "heart.fill")
            if let feed = summary?.lastFeeding {
                Text("Кормление \(feed.end, style: .relative) назад")
            } else {
                Text(isReady ? "Кормлений пока нет" : "Откройте «Малыш»")
            }
        }
    }

    @ViewBuilder private var feedElapsed: some View {
        if let feed = summary?.lastFeeding {
            Text("\(feed.end, style: .relative) назад").monospacedDigit().lineLimit(2)
        } else {
            Text(isReady ? "Нет кормлений" : "Нет данных").lineLimit(2)
        }
    }

    @ViewBuilder private var feedDetail: some View {
        if let feed = summary?.lastFeeding {
            Text("\(feed.kind.label) · \(feed.start.formatted(date: .omitted, time: .shortened))")
                .lineLimit(2)
        } else {
            Text(isReady ? "Кормлений ещё нет" : "Откройте «Малыш»").lineLimit(2)
        }
    }

    private func shortcut(_ title: String, symbol: String, destination: WidgetRoute.Destination,
                          kind: EventKind) -> some View
    {
        Link(destination: WidgetRoute(destination, babyID: babyID).url) {
            Label { Text(title) } icon: {
                Image(systemName: symbol).font(AppDesign.Typography.note)
                    .foregroundStyle(AppDesign.Palette.primaryText)
                    .frame(width: 26, height: 26)
                    .background(renderingMode == .fullColor ? color(kind) : .clear, in: Circle())
            }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
                .foregroundStyle(AppDesign.Palette.primaryText)
                .widgetAccentable()
        }.accessibilityLabel("Открыть: " + title)
    }

    private func metric(_ title: String, value: String, kind: EventKind) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
            Image(systemName: symbol(kind)).font(AppDesign.Typography.note)
                .frame(width: 26, height: 26)
                .background(renderingMode == .fullColor ? color(kind) : .clear, in: Circle())
                .widgetAccentable()
            Text(value).font(.title3.bold()).monospacedDigit().lineLimit(2)
            Text(title).font(.caption2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) м" : "\(minutes) м"
    }

    private func symbol(_ kind: EventKind) -> String {
        switch kind {
        case .breast: "heart.fill"
        case .bottle: "waterbottle.fill"
        case .diaper: "drop.fill"
        case .sleep: "moon.zzz.fill"
        }
    }

    private func color(_ kind: EventKind) -> Color {
        switch kind {
        case .breast, .bottle: AppDesign.Palette.feeding
        case .diaper: AppDesign.Palette.diaper
        case .sleep: AppDesign.Palette.sleep
        }
    }
}
