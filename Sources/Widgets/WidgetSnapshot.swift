import Foundation

/// A disposable projection of the selected diary. Core Data remains the source of truth.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let historyLimit = 4096
    let version: Int
    let generatedAt: Date
    let babyID: UUID?
    let babyName: String?
    let events: [WidgetSnapshotEvent]

    init(baby: Baby?, events: [CareEvent], generatedAt: Date = Date()) {
        version = Self.currentVersion
        self.generatedAt = generatedAt
        babyID = baby?.id
        babyName = baby?.name
        // Retain a week for offline day/time-zone projection, plus the last feed even
        // when the diary has been quiet for longer. Never serialize notes or authors.
        let normalizedEvents: [CareEvent] = events.map { event in
            var normalized = event
            // Imported point events can omit end or contain a legacy interval.
            // Their recorded start is authoritative, just as in AppStore.save.
            if normalized.kind == .bottle || normalized.kind == .diaper {
                normalized.end = normalized.start
            }
            return normalized
        }
        let completed = normalizedEvents.filter {
            $0.babyID == baby?.id && $0.end != nil && $0.start <= generatedAt &&
                $0.end! >= $0.start && $0.end! <= generatedAt
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start > $1.start }
        let cutoff = generatedAt.addingTimeInterval(-8 * 86400)
        var retained = Array(completed.filter { $0.end! >= cutoff }.prefix(Self.historyLimit))
        let anchors = Array(completed.prefix(3)) + Array(completed.first(where: {
            $0.kind == .breast || $0.kind == .bottle
        }).map { [$0] } ?? [])
        for anchor in anchors where !retained.contains(where: { $0.id == anchor.id }) {
            if retained.count == Self.historyLimit {
                retained.removeLast()
            }
            retained.append(anchor)
        }
        self.events = retained.map(WidgetSnapshotEvent.init)
    }

    func summary(at date: Date = Date(), calendar: Calendar = .current) -> WidgetSummary {
        let completed = events.filter { $0.end <= date && $0.start <= date }
            .sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start > $1.start }
        let domainEvents = completed.map { event in
            CareEvent(id: event.id, babyID: babyID ?? UUID(), kind: event.kind,
                      start: event.start, end: event.end, volumeML: event.volumeML,
                      diaperType: event.diaperType)
        }
        let statistics = DailyStatistics(events: domainEvents, day: date, calendar: calendar, now: date)
        return WidgetSummary(babyID: babyID, babyName: babyName, feeds: statistics.feeds,
                             wetDiapers: statistics.wetDiapers, sleepSeconds: statistics.sleepSeconds,
                             lastFeeding: completed.first { $0.kind == .breast || $0.kind == .bottle },
                             recentEvents: Array(completed.prefix(3)), generatedAt: generatedAt)
    }
}

struct WidgetSnapshotEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: EventKind
    let start: Date
    let end: Date
    let volumeML: Int
    let diaperType: DiaperType

    init(_ event: CareEvent) {
        id = event.id
        kind = event.kind
        start = event.start
        end = event.end ?? event.start
        volumeML = event.kind == .bottle ? event.volumeML : 0
        diaperType = event.kind == .diaper ? event.diaperType : .wet
    }
}

struct WidgetSummary: Equatable, Sendable {
    let babyID: UUID?
    let babyName: String?
    let feeds: Int
    let wetDiapers: Int
    let sleepSeconds: TimeInterval
    let lastFeeding: WidgetSnapshotEvent?
    let recentEvents: [WidgetSnapshotEvent]
    let generatedAt: Date
}
