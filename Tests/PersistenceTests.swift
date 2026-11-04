import CoreData
@testable import Malysh
import XCTest

@MainActor
final class PersistenceTests: XCTestCase {
    func testLightweightMigrationFromV1PreservesBabyAndEvent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelDirectory = try XCTUnwrap(Bundle.main.url(forResource: "Malysh", withExtension: "momd"))
        let oldModel =
            try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("Malysh.mom")))
        let baby = Baby(name: "До обновления")
        let event = CareEvent(babyID: baby.id, kind: .bottle, volumeML: 135, note: "Сохранить при обновлении")
        let old = NSPersistentContainer(name: "Malysh", managedObjectModel: oldModel)
        let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("Malysh-private.sqlite"))
        description.shouldAddStoreAsynchronously = false
        old.persistentStoreDescriptions = [description]
        old.loadPersistentStores { _, error in XCTAssertNil(error) }
        let babyObject = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: old.viewContext)
        babyObject.setValue(baby.id, forKey: "id")
        babyObject.setValue(baby.name, forKey: "name")
        babyObject.setValue(baby.birthDate, forKey: "birthDate")
        try babyObject.setValue(JSONEncoder().encode(baby), forKey: "payload")
        let eventObject = NSEntityDescription.insertNewObject(forEntityName: "EventRecord", into: old.viewContext)
        eventObject.setValue(event.id, forKey: "id")
        eventObject.setValue(event.babyID, forKey: "babyID")
        eventObject.setValue(event.start, forKey: "start")
        eventObject.setValue(event.modifiedAt, forKey: "modifiedAt")
        try eventObject.setValue(JSONEncoder().encode(event), forKey: "payload")
        eventObject.setValue(babyObject, forKey: "baby")
        try old.viewContext.save()
        old.viewContext.reset()
        for store in old.persistentStoreCoordinator
            .persistentStores
        {
            try old.persistentStoreCoordinator.remove(store)
        }

        let current = Persistence(directory: directory)
        try await current.load()
        XCTAssertEqual(try current.babies(), [baby])
        XCTAssertEqual(try current.events(babyID: baby.id), [event])
        let migratedBaby = try XCTUnwrap(current.babyObject(id: baby.id))
        let related = try XCTUnwrap(migratedBaby.value(forKey: "events") as? Set<NSManagedObject>)
        XCTAssertEqual(related.count, 1)
        XCTAssertEqual((related.first?.value(forKey: "schemaVersion") as? NSNumber)?.intValue, 1)
        var updated = event
        updated.volumeML = 150
        try current.saveEvent(updated)
        XCTAssertEqual(try current.events(babyID: baby.id), [updated])
    }

    func testDiskReloadUpdateDeleteAndRelationship() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baby = Baby(name: "Тест")
        let original = CareEvent(babyID: baby.id, kind: .bottle, volumeML: 80)
        do {
            let persistence = Persistence(directory: directory)
            try await persistence.load()
            try persistence.saveBaby(baby)
            try persistence.saveEvent(original)
            let root = try XCTUnwrap(persistence.babyObject(id: baby.id))
            let related = try XCTUnwrap(root.value(forKey: "events") as? Set<NSManagedObject>)
            XCTAssertEqual(related.count, 1)
            XCTAssertEqual(related.first?.objectID.persistentStore, root.objectID.persistentStore)
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        let reloaded = Persistence(directory: directory)
        try await reloaded.load()
        XCTAssertEqual(try reloaded.babies(), [baby])
        XCTAssertEqual(try reloaded.events(babyID: baby.id), [original])
        var changed = original
        changed.volumeML = 110
        try reloaded.saveEvent(changed)
        XCTAssertEqual(try reloaded.events(babyID: baby.id), [changed])
        try reloaded.deleteEvent(id: changed.id)
        XCTAssertTrue(try reloaded.events(babyID: baby.id).isEmpty)
        XCTAssertEqual(try reloaded.babies(), [baby])
    }

    func testEncodingFailureRollsBackInsertedAndUpdatedObjects() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        let baby = Baby(name: "Тест")
        try persistence.saveBaby(baby)
        let original = CareEvent(babyID: baby.id, kind: .breast)
        try persistence.saveEvent(original)
        var invalid = original
        invalid.leftSeconds = .nan
        XCTAssertThrowsError(try persistence.saveEvent(invalid))
        XCTAssertEqual(try persistence.events(babyID: baby.id), [original])
        invalid.id = UUID()
        XCTAssertThrowsError(try persistence.saveEvent(invalid))
        XCTAssertEqual(try persistence.events(babyID: baby.id), [original])
        XCTAssertFalse(persistence.container.viewContext.hasChanges)
    }

    func testMissingParentDoesNotLeaveInsertedEvent() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        let missingID = UUID()
        XCTAssertThrowsError(try persistence.saveEvent(CareEvent(babyID: missingID, kind: .diaper)))
        XCTAssertTrue(try persistence.events(babyID: missingID).isEmpty)
        XCTAssertFalse(persistence.container.viewContext.hasChanges)
    }
}
