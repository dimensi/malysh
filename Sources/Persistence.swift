import CloudKit
import Combine
@preconcurrency import CoreData
import Foundation

/// All application access is on the main actor. CloudKit mirroring runs in Core Data.
@MainActor
final class Persistence {
    static let containerIdentifier = AppConfiguration.cloudKitContainer
    var container: NSPersistentCloudKitContainer {
        guard let activeContainer else { preconditionFailure("The persistence container is unavailable") }
        return activeContainer
    }

    private var activeContainer: NSPersistentCloudKitContainer?
    private(set) var cloudEnabled: Bool
    private(set) var cloudStartupError: Error?
    private let model: NSManagedObjectModel?
    private let directory: URL
    private let inMemory: Bool
    private let configureStoreDescription: ((NSPersistentStoreDescription) -> Void)?
    private let parentProfileCache: ParentProfileCache
    private let eventAuthorCache: EventAuthorCache
    private var accountChangeObserver: AnyCancellable?
    private(set) var isLoaded = false
    private(set) var generation = UUID()
    private var attemptedLoad = false

    enum Failure: LocalizedError {
        case missingModel, notLoaded, missingBaby, missingStore, cloudDisabled, diaryChanged
        case cloudRollbackFailed(switchError: Error, rollbackError: Error)

        var errorDescription: String? {
            switch self {
            case .missingModel: "Не найдена модель базы данных."
            case .notLoaded: "База данных ещё не открыта."
            case .missingBaby: "Профиль ребёнка не найден."
            case .missingStore: "Хранилище недоступно."
            case .cloudDisabled: "Включите iCloud в настройках."
            case .cloudRollbackFailed:
                "Не удалось открыть базу данных после переключения iCloud. Повторите попытку."
            case .diaryChanged: "Список дневников изменился. Проверьте его и повторите действие."
            }
        }
    }

