import AppIntents
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
        DiaryWidgetPreview.entry
    }

    func getSnapshot(in context: Context, completion: @escaping (DiaryWidgetEntry) -> Void) {
        completion(context.isPreview ? DiaryWidgetPreview.entry : DiaryWidgetEntry(
            date: .now,
            snapshot: try? WidgetSnapshotStore().read()
        ))
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

/// Separate gallery entries make the choice of task explicit; the original kind remains
/// installed and maps each existing family onto the corresponding new surface.
enum DiaryWidgetSurface: String, CaseIterable {
    case feeding, diaper, sleep, quickActions, summary, dashboard
    case lastFeeding, wetDiapers, sleepStatus, age

    var title: String {
        switch self {
        case .feeding: "Кормление"
        case .diaper: "Подгузник"
        case .sleep: "Сон"
        case .quickActions: "Быстрые действия"
        case .summary: "Сегодня"
        case .dashboard: "Дневник и действия"
        case .lastFeeding: "Последнее кормление"
        case .wetDiapers: "Мокрые подгузники"
        case .sleepStatus: "Сон малыша"
        case .age: "Возраст малыша"
        }
    }

    var families: [WidgetFamily] {
        switch self {
        case .feeding, .diaper, .sleep: [.systemSmall]
        case .quickActions, .summary: [.systemMedium]
        case .dashboard: [.systemLarge]
        case .lastFeeding, .sleepStatus: [.accessoryRectangular, .accessoryInline]
        case .wetDiapers, .age: [.accessoryCircular, .accessoryRectangular, .accessoryInline]
        }
    }

    var symbol: String {
        switch self {
        case .feeding, .lastFeeding: "heart.fill"
        case .diaper, .wetDiapers: "drop.fill"
        case .sleep, .sleepStatus: "moon.zzz.fill"
        case .age: "birthday.cake.fill"
        default: "book.closed.fill"
        }
    }
}

struct CareDiaryWidget: Widget {
    var surface: DiaryWidgetSurface = .feeding
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Malysh." + surface.rawValue, provider: DiaryWidgetProvider()) { entry in
            DiaryWidgetView(entry: entry, surface: surface)
        }
        .configurationDisplayName(surface.title)
        .description(description)
        .supportedFamilies(surface.families)
    }

    private var description: String {
        switch surface {
        case .feeding: "Начните кормление с нужной стороны, смените грудь или завершите таймер."
        case .diaper: "Запишите мокрый подгузник или стул одним нажатием."
        case .sleep: "Начните или завершите сон, не открывая дневник."
        case .quickActions: "Кормление, подгузник и сон одним нажатием."
        case .summary: "Кормления, мокрые подгузники и завершённый сон за сегодня."
        case .dashboard: "Дневные итоги, таймеры, быстрые действия и последние события."
        case .lastFeeding: "Время последнего завершённого кормления."
        case .wetDiapers: "Мокрые и смешанные подгузники за сегодня."
        case .sleepStatus: "Длительность завершённого сна за сегодня."
        case .age: "Календарный возраст по подтверждённой дате рождения."
        }
    }
}

struct DiaryWidgetView: View {
    let entry: DiaryWidgetEntry
    @Environment(\.widgetFamily) private var environmentFamily
    @Environment(\.widgetRenderingMode) private var environmentRenderingMode
    @Environment(\.dynamicTypeSize) private var typeSize
    var familyOverride: WidgetFamily?
    var renderingModeOverride: WidgetRenderingMode?
    var surface: DiaryWidgetSurface?

    private var family: WidgetFamily {
        familyOverride ?? environmentFamily
    }

    private var renderingMode: WidgetRenderingMode {
        renderingModeOverride ?? environmentRenderingMode
    }

    private var summary: WidgetSummary? {
        entry.summary
    }

    private var babyID: UUID? {
        summary?.babyID
    }

    private var ready: Bool {
        babyID != nil
    }

    private var selected: DiaryWidgetSurface {
        surface ?? {
            switch family {
            case .systemMedium: .quickActions
            case .systemLarge: .dashboard
            case .accessoryCircular: .wetDiapers
            case .accessoryRectangular, .accessoryInline: .lastFeeding
            default: .feeding
            }
        }()
    }

    private var breast: WidgetActiveEvent? {
        summary?.activeEvents.first { $0.kind == .breast }
    }

    private var sleep: WidgetActiveEvent? {
        summary?.activeEvents.first { $0.kind == .sleep }
    }

