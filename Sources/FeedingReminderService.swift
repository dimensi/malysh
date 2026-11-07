import ActivityKit
import Foundation
import Observation
import UserNotifications

enum FeedingReminderAuthorization: Equatable {
    case notDetermined, denied, allowed, unavailable
}

enum FeedingReminderStatus: Equatable {
    case off, noChild, noFeeding, feedingActive, overdue, scheduled(Date), unavailable
}

enum FeedingReminderNotification {
    static let requestID = "feeding-reminder"
    static let categoryID = "feeding-reminder"
    static let openActionID = "feeding-reminder.open"
    static let snoozeActionID = "feeding-reminder.snooze"
    static let tokenKey = "token"
    static let babyIDKey = "babyID"
}

enum FeedingReminderDeliveryChannel: String, Codable {
    case liveActivity, notification
}

struct FeedingReminderLiveActivity {
    enum State { case pending, shown, finished }
    let id: String
    let token: String
    let state: State
}

struct FeedingReminderRequest: Equatable {
    let token: String
    let babyID: UUID
    let due: Date
    let babyName: String
    let elapsedLabel: String
    let body: String
}

struct FeedingReminderNotificationState {
    var pendingToken: String?
    var deliveredToken: String?
}

@MainActor
protocol FeedingReminderScheduling {
    var liveActivitiesEnabled: Bool { get }
    func liveActivities() -> [FeedingReminderLiveActivity]
    func scheduleLiveActivity(_ request: FeedingReminderRequest) throws
    func endLiveActivities(except activityID: String?) async
    func authorization() async -> FeedingReminderAuthorization
    func requestAuthorization() async throws
    func notificationState() async -> FeedingReminderNotificationState
    func schedule(_ request: FeedingReminderRequest) async throws
    func removePending()
    func removeDelivered()
}

extension FeedingReminderScheduling {
    var liveActivitiesEnabled: Bool {
        false
    }

    func liveActivities() -> [FeedingReminderLiveActivity] {
        []
    }

    func scheduleLiveActivity(_: FeedingReminderRequest) throws {}
    func endLiveActivities(except _: String?) async {}
}

@MainActor
struct SystemFeedingReminderScheduler: FeedingReminderScheduling {
    private enum ScheduleError: Error { case expired }
    private typealias ReminderActivity = Activity<FeedingReminderActivityAttributes>

    var liveActivitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func liveActivities() -> [FeedingReminderLiveActivity] {
        ReminderActivity.activities.compactMap { activity in
            let state: FeedingReminderLiveActivity.State
            switch activity.activityState {
            case .pending: state = .pending
            case .active, .stale: state = .shown
            case .ended, .dismissed: state = .finished
            @unknown default: return nil
            }
            return FeedingReminderLiveActivity(id: activity.id, token: activity.attributes.token, state: state)
        }
    }

    func scheduleLiveActivity(_ request: FeedingReminderRequest) throws {
        guard request.due > Date() else { throw ScheduleError.expired }
        let attributes = FeedingReminderActivityAttributes(token: request.token, babyID: request.babyID)
        let content = ActivityContent(
            state: FeedingReminderActivityAttributes.ContentState(babyName: request.babyName,
                                                                  elapsedLabel: request.elapsedLabel),
            staleDate: nil
        )
        _ = try ReminderActivity.request(
            attributes: attributes,
            content: content,
            pushType: nil,
            style: .standard,
            alertConfiguration: AlertConfiguration(
                title: "Кормление",
                body: LocalizedStringResource(stringLiteral: request.body),
                sound: .default
            ),
            start: request.due
        )
    }

