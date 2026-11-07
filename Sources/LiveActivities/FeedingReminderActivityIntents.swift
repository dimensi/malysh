import AppIntents
import Foundation

struct StartFeedingFromReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Начать кормление"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Напоминание") var token: String
    @Parameter(title: "Ребёнок") var babyID: String
    @Parameter(title: "Сторона") var side: String

    init() {}

    init(token: String, babyID: UUID, side: BreastSide) {
        self.token = token
        self.babyID = babyID.uuidString
        self.side = side.rawValue
    }

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        guard let babyID = UUID(uuidString: babyID), let side = BreastSide(rawValue: side) else {
            throw WidgetCommandFailure.invalidParameters
        }
        #if MALYSH_WIDGET_EXTENSION
            throw WidgetCommandFailure.applicationRequired
        #else
            try await CareActivityRuntime.current.startFeedingFromReminder(token: token, babyID: babyID, side: side)
            return .result()
        #endif
    }
}

struct SnoozeFeedingReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Отложить на 15 минут"
    static let openAppWhenRun = false
    static let isDiscoverable = false

    @Parameter(title: "Напоминание") var token: String
    @Parameter(title: "Ребёнок") var babyID: String

    init() {}

    init(token: String, babyID: UUID) {
        self.token = token
        self.babyID = babyID.uuidString
    }

    @MainActor
    func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        guard let babyID = UUID(uuidString: babyID) else { throw WidgetCommandFailure.invalidParameters }
        #if MALYSH_WIDGET_EXTENSION
            throw WidgetCommandFailure.applicationRequired
        #else
            await CareActivityRuntime.current.snoozeFeedingReminderActivity(token: token, babyID: babyID)
            return .result()
        #endif
    }
}
