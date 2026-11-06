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
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var typeSize
    var surface: DiaryWidgetSurface?

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

    var body: some View {
        Group {
            if [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family) {
                lockContent
                    .containerBackground(for: .widget) { AppDesign.Palette.cardBackground }
            } else {
                HomeDiaryWidget(entry: entry, surface: selected, age: confirmedBirthDate == nil ? nil : ageText)
            }
        }
        .foregroundStyle(AppDesign.Palette.primaryText)
        .privacySensitive()
        .widgetURL(WidgetRoute(selected == .diaper ? .history : .today, babyID: babyID).url)
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

    @ViewBuilder private var lastFeedingTime: some View {
        if let feed = summary?.lastFeeding {
            let time = Calendar.current.isDate(feed.start, inSameDayAs: entry.date)
                ? feed.start.formatted(date: .omitted, time: .shortened)
                : feed.start.formatted(.dateTime.day().month().hour().minute())
            Text(time).font(.caption).monospacedDigit().accessibilityLabel("Последнее кормление: " + time)
        } else {
            Text(ready ? "Кормлений ещё нет" : "—").font(.caption)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) м" : "\(minutes) м"
    }
}

private struct HomeDiaryWidget: View {
    let entry: DiaryWidgetEntry
    let surface: DiaryWidgetSurface
    let age: String?

