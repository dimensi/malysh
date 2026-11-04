#if DEBUG
    import CloudKit
    @preconcurrency import CoreData
    import Foundation

    extension Persistence {
        /// Developer-only schema preparation, invoked explicitly by a DEBUG launch argument.
        /// Only the model URL and container identifier cross into the background task.
        func prepareDevelopmentSchema() async throws {
            guard cloudEnabled else { throw Failure.cloudDisabled }
            guard let modelURL = Bundle.main.url(forResource: "Malysh", withExtension: "momd") else {
                throw Failure.missingModel
            }
            let identifier = Self.containerIdentifier
            try await Task.detached(priority: .userInitiated) {
                try DevelopmentSchemaPreparation.run(modelURL: modelURL, containerIdentifier: identifier)
            }.value
        }
    }

    private enum DevelopmentSchemaPreparation {
        static func run(modelURL: URL, containerIdentifier: String) throws {
            guard let model = NSManagedObjectModel(contentsOf: modelURL) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Malysh-Schema-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let schemaContainer = NSPersistentCloudKitContainer(
                name: "MalyshSchemaInitialization",
                managedObjectModel: model
            )
            let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("Schema.sqlite"))
            description.shouldAddStoreAsynchronously = false
            description.shouldMigrateStoreAutomatically = true
            description.shouldInferMappingModelAutomatically = true
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
            options.databaseScope = .private
            description.cloudKitContainerOptions = options
            schemaContainer.persistentStoreDescriptions = [description]

            func removeTemporaryStore() throws {
                for store in schemaContainer.persistentStoreCoordinator.persistentStores {
                    // Removing the coordinator reference does not purge any CloudKit zone.
                    try schemaContainer.persistentStoreCoordinator.remove(store)
                }
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
            }

            do {
                let result = SchemaStoreLoadResult()
                schemaContainer.loadPersistentStores { _, error in result.record(error) }
                if let error = result.error {
                    throw error
                }
                // Includes BabyRecord, EventRecord, their fields, and inverse relationships.
                // Never call this on the main container: shared database initialization is unsupported.
                try schemaContainer.initializeCloudKitSchema(options: [])
                try removeTemporaryStore()
                print("SCHEMA_INITIALIZATION_SUCCEEDED")
            } catch {
                // Preserve the original failure. If detachment fails, retain the isolated
                // directory instead of deleting files while a store may still be open.
                try? removeTemporaryStore()
                throw error
            }
        }
    }

    private final class SchemaStoreLoadResult: @unchecked Sendable {
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
#endif
