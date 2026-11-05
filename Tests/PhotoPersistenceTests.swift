import CoreData
@testable import Malysh
import XCTest

@MainActor
final class PhotoPersistenceTests: XCTestCase {
    func testResourcesReopenOfflineMetadataUpdateDuplicateAndIndependentDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        try await persistence.load()
        let baby = Baby(name: "Фото")
        try persistence.saveBaby(baby)
        var photo = BabyPhoto(
            babyID: baby.id,
            capturedAt: Date(),
            addedBy: "owner",
            pixelWidth: 1000,
            pixelHeight: 1000
        )
        let second = BabyPhoto(
            babyID: baby.id,
            capturedAt: Date(),
            addedBy: "user-second",
            pixelWidth: 20,
            pixelHeight: 30
        )
        let image = Data(repeating: 42, count: 2_000_000)
        let thumbnail = Data([1, 2, 3])
        try persistence.savePhoto(photo, imageData: image, thumbnailData: thumbnail)
        try persistence.savePhoto(photo, imageData: image, thumbnailData: thumbnail)
        try persistence.savePhoto(second, imageData: Data([5]), thumbnailData: Data([6]))
        photo.caption = "Подпись"
        photo.isFavorite = true
        try persistence.updatePhoto(photo)
        XCTAssertEqual(try persistence.photos(babyID: baby.id).count, 2)
        XCTAssertEqual(try persistence.photoData(id: photo.id), image)
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
        let reopened = Persistence(directory: directory, cloudEnabled: false)
        try await reopened.load()
        XCTAssertTrue(try reopened.photos(babyID: baby.id).contains(photo))
        XCTAssertEqual(try reopened.photoData(id: photo.id), image)
        XCTAssertEqual(try reopened.photoData(id: photo.id, thumbnail: true), thumbnail)
        try reopened.deletePhoto(id: second.id)
        XCTAssertEqual(try reopened.photos(babyID: baby.id), [photo])
        XCTAssertEqual(try reopened.babies(), [baby])
        XCTAssertEqual(try reopened.photoData(id: photo.id), image)
    }

    func testSharedStoreRoutingAndCascadeWithoutChangingOtherChildren() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        let baby = Baby(name: "Общий")
        let context = persistence.container.viewContext
        let root = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
        try context.assign(root, to: XCTUnwrap(persistence.sharedStore))
        root.setValue(baby.id, forKey: "id")
        try root.setValue(JSONEncoder().encode(baby), forKey: "payload")
        try context.save()
        let photo = BabyPhoto(
            babyID: baby.id,
            capturedAt: Date(),
            addedBy: "user-parent",
            pixelWidth: 20,
            pixelHeight: 30
        )
        try persistence.savePhoto(photo, imageData: Data([1]), thumbnailData: Data([2]))
        let records = try XCTUnwrap(root.value(forKey: "photos") as? Set<NSManagedObject>)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.objectID.persistentStore, persistence.sharedStore)
        context.delete(root)
        try context.save()
        XCTAssertTrue(try persistence.photos(babyID: baby.id).isEmpty)
    }

    func testV3MigrationPreservesEachStoreAndExistingChildren() async throws {
        for storeName in ["private", "shared"] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let modelDirectory = try XCTUnwrap(Bundle.main.url(forResource: "Malysh", withExtension: "momd"))
            let model =
                try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("MalyshV3.mom")))
            let old = NSPersistentContainer(name: "Malysh", managedObjectModel: model)
            let description = NSPersistentStoreDescription(url: directory
                .appendingPathComponent("Malysh-\(storeName).sqlite"))
            description.shouldAddStoreAsynchronously = false
            old.persistentStoreDescriptions = [description]
            old.loadPersistentStores { _, error in XCTAssertNil(error) }
            let baby = Baby(name: "До фото")
            let event = CareEvent(babyID: baby.id, kind: .diaper)
            let measurement = ChildMeasurement(babyID: baby.id, type: .weight, value: 3500)
            let root = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: old.viewContext)
            root.setValue(baby.id, forKey: "id")
            try root.setValue(JSONEncoder().encode(baby), forKey: "payload")
            for (entity, id, payload) in try [
                ("EventRecord", event.id, JSONEncoder().encode(event)),
                ("MeasurementRecord", measurement.id, JSONEncoder().encode(measurement)),
            ] {
                let child = NSEntityDescription.insertNewObject(forEntityName: entity, into: old.viewContext)
                child.setValue(id, forKey: "id")
                child.setValue(baby.id, forKey: "babyID")
                child.setValue(payload, forKey: "payload")
                child.setValue(root, forKey: "baby")
            }
            try old.viewContext.save()
            old.viewContext.reset()
            for store in old.persistentStoreCoordinator
                .persistentStores
            {
                try old.persistentStoreCoordinator.remove(store)
            }
            let migrated = Persistence(directory: directory)
            try await migrated.load()
            XCTAssertEqual(try migrated.babies(), [baby])
            XCTAssertEqual(try migrated.events(babyID: baby.id), [event])
            XCTAssertEqual(try migrated.measurements(babyID: baby.id), [measurement])
            let photo = BabyPhoto(babyID: baby.id, capturedAt: Date(), addedBy: "owner", pixelWidth: 1, pixelHeight: 1)
            try migrated.savePhoto(photo, imageData: Data([1]), thumbnailData: Data([2]))
            XCTAssertEqual(try migrated.photos(babyID: baby.id), [photo])
            let migratedRoot = try XCTUnwrap(migrated.babyObject(id: baby.id))
            XCTAssertEqual(
                migratedRoot.objectID.persistentStore,
                storeName == "private" ? migrated.privateStore : migrated.sharedStore
            )
        }
    }
}
