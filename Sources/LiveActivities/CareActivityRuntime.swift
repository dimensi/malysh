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

    func ensureReady() async {
        if store.ready {
            return
        }
        if let readiness {
            await readiness.value
            return
        }
        let task = Task { await store.load() }
        readiness = task
        await task.value
        readiness = nil
    }

    func finish(eventID: UUID, babyID: UUID) async throws {
        await ensureReady()
        actionsInFlight += 1
        defer { actionsInFlight -= 1 }
        do {
            try store.finish(eventID: eventID, babyID: babyID)
        } catch {
            await coordinator.flush()
            throw error
        }
        await coordinator.flush()
    }

    func switchSide(eventID: UUID, babyID: UUID, to side: BreastSide) async throws {
        await ensureReady()
        actionsInFlight += 1
        defer { actionsInFlight -= 1 }
        do {
            try store.switchSide(eventID: eventID, babyID: babyID, to: side)
        } catch {
            await coordinator.flush()
            throw error
        }
        await coordinator.flush()
    }
}