    func endLiveActivities(except activityID: String?) async {
        for activity in ReminderActivity.activities where activity.id != activityID {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private var center: UNUserNotificationCenter {
        .current()
    }

    static func registerCategories() {
        let open = UNNotificationAction(
            identifier: FeedingReminderNotification.openActionID,
            title: "Открыть кормление",
            options: .foreground
        )
        let snooze = UNNotificationAction(identifier: FeedingReminderNotification.snoozeActionID,
                                          title: "Через 15 минут")
        let category = UNNotificationCategory(
            identifier: FeedingReminderNotification.categoryID,
            actions: [open, snooze],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func authorization() async -> FeedingReminderAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized, .provisional, .ephemeral: .allowed
        @unknown default: .unavailable
        }
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func notificationState() async -> FeedingReminderNotificationState {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let identifier = FeedingReminderNotification.requestID
        let key = FeedingReminderNotification.tokenKey
        return FeedingReminderNotificationState(
            pendingToken: pending.first { $0.identifier == identifier }?.content.userInfo[key] as? String,
            deliveredToken: delivered.first { $0.request.identifier == identifier }?.request.content
                .userInfo[key] as? String
        )
    }

    func schedule(_ request: FeedingReminderRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Кормление"
        content.body = request.body
        content.sound = .default
        content.categoryIdentifier = FeedingReminderNotification.categoryID
        content.userInfo = [
            FeedingReminderNotification.tokenKey: request.token,
            FeedingReminderNotification.babyIDKey: request.babyID.uuidString,
        ]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let roundedDue = Date(timeIntervalSince1970: ceil(request.due.timeIntervalSince1970))
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: roundedDue)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        guard let next = trigger.nextTriggerDate(), next > Date() else { throw ScheduleError.expired }
        try await center.add(UNNotificationRequest(identifier: FeedingReminderNotification.requestID,
                                                   content: content, trigger: trigger))
    }

    func removePending() {
        center.removePendingNotificationRequests(withIdentifiers: [FeedingReminderNotification.requestID])
    }

    func removeDelivered() {
        center.removeDeliveredNotifications(withIdentifiers: [FeedingReminderNotification.requestID])
    }
}

@MainActor
@Observable
final class FeedingReminderService {
    private struct Feeding: Codable, Equatable {
        let babyID: UUID
        let eventID: UUID
        let kind: EventKind
        let completedAt: Date
        let modifiedAt: Date
    }

    private struct Plan: Codable, Equatable {
        let feeding: Feeding
        let interval: Int
        let token: String
        let due: Date
        var channel: FeedingReminderDeliveryChannel?
        var liveActivityFailed: Bool?
        var installed = false
        var delivered = false
    }

    private enum Target {
        case inactive(FeedingReminderStatus)
        case feeding(Feeding)
    }

    private enum Key {
        static let enabled = "feedingReminder.enabled"
        static let interval = "feedingReminder.intervalMinutes"
        static let plan = "feedingReminder.plan"
    }

    static let presets = [120, 150, 180, 240]
    static let customRange = 15 ... 1440
    static let customStep = 5

    private(set) var enabled: Bool
    private(set) var intervalMinutes: Int
    private(set) var authorization: FeedingReminderAuthorization = .notDetermined
    private(set) var status: FeedingReminderStatus = .off
    private(set) var liveActivitiesEnabled = false
    private(set) var deliveryChannel: FeedingReminderDeliveryChannel?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let scheduler: any FeedingReminderScheduling
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var babyID: UUID?
    @ObservationIgnored private var babyName: String?
    @ObservationIgnored private var events: [CareEvent] = []
    @ObservationIgnored private var hasSnapshot = false
    @ObservationIgnored private var plan: Plan? {
        didSet { defaults.set(plan.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.plan) }
    }

    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var shouldRequestAuthorization = false

    init(defaults: UserDefaults = .standard,
         scheduler: any FeedingReminderScheduling = SystemFeedingReminderScheduler(),
         now: @escaping () -> Date = Date.init)
    {
        self.defaults = defaults
        self.scheduler = scheduler
        self.now = now
        enabled = defaults.bool(forKey: Key.enabled)
        let savedInterval = defaults.integer(forKey: Key.interval)
        intervalMinutes = Self.validInterval(savedInterval) ? savedInterval : 180
        plan = defaults.data(forKey: Key.plan).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.enabled else { return }
        self.enabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        shouldRequestAuthorization = enabled
        invalidateObsoletePlan()
        enqueueReconciliation()
    }

    func setIntervalMinutes(_ minutes: Int) {
        guard Self.validInterval(minutes), minutes != intervalMinutes else { return }
        intervalMinutes = minutes
        defaults.set(minutes, forKey: Key.interval)
        invalidateObsoletePlan()
        enqueueReconciliation()
    }

    func update(babyID: UUID?, events: [CareEvent], babyName: String? = nil) {
        self.babyID = babyID
        self.babyName = babyName
        self.events = events
        hasSnapshot = true
        invalidateObsoletePlan()
        enqueueReconciliation()
    }

    func flush() async {
        while let work {
            await work.value
        }
    }

    /// A delegate callback confirms delivery even when iOS has removed the notification from its list.
    func recordDelivery(token: String, babyID: UUID) -> Bool {
        guard var plan, plan.token == token, plan.feeding.babyID == babyID,
              plan.channel != .liveActivity, isCurrent(plan)
        else { return false }
        if !plan.delivered {
            plan.delivered = true
            self.plan = plan
            enqueueReconciliation()
        }
        return true
    }

    func canOpen(token: String, babyID: UUID) -> Bool {
        guard let plan, plan.token == token, plan.feeding.babyID == babyID else { return false }
        return isCurrent(plan)
            && (plan.delivered || (plan.channel != .liveActivity && plan.installed && plan.due <= now()))
    }

    func snooze(token: String) async {
        await flush()
        guard let plan,
              canOpen(token: token, babyID: plan.feeding.babyID)
        else { return }
        self.plan = Plan(feeding: plan.feeding, interval: plan.interval, token: UUID().uuidString,
                         due: now().addingTimeInterval(15 * 60))
        enqueueReconciliation()
        await flush()
    }

    static func intervalLabel(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        var parts: [String] = []
        if hours > 0 {
            parts.append("\(hours) \(plural(hours, one: "час", few: "часа", many: "часов"))")
        }
        if remainder > 0 || parts.isEmpty {
            parts.append("\(remainder) \(plural(remainder, one: "минута", few: "минуты", many: "минут"))")
        }
        return parts.joined(separator: " ")
    }

    private static func plural(_ value: Int, one: String, few: String, many: String) -> String {
        if (11 ... 14).contains(value % 100) {
            return many
        }
        switch value % 10 {
        case 1: return one
        case 2 ... 4: return few
        default: return many
        }
    }

    static func validInterval(_ minutes: Int) -> Bool {
        customRange.contains(minutes) && minutes.isMultiple(of: customStep)
    }

    private static func target(babyID: UUID?, events: [CareEvent], at date: Date) -> Target {
        guard let babyID else { return .inactive(.noChild) }
        let childEvents = events.filter { $0.babyID == babyID }
        if childEvents.contains(where: { $0.kind == .breast && $0.end == nil }) {
            return .inactive(.feedingActive)
        }
        let latest = childEvents.compactMap { event -> Feeding? in
            let completedAt: Date?
            switch event.kind {
            case .breast: completedAt = event.end
            case .bottle: completedAt = event.start
            default: return nil
            }
            guard let completedAt, completedAt <= date else { return nil }
            return Feeding(babyID: babyID, eventID: event.id, kind: event.kind,
                           completedAt: completedAt, modifiedAt: event.modifiedAt)
        }.max {
            if $0.completedAt == $1.completedAt {
                return $0.eventID.uuidString < $1.eventID.uuidString
            }
            return $0.completedAt < $1.completedAt
        }
        guard let latest else { return .inactive(.noFeeding) }
        return .feeding(latest)
    }

    private func isCurrent(_ plan: Plan) -> Bool {
        guard enabled, hasSnapshot, plan.interval == intervalMinutes,
              case let .feeding(feeding) = Self.target(babyID: babyID, events: events, at: now())
        else { return false }
        return plan.feeding == feeding
    }

    private func invalidateObsoletePlan() {
        guard let plan else { return }
        if !enabled || plan.interval != intervalMinutes || (hasSnapshot && !isCurrent(plan)) {
            self.plan = nil
        }
    }

    private func enqueueReconciliation() {
        revision += 1
        guard work == nil else { return }
        work = Task {
            var processedRevision: Int
            repeat {
                processedRevision = revision
                await reconcile(revision: processedRevision)
            } while revision != processedRevision
            work = nil
        }
    }

    private func reconcile(revision: Int) async {
        var permission = await scheduler.authorization()
        guard revision == self.revision else { return }
        if shouldRequestAuthorization {
            shouldRequestAuthorization = false
            if enabled, permission == .notDetermined {
                do {
                    try await scheduler.requestAuthorization()
                    permission = await scheduler.authorization()
                } catch {
                    permission = .unavailable
                }
            }
        }
        guard revision == self.revision else { return }
        authorization = permission
        liveActivitiesEnabled = scheduler.liveActivitiesEnabled
        guard enabled else {
            await clearReminder(status: .off)
            return
        }
        guard hasSnapshot else { return }

        switch Self.target(babyID: babyID, events: events, at: now()) {
        case let .inactive(status):
            await clearReminder(status: status)
        case let .feeding(feeding):
            await reconcile(feeding: feeding, revision: revision)
        }
    }

    private func clearReminder(status: FeedingReminderStatus) async {
        plan = nil
        scheduler.removePending()
        scheduler.removeDelivered()
        self.status = status
        deliveryChannel = nil
        await scheduler.endLiveActivities(except: nil)
    }

    private func reconcile(feeding: Feeding, revision: Int) async {
        let notification = await scheduler.notificationState()
        guard revision == self.revision else { return }
        let date = now()
        let due = feeding.completedAt.addingTimeInterval(TimeInterval(intervalMinutes * 60))
        var current = plan
        if current?.feeding != feeding || current?.interval != intervalMinutes {
            current = due > date ? Plan(feeding: feeding, interval: intervalMinutes, token: UUID().uuidString,
                                        due: due) : nil
        }
        guard var current else {
            await clearReminder(status: .overdue)
            return
        }

        let activities = scheduler.liveActivities().filter { $0.token == current.token }
        let shown = activities.first { $0.state == .shown }
        let pending = activities.first { $0.state == .pending }
        if let token = notification.deliveredToken, token != current.token || shown != nil {
            scheduler.removeDelivered()
        }
        let notificationDelivered = notification.deliveredToken == current.token
        let activityFinished = current.channel == .liveActivity && pending == nil
            && activities.contains { $0.state == .finished }
        if shown != nil || notificationDelivered || activityFinished {
            current.delivered = true
            current.channel = shown != nil ? .liveActivity : (notificationDelivered ? .notification : current.channel)
        }
        let pendingNotification = notification.pendingToken == current.token
        if current.delivered || current.due <= date {
            await keepDelivered(current, shown: shown, pending: pending, pendingNotification: pendingNotification)
            return
        }

        let activePending = liveActivitiesEnabled ? pending : nil
        await scheduler.endLiveActivities(except: activePending?.id)
        guard revision == self.revision else { return }
        if activePending != nil {
            scheduler.removePending()
            saveScheduled(current, channel: .liveActivity)
        } else if pendingNotification, authorization == .allowed,
                  !liveActivitiesEnabled || current.liveActivityFailed == true
        {
            saveScheduled(current, channel: .notification)
        } else {
            await install(current, revision: revision)
        }
    }

    private func keepDelivered(
        _ current: Plan,
        shown: FeedingReminderLiveActivity?,
        pending: FeedingReminderLiveActivity?,
        pendingNotification: Bool
    ) async {
        var current = current
        if current.delivered || !pendingNotification {
            scheduler.removePending()
        }
        if current.installed, !pendingNotification, pending == nil {
            current.delivered = true
        }
        plan = current
        status = .overdue
        deliveryChannel = current.channel
        // Keep an already shown activity, or a scheduled activity in its transition to active.
        await scheduler.endLiveActivities(except: shown?.id ?? (current.delivered ? nil : pending?.id))
    }

    private func saveScheduled(_ current: Plan, channel: FeedingReminderDeliveryChannel) {
        var installed = current
        installed.installed = true
        installed.channel = channel
        plan = installed
        status = .scheduled(current.due)
        deliveryChannel = channel
    }

    private func install(_ current: Plan, revision: Int) async {
        var current = current
        plan = current
        let minutes = Int(current.due.timeIntervalSince(current.feeding.completedAt) / 60)
        let elapsedLabel = Self.intervalLabel(minutes)
        let request = FeedingReminderRequest(
            token: current.token, babyID: current.feeding.babyID, due: current.due,
            babyName: babyName ?? "Малыш", elapsedLabel: elapsedLabel,
            body: "После последнего кормления прошло \(elapsedLabel)."
        )
        if liveActivitiesEnabled {
            scheduler.removePending()
            do {
                try scheduler.scheduleLiveActivity(request)
                saveScheduled(current, channel: .liveActivity)
                return
            } catch {
                // The OS may reject a local ActivityKit request while the app is in the background.
                current.liveActivityFailed = true
                plan = current
            }
        }
        guard authorization == .allowed else {
            scheduler.removePending()
            deliveryChannel = nil
            status = .unavailable
            return
        }
        do {
            try await scheduler.schedule(request)
            guard revision == self.revision, plan?.token == current.token else { return }
            saveScheduled(current, channel: .notification)
        } catch {
            // Same-identifier replacement only cancels the old request on success.
            scheduler.removePending()
            if revision == self.revision {
                deliveryChannel = nil
                status = .unavailable
            }
        }
    }
}