    init(
        directory: URL? = nil,
        inMemory: Bool = false,
        cloudEnabled: Bool = false,
        configureStoreDescription: ((NSPersistentStoreDescription) -> Void)? = nil
    ) {
        self.cloudEnabled = cloudEnabled && !inMemory
        self.directory = directory ?? NSPersistentContainer.defaultDirectoryURL()
        self.inMemory = inMemory
        self.configureStoreDescription = configureStoreDescription
        let modelURL = Bundle.main.url(forResource: "Malysh", withExtension: "momd")
        model = modelURL.flatMap(NSManagedObjectModel.init(contentsOf:))
        parentProfileCache = ParentProfileCache(directory: self.directory, inMemory: inMemory)
        eventAuthorCache = EventAuthorCache(directory: self.directory, inMemory: inMemory)
        if let model {
            activeContainer = makeContainer(model: model, cloudEnabled: self.cloudEnabled, allowsMigration: true)
        }
        accountChangeObserver = NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in try? self?.clearEventAuthorCache() }
    }

    private func makeContainer(
        model: NSManagedObjectModel,
        cloudEnabled: Bool,
        allowsMigration: Bool
    ) -> NSPersistentCloudKitContainer {
        let container = NSPersistentCloudKitContainer(name: "Malysh", managedObjectModel: model)
        container.persistentStoreDescriptions = ["private", "shared"].map { name in
            let description = NSPersistentStoreDescription(url: directory
                .appendingPathComponent("Malysh-\(name).sqlite"))
            description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = allowsMigration
            description.shouldInferMappingModelAutomatically = allowsMigration
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if cloudEnabled {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerIdentifier)
                options.databaseScope = name == "private" ? .private : .shared
                description.cloudKitContainerOptions = options
            }
            configureStoreDescription?(description)
            return description
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.transactionAuthor = "Malysh"
        return container
    }

    func load() async throws {
        guard !isLoaded else { return }
        if !inMemory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if attemptedLoad {
            try detachStores()
        }
        attemptedLoad = true
        do {
            try openStores(cloudEnabled: cloudEnabled, allowsMigration: true, reusePreparedContainer: true)
            cloudStartupError = nil
        } catch {
            try detachStores()
            guard cloudEnabled else { throw error }
            cloudStartupError = error
            // Reopen the same files locally; retain CloudKit metadata for a later launch.
            do {
                try openStores(cloudEnabled: false, allowsMigration: true)
            } catch {
                try detachStores()
                throw error
            }
        }
    }

    func switchCloud(to enabled: Bool, reopen: Bool = false) throws {
        let enabled = enabled && !inMemory
        let previousMode = cloudEnabled
        if isLoaded {
            guard enabled != previousMode || (reopen && !inMemory) else {
                cloudStartupError = nil
                return
            }
            if container.viewContext.hasChanges {
                try container.viewContext.save()
            }
        }

        do {
            try detachStores()
            try openStores(cloudEnabled: enabled, allowsMigration: false)
            cloudStartupError = nil
        } catch {
            let switchError = error
            do {
                try detachStores()
                try openStores(cloudEnabled: previousMode, allowsMigration: false)
            } catch {
                try? detachStores()
                throw Failure.cloudRollbackFailed(switchError: switchError, rollbackError: error)
            }
            throw switchError
        }
    }

    private func openStores(
        cloudEnabled: Bool,
        allowsMigration: Bool,
        reusePreparedContainer: Bool = false
    ) throws {
        guard let model else { throw Failure.missingModel }
        if activeContainer == nil || !reusePreparedContainer {
            activeContainer = makeContainer(model: model, cloudEnabled: cloudEnabled, allowsMigration: allowsMigration)
        }
        // Synchronous loading prevents callers from reading a partially loaded store pair.
        let result = StoreLoadResult()
        container.loadPersistentStores { _, error in result.record(error) }
        if let error = result.error {
            throw error
        }
        guard container.persistentStoreCoordinator.persistentStores.count == 2 else { throw Failure.missingStore }
        self.cloudEnabled = cloudEnabled
        generation = UUID()
        isLoaded = true
    }

    private func detachStores() throws {
        isLoaded = false
        try autoreleasepool {
            guard let activeContainer else { return }
            activeContainer.viewContext.reset()
            // Detaching a store does not delete its SQLite file or CloudKit records.
            for store in activeContainer.persistentStoreCoordinator.persistentStores {
                try activeContainer.persistentStoreCoordinator.remove(store)
            }
            self.activeContainer = nil
        }
    }

    var privateStore: NSPersistentStore? {
        guard isLoaded else { return nil }
        return container.persistentStoreCoordinator.persistentStores
            .first { $0.url?.lastPathComponent == "Malysh-private.sqlite" }
    }

    var sharedStore: NSPersistentStore? {
        guard isLoaded else { return nil }
        return container.persistentStoreCoordinator.persistentStores
            .first { $0.url?.lastPathComponent == "Malysh-shared.sqlite" }
    }

    func babies() throws -> [Baby] {
        let records = try objects(entity: "BabyRecord", predicate: nil, sort: "birthDate")
        var values: [Baby] = []
        try transaction {
            for record in records {
                var value: Baby = try decode(record)
                value.birthMeasurementsCompleted = record.value(forKey: "birthMeasurementsCompleted") as? Bool == true
                let merged = try ParentProfile.merging(
                    value.parentProfiles,
                    parentProfileCache.profiles(babyID: value.id)
                )
                if merged != value.parentProfiles {
                    value.parentProfiles = merged
                    try record.setValue(JSONEncoder().encode(value), forKey: "payload")
                }
                values.append(value)
            }
        }
        for value in values {
            try parentProfileCache.remember(babyID: value.id, profiles: value.parentProfiles)
        }
        try? eventAuthorCache.retain(babyIDs: Set(values.map(\.id)))
        return values
    }

    /// Uses only local share metadata and a durable last-known-current-user cache.
    func currentEventAuthor(babyID: UUID) throws -> EventAuthor? {
        guard let record = try babyObject(id: babyID) else { throw Failure.missingBaby }
        let baby: Baby = try decode(record)
        if let family = try? familySnapshot(babyID: babyID),
           let current = family.members.first(where: \.isCurrentUser),
           current.id == "owner" || current.id.hasPrefix("user-")
        {
            let profile = baby.parentProfiles[current.id]
            let author = EventAuthor(id: current.id,
                                     nameSnapshot: profile?.name ?? (current.name.isEmpty ? nil : current.name),
                                     role: profile?.role)
            try? eventAuthorCache.remember(author, babyID: babyID)
            return author
        }
        if privateStore != nil, record.objectID.persistentStore == privateStore {
            let profile = baby.parentProfiles["owner"]
            return EventAuthor(id: "owner", nameSnapshot: profile?.name, role: profile?.role)
        }
        // A shared store never proves the owner is the person using this device.
        guard let cached = try? eventAuthorCache.author(babyID: babyID),
              cached.id.hasPrefix("user-") else { return nil }
        let profile = baby.parentProfiles[cached.id]
        return EventAuthor(
            id: cached.id,
            nameSnapshot: profile?.name ?? cached.nameSnapshot,
            role: profile?.role ?? cached.role
        )
    }

    func clearEventAuthorCache() throws {
        try eventAuthorCache.clear()
    }

    func events(babyID: UUID) throws -> [CareEvent] {
        try objects(
            entity: "EventRecord",
            predicate: NSPredicate(format: "babyID == %@", babyID as NSUUID),
            sort: "start"
        ).map { try decode($0) }
    }

    func measurements(babyID: UUID) throws -> [ChildMeasurement] {
        try objects(entity: "MeasurementRecord", predicate: NSPredicate(format: "babyID == %@", babyID as NSUUID))
            .map { try decode($0) as ChildMeasurement }.sorted(by: ChildMeasurement.newestFirst)
    }

    /// Each measurement is its own CloudKit record. Saving replaces its complete payload;
    /// concurrent edits of the same measurement use Core Data's object-trump policy.
    func saveMeasurement(_ measurement: ChildMeasurement) throws {
        try transaction {
            guard let baby = try babyObject(id: measurement.babyID) else { throw Failure.missingBaby }
            let existing = try objects(entity: "MeasurementRecord",
                                       predicate: NSPredicate(format: "id == %@", measurement.id as NSUUID)).first
            try writeMeasurement(measurement, baby: baby, existing: existing)
        }
    }

    private func writeMeasurement(_ measurement: ChildMeasurement, baby: NSManagedObject,
                                  existing: NSManagedObject? = nil) throws
    {
        try measurement.validate()
        let object = try existing ?? insert(entity: "MeasurementRecord", store: baby.objectID.persistentStore)
        guard object.objectID.isTemporaryID || object.objectID.persistentStore == baby.objectID.persistentStore
        else { throw Failure.missingStore }
        object.setValue(measurement.id, forKey: "id")
        object.setValue(measurement.babyID, forKey: "babyID")
        object.setValue(measurement.measuredAt, forKey: "measuredAt")
        object.setValue(measurement.modifiedAt, forKey: "modifiedAt")
        try object.setValue(JSONEncoder().encode(measurement), forKey: "payload")
        object.setValue(baby, forKey: "baby")
    }

    func deleteMeasurement(id: UUID) throws {
        try transaction {
            for object in try objects(
                entity: "MeasurementRecord",
                predicate: NSPredicate(format: "id == %@", id as NSUUID)
            ) {
                container.viewContext.delete(object)
            }
        }
    }

    func photos(babyID: UUID) throws -> [BabyPhoto] {
        try objects(entity: "PhotoRecord", predicate: NSPredicate(format: "babyID == %@", babyID as NSUUID))
            .map { try decode($0) as BabyPhoto }.sorted(by: BabyPhoto.newestFirst)
    }

    func photoData(id: UUID, thumbnail: Bool = false) throws -> Data? {
        try objects(entity: "PhotoRecord", predicate: NSPredicate(format: "id == %@", id as NSUUID))
            .first?.value(forKey: thumbnail ? "thumbnailData" : "imageData") as? Data
    }

    func savePhoto(_ photo: BabyPhoto, imageData: Data, thumbnailData: Data) throws {
        try transaction {
            let object = try photoObject(for: photo, create: true)
            try writePhotoMetadata(photo, to: object)
            object.setValue(imageData, forKey: "imageData")
            object.setValue(thumbnailData, forKey: "thumbnailData")
        }
    }

    func updatePhoto(_ photo: BabyPhoto) throws {
        try transaction {
            let object = try photoObject(for: photo, create: false)
            try writePhotoMetadata(photo, to: object)
        }
    }

    func deletePhoto(id: UUID) throws {
        try transaction {
            for object in try objects(entity: "PhotoRecord", predicate: NSPredicate(format: "id == %@", id as NSUUID)) {
                container.viewContext.delete(object)
            }
        }
    }

    private func photoObject(for photo: BabyPhoto, create: Bool) throws -> NSManagedObject {
        guard let baby = try babyObject(id: photo.babyID) else { throw Failure.missingBaby }
        let existing = try objects(entity: "PhotoRecord",
                                   predicate: NSPredicate(format: "id == %@", photo.id as NSUUID)).first
        if let existing {
            guard existing.value(forKey: "babyID") as? UUID == photo.babyID,
                  existing.objectID.persistentStore == baby.objectID.persistentStore else { throw Failure.missingStore }
            return existing
        }
        guard create else { throw CocoaError(.validationMissingMandatoryProperty) }
        let object = try insert(entity: "PhotoRecord", store: baby.objectID.persistentStore)
        object.setValue(baby, forKey: "baby")
        return object
    }

    private func writePhotoMetadata(_ photo: BabyPhoto, to object: NSManagedObject) throws {
        object.setValue(photo.id, forKey: "id")
        object.setValue(photo.babyID, forKey: "babyID")
        object.setValue(photo.capturedAt, forKey: "capturedAt")
        try object.setValue(JSONEncoder().encode(photo), forKey: "payload")
    }

    func saveBaby(_ baby: Baby) throws {
        var mergedProfiles = baby.parentProfiles
        try transaction {
            let object = try babyObject(id: baby.id) ?? insert(entity: "BabyRecord", store: privateStore)
            mergedProfiles = try writeBaby(baby, to: object)
        }
        try parentProfileCache.remember(babyID: baby.id, profiles: mergedProfiles)
    }

    /// An empty array completes onboarding by skipping it. A nil array only saves the profile.
    func saveChildProfile(_ baby: Baby, initialMeasurements: [ChildMeasurement]?) throws {
        try transaction {
            guard let object = try babyObject(id: baby.id) else { throw Failure.missingBaby }
            _ = try writeBaby(baby, to: object)
            if let initialMeasurements {
                guard object.value(forKey: "birthMeasurementsCompleted") as? Bool != true
                else { throw ChildProfileError.conflict }
                guard initialMeasurements.isEmpty || baby.birthDateConfirmed
                else { throw ChildProfileError.missingConfirmedBirthday }
                object.setValue(true, forKey: "birthMeasurementsCompleted")
                for measurement in initialMeasurements {
                    guard measurement.babyID == baby.id else { throw Failure.missingBaby }
                    try writeMeasurement(measurement, baby: object)
                }
            }
        }
    }

    private func writeBaby(_ baby: Baby, to object: NSManagedObject) throws -> [String: ParentProfile] {
        let stored: Baby? = object.value(forKey: "payload") == nil ? nil : try decode(object)
        let cached = try parentProfileCache.profiles(babyID: baby.id)
        var merged = baby
        // Completion is a separate CloudKit field. Ordinary payload writes never change it.
        merged.birthMeasurementsCompleted = false
        merged.parentProfiles = ParentProfile.merging(
            ParentProfile.merging(stored?.parentProfiles ?? [:], cached), baby.parentProfiles
        )
        object.setValue(baby.id, forKey: "id")
        object.setValue(baby.name, forKey: "name")
        object.setValue(baby.birthDate, forKey: "birthDate")
        if stored != merged {
            try object.setValue(JSONEncoder().encode(merged), forKey: "payload")
        }
        return merged.parentProfiles
    }

    func saveEvent(_ event: CareEvent, transactionAuthor: String? = nil) throws {
        guard isLoaded else { throw Failure.notLoaded }
        let context = container.viewContext
        let previousAuthor = context.transactionAuthor
        if let transactionAuthor {
            context.transactionAuthor = transactionAuthor
        }
        defer { context.transactionAuthor = previousAuthor }
        try transaction {
            guard let baby = try babyObject(id: event.babyID) else { throw Failure.missingBaby }
            let existing = try objects(
                entity: "EventRecord",
                predicate: NSPredicate(format: "id == %@", event.id as NSUUID)
            ).first
            let object = try existing ?? insert(entity: "EventRecord", store: baby.objectID.persistentStore)
            guard object.objectID.isTemporaryID || object.objectID.persistentStore == baby.objectID.persistentStore
            else { throw Failure.missingStore }
            object.setValue(1, forKey: "schemaVersion")
            object.setValue(event.id, forKey: "id")
            object.setValue(event.babyID, forKey: "babyID")
            object.setValue(event.start, forKey: "start")
            object.setValue(event.modifiedAt, forKey: "modifiedAt")
            try object.setValue(JSONEncoder().encode(event), forKey: "payload")
            object.setValue(baby, forKey: "baby")
        }
    }

    func deleteBabyAndEvents(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try transaction {
            guard let privateStore else { throw Failure.missingStore }
            let babies = try ids.flatMap { id in
                try objects(entity: "BabyRecord", predicate: NSPredicate(format: "id == %@", id as NSUUID))
            }
            // Validate the complete batch before making any changes.
            for baby in babies {
                let value: Baby = try decode(baby)
                guard baby.objectID.persistentStore == privateStore, value.name == "Малыш" else {
                    throw Failure.missingBaby
                }
            }
            for baby in babies {
                guard let id = baby.value(forKey: "id") as? UUID else { throw Failure.missingBaby }
                let events = try objects(
                    entity: "EventRecord",
                    predicate: NSPredicate(format: "babyID == %@", id as NSUUID)
                )
                for event in events where event.objectID.persistentStore == privateStore {
                    container.viewContext.delete(event)
                }
                container.viewContext.delete(baby)
            }
        }
        try parentProfileCache.forget(babyIDs: ids)
        try? eventAuthorCache.forget(babyIDs: ids)
    }

    func isInvitedDiary(id: UUID) -> Bool {
        guard let sharedStore, let record = try? babyObject(id: id) else { return false }
        return record.objectID.persistentStore == sharedStore
    }

    func removeDiary(id: UUID, invited: Bool) async throws {
        guard let baby = try babyObject(id: id) else { return }
        guard let store = baby.objectID.persistentStore,
              store == (invited ? sharedStore : privateStore) else { throw Failure.diaryChanged }
        let share = try container.fetchShares(matching: [baby.objectID])[baby.objectID]
        if let share {
            guard cloudEnabled else { throw Failure.cloudDisabled }
            try await purgeDiaryZone(share.recordID.zoneID, in: store)
        } else {
            guard !invited else { throw cloudEnabled ? Failure.diaryChanged : Failure.cloudDisabled }
            try transaction { try deleteDiaryRecords(babyID: id, in: store) }
        }
        forgetDiaryCaches(ids: [id])
    }

    func resetDiaries() async throws {
        guard let privateStore, let sharedStore else { throw Failure.missingStore }
        let records = try objects(entity: "BabyRecord", predicate: nil)
        let ids = Set(records.compactMap { $0.value(forKey: "id") as? UUID })
        if cloudEnabled {
            let cloud = CKContainer(identifier: Self.containerIdentifier)
            // This container is dedicated to diaries. Include zones without an imported root.
            let sharedZones = try await cloud.sharedCloudDatabase.allRecordZones()
            let privateZones = try await cloud.privateCloudDatabase.allRecordZones()
            for zone in sharedZones {
                try await purgeDiaryZone(zone.zoneID, in: sharedStore)
            }
            for zone in privateZones where zone.zoneID != CKRecordZone.default().zoneID {
                try await purgeDiaryZone(zone.zoneID, in: privateStore)
            }
        }
        // Never save deletes of individual records in the shared database.
        let remaining = try objects(entity: "BabyRecord", predicate: nil)
        guard !remaining.contains(where: { $0.objectID.persistentStore == sharedStore }) else {
            throw cloudEnabled ? Failure.diaryChanged : Failure.cloudDisabled
        }
        if !cloudEnabled, try !container.fetchShares(in: privateStore).isEmpty {
            throw Failure.cloudDisabled
        }
        let removedIDs = ids.union(remaining.compactMap { $0.value(forKey: "id") as? UUID })
        try transaction { try deleteDiaryRecords(babyID: nil, in: privateStore) }
        forgetDiaryCaches(ids: removedIDs)
    }

    private func deleteDiaryRecords(babyID: UUID?, in store: NSPersistentStore) throws {
        // The foreign key also finds legacy records without a Core Data relationship.
        for entity in ["EventRecord", "MeasurementRecord", "PhotoRecord", "BabyRecord"] {
            let key = entity == "BabyRecord" ? "id" : "babyID"
            let predicate = babyID.map { NSPredicate(format: "%K == %@", key, $0 as NSUUID) }
            for record in try objects(entity: entity, predicate: predicate)
                where record.objectID.persistentStore == store
            {
                container.viewContext.delete(record)
            }
        }
    }

    private func forgetDiaryCaches(ids: Set<UUID>) {
        try? parentProfileCache.forget(babyIDs: ids)
        try? eventAuthorCache.forget(babyIDs: ids)
    }

    func deleteEvent(id: UUID) throws {
        try transaction {
            for object in try objects(entity: "EventRecord", predicate: NSPredicate(format: "id == %@", id as NSUUID)) {
                container.viewContext.delete(object)
            }
        }
    }

    func babyObject(id: UUID) throws -> NSManagedObject? {
        try objects(entity: "BabyRecord", predicate: NSPredicate(format: "id == %@", id as NSUUID)).first
    }

    private func objects(entity: String, predicate: NSPredicate?, sort: String? = nil) throws -> [NSManagedObject] {
        guard isLoaded else { throw Failure.notLoaded }
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = predicate
        if let sort {
            request.sortDescriptors = [NSSortDescriptor(key: sort, ascending: true)]
        }
        return try container.viewContext.fetch(request)
    }

    private func insert(entity: String, store: NSPersistentStore?) throws -> NSManagedObject {
        guard let store else { throw Failure.missingStore }
        let object = NSEntityDescription.insertNewObject(forEntityName: entity, into: container.viewContext)
        container.viewContext.assign(object, to: store)
        return object
    }

    private func decode<T: Decodable>(_ object: NSManagedObject) throws -> T {
        guard let data = object.value(forKey: "payload") as? Data else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func transaction(_ body: () throws -> Void) throws {
        guard isLoaded else { throw Failure.notLoaded }
        do {
            try body()
            if container.viewContext.hasChanges {
                try container.viewContext.save()
            }
        } catch {
            container.viewContext.rollback()
            throw error
        }
    }
}

/// Core Data may invoke load callbacks on its own queue.
private final class StoreLoadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: Error?
    var error: Error? {
        lock.withLock { failure }
    }

    func record(_ error: Error?) {
        lock.withLock {
            if failure == nil {
                failure = error
            }
        }
    }
}
