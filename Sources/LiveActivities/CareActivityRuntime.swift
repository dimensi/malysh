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

    init(persistence: Persistence? = nil, coordinator: any CareActivityCoordinating = CareActivityCoordinator()) {
        self.coordinator = coordinator
        store = AppStore(persistence: persistence, activityCoordinator: coordinator)
        store.allowsActivityStart = { [weak self] in
            (self?.actionsInFlight ?? 0) > 0 || UIApplication.shared.applicationState == .active
        }
        NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange)
            .merge(with: NotificationCenter.default.publisher(for: .malyshSharingChanged))
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let store = self?.store else { return }
                if notification.name == .malyshSharingChanged {
                    store.syncStatus = "Доступ к дневнику изменён · ожидаем обновление iCloud"
                }
                guard store.ready else { return }
                store.perform { try store.reload() }
            }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSPersistentCloudKitContainer.eventChangedNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
                self?.store.handleCloudEvent(event)
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
            throw error
        }
        #if DEBUG
            WidgetCommandTiming.current?.mark("storeMutationCommitted")
        #endif
        await coordinator.flush()
        #if DEBUG
            WidgetCommandTiming.current?.mark("coordinatorFlushComplete")
        #endif
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
            throw error
        }
        #if DEBUG
            WidgetCommandTiming.current?.mark("storeMutationCommitted")
        #endif
        await coordinator.flush()
        #if DEBUG
            WidgetCommandTiming.current?.mark("coordinatorFlushComplete")
        #endif
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
            throw error
        }
        #if DEBUG
            WidgetCommandTiming.current?.mark("storeMutationCommitted")
        #endif
        await coordinator.flush()
        #if DEBUG
            WidgetCommandTiming.current?.mark("coordinatorFlushComplete")
        #endif
    }
}