    @Environment(\.widgetRenderingMode) private var renderingMode
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetFamily) private var family

    private var summary: WidgetSummary? {
        entry.summary
    }

    private var breast: WidgetActiveEvent? {
        summary?.activeEvents.first { $0.kind == .breast }
    }

    private var sleep: WidgetActiveEvent? {
        summary?.activeEvents.first { $0.kind == .sleep }
    }

    private var activeCategory: Bool {
        (surface == .feeding && breast != nil) || (surface == .sleep && sleep != nil)
    }

    private var lastDiaper: WidgetSnapshotEvent? {
        entry.snapshot?.events.first { $0.kind == .diaper && $0.end <= entry.date }
    }

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let babyID = snapshot.babyID, let summary {
                switch surface {
                case .feeding, .diaper, .sleep: small(summary, babyID: babyID, snapshot: snapshot)
                case .summary: dailySummary(summary)
                case .dashboard: dashboard(summary, babyID: babyID, snapshot: snapshot)
                default: quickActions(babyID: babyID, snapshot: snapshot)
                }
            } else {
                Link(destination: WidgetRoute(.today).url) {
                    Label("Открыть дневник", systemImage: "book.closed").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .buttonStyle(.plain)
        .containerBackground(for: .widget) {
            if renderingMode == .fullColor {
                AppDesign.Palette.cardBackground
                    .overlay(alignment: .bottomTrailing) {
                        RadialGradient(colors: [
                            activeCategory ? categoryAccent(surface).opacity(colorScheme == .dark ? 0.34 : 0.19) :
                                color(surface).opacity(0.9),
                            .clear,
                        ], center: .bottomTrailing, startRadius: 8, endRadius: 190)
                    }
            } else {
                AppDesign.Palette.cardBackground
            }
        }
    }

    private func small(_ summary: WidgetSummary, babyID: UUID, snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !typeSize.isAccessibilitySize {
                Text(surface.title).font(.headline).accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 2)
            HStack(alignment: .center, spacing: 4) {
                smallStatus(summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !typeSize.isAccessibilitySize {
                    careArt(surface == .feeding ? "heart.fill" : surface.symbol, category: surface, size: 46)
                        .accessibilityHidden(true)
                }
            }
            .invalidatableContent()
            Spacer(minLength: 2)
            switch surface {
            case .diaper:
                HStack(spacing: 5) {
                    diaperButton(.wetDiaper, snapshot: snapshot, compact: true)
                    diaperButton(.dirtyDiaper, snapshot: snapshot, compact: true)
                }
            case .sleep:
                sleepButton(babyID: babyID, snapshot: snapshot, compact: true)
            default:
                feedingButtons(babyID: babyID, snapshot: snapshot, compact: true)
            }
        }
    }

    private func smallStatus(_ summary: WidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch surface {
            case .diaper: smallDiaperStatus(summary)
            case .sleep: smallSleepStatus(summary)
            default: smallFeedingStatus(summary)
            }
        }
    }

    private func smallDiaperStatus(_ summary: WidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if typeSize.isAccessibilitySize {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(summary.wetDiapers)").font(.headline.bold()).monospacedDigit()
                    Text("мокрых").font(.caption2)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Мокрых подгузников сегодня: \(summary.wetDiapers)")
            } else {
                Text("\(summary.wetDiapers)").font(.title.bold()).monospacedDigit()
                    .accessibilityLabel("Мокрых подгузников сегодня: \(summary.wetDiapers)")
                Text("Мокрых").font(.caption2)
                if let lastDiaper {
                    Text(timestamp(lastDiaper.start)).font(.caption2).monospacedDigit()
                        .accessibilityLabel(
                            "Последний подгузник: \(lastDiaper.diaperType.label), \(timestamp(lastDiaper.start))"
                        )
                }
            }
        }
    }

    @ViewBuilder private func smallSleepStatus(_ summary: WidgetSummary) -> some View {
        if let sleep {
            elapsed(sleep.start, font: .title2.bold())
            Text("Спит").font(.caption2)
        } else if let last = summary.lastSleep {
            Text(typeSize.isAccessibilitySize ? "Сон" : "Последний").font(.caption2)
                .accessibilityHidden(true)
            Text(duration(last.end.timeIntervalSince(last.start))).font(.title2.bold()).monospacedDigit()
                .accessibilityLabel(
                    "Последний сон: \(duration(last.end.timeIntervalSince(last.start))), до \(recordedTime(last.end))"
                )
            if !typeSize.isAccessibilitySize {
                Text("До \(timestamp(last.end))").font(.caption2)
            }
        } else {
            Text("Сна ещё нет").font(.subheadline)
        }
    }

    @ViewBuilder private func smallFeedingStatus(_ summary: WidgetSummary) -> some View {
        if let breast {
            elapsed(breast.start, font: .title2.bold())
            Text("\(breast.side.label) грудь").font(.caption2)
        } else if let last = summary.lastFeeding {
            Text(Calendar.current.isDate(last.end, inSameDayAs: entry.date)
                ? "Последнее" : last.end.formatted(.dateTime.day().month(.twoDigits)))
                .font(.caption2).accessibilityHidden(true)
            Text(last.end, format: .dateTime.hour().minute()).font(.title2.bold()).monospacedDigit()
                .accessibilityLabel("Последнее кормление завершилось \(recordedTime(last.end))" +
                    (feedingDetail(last).map { ", " + $0 } ?? ""))
            if let detail = feedingDetail(last), !typeSize.isAccessibilitySize {
                Text(detail).font(.caption2)
            }
        } else {
            Text(typeSize.isAccessibilitySize ? "Нет кормлений" : "Ещё нет")
                .font(.subheadline).accessibilityLabel("Кормлений ещё нет")
        }
    }

    private func quickActions(babyID: UUID, snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !typeSize.isAccessibilitySize {
                Label("Быстрые действия", systemImage: "bolt.fill").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
            }
            actions(babyID: babyID, snapshot: snapshot, grid: typeSize.isAccessibilitySize)
        }
    }

    @ViewBuilder private func actions(babyID: UUID, snapshot: WidgetSnapshot, grid: Bool) -> some View {
        if grid {
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    feedingButtons(babyID: babyID, snapshot: snapshot, compact: false)
                    diaperButton(.wetDiaper, snapshot: snapshot, compact: false)
                }
                HStack(spacing: 6) {
                    diaperButton(.dirtyDiaper, snapshot: snapshot, compact: false)
                    sleepButton(babyID: babyID, snapshot: snapshot, compact: false)
                }
            }
        } else {
            HStack(alignment: .bottom, spacing: 5) {
                feedingButtons(babyID: babyID, snapshot: snapshot, compact: false)
                    .frame(width: 94)
                diaperButton(.wetDiaper, snapshot: snapshot, compact: false)
                diaperButton(.dirtyDiaper, snapshot: snapshot, compact: false)
                sleepButton(babyID: babyID, snapshot: snapshot, compact: false)
            }
        }
    }

    @ViewBuilder private func feedingButtons(babyID: UUID, snapshot: WidgetSnapshot, compact: Bool) -> some View {
        if let breast {
            HStack(spacing: 4) {
                Button(intent: FinishCareActivityIntent(eventID: breast.id, babyID: babyID)) {
                    tile("Стоп", icon: "stop.fill", category: .feeding,
                         timer: compact ? nil : breast.start, compact: compact)
                }
                .accessibilityLabel("Завершить кормление")
                .accessibilityValue(Text("\(breast.side.label) грудь, \(breast.start, style: .timer)"))
                .accessibilityIdentifier("widget.breast.finish")
                if !typeSize.isAccessibilitySize, compact || family == .systemLarge {
                    Button(intent: SwitchCareSideIntent(eventID: breast.id, babyID: babyID,
                                                        side: breast.side == .left ? "right" : "left"))
                    {
                        if compact {
                            tile("Смена", icon: "arrow.left.arrow.right", category: .feeding, compact: true)
                        } else {
                            symbol("arrow.left.arrow.right", category: .feeding)
                                .font(.subheadline.weight(.semibold))
                                .frame(width: AppDesign.Metrics.minimumTouch)
                                .frame(minHeight: 56)
                                .background { tileSurface(.feeding) }
                                .contentShape(Rectangle())
                        }
                    }
                    .accessibilityLabel("Сменить грудь")
                    .accessibilityIdentifier("widget.breast.switch")
                }
            }
        } else {
            Group {
                if !compact, family == .systemLarge, !typeSize.isAccessibilitySize {
                    HStack(spacing: 3) {
                        careArt("heart.fill", category: .feeding, size: 34).accessibilityHidden(true)
                        VStack(spacing: 0) {
                            Text("Кормить").font(.caption.weight(.semibold)).accessibilityHidden(true)
                            feedingSides(snapshot: snapshot, compact: compact)
                        }
                    }
                    .padding(.horizontal, 5)
                } else {
                    VStack(spacing: 0) {
                        if !compact, !typeSize.isAccessibilitySize {
                            HStack(spacing: 2) {
                                careArt("heart.fill", category: .feeding, size: 20)
                                Text("Кормить").font(.caption2.weight(.semibold))
                            }
                            .accessibilityHidden(true)
                        }
                        feedingSides(snapshot: snapshot, compact: compact)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background { tileSurface(.feeding) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Начать кормление")
        }
    }

    private func feedingSides(snapshot: WidgetSnapshot, compact: Bool) -> some View {
        HStack(spacing: 0) {
            start(.startBreastLeft, snapshot: snapshot,
                  label: "Начать кормление левой грудью", id: "widget.breast.left")
            {
                sideLabel("Л", full: "Левая", compact: compact)
            }
            Rectangle().fill(Color.primary.opacity(0.16)).frame(width: 1, height: 18)
            start(.startBreastRight, snapshot: snapshot,
                  label: "Начать кормление правой грудью", id: "widget.breast.right")
            {
                sideLabel("П", full: "Правая", compact: compact)
            }
        }
    }

    private func sideLabel(_ short: String, full: String, compact: Bool) -> some View {
        Text(compact && typeSize <= .large ? full : short)
            .font(.caption.weight(.semibold))
            .frame(minWidth: AppDesign.Metrics.minimumTouch, maxWidth: .infinity,
                   minHeight: AppDesign.Metrics.minimumTouch)
            .contentShape(Rectangle())
    }

    private func diaperButton(
        _ action: WidgetCareAction,
        snapshot: WidgetSnapshot,
        compact: Bool
    ) -> some View {
        let wet = action == .wetDiaper
        let latest = snapshot.events.first {
            $0.kind == .diaper && ($0.diaperType != .dirty) == wet && $0.end <= entry.date
        }
        return start(action, snapshot: snapshot,
                     label: wet ? "Мокрый подгузник" : "Стул", id: wet ? "widget.diaper.wet" : "widget.diaper.dirty")
        {
            tile(wet ? "Мокрый" : "Стул", icon: wet ? "drop.fill" : "care.stool", category: .diaper,
                 subtitle: latest.map { timestamp($0.start) }, compact: compact)
        }
        .accessibilityValue(latest.map { "Последняя запись: " + timestamp($0.start) } ?? "")
    }

    @ViewBuilder private func sleepButton(babyID: UUID, snapshot: WidgetSnapshot, compact: Bool) -> some View {
        if let sleep {
            Button(intent: FinishCareActivityIntent(eventID: sleep.id, babyID: babyID)) {
                tile("Стоп", icon: "stop.fill", category: .sleep,
                     timer: compact ? nil : sleep.start, compact: compact)
            }
            .accessibilityLabel("Завершить сон")
            .accessibilityValue(Text("Спит \(sleep.start, style: .timer)"))
            .accessibilityIdentifier("widget.sleep.finish")
        } else {
            start(.startSleep, snapshot: snapshot, label: "Начать сон", id: "widget.sleep.start") {
                tile(compact ? "Начать" : "Спать", icon: "moon.zzz.fill", category: .sleep, compact: compact)
            }
        }
    }

    @ViewBuilder private func start(
        _ action: WidgetCareAction,
        snapshot: WidgetSnapshot,
        label: String,
        id: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        if let babyID = snapshot.babyID {
            Button(intent: WidgetCareIntent(babyID: babyID, commandID: snapshot.commandID(for: action), action: action),
                   label: content)
                .accessibilityLabel(label)
                .accessibilityIdentifier(id)
        }
    }

    private func tile(
        _ title: String,
        icon: String,
        category: DiaryWidgetSurface,
        subtitle: String? = nil,
        timer: Date? = nil,
        compact: Bool
    ) -> some View {
        Group {
            if compact, typeSize.isAccessibilitySize, icon == "drop.fill" {
                symbol(icon, category: category).font(.title3.weight(.semibold)).accessibilityHidden(true)
            } else if !compact, family == .systemLarge, !typeSize.isAccessibilitySize {
                HStack(spacing: 7) {
                    careArt(icon, category: category, size: 36).accessibilityHidden(true)
                    tileText(title, subtitle: subtitle, timer: timer, compact: compact)
                }
                .padding(.horizontal, 6)
            } else {
                VStack(spacing: 2) {
                    if !compact, !typeSize.isAccessibilitySize {
                        careArt(icon, category: category, size: 26).accessibilityHidden(true)
                    }
                    tileText(title, subtitle: subtitle, timer: timer, compact: compact)
                }
            }
        }
        .frame(minWidth: AppDesign.Metrics.minimumTouch, maxWidth: .infinity,
               minHeight: compact || typeSize.isAccessibilitySize ? AppDesign.Metrics.minimumTouch :
                   family == .systemLarge ? 56 : 64)
        .background { tileSurface(category) }
        .contentShape(Rectangle())
    }

    private func tileText(_ title: String, subtitle: String?, timer: Date?, compact: Bool) -> some View {
        VStack(spacing: 1) {
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            if let timer, !compact {
                elapsed(timer, font: .caption2.bold()).multilineTextAlignment(.center)
            }
            if let subtitle, !compact, !typeSize.isAccessibilitySize {
                Text(subtitle).font(.caption2).monospacedDigit().invalidatableContent()
            }
        }
    }

    @ViewBuilder private func careArt(_ icon: String, category: DiaryWidgetSurface, size: CGFloat) -> some View {
        if renderingMode == .fullColor {
            let asset = switch category {
            case .feeding: "WidgetFeedingArt"
            case .diaper: icon == "care.stool" ? "WidgetStoolArt" : "WidgetDiaperArt"
            default: "WidgetSleepArt"
            }
            Image(asset).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            symbol(icon == "stop.fill" ? category.symbol : icon, category: category)
                .font(.title3.weight(.semibold)).frame(width: size, height: size)
        }
    }

    private func dailySummary(_ summary: WidgetSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !typeSize.isAccessibilitySize {
                Label("Сегодня", systemImage: "calendar").font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            totals(summary).layoutPriority(1)
            if typeSize.isAccessibilitySize, breast != nil || sleep != nil {
                HStack(spacing: 12) {
                    if let breast {
                        Label("Кормление", systemImage: "heart.fill")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Кормление")
                            .accessibilityValue(Text("\(breast.start, style: .timer)"))
                    }
                    if let sleep {
                        Label("Спит", systemImage: "moon.zzz.fill")
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("Сон")
                            .accessibilityValue(Text("\(sleep.start, style: .timer)"))
                    }
                }
                .font(.caption2.weight(.semibold))
            }
            Spacer(minLength: 0)
            lastFeeding(summary)
        }
    }

    private func dashboard(_ summary: WidgetSummary, babyID: UUID, snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image("BabyBear").renderingMode(.template).resizable().scaledToFit()
                    .foregroundStyle(.primary).frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.babyName ?? "Малыш").font(.headline).accessibilityAddTraits(.isHeader)
                    if let age, !typeSize.isAccessibilitySize {
                        Text(age).font(.caption2)
                    }
                }
            }
            if !typeSize.isAccessibilitySize {
                totals(summary)
                    .padding(.vertical, 5)
                    .background { tileSurface(.summary) }
            }
            actions(babyID: babyID, snapshot: snapshot, grid: true)
            if !typeSize.isAccessibilitySize || typeSize <= .accessibility2 {
                lastFeeding(summary)
            }
            if !typeSize.isAccessibilitySize {
                recentEvents(summary).layoutPriority(1)
            } else if typeSize >= .accessibility3 {
                diaryLink("Дневник", destination: .today, babyID: babyID) {
                    Label("Дневник", systemImage: "book.closed").font(.caption)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func totals(_ summary: WidgetSummary) -> some View {
        HStack(spacing: 4) {
            metric("Кормлений", value: "\(summary.feeds)", icon: "heart.fill", category: .feeding,
                   active: surface == .summary && !typeSize.isAccessibilitySize ? breast : nil)
            metric("Мокрых", value: "\(summary.wetDiapers)", icon: "drop.fill", category: .diaper)
            metric("Сон", value: duration(summary.sleepSeconds), icon: "moon.zzz.fill", category: .sleep,
                   active: surface == .summary && !typeSize.isAccessibilitySize ? sleep : nil)
        }
        .invalidatableContent()
    }

    @ViewBuilder private func metric(
        _ title: String, value: String, icon: String, category: DiaryWidgetSurface, active: WidgetActiveEvent? = nil
    ) -> some View {
        if let active {
            HStack(spacing: 4) {
                symbol(icon, category: category).font(.caption)
                VStack(alignment: .leading, spacing: 1) {
                    Text(value).font(.headline.bold()).monospacedDigit()
                    HStack(spacing: 3) {
                        Text(category == .sleep ? "Спит" : "Грудь").font(.caption2)
                        elapsed(active.start, font: .caption2.bold())
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(title): \(value)")
            .accessibilityValue(Text("\(category == .sleep ? "Спит" : "Кормление"), \(active.start, style: .timer)"))
        } else {
            metricValue(title, value: value, icon: icon, category: category)
        }
    }

    private func metricValue(_ title: String, value: String, icon: String, category: DiaryWidgetSurface) -> some View {
        ViewThatFits {
            HStack(spacing: 5) {
                symbol(icon, category: category).font(.subheadline)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.headline.bold()).monospacedDigit()
                    Text(title).font(.caption2)
                }
            }
            .fixedSize()
            HStack(spacing: 4) {
                symbol(icon, category: category).font(.caption)
                Text(value).font(.caption.bold()).monospacedDigit()
            }
            .fixedSize()
            VStack(spacing: 1) {
                symbol(icon, category: category).font(.caption2)
                Text(value).font(.caption2.bold()).monospacedDigit()
            }
            .fixedSize()
            Text(value).font(.caption2.bold()).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }

    private func lastFeeding(_ summary: WidgetSummary) -> some View {
        let last = summary.lastFeeding
        let detail = last.flatMap(feedingDetail)
        let time = last.map { recordedTime($0.end) }
        let description = [last.map { recordedTime($0.end) }, detail].compactMap(\.self).joined(separator: ", ")
        return diaryLink("Последнее кормление: " + (description.isEmpty ? "ещё нет" : description),
                         destination: .today, babyID: summary.babyID)
        {
            symbol("heart.fill", category: .feeding).font(.caption)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Text("Последнее кормление")
                    Text(time ?? "—").bold().monospacedDigit()
                    if let detail {
                        Text(detail)
                    }
                }
                .fixedSize()
                Text(time.map { "Кормление · \($0)" } ?? "Кормлений ещё нет").fixedSize()
                Text(time ?? "—").bold().monospacedDigit()
            }
            .font(.caption2)
            .invalidatableContent()
        }
    }

    private func recentEvents(_ summary: WidgetSummary) -> some View {
        recentRows(summary, limit: 2)
    }

    private func recentRows(_ summary: WidgetSummary, limit: Int) -> some View {
        let events = summary.recentEvents.prefix(limit)
        return Link(destination: WidgetRoute(.history, babyID: summary.babyID).url) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Последние события").fontWeight(.semibold)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").accessibilityHidden(true)
                }
                if events.isEmpty {
                    Text("Событий ещё нет").foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    HStack(spacing: 5) {
                        symbol(
                            event.kind == .diaper && event
                                .diaperType == .dirty ? "care.stool" : eventSymbol(event.kind),
                            category: eventCategory(event.kind), compact: true
                        )
                        .frame(width: 16).accessibilityHidden(true)
                        Text(eventLabel(event))
                        Spacer(minLength: 0)
                        Text(timestamp(event.start)).monospacedDigit()
                    }
                }
            }
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(minHeight: AppDesign.Metrics.minimumTouch)
            .background { tileSurface(.summary) }
            .contentShape(Rectangle())
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Последние события")
        .accessibilityValue(events.isEmpty ? "Событий ещё нет" :
            events.map { "\(eventLabel($0)), \(timestamp($0.start))" }.joined(separator: ". "))
        .accessibilityHint("Открыть историю")
    }

    private func eventLabel(_ event: WidgetSnapshotEvent) -> String {
        event.kind == .diaper ? event.diaperType.label : event.kind.label
    }

    private func diaryLink(
        _ label: String,
        destination: WidgetRoute.Destination,
        babyID: UUID?,
        @ViewBuilder content: () -> some View
    ) -> some View {
        Link(destination: WidgetRoute(destination, babyID: babyID).url) {
            HStack(spacing: 6) {
                content()
                Spacer(minLength: 2)
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).accessibilityHidden(true)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: AppDesign.Metrics.minimumTouch)
            .background { tileSurface(.summary) }
            .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
        .accessibilityHint("Открыть дневник")
    }

    private func tileSurface(_ category: DiaryWidgetSurface) -> some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        return shape.fill(.clear)
            .background {
                if renderingMode == .fullColor {
                    shape.fill(LinearGradient(
                        colors: [
                            color(category).mix(with: categoryAccent(category), by: category == .summary ? 0 : 0.20),
                            color(category),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .overlay { shape.strokeBorder(Color.primary.opacity(0.09)) }
                } else {
                    shape.strokeBorder(Color.primary.opacity(0.25))
                }
            }
    }

    private func color(_ category: DiaryWidgetSurface) -> Color {
        switch category {
        case .feeding: AppDesign.Palette.feeding
        case .diaper: AppDesign.Palette.diaper
        case .sleep: AppDesign.Palette.sleep
        default: Color(uiColor: .tertiarySystemFill)
        }
    }

    private func symbol(_ name: String, category: DiaryWidgetSurface, compact: Bool = false) -> some View {
        Group {
            if name == "care.stool" {
                StoolSymbol().frame(width: compact ? 14 : 24, height: compact ? 14 : 24)
            } else {
                Image(systemName: name)
            }
        }
        .foregroundStyle(renderingMode == .fullColor ? categoryAccent(category) : .primary)
        .widgetAccentable()
    }

    private func categoryAccent(_ category: DiaryWidgetSurface) -> Color {
        switch category {
        case .feeding: colorScheme == .dark ? .yellow : .brown
        case .diaper: colorScheme == .dark ? .cyan : .blue
        case .sleep: colorScheme == .dark ? .purple.mix(with: .white, by: 0.42) : .purple
        default: .primary
        }
    }

    private func recordedTime(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: entry.date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month().hour().minute())
    }

    private func elapsed(_ start: Date, font: Font) -> some View {
        Text(start, style: .timer)
            .font(font).monospacedDigit().lineLimit(1).invalidatableContent()
    }

    private func timestamp(_ date: Date) -> String {
        Calendar.current.isDate(date, inSameDayAs: entry.date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.day().month(.twoDigits))
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) м" : "\(minutes) м"
    }

    private func feedingDetail(_ event: WidgetSnapshotEvent) -> String? {
        if event.kind == .bottle {
            return "\(event.volumeML) мл"
        }
        return event.side.map { $0 == .left ? "С левой" : "С правой" }
    }

    private func eventCategory(_ kind: EventKind) -> DiaryWidgetSurface {
        switch kind {
        case .breast, .bottle: .feeding
        case .diaper: .diaper
        case .sleep: .sleep
        }
    }

    private func eventSymbol(_ kind: EventKind) -> String {
        switch kind {
        case .breast: "heart.fill"
        case .bottle: "waterbottle.fill"
        case .diaper: "drop.fill"
        case .sleep: "moon.zzz.fill"
        }
    }
}

