import AppIntents
import Foundation

enum WidgetCareAction: String, CaseIterable, Codable, Sendable {
    case startBreastLeft, startBreastRight, startSleep, wetDiaper, dirtyDiaper
}

/// Runs in the application process, which owns the private Core Data store.
struct WidgetCareIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Записать уход"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Ребёнок") var babyID: String
    @Parameter(title: "Действие") var action: String
    @Parameter(title: "Команда") var commandID: String

    init() {}
    init(babyID: UUID, commandID: UUID, action: WidgetCareAction) {
        self.babyID = babyID.uuidString
        self.commandID = commandID.uuidString
        self.action = action.rawValue
    }

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        guard let baby = UUID(uuidString: babyID), let command = UUID(uuidString: commandID),
              let action = WidgetCareAction(rawValue: action)
        else {
            throw WidgetCommandFailure.invalidParameters
        }
        #if MALYSH_WIDGET_EXTENSION
            throw WidgetCommandFailure.applicationRequired
        #else
            #if DEBUG
                try await WidgetCommandTiming.measure(action: action.rawValue) {
                    try await CareActivityRuntime.current.recordWidgetAction(action, babyID: baby, commandID: command)
                }
            #else
                try await CareActivityRuntime.current.recordWidgetAction(action, babyID: baby, commandID: command)
            #endif
            return .result()
        #endif
    }
}

enum WidgetCommandFailure: LocalizedError {
    case invalidParameters, applicationRequired
    var errorDescription: String? {
        switch self {
        case .invalidParameters: "Данные виджета устарели. Обновите виджет в приложении «Малыш»."
        case .applicationRequired: "Не удалось выполнить действие в приложении «Малыш»."
        }
    }
}

/// The rendered control captures either a precise timer to finish, or a start command.
/// Replaying a stop never changes a newer timer and never turns it back on.
struct SleepCareControlIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Сон"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Ребёнок") var babyID: String
    @Parameter(title: "Команда") var commandID: String
    @Parameter(title: "Запись") var eventID: String?

    init() {}
    init(babyID: UUID, commandID: UUID, eventID: UUID?) {
        self.babyID = babyID.uuidString
        self.commandID = commandID.uuidString
        self.eventID = eventID?.uuidString
    }

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        guard let baby = UUID(uuidString: babyID), let command = UUID(uuidString: commandID) else {
            throw WidgetCommandFailure.invalidParameters
        }
        if let eventID {
            guard let event = UUID(uuidString: eventID) else { throw WidgetCommandFailure.invalidParameters }
            _ = try await FinishCareActivityIntent(eventID: event, babyID: baby).perform()
        } else {
            _ = try await WidgetCareIntent(babyID: baby, commandID: command, action: .startSleep).perform()
        }
        return .result()
    }
}
