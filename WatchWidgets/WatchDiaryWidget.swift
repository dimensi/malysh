import SwiftUI
import WidgetKit

@main
struct WatchDiaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "WatchDiaryWidget", provider: WatchDiaryTimeline()) { entry in
            WatchDiaryWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Малыш")
        .description("Последнее кормление и активные таймеры выбранного дневника.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct WatchDiaryEntry: TimelineEntry {
    let date: Date
    let diaryID: UUID?
    let name: String?
    let lastFeeding: Date?
    let active: CareEvent?
    let isStale: Bool

    init(date: Date, diary: WatchDiary?, isStale: Bool = false) {
        self.date = date
        diaryID = diary?.id
        name = diary?.name
        lastFeeding = diary?.latestCompletedFeeding?.feedingReferenceDate
        self.isStale = isStale
        active = isStale ? nil : (diary?.active(.breast) ?? diary?.active(.sleep))
    }

    func url(showingActive: Bool) -> URL {
        if showingActive, let diaryID, let active {
            return WidgetRoute(.activity, babyID: diaryID, eventID: active.id).url
        }
        return WidgetRoute(.today, babyID: diaryID).url
    }
}

private struct WatchDiaryTimeline: TimelineProvider {
    func placeholder(in _: Context) -> WatchDiaryEntry {
        let date = Date.now
        let id = UUID()
        let event = CareEvent(babyID: id, kind: .bottle, start: date.addingTimeInterval(-35 * 60))
        return WatchDiaryEntry(date: date, diary: WatchDiary(id: id, name: "Малыш", canWrite: false, events: [event]))
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchDiaryEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : timeline().entries[0])
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<WatchDiaryEntry>) -> Void) {
        completion(timeline())
    }

    private func timeline() -> Timeline<WatchDiaryEntry> {
        let state = WatchLocalState.fileURL.flatMap { try? WatchLocalState.read(from: $0) }
        let diary = state?.selectedDiary
        let now = Date()
        let active = diary?.active(.breast) ?? diary?.active(.sleep)
        let isLocalTimer = state?.pending.contains { $0.action.createsEvent && $0.eventID == active?.id } == true
        guard let diary, let staleAt = state?.snapshot?.staleAt, !isLocalTimer else {
            return Timeline(entries: [WatchDiaryEntry(date: now, diary: diary)], policy: .never)
        }
        let stale = WatchDiaryEntry(date: max(staleAt, now), diary: diary, isStale: true)
        guard staleAt > now else { return Timeline(entries: [stale], policy: .never) }
        let fresh = WatchDiaryEntry(date: now, diary: diary)
        // Re-read the local file when the boundary arrives. An identical newer projection can extend freshness.
        return Timeline(entries: [fresh, stale], policy: .after(staleAt))
    }
}

private struct WatchDiaryWidgetView: View {
    let entry: WatchDiaryEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .widgetURL(entry.url(showingActive: family == .accessoryRectangular || entry.active?.kind == .breast))
    }

    private var circular: some View {
        let activeFeed = entry.active?.kind == .breast ? entry.active : nil
        return ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: circularSymbol(hasActiveFeed: activeFeed != nil))
                    .font(.caption2)
                    .widgetAccentable()
                    .accessibilityLabel(circularLabel(hasActiveFeed: activeFeed != nil))
                if !entry.isStale, let date = activeFeed?.start ?? entry.lastFeeding {
                    Text(.currentDate, format: .offset(to: date, allowedFields: [.day, .hour, .minute],
                                                       maxFieldCount: 1, sign: .never))
                        .font(.caption2.weight(.semibold))
                        .accessibilityLabel(activeFeed == nil
                            ? Text("Кормление \(date, style: .relative) назад")
                            : Text("Кормление длится \(date, style: .relative)"))
                        .monospacedDigit()
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.caption2)
                        .accessibilityHidden(entry.isStale)
                }
            }
            .padding(.horizontal, 3)
            .accessibilityElement(children: .combine)
            .privacySensitive()
        }
    }

    private func circularSymbol(hasActiveFeed: Bool) -> String {
        if entry.isStale {
            return "clock.badge.exclamationmark"
        }
        return hasActiveFeed ? "timer" : "drop.fill"
    }

    private func circularLabel(hasActiveFeed: Bool) -> String {
        if entry.isStale {
            return "Данные устарели"
        }
        return hasActiveFeed ? "Идёт кормление" : "Последнее кормление"
    }

    @ViewBuilder
    private var inline: some View {
        if entry.isStale {
            Label("Данные устарели", systemImage: "clock.badge.exclamationmark")
        } else if entry.active?.kind == .breast {
            Label("Идёт кормление", systemImage: "drop.fill")
                .privacySensitive()
        } else if let date = entry.lastFeeding {
            Label {
                Text("Кормл. \(date, style: .relative) назад")
            } icon: {
                Image(systemName: "drop.fill")
            }
            .privacySensitive()
        } else {
            Label(entry.diaryID == nil ? "Малыш" : "Нет кормлений", systemImage: "drop.fill")
                .privacySensitive()
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.name ?? "Малыш")
                .font(.headline)
                .lineLimit(1)
            if entry.isStale {
                Text("Данные устарели").font(.caption)
            } else if let active = entry.active {
                Label(active.kind == .breast ? "Идёт кормление" : "Идёт сон",
                      systemImage: active.kind == .breast ? "drop.fill" : "moon.zzz.fill")
                    .font(.caption)
                    .widgetAccentable()
                    .lineLimit(1)
                if isLuminanceReduced {
                    Text(active.start, style: .relative)
                        .font(.caption.weight(.semibold))
                } else {
                    Text(timerInterval: active.start ... .distantFuture, countsDown: false)
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
            } else if let date = entry.lastFeeding {
                Text("Последнее кормление")
                    .font(.caption)
                    .lineLimit(1)
                Text("\(date, style: .relative) назад")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            } else {
                Text(entry.diaryID == nil ? "Откройте дневник" : "Нет кормлений")
                    .font(.caption)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .privacySensitive()
    }
}