    private var accessory: Bool {
        [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
    }

    var body: some View {
        Group {
            if accessory {
                lockContent
            } else {
                switch selected {
                case .feeding, .diaper, .sleep:
                    if typeSize.isAccessibilitySize {
                        accessibleSmall
                    } else {
                        small
                    }
                case .summary: dailySummary
                case .dashboard:
                    if typeSize.isAccessibilitySize {
                        accessibleActions
                    } else {
                        dashboard
                    }
                default:
                    if typeSize.isAccessibilitySize {
                        accessibleActions
                    } else {
                        quickActions
                    }
                }
            }
        }
        .foregroundStyle(AppDesign.Palette.primaryText)
        .privacySensitive()
        .widgetURL(WidgetRoute(selected == .diaper ? .history : .today, babyID: babyID).url)
        .containerBackground(for: .widget) {
            if family == .systemSmall, renderingMode == .fullColor {
                tint(selected)
            } else {
                AppDesign.Palette.cardBackground
            }
        }
    }

    /// Small AX uses its full width for readable primary actions. Secondary
    /// switching remains available in the Live Activity and the application.
    private var accessibleSmall: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ready {
                switch selected {
                case .diaper:
                    if lastDiaper != nil {
                        Link(destination: WidgetRoute(.history, babyID: babyID).url) {
                            latestDiaperFeedback
                        }.accessibilityLabel("Сохранено: " + diaperFeedback + ". Открыть историю")
                    } else {
                        readableStart(.wetDiaper, title: "Мокр.", category: .diaper,
                                      label: "Мокрый подгузник", id: "widget.diaper.wet")
                        readableStart(.dirtyDiaper, title: "Стул", category: .diaper,
                                      label: "Стул", id: "widget.diaper.dirty")
                    }
                case .sleep:
                    if let sleep {
                        Text("Спит").font(.caption2).invalidatableContent()
                            .accessibilityLabel("Сон с " + recordedTime(sleep.start))
                    } else if let last = summary?.lastSleep {
                        Text(compactTimestamp(last.end)).font(.caption2).invalidatableContent()
                    }
                    if let sleep, let babyID {
                        Button(intent: FinishCareActivityIntent(eventID: sleep.id, babyID: babyID)) {
                            readableAction("Стоп", category: .sleep)
                        }.accessibilityLabel("Завершить сон").accessibilityIdentifier("widget.sleep.finish")
                    } else {
                        readableStart(.startSleep, title: "Спать", category: .sleep,
                                      label: "Начать сон", id: "widget.sleep.start")
                    }
                default:
                    if let breast {
                        Text(breast.side.label).font(.caption2).invalidatableContent()
                    } else if let last = summary?.lastFeeding {
                        Text(compactTimestamp(last.start)).font(.caption2).invalidatableContent()
                    }
                    if let breast, let babyID {
                        Button(intent: FinishCareActivityIntent(eventID: breast.id, babyID: babyID)) {
                            readableAction("Стоп", category: .feeding)
                        }.accessibilityLabel("Завершить кормление").accessibilityIdentifier("widget.breast.finish")
                    } else {
                        readableStart(.startBreastLeft, title: "Старт", category: .feeding,
                                      label: "Начать кормление левой грудью", id: "widget.breast.left")
                    }
                }
            } else {
                Link(destination: WidgetRoute(selected == .diaper ? .history : .today, babyID: babyID).url) {
                    readableAction("Открыть", category: selected)
                }.accessibilityLabel("Нет данных. Открыть приложение «Малыш»")
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            if selected != .diaper, typeSize <= .xxxLarge {
                Text(stateTitle(selected))
                    .font(.caption2.weight(.semibold)).widgetAccentable()
            }
            if ready {
                if selected == .feeding {
                    if let breast {
                        timer(breast.start)
                    } else {
                        lastFeedingTime.invalidatableContent()
                    }
                    if typeSize <= .large {
                        Text(breast.map { "\($0.side.label) грудь" } ?? "Начнём с левой")
                            .font(.caption).lineLimit(1)
                    }
                    breastActions
                } else if selected == .sleep {
                    if let sleep {
                        timer(sleep.start)
                    } else {
                        lastSleepTime.invalidatableContent()
                    }
                    if typeSize <= .large, sleep == nil {
                        Text("Готовы ко сну?").font(.caption)
                    }
                    sleepAction
                } else {
                    if typeSize > .large {
                        latestDiaperFeedback
                    } else {
                        Text("Мокрых: \(summary?.wetDiapers ?? 0)").font(.caption2.weight(.semibold))
                            .invalidatableContent()
                        Text("Последнее: " + diaperFeedback).font(.caption2).invalidatableContent()
                    }
                    HStack(spacing: 6) { wetAction; dirtyAction }
                }
            } else {
                unavailable
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var lastDiaper: WidgetSnapshotEvent? {
        entry.snapshot?.events.filter { $0.kind == .diaper && $0.start <= entry.date }
            .max { $0.start < $1.start }
    }

    /// Feedback comes from the refreshed persisted projection, never a local button tap.
    private var diaperFeedback: String {
        guard let event = lastDiaper else { return "Подгузников ещё нет" }
        let title = event.diaperType == .dirty ? "Стул" : event.diaperType.label
        return "\(title) · \(recordedTime(event.start))"
    }

    private var latestDiaperFeedback: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let event = lastDiaper {
                Text(event.diaperType == .dirty ? "Стул" : event.diaperType == .wet ? "Мокр." : "Смеш.")
                Text(Calendar.current.isDate(event.start, inSameDayAs: entry.date)
                    ? event.start.formatted(date: .omitted, time: .shortened)
                    : event.start.formatted(.dateTime.day().month(.twoDigits)))
                    .monospacedDigit()
            } else {
                Text("Ещё нет")
            }
        }
        .font(.caption2)
        .invalidatableContent()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Последний подгузник: \(diaperFeedback). Мокрых сегодня: \(summary?.wetDiapers ?? 0)")
    }

    /// Fixed Medium has room for two readable targets. Large keeps all actions in
    /// one column; secondary stats/history yield their space to the user's text.
    @ViewBuilder private var accessibleActions: some View {
        if family == .systemMedium, ready, lastDiaper != nil {
            accessibleMediumFeedback
        } else {
            standardAccessibleActions
        }
    }

    private var accessibleMediumFeedback: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let sleep, let babyID {
                Button(intent: FinishCareActivityIntent(eventID: sleep.id, babyID: babyID)) {
                    readableAction("Стоп сон", category: .sleep)
                }.accessibilityLabel("Завершить сон").accessibilityIdentifier("widget.sleep.finish")
            } else if let breast, let babyID {
                Button(intent: FinishCareActivityIntent(eventID: breast.id, babyID: babyID)) {
                    readableAction("Стоп грудь", category: .feeding)
                }.accessibilityLabel("Завершить кормление").accessibilityIdentifier("widget.breast.finish")
            } else {
                readableStart(.startBreastLeft, title: "Кормить", category: .feeding,
                              label: "Начать кормление левой грудью", id: "widget.breast.left")
            }
            Text(compactDiaperFeedback).font(.caption2).invalidatableContent()
                .accessibilityLabel("Сохранено: " + diaperFeedback)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var compactDiaperFeedback: String {
        guard let event = lastDiaper else { return "Нет записей" }
        let kind = event.diaperType == .dirty ? "Стул" : event.diaperType == .wet ? "Мокр." : "Смеш."
        return kind + " · " + compactTimestamp(event.start)
    }

    private var standardAccessibleActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if ready {
                if family == .systemLarge, breast == nil, typeSize < .accessibility5 {
                    Text(summary?.babyName ?? "Малыш").font(.caption2)
                }
                if let breast, let babyID {
                    if family == .systemLarge {
                        Button(intent: SwitchCareSideIntent(eventID: breast.id, babyID: babyID,
                                                            side: breast.side == .left ? "right" : "left"))
                        {
                            readableAction("Сменить грудь", category: .feeding)
                        }
                        .accessibilityLabel("Сменить грудь").accessibilityIdentifier("widget.breast.switch")
                    }
                    Button(intent: FinishCareActivityIntent(eventID: breast.id, babyID: babyID)) {
                        readableAction("Стоп грудь", category: .feeding)
                    }
                    .accessibilityLabel("Завершить кормление").accessibilityIdentifier("widget.breast.finish")
                    .accessibilityValue(Text("\(breast.side.label) грудь, идёт \(breast.start, style: .timer)"))
                } else {
                    readableStart(.startBreastLeft, title: "Кормить", category: .feeding,
                                  label: "Начать кормление левой грудью", id: "widget.breast.left")
                }
                if family == .systemLarge || sleep == nil {
                    readableStart(.wetDiaper, title: "Мокрый", category: .diaper,
                                  label: "Мокрый подгузник. Последнее: " + diaperFeedback, id: "widget.diaper.wet")
                }
                if family == .systemLarge {
                    readableStart(.dirtyDiaper, title: "Стул", category: .diaper,
                                  label: "Стул. Последнее: " + diaperFeedback, id: "widget.diaper.dirty")
                }
                if let sleep, let babyID {
                    Button(intent: FinishCareActivityIntent(eventID: sleep.id, babyID: babyID)) {
                        readableAction("Стоп сон", category: .sleep)
                    }
                    .accessibilityLabel("Завершить сон").accessibilityIdentifier("widget.sleep.finish")
                    .accessibilityValue(Text("Сон идёт \(sleep.start, style: .timer)"))
                } else if family == .systemLarge {
                    readableStart(.startSleep, title: "Начать сон", category: .sleep,
                                  label: "Начать сон", id: "widget.sleep.start")
                }
                if family == .systemLarge {
                    Text(typeSize == .accessibility5 ? compactDiaperFeedback : diaperFeedback)
                        .font(.caption2).invalidatableContent()
                        .accessibilityLabel("Последний подгузник: " + diaperFeedback)
                }
            } else {
                unavailable
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func readableStart(
        _ action: WidgetCareAction,
        title: String,
        category: DiaryWidgetSurface,
        label: String,
        id: String
    ) -> some View {
        if let babyID, let snapshot = entry.snapshot {
            Button(intent: WidgetCareIntent(
                babyID: babyID,
                commandID: snapshot.commandID(for: action),
                action: action
            )) {
                readableAction(title, category: category)
            }.accessibilityLabel(label).accessibilityIdentifier(id)
        }
    }

    private func readableAction(_ title: String, category: DiaryWidgetSurface) -> some View {
        Text(title).font(.caption2.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch, alignment: .leading)
            .padding(.horizontal, family == .systemSmall ? 0 : 8)
            .background(renderingMode == .fullColor ? tint(category) : .clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle()).widgetAccentable()
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 6) {
            if typeSize <= .large {
                HStack(alignment: .top, spacing: AppDesign.Spacing.row) {
                    quickCell { Text("Кормление") }
                    quickCell { Text("Подгузники") }
                    quickCell { Text("Сон") }
                }.font(.caption.weight(.semibold)).widgetAccentable()
            }
            if ready {
                HStack(alignment: .top, spacing: AppDesign.Spacing.row) {
                    quickCell { quickFeedingPrimary }
                    quickCell { wetAction }
                    quickCell { sleepAction }
                }
                HStack(alignment: .top, spacing: AppDesign.Spacing.row) {
                    quickCell {
                        if let breast, let babyID {
                            Button(intent: SwitchCareSideIntent(eventID: breast.id, babyID: babyID,
                                                                side: breast.side == .left ? "right" : "left"))
                            {
                                actionLabel("Сменить", symbol: "arrow.left.arrow.right", iconOnly: false)
                            }.buttonStyle(.plain).accessibilityLabel("Сменить грудь")
                                .accessibilityIdentifier("widget.breast.switch")
                        } else {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(summary?.lastFeeding.map { compactTimestamp($0.start) } ?? "Ещё нет")
                                Text("С левой")
                            }.font(.caption2).frame(minHeight: 44, alignment: .leading)
                                .invalidatableContent()
                                .accessibilityLabel(
                                    "Последнее кормление: \(summary?.lastFeeding.map { recordedTime($0.start) } ?? "ещё нет"). Начнём с левой груди"
                                )
                        }
                    }
                    quickCell { dirtyAction }
                    quickCell {
                        Group {
                            if let sleep {
                                timer(sleep.start)
                            } else {
                                Text(summary?.lastSleep.map { compactTimestamp($0.end) } ?? "Ещё нет").font(.caption2)
                            }
                        }.frame(minHeight: 44, alignment: .leading).invalidatableContent()
                    }
                }
            } else {
                openApp
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var quickFeedingPrimary: some View {
        if let breast, let babyID {
            Button(intent: FinishCareActivityIntent(eventID: breast.id, babyID: babyID)) {
                actionLabel("Стоп", symbol: "stop.fill", iconOnly: false,
                            timerStart: family == .systemMedium ? breast.start : nil)
            }.buttonStyle(.plain).accessibilityLabel("Завершить кормление")
                .accessibilityIdentifier("widget.breast.finish")
        } else {
            startAction(.startBreastLeft, title: "Кормить", symbol: "play.fill",
                        label: "Начать кормление левой грудью", id: "widget.breast.left")
        }
    }

    private func quickCell(@ViewBuilder content: () -> some View) -> some View {
        content().frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactTimestamp(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: entry.date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.twoDigits))
    }

    private func diaperActionTimestamp(dirty: Bool) -> String? {
        guard family != .systemSmall else { return nil }
        let event = entry.snapshot?.events.filter {
            $0.kind == .diaper && ($0.diaperType == .dirty) == dirty && $0.start <= entry.date
        }.max { $0.start < $1.start }
        return event.map { compactTimestamp($0.start) }
    }

    private var dailySummary: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            if !typeSize.isAccessibilitySize {
                HStack {
                    Text("Сегодня").font(AppDesign.Typography.itemTitle)
                    Spacer(minLength: 4)
                    if typeSize <= .large {
                        Text(entry.date, format: .dateTime.day().month()).font(.caption)
                    }
                }
            }
            totals
            if typeSize <= .large {
                ForEach((summary?.recentEvents ?? []).prefix(2)) { event in
                    HStack(spacing: 6) {
                        Image(systemName: symbol(event.kind)).widgetAccentable()
                        Text(event.kind.label)
                        Spacer(minLength: 0)
                        Text(event.start, format: .dateTime.hour().minute()).monospacedDigit()
                    }.font(.caption2)
                }
                if summary?.recentEvents.isEmpty != false {
                    Text(ready ? "Пока нет событий" : "Откройте дневник").font(.caption)
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var totals: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: AppDesign.Spacing.related) {
                accessibleTotal("Кормлений", symbol: "heart.fill", value: ready ? "\(summary?.feeds ?? 0)" : "—")
                accessibleTotal("Мокрых", symbol: "drop.fill", value: ready ? "\(summary?.wetDiapers ?? 0)" : "—")
                accessibleTotal(
                    "Сон",
                    symbol: "moon.zzz.fill",
                    value: ready ? duration(summary?.sleepSeconds ?? 0) : "—"
                )
            }
        } else {
            HStack(alignment: .top, spacing: AppDesign.Spacing.group) {
                total("Кормлений", symbol: "heart.fill", value: ready ? "\(summary?.feeds ?? 0)" : "—")
                total("Мокрых", symbol: "drop.fill", value: ready ? "\(summary?.wetDiapers ?? 0)" : "—")
                total("Сон", symbol: "moon.zzz.fill", value: ready ? duration(summary?.sleepSeconds ?? 0) : "—")
            }
        }
    }

    private func accessibleTotal(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: AppDesign.Spacing.group) {
            Image(systemName: symbol).resizable().scaledToFit().frame(width: 20, height: 20).widgetAccentable()
            Text(title)
            Spacer(minLength: 4)
            Text(value).bold().monospacedDigit()
        }
        .font(.caption2)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value)")
    }

    private func total(_ title: String, symbol: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Image(systemName: symbol).font(.caption).widgetAccentable()
            Text(value).font(typeSize.isAccessibilitySize ? .caption : .title3).bold().monospacedDigit()
            if typeSize <= .xxxLarge {
                Text(title).font(.caption2)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore).accessibilityLabel("\(title): \(value)")
    }

    private var hasActiveTimer: Bool {
        breast != nil || sleep != nil
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            HStack {
                Text(summary?.babyName ?? "Малыш").font(AppDesign.Typography.itemTitle)
                Spacer()
                if typeSize <= .large {
                    Text("Сегодня").font(.caption)
                }
            }
            totals
            Divider()
            if ready {
                if hasActiveTimer {
                    HStack(spacing: AppDesign.Spacing.row) {
                        if let breast {
                            HStack(spacing: 4) {
                                Image(systemName: "heart.fill").widgetAccentable()
                                timer(breast.start)
                            }.accessibilityLabel(Text("Кормление: \(breast.start, style: .timer)"))
                        }
                        if let sleep {
                            HStack(spacing: 4) {
                                Image(systemName: "moon.zzz.fill").widgetAccentable()
                                timer(sleep.start)
                            }.accessibilityLabel(Text("Сон: \(sleep.start, style: .timer)"))
                        }
                    }.font(.caption)
                }
                quickActions
                if typeSize <= .large {
                    Divider()
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                        Text("Последние события").font(.caption.weight(.semibold))
                        if let events = summary?.recentEvents, !events.isEmpty {
                            ForEach(events.prefix(hasActiveTimer ? 2 : 3)) { event in
                                HStack(spacing: 8) {
                                    Image(systemName: symbol(event.kind)).frame(width: 18).widgetAccentable()
                                    Text(event.kind.label)
                                    Spacer(minLength: 0)
                                    Text(event.start, format: .dateTime.hour().minute()).monospacedDigit()
                                }.font(.caption)
                            }
                        } else {
                            Text("Запишите первое событие кнопками выше").font(.caption)
                        }
                    }
                }
            } else {
                unavailable
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var breastActions: some View {
        if let breast, let babyID {
            HStack(spacing: 4) {
                Button(intent: SwitchCareSideIntent(eventID: breast.id, babyID: babyID,
                                                    side: breast.side == .left ? "right" : "left"))
                {
                    actionLabel("Сменить", symbol: "arrow.left.arrow.right", iconOnly: compactButtons)
                }.accessibilityLabel("Сменить грудь").accessibilityIdentifier("widget.breast.switch")
                Button(intent: FinishCareActivityIntent(eventID: breast.id, babyID: babyID)) {
                    actionLabel("Стоп", symbol: "stop.fill", iconOnly: compactButtons)
                }.accessibilityLabel("Завершить кормление").accessibilityIdentifier("widget.breast.finish")
            }.buttonStyle(.plain)
        } else {
            startAction(.startBreastLeft, title: "Начать", symbol: "play.fill",
                        label: "Начать кормление левой грудью", id: "widget.breast.left")
        }
    }

    private var compactButtons: Bool {
        typeSize.isAccessibilitySize
    }

    private var wetAction: some View {
        startAction(
            .wetDiaper,
            title: "Мокрый",
            symbol: "drop.fill",
            label: "Мокрый подгузник",
            id: "widget.diaper.wet",
            subtitle: diaperActionTimestamp(dirty: false)
        )
    }

    private var dirtyAction: some View {
        startAction(
            .dirtyDiaper,
            title: "Стул",
            symbol: "circle.lefthalf.filled",
            label: "Стул",
            id: "widget.diaper.dirty",
            subtitle: diaperActionTimestamp(dirty: true)
        )
    }

    @ViewBuilder private var sleepAction: some View {
        if let sleep, let babyID {
            Button(intent: FinishCareActivityIntent(eventID: sleep.id, babyID: babyID)) {
                actionLabel("Завершить", symbol: "stop.fill", iconOnly: compactButtons, category: .sleep)
            }.buttonStyle(.plain).accessibilityLabel("Завершить сон").accessibilityIdentifier("widget.sleep.finish")
        } else {
            startAction(
                .startSleep,
                title: family == .systemSmall ? "Начать" : "Спать",
                symbol: "moon.zzz.fill",
                label: "Начать сон",
                id: "widget.sleep.start"
            )
        }
    }

    @ViewBuilder private func startAction(_ action: WidgetCareAction, title: String, symbol: String,
                                          label: String, id: String, subtitle: String? = nil) -> some View
    {
        if let babyID, let snapshot = entry.snapshot {
            Button(intent: WidgetCareIntent(
                babyID: babyID,
                commandID: snapshot.commandID(for: action),
                action: action
            )) {
                actionLabel(title, symbol: symbol, iconOnly: compactButtons,
                            category: action == .startSleep ? .sleep :
                                (action == .wetDiaper || action == .dirtyDiaper) ? .diaper : .feeding,
                            subtitle: subtitle)
            }.buttonStyle(.plain).accessibilityLabel(label).accessibilityIdentifier(id)
        } else {
            openApp
        }
    }

    private func actionLabel(_ title: String, symbol: String, iconOnly: Bool,
                             category: DiaryWidgetSurface = .feeding, subtitle: String? = nil,
                             timerStart: Date? = nil) -> some View
    {
        Group {
            if iconOnly {
                Image(systemName: symbol).resizable().scaledToFit().frame(width: 20, height: 20)
            } else {
                VStack(spacing: 0) {
                    Text(title).font(.caption.weight(.semibold))
                    if let subtitle {
                        Text(subtitle).font(.caption2).monospacedDigit().invalidatableContent()
                    }
                    if let timerStart {
                        Text(timerInterval: timerStart ... Date.distantFuture, countsDown: false, showsHours: true)
                            .font(.caption2).monospacedDigit().invalidatableContent()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
        .background(renderingMode == .fullColor ?
            (family == .systemSmall ? AppDesign.Palette.cardBackground.opacity(0.8) : tint(category)) : .clear,
            in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle()).widgetAccentable()
    }

    private var openApp: some View {
        Link(destination: WidgetRoute(.today, babyID: babyID).url) {
            Label("Открыть", systemImage: "arrow.up.forward.app").font(.caption)
                .frame(minHeight: AppDesign.Metrics.minimumTouch)
        }.accessibilityLabel("Открыть приложение «Малыш»")
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Нет данных").font(.headline)
            if typeSize <= .large {
                Text("Откройте дневник малыша").font(.caption)
            }
            openApp
        }
    }

    @ViewBuilder private var lockContent: some View {
        if family == .accessoryInline {
            if typeSize >= .accessibility2 {
                Image(systemName: selected.symbol).resizable().scaledToFit().frame(width: 20, height: 20)
                    .accessibilityLabel(lockAccessibility)
            } else {
                HStack(spacing: 4) {
                    if typeSize <= .large {
                        Image(systemName: selected.symbol)
                    }
                    lockValue
                }.font(.caption2).accessibilityElement(children: .ignore).accessibilityLabel(lockAccessibility)
            }
        } else if family == .accessoryCircular {
            VStack(spacing: 2) {
                if typeSize <= .large {
                    Image(systemName: selected.symbol).font(.caption).widgetAccentable()
                }
                Text(lockNumericValue).font(typeSize > .large ? .caption2 : .title2).bold().monospacedDigit()
                if typeSize <= .large {
                    Text(selected == .age ? "дней" : "сегодня").font(.caption2)
                }
            }.accessibilityElement(children: .ignore).accessibilityLabel(lockAccessibility)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if typeSize <= .large {
                    Label(selected.title, systemImage: selected.symbol).font(.caption.weight(.semibold))
                }
                if typeSize >= .accessibility2 {
                    Text(lockCompactValue).font(.caption2).monospacedDigit()
                } else {
                    lockValue.font(.caption)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore).accessibilityLabel(lockAccessibility)
        }
    }

    @ViewBuilder private var lockValue: some View {
        switch selected {
        case .wetDiapers: Text(ready ? "\(summary?.wetDiapers ?? 0) мокрых сегодня" : "—")
        case .age: Text(ageText)
        case .sleepStatus:
            Text(ready ? "Сон: \(duration(summary?.sleepSeconds ?? 0))" : "—")
        default: lastFeedingTime
        }
    }

    private var confirmedBirthDate: Date? {
        entry.snapshot?.birthDay?.date(calendar: .current) ?? summary?.birthDate
    }

    private var ageDays: Int? {
        guard let birth = confirmedBirthDate else { return nil }
        return max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: birth),
                                                      to: Calendar.current.startOfDay(for: entry.date)).day ?? 0)
    }

    private var ageText: String {
        guard let birth = confirmedBirthDate else { return ready ? "Укажите дату рождения" : "—" }
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day],
            from: Calendar.current.startOfDay(for: birth),
            to: Calendar.current.startOfDay(for: entry.date)
        )
        if (parts.year ?? 0) > 0 {
            return "\(parts.year ?? 0) г \(parts.month ?? 0) мес"
        }
        if (parts.month ?? 0) > 0 {
            return "\(parts.month ?? 0) мес \(parts.day ?? 0) дн"
        }
        return "\(ageDays ?? 0) дн"
    }

    private var lockNumericValue: String {
        selected == .age ? ageDays.map(String.init) ?? "—" : ready ? "\(summary?.wetDiapers ?? 0)" : "—"
    }

    private var lockCompactValue: String {
        switch selected {
        case .age: ageDays.map(String.init) ?? "—"
        case .wetDiapers: lockNumericValue
        case .sleepStatus: ready ? duration(summary?.sleepSeconds ?? 0) : "—"
        default: summary?.lastFeeding?.start.formatted(date: .omitted, time: .shortened) ?? "—"
        }
    }

    private var lockAccessibility: String {
        switch selected {
        case .age: "Возраст малыша: " + ageText
        case .wetDiapers: "Мокрых подгузников сегодня: " + lockNumericValue
        case .sleepStatus: ready ? "Завершённый сон сегодня: \(duration(summary?.sleepSeconds ?? 0))" : "Откройте дневник"
        default: summary?.lastFeeding
            .map { "Последнее кормление: \($0.kind.label), \($0.start.formatted(date: .omitted, time: .shortened))" }
            ?? (ready ? "Кормлений ещё нет" : "Откройте дневник")
        }
    }

    private func stateTitle(_ kind: DiaryWidgetSurface) -> String {
        switch kind {
        case .feeding: breast == nil ? "Последнее кормление" : "Идёт кормление"
        case .sleep: sleep == nil ? "Последний сон" : "Спит"
        case .diaper: "Мокрых сегодня"
        default: kind.title
        }
    }

    @ViewBuilder private var lastSleepTime: some View {
        if let sleep = summary?.lastSleep {
            Text(recordedTime(sleep.end))
                .font(family == .systemSmall && typeSize <= .large ? .title2.bold() : .caption)
                .monospacedDigit().accessibilityLabel("Последний сон завершён: " + recordedTime(sleep.end))
        } else {
            Text(ready ? (family == .systemSmall ? "Сна ещё нет" : "Ещё нет") : "—").font(.caption)
        }
    }

    private func recordedTime(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: entry.date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month().hour().minute())
    }

    private func timer(_ start: Date) -> some View {
        Text(timerInterval: start ... Date.distantFuture, countsDown: false, showsHours: true)
            .font(family == .systemSmall && typeSize <= .large ? .title2.bold() : .caption.bold()).monospacedDigit()
            .invalidatableContent()
    }

    @ViewBuilder private var lastFeedingTime: some View {
        if let feed = summary?.lastFeeding {
            let time = recordedTime(feed.start)
            Text(time)
                .font(family == .systemSmall && typeSize <= .large ? .title2.bold() : .caption)
                .monospacedDigit()
                .accessibilityLabel("Последнее кормление: " + time)
        } else {
            Text(ready ? (family == .systemSmall || accessory ? "Кормлений ещё нет" : "Ещё нет") : "—").font(.caption)
        }
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

    private func tint(_ kind: DiaryWidgetSurface) -> Color {
        switch kind {
        case .feeding: AppDesign.Palette.feeding
        case .diaper: AppDesign.Palette.diaper
        case .sleep: AppDesign.Palette.sleep
        default: AppDesign.Palette.cardBackground
        }
    }
}

