import CloudKit
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
        try objects(entity: "BabyRecord", predicate: nil, sort: "birthDate").map { try decode($0) }
    }

    func events(babyID: UUID) throws -> [CareEvent] {
        try objects(
            entity: "EventRecord",
            predicate: NSPredicate(format: "babyID == %@", babyID as NSUUID),
            sort: "start"
        ).map { try decode($0) }
    }

    func saveBaby(_ baby: Baby) throws {
        try transaction {
            let object = try babyObject(id: baby.id) ?? insert(entity: "BabyRecord", store: privateStore)
            object.setValue(baby.id, forKey: "id")
            object.setValue(baby.name, forKey: "name")
            object.setValue(baby.birthDate, forKey: "birthDate")
            try object.setValue(JSONEncoder().encode(baby), forKey: "payload")
        }
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
