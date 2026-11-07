@preconcurrency import CloudKit
import Combine
@preconcurrency import CoreData
import UIKit

/// One app-process diary, shared by the scene and Live Activity actions.
@MainActor
final class CareActivityRuntime {
    static let shared = CareActivityRuntime()
    @TaskLocal static var actionRuntime: CareActivityRuntime?
    static var current: CareActivityRuntime {
        actionRuntime ?? shared
    }

    let store: AppStore
    private let coordinator: any CareActivityCoordinating
    private var readiness: Task<Void, Never>?
    private var deferredCloudAccountCheck = false
    private var cloudAccountReadiness: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var actionsInFlight = 0
    private var reminderStartsInFlight = 0

    init(persistence: Persistence? = nil,
         coordinator: any CareActivityCoordinating = CareActivityCoordinator(),
         feedingReminders: FeedingReminderService? = nil)
    {
        self.coordinator = coordinator
        store = AppStore(persistence: persistence, activityCoordinator: coordinator, feedingReminders: feedingReminders)
        store.allowsActivityStart = { [weak self] in
            guard let self, reminderStartsInFlight == 0 else { return false }
            return actionsInFlight > 0 || UIApplication.shared.applicationState == .active
        }
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .merge(with: NotificationCenter.default.publisher(for: .malyshSharingChanged))
            .map { @Sendable in (name: $0.name, sender: NotificationSender($0)) }
            .receive(on: RunLoop.main)
            .sink { [weak self] notice in
                guard let store = self?.store, store.ready, store.persistence.isLoaded else { return }
                if notice.name == .malyshSharingChanged {
                    guard store.cloudMirroringEnabled else { return }
                    store.syncStatus = "Доступ к дневнику изменён · ожидаем обновление iCloud"
                } else if notice.sender.object !== store.persistence.container.persistentStoreCoordinator {
                    return
                }
                store.perform { try store.reload() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .compactMap { @Sendable notification -> (
                sender: NotificationSender,
                event: NSPersistentCloudKitContainer.Event
            )? in
                let key = NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                guard let event = notification.userInfo?[key] as? NSPersistentCloudKitContainer.Event
                else { return nil }
                return (sender: NotificationSender(notification), event: event)
            }
            .receive(on: RunLoop.main)
            .sink { [weak self] notice in
                guard let store = self?.store, store.persistence.isLoaded,
                      notice.sender.object === store.persistence.container else { return }
                store.handleCloudEvent(notice.event)
            }
            .store(in: &subscriptions)
    }

    func ensureReady(checkCloudAccount: Bool = true) async {
        if !store.ready {
            if let readiness {
                await readiness.value
            } else {
                deferredCloudAccountCheck = true
                // Share only local readiness; foreground account work has its own task.
                let task = Task { await store.load(checkCloudAccount: false) }
                readiness = task
                await task.value
                readiness = nil
            }
        }
        // An intent may have opened the local diary before the scene exists.
        // Finish the postponed account check when foreground code first asks,
        // including callers that awaited the same background load task.
        guard checkCloudAccount, store.ready, store.persistence.cloudEnabled else { return }
        if let cloudAccountReadiness {
            await cloudAccountReadiness.value
        } else if deferredCloudAccountCheck {
            deferredCloudAccountCheck = false
            let task = Task { await store.checkAccount() }
            cloudAccountReadiness = task
            await task.value
            cloudAccountReadiness = nil
        }
    }

    func snoozeFeedingReminder(token: String, babyID: UUID) async {
        guard await acceptFeedingReminderDelivery(token: token, babyID: babyID) else { return }
        await store.feedingReminders.snooze(token: token)
    }

    func openFeedingReminder(token: String, babyID: UUID) async {
        guard await acceptFeedingReminderDelivery(token: token, babyID: babyID) else { return }
        WidgetRouteInbox.shared.receive(WidgetRoute(.breast, babyID: babyID))
    }

    func startFeedingFromReminder(token: String, babyID: UUID, side: BreastSide) async throws {
        guard let commandID = UUID(uuidString: token),
              await acceptFeedingReminderDelivery(token: token, babyID: babyID, channel: .liveActivity)
        else { return }
        actionsInFlight += 1
        defer { actionsInFlight -= 1 }
        // Release the reminder's ActivityKit slot before requesting the running timer.
        reminderStartsInFlight += 1
        let action: WidgetCareAction = side == .left ? .startBreastLeft : .startBreastRight
        let mutation = Result { try store.recordWidgetAction(
            action,
            babyID: babyID,
            commandID: commandID,
            reminderToken: token
        ) }
        await store.feedingReminders.flush()
        reminderStartsInFlight -= 1
        let reconciliation = Result { try store.reload() }
        await coordinator.flush()
        await store.feedingReminders.flush()
        try mutation.get()
        try reconciliation.get()
    }

    func snoozeFeedingReminderActivity(token: String, babyID: UUID) async {
        guard await acceptFeedingReminderDelivery(token: token, babyID: babyID, channel: .liveActivity)
        else { return }
        await store.feedingReminders.snooze(token: token)
    }

    func acceptFeedingReminderDelivery(
        token: String, babyID: UUID, channel: FeedingReminderDeliveryChannel = .notification
    ) async -> Bool {
        await ensureReady(checkCloudAccount: false)
        guard store.ready, !store.diaryRemovalInProgress, (try? store.reload()) != nil else { return false }
        let recorded = channel == .liveActivity || store.feedingReminders.recordDelivery(token: token, babyID: babyID)
        await store.feedingReminders.flush()
        return recorded && !store.diaryRemovalInProgress && store.selectedID == babyID &&
            store.feedingReminders.deliveryChannel == channel && store.feedingReminders.canOpen(
                token: token,
                babyID: babyID
            )
    }

    func recordWidgetAction(_ action: WidgetCareAction, babyID: UUID, commandID: UUID) async throws {
        #if DEBUG
            WidgetCommandTiming.current?.mark("beforeLocalReady")
        #endif
        await ensureReady(checkCloudAccount: false)
        #if DEBUG
            WidgetCommandTiming.current?.mark("localReady")
        #endif
        actionsInFlight += 1
        defer { actionsInFlight -= 1 }
        do {
            try store.recordWidgetAction(action, babyID: babyID, commandID: commandID)
        } catch {
            #if DEBUG
                WidgetCommandTiming.current?.mark("mutationFailed")
            #endif
            await coordinator.flush()
            await store.feedingReminders.flush()
            throw error
        }
        #if DEBUG
            WidgetCommandTiming.current?.mark("storeMutationCommitted")
        #endif
        await coordinator.flush()
        #if DEBUG
            WidgetCommandTiming.current?.mark("coordinatorFlushComplete")
        #endif
        await store.feedingReminders.flush()
    }

    func finish(eventID: UUID, babyID: UUID) async throws {
        #if DEBUG
            WidgetCommandTiming.current?.mark("beforeLocalReady")
        #endif
        await ensureReady(checkCloudAccount: false)
        #if DEBUG
            WidgetCommandTiming.current?.mark("localReady")
        #endif
        actionsInFlight += 1
        defer { actionsInFlight -= 1 }
        do {
            try store.finish(eventID: eventID, babyID: babyID)
        } catch {
            #if DEBUG
                WidgetCommandTiming.current?.mark("mutationFailed")
            #endif
            await coordinator.flush()
            await store.feedingReminders.flush()
            throw error
        }
        #if DEBUG
            WidgetCommandTiming.current?.mark("storeMutationCommitted")
        #endif
        await coordinator.flush()
        #if DEBUG
            WidgetCommandTiming.current?.mark("coordinatorFlushComplete")
        #endif
        await store.feedingReminders.flush()
    }

    func switchSide(eventID: UUID, babyID: UUID, to side: BreastSide) async throws {
        #if DEBUG
            WidgetCommandTiming.current?.mark("beforeLocalReady")
        #endif
        await ensureReady(checkCloudAccount: false)
        #if DEBUG
            WidgetCommandTiming.current?.mark("localReady")
        #endif
        actionsInFlight += 1
        defer { actionsInFlight -= 1 }
        do {
            try store.switchSide(eventID: eventID, babyID: babyID, to: side)
        } catch {
            #if DEBUG
                WidgetCommandTiming.current?.mark("mutationFailed")
            #endif
            await coordinator.flush()
            await store.feedingReminders.flush()
            throw error
        }
        #if DEBUG
            WidgetCommandTiming.current?.mark("storeMutationCommitted")
        #endif
        await coordinator.flush()
        #if DEBUG
            WidgetCommandTiming.current?.mark("coordinatorFlushComplete")
        #endif
        await store.feedingReminders.flush()
    }
}

/// Queued notifications must not keep the previous Core Data stack alive.
private struct NotificationSender {
    weak var object: AnyObject?

    init(_ notification: Notification) {
        object = notification.object as AnyObject?
    }
}
