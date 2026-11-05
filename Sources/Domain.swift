import Foundation

public enum EventKind: String, Codable, CaseIterable, Sendable {
    case breast, bottle, diaper, sleep
    public var label: String {
        switch self {
        case .breast: "Грудь"
        case .bottle: "Бутылочка"
        case .diaper: "Подгузник"
        case .sleep: "Сон"
        }
    }
}

public enum BreastSide: String, Codable, CaseIterable, Sendable {
    case left, right
    public var label: String {
        self == .left ? "Левая" : "Правая"
    }
}

public enum BottleType: String, Codable, CaseIterable, Sendable {
    case formula, expressed
    public var label: String {
        self == .formula ? "Смесь" : "Сцеженное молоко"
    }
}

public enum DiaperType: String, Codable, CaseIterable, Sendable {
    case wet, dirty, mixed
    public var label: String {
        switch self {
        case .wet: "Мокрый"
        case .dirty: "Грязный"
        case .mixed: "Смешанный"
        }
    }
}

public enum ParentRole: String, Codable, CaseIterable, Sendable {
    case father, mother, parent

    public var label: String {
        switch self {
        case .father: "Папа"
        case .mother: "Мама"
        case .parent: "Родитель"
        }
    }
}

public enum ParentProfileError: Error, LocalizedError {
    case emptyName, memberUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyName: "Введите имя родителя."
        case .memberUnavailable: "Участник семьи пока недоступен. Откройте настройки снова."
        }
    }
}

public struct ParentProfile: Codable, Sendable, Equatable {
    public var name: String
    public var role: ParentRole
    public var updatedAt: Date

    public init(name: String, role: ParentRole = .parent, updatedAt: Date = Date()) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.role = role
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case name, role, updatedAt }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        role = try values.decode(ParentRole.self, forKey: .role)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    /// Union independent parent edits; equal timestamps resolve identically on every device.
    public static func merging(_ first: [String: Self], _ second: [String: Self]) -> [String: Self] {
        first.merging(second) { existing, incoming in
            if existing.updatedAt != incoming.updatedAt {
                return existing.updatedAt > incoming.updatedAt ? existing : incoming
            }
            let existingKey = existing.role.rawValue + "\0" + existing.name
            let incomingKey = incoming.role.rawValue + "\0" + incoming.name
            return existingKey >= incomingKey ? existing : incoming
        }
    }
}

/// Gregorian civil date survives timezone changes without shifting the chosen birthday.
public struct CivilDay: Codable, Sendable, Equatable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        year = parts.year ?? 1970
        month = parts.month ?? 1
        day = parts.day ?? 1
    }

    public func date(calendar: Calendar) -> Date? {
        calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}

public struct Baby: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var birthDate: Date
    public var parentProfiles: [String: ParentProfile]
    public var birthDateConfirmed: Bool
    public var birthDay: CivilDay?
    public var pinnedPhotoID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        birthDate: Date = Date(),
        parentProfiles: [String: ParentProfile] = [:],
        birthDateConfirmed: Bool = false,
        pinnedPhotoID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.birthDate = birthDate
        self.parentProfiles = parentProfiles
        self.birthDateConfirmed = birthDateConfirmed
        self.pinnedPhotoID = pinnedPhotoID
        birthDay = birthDateConfirmed ? CivilDay(date: birthDate) : nil
    }

    private enum CodingKeys: String,
        CodingKey { case id, name, birthDate, parentProfiles, birthDateConfirmed, birthDay, pinnedPhotoID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        birthDate = try values.decode(Date.self, forKey: .birthDate)
        parentProfiles = try values.decodeIfPresent([String: ParentProfile].self, forKey: .parentProfiles) ?? [:]
        birthDateConfirmed = try values.decodeIfPresent(Bool.self, forKey: .birthDateConfirmed) ?? false
        birthDay = try values.decodeIfPresent(CivilDay.self, forKey: .birthDay)
        pinnedPhotoID = try values.decodeIfPresent(UUID.self, forKey: .pinnedPhotoID)
    }
}

public enum EventValidationError: Error, LocalizedError, Sendable {
    case futureStart, invalidEnd, invalidDuration, invalidVolume, invalidSideStart
    public var errorDescription: String? {
        switch self {
        case .futureStart: "Начало события не может быть в будущем."
        case .invalidEnd: "Окончание должно быть после начала и не в будущем."
        case .invalidDuration: "Длительность должна быть конечной и неотрицательной."
        case .invalidVolume: "Объём должен быть от 1 до 2000 мл."
        case .invalidSideStart: "Время начала кормления не соответствует событию."
        }
    }
}

public struct EventAuthor: Codable, Sendable, Equatable {
    public var id: String
    public var nameSnapshot: String?
    public var role: ParentRole?

    public init(id: String, nameSnapshot: String? = nil, role: ParentRole? = nil) {
        self.id = id
        self.nameSnapshot = nameSnapshot
        self.role = role
    }
}

