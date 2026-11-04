import CloudKit
import CoreData
import Observation
import SwiftUI

@MainActor @Observable
final class AppStore {
    let persistence: Persistence
    var babies: [Baby] = []
    var visibleBabies: [Baby] = []
    var family: FamilySnapshot?
    var selectedID: UUID?
    var events: [CareEvent] = []
    var ready = false
    var loadFailed = false
    var errorMessage: String?
    var syncStatus = "Записи сохраняются на этом iPhone"
    var cloudBusy = false
    private var cloudSetup = CloudSetupState()
    private var cloudAccountAvailable = false
    var pendingShare: CKShare?
    private var pendingAcceptedShareID: CKRecord.ID?
    #if DEBUG
        private var testingFamily: FamilySnapshot?
    #endif
    var baby: Baby? {
        babies.first { $0.id == selectedID }
    }

    var isSharedDiary: Bool {
        guard let selectedID else { return false }
        if family != nil {
            return true
        }
        guard let sharedStore = persistence.sharedStore,
              let object = try? persistence.babyObject(id: selectedID) else { return false }
        return object.objectID.persistentStore == sharedStore
    }

    var active: [CareEvent] {
        events.filter { $0.end == nil && ($0.kind == .breast || $0.kind == .sleep) }
    }

    private var expectedCloudStores: Set<String> {
        Set(persistence.container.persistentStoreCoordinator.persistentStores.map(\.identifier))
    }

    var cloudSharingReady: Bool {
        persistence.cloudEnabled && cloudAccountAvailable && cloudSetup.isReady(expected: expectedCloudStores)
    }

    private func updateCloudStatus() {
        if let error = persistence.cloudStartupError {
            syncStatus = CloudFailure.message(for: error)
        } else if !persistence.cloudEnabled {
            syncStatus = "Записи сохраняются на этом iPhone"
        } else if let failure = cloudSetup.failure(expected: expectedCloudStores) {
            syncStatus = failure
        } else if !cloudAccountAvailable {
            syncStatus = "Проверяем доступ к iCloud · записи доступны локально"
        } else if !cloudSharingReady {
            syncStatus = "Подготавливаем iCloud · записи доступны локально"
        } else {
            syncStatus = "iCloud готов · доставка изменений может занять время"
        }
    }

    func recordCloudSetup(identifier: String, error: Error?) {
        cloudSetup.record(identifier: identifier, error: error)
        updateCloudStatus()
    }

    func handleCloudEvent(_ event: NSPersistentCloudKitContainer.Event) {
        guard persistence.cloudEnabled else { return }
        if event.type == .setup {
            if let error = event.error {
                recordCloudSetup(identifier: event.storeIdentifier, error: error)
            } else if event.endDate != nil, event.succeeded {
                recordCloudSetup(identifier: event.storeIdentifier, error: nil)
            } else if event.endDate == nil {
                cloudSetup.begin(identifier: event.storeIdentifier)
                updateCloudStatus()
            } else {
                recordCloudSetup(
                    identifier: event.storeIdentifier,
                    error: NSError(domain: CKErrorDomain, code: CKError.internalError.rawValue)
                )
            }
        } else if let error = event.error {
            syncStatus = CloudFailure.message(for: error)
        } else if event.endDate != nil, event.succeeded {
            if cloudSharingReady {
                syncStatus = "Последняя синхронизация: \((event.endDate ?? Date()).formatted(date: .omitted, time: .shortened))"
            }
            if ready {
                perform { try reload() }
            }
        }
    }

    init(persistence injectedPersistence: Persistence? = nil) {
        if let injectedPersistence {
            persistence = injectedPersistence
            return
        }
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        var directory: URL?
        if testing {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UITesting", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-data"), let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        persistence = Persistence(
            directory: directory,
            cloudEnabled: !testing && UserDefaults.standard.bool(forKey: "cloudEnabled")
        )
    }

