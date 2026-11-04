import CloudKit
import Combine
@preconcurrency import CoreData
import Foundation

/// All application access is on the main actor. CloudKit mirroring runs in Core Data.
@MainActor
final class Persistence {
    static let containerIdentifier = "iCloud.dev.dimensi.malysh"
    let container: NSPersistentCloudKitContainer
    private(set) var cloudEnabled: Bool
    private(set) var cloudStartupError: Error?
    private let modelFound: Bool
    private let parentProfileCache: ParentProfileCache
    private let eventAuthorCache: EventAuthorCache
    private var accountChangeObserver: AnyCancellable?
    private var loaded = false

    enum Failure: LocalizedError {
        case missingModel, notLoaded, missingBaby, missingStore, cloudDisabled
        var errorDescription: String? {
            switch self {
            case .missingModel: "Не найдена модель базы данных."
            case .notLoaded: "База данных ещё не открыта."
            case .missingBaby: "Профиль ребёнка не найден."
            case .missingStore: "Хранилище недоступно."
            case .cloudDisabled: "Включите iCloud в настройках и перезапустите приложение."
            }
        }
    }

    init(directory: URL? = nil, inMemory: Bool = false, cloudEnabled: Bool = false) {
        self.cloudEnabled = cloudEnabled && !inMemory
        let modelURL = Bundle.main.url(forResource: "Malysh", withExtension: "momd")
        let model = modelURL.flatMap(NSManagedObjectModel.init(contentsOf:))
        modelFound = model != nil
        container = NSPersistentCloudKitContainer(name: "Malysh", managedObjectModel: model ?? NSManagedObjectModel())
        let root = directory ?? NSPersistentContainer.defaultDirectoryURL()
        parentProfileCache = ParentProfileCache(directory: root, inMemory: inMemory)
        eventAuthorCache = EventAuthorCache(directory: root, inMemory: inMemory)
        container.persistentStoreDescriptions = ["private", "shared"].map { name in
            let description = NSPersistentStoreDescription(url: root.appendingPathComponent("Malysh-\(name).sqlite"))
            description.type = inMemory ? NSInMemoryStoreType : NSSQLiteStoreType
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            if self.cloudEnabled {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerIdentifier)
                options.databaseScope = name == "private" ? .private : .shared
                description.cloudKitContainerOptions = options
            }
            return description
        }
        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.transactionAuthor = "Malysh"
        accountChangeObserver = NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in try? self?.clearEventAuthorCache() }
    }

    func load() async throws {
        if loaded {
            return
        }
        guard modelFound else { throw Failure.missingModel }
        for description in container.persistentStoreDescriptions where description.type == NSSQLiteStoreType {
            if let directory = description.url?.deletingLastPathComponent() {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        do {
            try loadStores()
        } catch {
            try detachStores()
            guard cloudEnabled else { throw error }
            cloudStartupError = error
            cloudEnabled = false
            // Reopen the same files locally; retain CloudKit metadata for a later launch.
            for description in container.persistentStoreDescriptions {
                description.cloudKitContainerOptions = nil
            }
            do {
                try loadStores()
            } catch {
                try detachStores()
                throw error
            }
        }
        loaded = true
    }

    private func loadStores() throws {
        // Synchronous loading prevents callers from reading a partially loaded store pair.
        let result = StoreLoadResult()
        container.loadPersistentStores { _, error in result.record(error) }
        if let error = result.error {
            throw error
        }
    }

    private func detachStores() throws {
        container.viewContext.reset()
        // Detaching a store does not delete its SQLite file or CloudKit records.
        for store in container.persistentStoreCoordinator.persistentStores {
            try container.persistentStoreCoordinator.remove(store)
        }
    }

    var privateStore: NSPersistentStore? {
        container.persistentStoreCoordinator.persistentStores
            .first { $0.url?.lastPathComponent == "Malysh-private.sqlite" }
    }

    var sharedStore: NSPersistentStore? {
        container.persistentStoreCoordinator.persistentStores
            .first { $0.url?.lastPathComponent == "Malysh-shared.sqlite" }
    }

    func babies() throws -> [Baby] {
        let records = try objects(entity: "BabyRecord", predicate: nil, sort: "birthDate")
        var values: [Baby] = []
        try transaction {
            for record in records {
                var value: Baby = try decode(record)
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
        try measurement.validate()
        try transaction {
            guard let baby = try babyObject(id: measurement.babyID) else { throw Failure.missingBaby }
            let existing = try objects(entity: "MeasurementRecord",
                                       predicate: NSPredicate(format: "id == %@", measurement.id as NSUUID)).first
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

    func saveBaby(_ baby: Baby) throws {
        var mergedBaby = baby
        try transaction {
            let object = try babyObject(id: baby.id) ?? insert(entity: "BabyRecord", store: privateStore)
            let stored: Baby? = object.value(forKey: "payload") == nil ? nil : try decode(object)
            let cached = try parentProfileCache.profiles(babyID: baby.id)
            mergedBaby.parentProfiles = ParentProfile.merging(
                ParentProfile.merging(stored?.parentProfiles ?? [:], cached), baby.parentProfiles
            )
            object.setValue(baby.id, forKey: "id")
            object.setValue(baby.name, forKey: "name")
            object.setValue(baby.birthDate, forKey: "birthDate")
            if stored != mergedBaby {
                try object.setValue(JSONEncoder().encode(mergedBaby), forKey: "payload")
            }
        }
        try parentProfileCache.remember(babyID: baby.id, profiles: mergedBaby.parentProfiles)
    }

    func saveEvent(_ event: CareEvent) throws {
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
        guard loaded else { throw Failure.notLoaded }
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
        guard loaded else { throw Failure.notLoaded }
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