public struct CareEvent: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var babyID: UUID
    public var start: Date
    public var end: Date?
    public var createdAt: Date
    public var modifiedAt: Date
    public var createdBy: EventAuthor?
    public var lastEditedBy: EventAuthor?
    public var kind: EventKind
    public var side: BreastSide
    public var sideStartedAt: Date?
    public var leftSeconds: TimeInterval
    public var rightSeconds: TimeInterval
    public var volumeML: Int
    public var bottleType: BottleType
    public var diaperType: DiaperType
    public var note: String

    public init(id: UUID = UUID(), babyID: UUID, kind: EventKind, start: Date = Date(),
                end: Date? = nil, createdAt: Date? = nil, modifiedAt: Date? = nil,
                side: BreastSide = .left, sideStartedAt: Date? = nil,
                leftSeconds: TimeInterval = 0, rightSeconds: TimeInterval = 0,
                volumeML: Int = 60, bottleType: BottleType = .formula,
                diaperType: DiaperType = .wet, note: String = "",
                createdBy: EventAuthor? = nil, lastEditedBy: EventAuthor? = nil)
    {
        self.id = id
        self.babyID = babyID
        self.kind = kind
        self.start = start
        self.end = end
        self.createdAt = createdAt ?? Date()
        self.modifiedAt = modifiedAt ?? self.createdAt
        self.createdBy = createdBy
        self.lastEditedBy = lastEditedBy
        self.side = side
        self.sideStartedAt = sideStartedAt ?? (kind == .breast && end == nil ? start : nil)
        self.leftSeconds = leftSeconds
        self.rightSeconds = rightSeconds
        self.volumeML = volumeML
        self.bottleType = bottleType
        self.diaperType = diaperType
        self.note = note
    }

    public func elapsed(now: Date = Date()) -> TimeInterval {
        max(0, min(end ?? now, now).timeIntervalSince(start))
    }

    public func breastDurations(now: Date = Date()) -> (left: TimeInterval, right: TimeInterval) {
        var left = leftSeconds
        var right = rightSeconds
        if kind == .breast, let sideStartedAt {
            let duration = max(0, min(end ?? now, now).timeIntervalSince(max(start, sideStartedAt)))
            if side == .left {
                left += duration
            } else {
                right += duration
            }
        }
        return (left, right)
    }

    public mutating func switchSide(at date: Date = Date()) {
        guard kind == .breast, end == nil, date >= (sideStartedAt ?? start) else { return }
        let durations = breastDurations(now: date)
        leftSeconds = durations.left
        rightSeconds = durations.right
        side = side == .left ? .right : .left
        sideStartedAt = date
        modifiedAt = date
    }

    public mutating func finish(at date: Date = Date()) {
        guard end == nil, date >= start, date >= (sideStartedAt ?? start) else { return }
        if kind == .breast {
            let durations = breastDurations(now: date)
            leftSeconds = durations.left
            rightSeconds = durations.right
            sideStartedAt = nil
        }
        end = date
        modifiedAt = date
    }

    public func validate(now: Date = Date()) throws {
        guard start <= now else { throw EventValidationError.futureStart }
        if let end, end < start || end > now {
            throw EventValidationError.invalidEnd
        }
        guard leftSeconds.isFinite, rightSeconds.isFinite, leftSeconds >= 0, rightSeconds >= 0,
              leftSeconds + rightSeconds <= elapsed(now: now) + 0.001
        else {
            throw EventValidationError.invalidDuration
        }
        if kind == .bottle, !(1 ... 2000).contains(volumeML) {
            throw EventValidationError.invalidVolume
        }
        if let sideStartedAt, sideStartedAt < start || sideStartedAt > (end ?? now) {
            throw EventValidationError.invalidSideStart
        }
    }
}

public struct DailyStatistics: Sendable, Equatable {
    public var feeds = 0
    public var wetDiapers = 0
    public var dirtyDiapers = 0
    public var sleepSeconds: TimeInterval = 0
    public var bottleML = 0

    public init(events: [CareEvent], day: Date, calendar: Calendar = .current, now: Date = Date()) {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return }
        var sleeps: [(Date, Date)] = []
        for event in events where event.start <= now {
            if event.kind == .sleep {
                let start = max(event.start, interval.start)
                let end = min(event.end ?? now, now, interval.end)
                if end > start {
                    sleeps.append((start, end))
                }
            }
            guard event.start >= interval.start, event.start < interval.end else { continue }
            tally(event)
        }
        sleepSeconds = Self.unionDuration(sleeps)
    }

    private mutating func tally(_ event: CareEvent) {
        switch event.kind {
        case .breast: feeds += 1
        case .bottle:
            feeds += 1
            bottleML += max(0, event.volumeML)
        case .diaper:
            if event.diaperType != .dirty {
                wetDiapers += 1
            }
            if event.diaperType != .wet {
                dirtyDiapers += 1
            }
        case .sleep: break
        }
    }

    private static func unionDuration(_ intervals: [(Date, Date)]) -> TimeInterval {
        var duration: TimeInterval = 0
        var merged: (Date, Date)?
        for span in intervals.sorted(by: { $0.0 < $1.0 }) {
            if let current = merged {
                if span.0 <= current.1 {
                    merged = (current.0, max(current.1, span.1))
                } else {
                    duration += current.1.timeIntervalSince(current.0); merged = span
                }
            } else {
                merged = span
            }
        }
        if let merged {
            duration += merged.1.timeIntervalSince(merged.0)
        }
        return duration
    }
}
