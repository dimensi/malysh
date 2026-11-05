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
    let birthDate: Date?
    let birthDay: CivilDay?
    private let activeEventValues: [WidgetActiveEvent]?
    private let actionToken: UUID?
    var activeEvents: [WidgetActiveEvent] {
        activeEventValues ?? []
    }

    /// Stable for a rendered snapshot; a refreshed snapshot permits the next point event.
    func commandID(for action: WidgetCareAction) -> UUID {
        var bytes = (actionToken ?? babyID ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")!).uuid
        bytes.15 ^= UInt8(WidgetCareAction.allCases.firstIndex(of: action)! + 1)
        return UUID(uuid: bytes)
    }

    init(baby: Baby?, events: [CareEvent], generatedAt: Date = Date()) {
        version = Self.currentVersion
        self.generatedAt = generatedAt
        babyID = baby?.id
        babyName = baby?.name
        birthDate = baby?.birthDateConfirmed == true ? baby?.birthDate : nil
        birthDay = baby?.birthDateConfirmed == true ? baby?.birthDay : nil
        actionToken = UUID()
        let active = events.filter {
            $0.babyID == baby?.id && $0.end == nil && $0.start <= generatedAt &&
                ($0.kind == .breast || $0.kind == .sleep)
        }.sorted { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start > $1.start }
        activeEventValues = [EventKind.breast, .sleep].compactMap { kind in
            active.first { $0.kind == kind }.map(WidgetActiveEvent.init)
        }
        // Retain a week for offline day/time-zone projection and the latest category
        // events in quiet diaries. Never serialize notes or authors.
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
        let anchors = Array(completed.prefix(3)) + [
            completed.first { $0.kind == .breast || $0.kind == .bottle },
            completed.first { $0.kind == .sleep },
            completed.first { $0.kind == .diaper && $0.diaperType != .dirty },
            completed.first { $0.kind == .diaper && $0.diaperType == .dirty },
        ].compactMap(\.self)
        // Reserve distinct anchors before filling recent history so a full cache
        // cannot evict one anchor while making room for another.
        var retained: [CareEvent] = []
        var retainedIDs: Set<UUID> = []
        for anchor in anchors where retainedIDs.insert(anchor.id).inserted {
            retained.append(anchor)
        }
        for event in completed where event.end! >= cutoff && retained.count < Self.historyLimit {
            if retainedIDs.insert(event.id).inserted {
                retained.append(event)
            }
        }
        retained.sort { $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start > $1.start }
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
                             lastSleep: completed.first { $0.kind == .sleep },
                             lastWetDiaper: completed.first { $0.kind == .diaper && $0.diaperType != .dirty },
                             recentEvents: Array(completed.prefix(3)), generatedAt: generatedAt, birthDate: birthDate,
                             birthDay: birthDay, activeEvents: activeEvents)
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
    let lastSleep: WidgetSnapshotEvent?
    let lastWetDiaper: WidgetSnapshotEvent?
    let recentEvents: [WidgetSnapshotEvent]
    let generatedAt: Date
    let birthDate: Date?
    let birthDay: CivilDay?
    let activeEvents: [WidgetActiveEvent]
}

/// Only timer display data; notes and identities never enter the shared cache.
struct WidgetActiveEvent: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let kind: EventKind
    let start: Date
    let side: BreastSide
    let sideStartedAt: Date?
    let leftSeconds: TimeInterval
    let rightSeconds: TimeInterval

    init(_ event: CareEvent) {
        id = event.id
        kind = event.kind
        start = event.start
        side = event.side
        sideStartedAt = event.sideStartedAt
        leftSeconds = event.leftSeconds
        rightSeconds = event.rightSeconds
    }
}