/// Synthetic samples only; previews never read the user's App Group.
private enum DiaryWidgetPreview {
    static var entry: DiaryWidgetEntry {
        let now = Date()
        let baby = Baby(name: "Малыш", birthDate: now.addingTimeInterval(-90 * 86400), birthDateConfirmed: true)
        return DiaryWidgetEntry(date: now, snapshot: WidgetSnapshot(baby: baby, events: [
            CareEvent(
                babyID: baby.id,
                kind: .bottle,
                start: now.addingTimeInterval(-3600),
                end: now.addingTimeInterval(-3600),
                volumeML: 90
            ),
            CareEvent(babyID: baby.id, kind: .sleep, start: now.addingTimeInterval(-900)),
        ], generatedAt: now))
    }
}

#Preview("Кормление", as: .systemSmall) { CareDiaryWidget(surface: .feeding) } timeline: { DiaryWidgetPreview.entry }
#Preview("Подгузник", as: .systemSmall) { CareDiaryWidget(surface: .diaper) } timeline: { DiaryWidgetPreview.entry }
#Preview("Сон", as: .systemSmall) { CareDiaryWidget(surface: .sleep) } timeline: { DiaryWidgetPreview.entry }
#Preview("Быстрые действия", as: .systemMedium) { CareDiaryWidget(surface: .quickActions) } timeline: {
    DiaryWidgetPreview.entry
}

#Preview("Сегодня", as: .systemMedium) { CareDiaryWidget(surface: .summary) } timeline: { DiaryWidgetPreview.entry }
#Preview("Дневник и действия", as: .systemLarge) { CareDiaryWidget(surface: .dashboard) } timeline: {
    DiaryWidgetPreview.entry
}

#Preview("Кормление · блокировка", as: .accessoryRectangular) { CareDiaryWidget(surface: .lastFeeding) } timeline: {
    DiaryWidgetPreview.entry
}

#Preview("Подгузники · блокировка", as: .accessoryCircular) { CareDiaryWidget(surface: .wetDiapers) } timeline: {
    DiaryWidgetPreview.entry
}

#Preview("Сон · блокировка", as: .accessoryRectangular) { CareDiaryWidget(surface: .sleepStatus) } timeline: {
    DiaryWidgetPreview.entry
}

#Preview("Возраст · строка", as: .accessoryInline) { CareDiaryWidget(surface: .age) } timeline: {
    DiaryWidgetPreview.entry
}
