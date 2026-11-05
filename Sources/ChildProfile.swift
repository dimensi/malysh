import Foundation

public extension Baby {
    func ageLabel(now: Date = Date(), calendar: Calendar = .current) -> String? {
        guard birthDateConfirmed else { return nil }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let birthday = (birthDay ?? CivilDay(date: birthDate, timeZone: calendar.timeZone)).date(calendar: gregorian)
        guard let birthday else { return nil }
        let today = gregorian.startOfDay(for: now)
        let start = min(birthday, today)
        let days = gregorian.dateComponents([.day], from: start, to: today).day ?? 0
        if days < 7 {
            return "\(days) дн."
        }
        let parts = gregorian.dateComponents([.year, .month], from: start, to: today)
        let years = parts.year ?? 0
        let months = parts.month ?? 0
        if years == 0, months == 0 {
            return "\(days / 7) нед. \(days % 7) дн."
        }
        if years == 0 {
            return "\(months) мес."
        }
        return months == 0 ? "\(years) г." : "\(years) г. \(months) мес."
    }

    func displayedBirthDate(calendar: Calendar = .current) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return birthDay?.date(calendar: gregorian) ?? birthDate
    }
}

public enum MeasurementType: String, Codable, CaseIterable, Sendable {
    case weight, height, headCircumference
    public var label: String {
        switch self {
        case .weight: "Вес"
        case .height: "Рост"
        case .headCircumference: "Окружность головы"
        }
    }

    public var unit: String {
        self == .weight ? "г" : "см"
    }
}

public enum ChildProfileError: Error, LocalizedError {
    case emptyName, futureBirthday, invalidBirthTime, invalidMeasurement, futureMeasurement, missingConfirmedBirthday,
         conflict
    public var errorDescription: String? {
        switch self {
        case .conflict: "Запись изменилась или удалена на другом устройстве. Откройте её снова."
        case .emptyName: "Введите имя ребёнка."
        case .futureBirthday: "Дата и время рождения не могут быть в будущем."
        case .invalidBirthTime: "Это время недоступно для выбранной даты. Проверьте дату и время рождения."
        case .invalidMeasurement: "Введите положительное конечное значение."
        case .futureMeasurement: "Дата измерения не может быть в будущем."
        case .missingConfirmedBirthday: "Укажите дату рождения, чтобы сохранить измерения при рождении."
        }
    }
}

public struct ChildMeasurement: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var babyID: UUID
    public var type: MeasurementType
    public var measuredAt: Date
    /// Weight is stored in grams; height and head circumference in centimetres.
    public var value: Double
    public var createdAt: Date
    public var modifiedAt: Date
    public var note: String?

    public init(id: UUID = UUID(), babyID: UUID, type: MeasurementType, measuredAt: Date = Date(),
                value: Double, createdAt: Date = Date(), modifiedAt: Date = Date(), note: String? = nil)
    {
        self.id = id
        self.babyID = babyID
        self.type = type
        self.measuredAt = measuredAt
        self.value = value
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.note = note
    }

    public func validate(now: Date = Date()) throws {
        guard value.isFinite, value > 0 else { throw ChildProfileError.invalidMeasurement }
        guard measuredAt <= now else { throw ChildProfileError.futureMeasurement }
    }

    public static func editorText(value: Double) -> String {
        String(value)
    }

    public static func convertedWeightText(_ text: String, toKilograms: Bool) -> String? {
        guard let number = Double(text.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return editorText(value: number * (toKilograms ? 0.001 : 1000))
    }

    public static func newestFirst(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.measuredAt != rhs.measuredAt {
            return lhs.measuredAt > rhs.measuredAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