/// A small, recognizable care symbol; it remains a single tintable silhouette in accented widgets.
private struct StoolSymbol: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                StoolSilhouette().fill()
                StoolBands().stroke(
                    .background.opacity(0.7),
                    style: StrokeStyle(lineWidth: side * 0.055, lineCap: .round)
                )
            }
            .frame(width: side, height: side)
        }
    }
}

private struct StoolSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.50, y: 0.04))
        path.addCurve(
            to: CGPoint(x: 0.57, y: 0.25),
            control1: CGPoint(x: 0.38, y: 0.11),
            control2: CGPoint(x: 0.44, y: 0.19)
        )
        path.addCurve(
            to: CGPoint(x: 0.75, y: 0.43),
            control1: CGPoint(x: 0.77, y: 0.25),
            control2: CGPoint(x: 0.81, y: 0.34)
        )
        path.addCurve(
            to: CGPoint(x: 0.84, y: 0.63),
            control1: CGPoint(x: 0.93, y: 0.47),
            control2: CGPoint(x: 0.93, y: 0.57)
        )
        path.addCurve(
            to: CGPoint(x: 0.75, y: 0.94),
            control1: CGPoint(x: 1.02, y: 0.70),
            control2: CGPoint(x: 0.95, y: 0.94)
        )
        path.addLine(to: CGPoint(x: 0.25, y: 0.94))
        path.addCurve(
            to: CGPoint(x: 0.16, y: 0.63),
            control1: CGPoint(x: 0.05, y: 0.94),
            control2: CGPoint(x: -0.02, y: 0.70)
        )
        path.addCurve(
            to: CGPoint(x: 0.25, y: 0.43),
            control1: CGPoint(x: 0.07, y: 0.57),
            control2: CGPoint(x: 0.07, y: 0.47)
        )
        path.addCurve(
            to: CGPoint(x: 0.43, y: 0.25),
            control1: CGPoint(x: 0.19, y: 0.34),
            control2: CGPoint(x: 0.23, y: 0.25)
        )
        path.addCurve(
            to: CGPoint(x: 0.50, y: 0.04),
            control1: CGPoint(x: 0.56, y: 0.19),
            control2: CGPoint(x: 0.62, y: 0.11)
        )
        path.closeSubpath()
        return path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height).translatedBy(
            x: rect.minX,
            y: rect.minY
        ))
    }
}

private struct StoolBands: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0.25, y: 0.44))
        path.addCurve(
            to: CGPoint(x: 0.75, y: 0.44),
            control1: CGPoint(x: 0.38, y: 0.52),
            control2: CGPoint(x: 0.62, y: 0.52)
        )
        path.move(to: CGPoint(x: 0.16, y: 0.65))
        path.addCurve(
            to: CGPoint(x: 0.84, y: 0.65),
            control1: CGPoint(x: 0.34, y: 0.74),
            control2: CGPoint(x: 0.66, y: 0.74)
        )
        return path.applying(CGAffineTransform(scaleX: rect.width, y: rect.height).translatedBy(
            x: rect.minX,
            y: rect.minY
        ))
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
