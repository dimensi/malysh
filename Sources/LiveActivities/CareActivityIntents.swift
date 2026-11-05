import AppIntents
import Foundation

private enum CareIntentFailure: Error, LocalizedError {
    case invalidParameters, appUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidParameters: "Не удалось найти запись для этого действия. Откройте приложение «Малыш»."
        case .appUnavailable: "Для изменения записи откройте приложение «Малыш»."
        }
    }
}

struct FinishCareActivityIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Завершить таймер"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Запись") var eventID: String
    @Parameter(title: "Ребёнок") var babyID: String

    init() {}

    init(eventID: String, babyID: String) {
        self.eventID = eventID
        self.babyID = babyID
    }

    init(eventID: UUID, babyID: UUID) {
        self.eventID = eventID.uuidString
        self.babyID = babyID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await performAction()
        return .result()
    }

    @MainActor
    private func performAction() async throws {
        guard let eventID = UUID(uuidString: eventID), let babyID = UUID(uuidString: babyID)
        else { throw CareIntentFailure.invalidParameters }
        #if MALYSH_WIDGET_EXTENSION
            throw CareIntentFailure.appUnavailable
        #else
            #if DEBUG
                try await WidgetCommandTiming.measure(action: "finish") {
                    try await CareActivityRuntime.current.finish(eventID: eventID, babyID: babyID)
                }
            #else
                try await CareActivityRuntime.current.finish(eventID: eventID, babyID: babyID)
            #endif
        #endif
    }
}

struct SwitchCareSideIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Переключить грудь"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Запись") var eventID: String
    @Parameter(title: "Ребёнок") var babyID: String
    @Parameter(title: "Сторона") var side: String

    init() {}

    init(eventID: String, babyID: String, side: String) {
        self.eventID = eventID
        self.babyID = babyID
        self.side = side
    }

    init(eventID: UUID, babyID: UUID, side: String) {
        self.eventID = eventID.uuidString
        self.babyID = babyID.uuidString
        self.side = side
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await performAction()
        return .result()
    }

    @MainActor
    private func performAction() async throws {
        guard let eventID = UUID(uuidString: eventID), let babyID = UUID(uuidString: babyID),
              let side = BreastSide(rawValue: side)
        else { throw CareIntentFailure.invalidParameters }
        #if MALYSH_WIDGET_EXTENSION
            throw CareIntentFailure.appUnavailable
        #else
            #if DEBUG
                try await WidgetCommandTiming.measure(action: "switchSide") {
                    try await CareActivityRuntime.current.switchSide(eventID: eventID, babyID: babyID, to: side)
                }
            #else
                try await CareActivityRuntime.current.switchSide(eventID: eventID, babyID: babyID, to: side)
            #endif
        #endif
    }
}
