import Foundation

struct WatchOperation: Codable, Equatable, Sendable {
    let id: UUID
    let babyID: UUID
    let eventID: UUID
    let date: Date
    let action: WatchAction

    init(id: UUID = UUID(), babyID: UUID, eventID: UUID? = nil, date: Date = Date(), action: WatchAction) {
        self.id = id
        self.babyID = babyID
        self.eventID = eventID ?? id
        self.date = date
        self.action = action
    }

    func applying(to events: [CareEvent], now: Date = Date()) throws -> CareEvent {
        var event: CareEvent
        switch action {
        case let .startBreast(side):
            event = try newEvent(.breast, in: events, side: side)
        case .startSleep:
            event = try newEvent(.sleep, in: events)
        case let .bottle(type, volume):
            event = try newEvent(.bottle, in: events)
            event.bottleType = type
            event.volumeML = volume
        case let .diaper(type):
            event = try newEvent(.diaper, in: events)
            event.diaperType = type
        case let .switchBreast(to: side, expected: expected):
            event = try activeTimer(in: events, expected: expected)
            guard event.kind == .breast, event.side != side else { throw WatchRejection.timerChanged }
            event.switchSide(at: date)
        case let .finish(expected: expected):
            event = try activeTimer(in: events, expected: expected)
            event.finish(at: date)
        }
        do {
            try event.validate(now: now)
        } catch {
            throw WatchRejection.invalidOperation
        }
        return event
    }

    private func newEvent(_ kind: EventKind, in events: [CareEvent], side: BreastSide = .left) throws -> CareEvent {
        guard eventID == id else { throw WatchRejection.invalidOperation }
        let timed = kind == .breast || kind == .sleep
        if timed, events.contains(where: { $0.babyID == babyID && $0.kind == kind && $0.end == nil }) {
            throw WatchRejection.timerChanged
        }
        return CareEvent(id: id, babyID: babyID, kind: kind, start: date, end: timed ? nil : date,
                         createdAt: date, side: side)
    }

    private func activeTimer(in events: [CareEvent], expected: WatchTimerVersion) throws -> CareEvent {
        guard let event = events.first(where: { $0.id == eventID && $0.babyID == babyID }),
              event.end == nil, event.kind == .breast || event.kind == .sleep,
              WatchTimerVersion(event) == expected, date >= max(event.start, event.sideStartedAt ?? event.start)
        else { throw WatchRejection.timerChanged }
        return event
    }
}

enum WatchAction: Codable, Equatable, Sendable {
    case startBreast(BreastSide)
    case bottle(BottleType, Int)
    case diaper(DiaperType)
    case startSleep
    case switchBreast(to: BreastSide, expected: WatchTimerVersion)
    case finish(expected: WatchTimerVersion)

    var createsEvent: Bool {
        switch self {
        case .startBreast, .startSleep, .bottle, .diaper: true
        case .switchBreast, .finish: false
        }
    }
}

/// Compare only the fields that determine a timer transition, independent of edit attribution.
struct WatchTimerVersion: Codable, Equatable, Sendable {
    private let kind: EventKind
    private let start: Date
    private let side: BreastSide
    private let sideStartedAt: Date?
    private let leftSeconds: TimeInterval
    private let rightSeconds: TimeInterval

    init(_ event: CareEvent) {
        kind = event.kind
        start = event.start
        side = event.side
        sideStartedAt = event.sideStartedAt
        leftSeconds = event.leftSeconds
        rightSeconds = event.rightSeconds
    }
}

enum WatchRejection: String, Codable, Equatable, LocalizedError, Sendable {
    case diaryUnavailable, timerChanged, invalidOperation

    var errorDescription: String? {
        switch self {
        case .diaryUnavailable: "Дневник больше недоступен для записи."
        case .timerChanged: "Таймер уже изменился. Проверьте его состояние."
        case .invalidOperation: "Не удалось сохранить запись с такими данными."
        }
    }
}

struct WatchDiary: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let name: String
    let canWrite: Bool
    var events: [CareEvent]

    var latestFeeding: CareEvent? {
        events.filter { $0.kind == .breast || $0.kind == .bottle }.max(by: Self.earlierFeeding)
    }

    var latestCompletedFeeding: CareEvent? {
        events.filter { $0.kind == .bottle || ($0.kind == .breast && $0.end != nil) }.max(by: Self.earlierFeeding)
    }

    func active(_ kind: EventKind) -> CareEvent? {
        events.filter { $0.kind == kind && $0.end == nil }.max(by: Self.earlier)
    }

    private static func earlierFeeding(_ lhs: CareEvent, _ rhs: CareEvent) -> Bool {
        if lhs.feedingReferenceDate != rhs.feedingReferenceDate {
            return lhs.feedingReferenceDate < rhs.feedingReferenceDate
        }
        return earlier(lhs, rhs)
    }

    private static func earlier(_ lhs: CareEvent, _ rhs: CareEvent) -> Bool {
        if lhs.start != rhs.start {
            return lhs.start < rhs.start
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct WatchSnapshot: Codable, Equatable, Sendable {
    static let freshnessInterval: TimeInterval = 6 * 60 * 60

    let streamID: UUID
    let revision: UInt64
    let generatedAt: Date
    let selectedID: UUID?
    let diaries: [WatchDiary]

    var staleAt: Date {
        generatedAt.addingTimeInterval(Self.freshnessInterval)
    }
}

struct WatchReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let rejection: WatchRejection?
    let snapshot: WatchSnapshot
}

enum WatchWire {
    static let operation = "malysh.watch.v1.operation"
    static let snapshot = "malysh.watch.v1.snapshot"
    static let receipt = "malysh.watch.v1.receipt"
    static let refresh = "malysh.watch.v1.refresh"
}