    func load() async {
        loadFailed = false
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--initialize-cloudkit-schema") {
                // Maintenance mode must never open or mirror the user's diary stores.
                do {
                    try await persistence.prepareDevelopmentSchema()
                    exit(0)
                } catch {
                    let detail = error as NSError
                    print("SCHEMA_INITIALIZATION_FAILED: \(detail.domain) \(detail.code)")
                    exit(1)
                }
            }
        #endif
        do {
            try await persistence.load()
            babies = try persistence.babies()
            if babies.isEmpty {
                let baby = Baby(name: "Малыш")
                try persistence.saveBaby(baby)
                babies = [baby]
            }
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                   ProcessInfo.processInfo.arguments.contains("--family-fixture")
                {
                    try prepareFamilyFixture()
                }
            #endif
            let saved = UserDefaults.standard.string(forKey: "selectedBaby").flatMap(UUID.init(uuidString:))
            selectedID = babies.first(where: { $0.id == saved })?.id
            try reload()
            ready = true
            if let cloudError = persistence.cloudStartupError {
                syncStatus = CloudFailure.message(for: cloudError)
            } else if persistence.cloudEnabled {
                await checkAccount()
            }
        } catch {
            loadFailed = true
            errorMessage =
                "Не удалось открыть дневник: \(error.localizedDescription). Данные не удалены. Попробуйте снова."
        }
    }

    func reload() throws {
        babies = try persistence.babies()
        try updateVisibleBabiesAndSelection()
        try selectAcceptedSharedBabyIfAvailable()
        events = try selectedID.map { try persistence.events(babyID: $0).sorted { $0.start > $1.start } } ?? []
        family = selectedID.flatMap { try? persistence.familySnapshot(babyID: $0) }
        #if DEBUG
            if let testingFamily {
                family = testingFamily
            }
        #endif
    }

    #if DEBUG
        /// Uses only the isolated UI-testing store; no iCloud connection or real identities.
        private func prepareFamilyFixture() throws {
            guard let sharedStore = persistence.sharedStore else { throw Persistence.Failure.missingStore }
            let existing = try persistence.babies().contains { baby in
                try persistence.babyObject(id: baby.id)?.objectID.persistentStore == sharedStore
            }
            if !existing {
                let baby = Baby(name: "Семейный малыш")
                let context = persistence.container.viewContext
                let object = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
                context.assign(object, to: sharedStore)
                object.setValue(baby.id, forKey: "id")
                object.setValue(baby.name, forKey: "name")
                object.setValue(baby.birthDate, forKey: "birthDate")
                try object.setValue(JSONEncoder().encode(baby), forKey: "payload")
                try context.save()
            }
            testingFamily = FamilySnapshot(isOwner: false, members: [
                FamilyMember(id: "owner", name: "Другой родитель", role: "Владелец дневника",
                             status: "В семье", isCurrentUser: false),
                FamilyMember(id: "participant-1", name: "Вы", role: "Родитель", status: "В семье", isCurrentUser: true),
            ])
        }
    #endif

    private func updateVisibleBabiesAndSelection() throws {
        let sharedStore = persistence.sharedStore
        let sharedIDs = try Set(babies.compactMap { baby -> UUID? in
            guard let sharedStore, let object = try persistence.babyObject(id: baby.id),
                  object.objectID.persistentStore == sharedStore else { return nil }
            return baby.id
        })
        visibleBabies = try babies.filter { baby in
            guard !sharedIDs.isEmpty, !sharedIDs.contains(baby.id), baby.name == "Малыш" else { return true }
            // An owned share is meaningful even before its first care event.
            if (try? persistence.familySnapshot(babyID: baby.id)) != nil {
                return true
            }
            return try !persistence.events(babyID: baby.id).isEmpty
        }
        if !visibleBabies.contains(where: { $0.id == selectedID }) {
            selectedID = visibleBabies.first(where: { sharedIDs.contains($0.id) })?.id ?? visibleBabies.first?.id
        }
        if let selectedID {
            UserDefaults.standard.set(selectedID.uuidString, forKey: "selectedBaby")
        }
    }

    private func selectAcceptedSharedBabyIfAvailable() throws {
        guard let acceptedShareID = pendingAcceptedShareID, let sharedStore = persistence.sharedStore else { return }
        var candidates: [NSManagedObjectID: UUID] = [:]
        for baby in babies {
            if let object = try persistence.babyObject(id: baby.id), object.objectID.persistentStore == sharedStore {
                candidates[object.objectID] = baby.id
            }
        }
        guard !candidates.isEmpty else { return }
        let shares = try persistence.container.fetchShares(matching: Array(candidates.keys))
        guard let objectID = shares.first(where: { $0.value.recordID == acceptedShareID })?.key,
              let babyID = candidates[objectID] else { return }
        selectedID = babyID
        UserDefaults.standard.set(babyID.uuidString, forKey: "selectedBaby")
        pendingAcceptedShareID = nil
    }

    func select(_ id: UUID) {
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: "selectedBaby")
        perform { try reload() }
    }

    func save(_ event: CareEvent) throws {
        var normalized = event
        if normalized.kind == .bottle || normalized.kind == .diaper {
            normalized.end = normalized.start
        }
        try normalized.validate()
        try persistence.saveEvent(normalized)
        try reload()
    }

    func delete(_ event: CareEvent) throws {
        try persistence.deleteEvent(id: event.id)
        try reload()
    }

    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    func start(_ kind: EventKind, side: BreastSide = .left) {
        guard let baby else { return }
        guard !active.contains(where: { $0.kind == kind }) else {
            errorMessage = "Этот таймер уже запущен. Завершите его на карточке выше."
            return
        }
        perform { try save(CareEvent(babyID: baby.id, kind: kind, side: side)) }
    }

    func diaper(_ type: DiaperType) {
        guard let baby else { return }
        let now = Date()
        perform { try save(CareEvent(babyID: baby.id, kind: .diaper, start: now, end: now, diaperType: type)) }
    }

    func finish(_ event: CareEvent) {
        var updated = event
        updated.finish()
        perform { try save(updated) }
    }

    func switchSide(_ event: CareEvent) {
        var updated = event
        updated.switchSide()
        perform { try save(updated) }
    }

    func checkAccount() async {
        do {
            let status = try await CKContainer(identifier: Persistence.containerIdentifier).accountStatus()
            cloudAccountAvailable = status == .available
            if cloudAccountAvailable {
                updateCloudStatus()
            } else {
                syncStatus = "Войдите в iCloud в настройках iPhone. Записи доступны локально."
            }
        } catch {
            cloudAccountAvailable = false
            syncStatus = CloudFailure.message(for: error)
        }
    }

    func invite() async {
        guard !cloudBusy else { return }
        guard cloudSharingReady else {
            errorMessage = syncStatus
            return
        }
        guard let baby else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        do {
            pendingShare = try await persistence.share(babyID: baby.id)
        } catch {
            errorMessage = CloudFailure.message(for: error)
        }
    }

    func accept(_ metadata: CKShare.Metadata) async {
        do {
            if !ready {
                await load()
            }
            try await persistence.accept(metadata: metadata)
        } catch {
            pendingAcceptedShareID = nil
            errorMessage = CloudFailure.message(for: error)
            return
        }
        pendingAcceptedShareID = metadata.share.recordID
        // Acceptance can complete before Core Data imports the shared objects.
        // Keep the target through delayed imports and transient metadata lookup errors.
        perform { try reload() }
    }
}
