import CoreData
@testable import Malysh
import XCTest

@MainActor
final class PersistenceTests: XCTestCase {
    func testLightweightMigrationFromBaselineV2PreservesBabyAndEvent() async throws {
        try await verifyMigration(storeName: "private")
        try await verifyMigration(storeName: "shared")
    }

    private func verifyMigration(storeName: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelDirectory = try XCTUnwrap(Bundle.main.url(forResource: "Malysh", withExtension: "momd"))
        let oldModel =
            try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("Malysh.mom")))
        let baby = Baby(name: "До обновления")
        let event = CareEvent(babyID: baby.id, kind: .bottle, volumeML: 135, note: "Сохранить при обновлении")
        let old = NSPersistentContainer(name: "Malysh", managedObjectModel: oldModel)
        let description = NSPersistentStoreDescription(url: directory
            .appendingPathComponent("Malysh-\(storeName).sqlite"))
        description.shouldAddStoreAsynchronously = false
        old.persistentStoreDescriptions = [description]
        old.loadPersistentStores { _, error in XCTAssertNil(error) }
        let babyObject = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: old.viewContext)
        babyObject.setValue(baby.id, forKey: "id")
        babyObject.setValue(baby.name, forKey: "name")
        babyObject.setValue(baby.birthDate, forKey: "birthDate")
        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(baby)) as? [String: Any])
        legacyJSON.removeValue(forKey: "birthDateConfirmed")
        legacyJSON.removeValue(forKey: "birthDay")
        try babyObject.setValue(JSONSerialization.data(withJSONObject: legacyJSON), forKey: "payload")
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

    func testMeasurementsSurviveDiskReopenWithMetadataAndOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baby = Baby(name: "Диск")
        let date = Date().addingTimeInterval(-100)
        let first = ChildMeasurement(babyID: baby.id, type: .weight, measuredAt: date,
                                     value: 3500.5, createdAt: date, modifiedAt: date, note: "Заметка")
        let second = ChildMeasurement(babyID: baby.id, type: .headCircumference,
                                      measuredAt: date.addingTimeInterval(10), value: 35)
        let initial = Persistence(directory: directory)
        try await initial.load()
        try initial.saveBaby(baby)
        try initial.saveMeasurement(first)
        try initial.saveMeasurement(second)
        for store in initial.container.persistentStoreCoordinator.persistentStores {
            try initial.container.persistentStoreCoordinator.remove(store)
        }
        let reopened = Persistence(directory: directory)
        try await reopened.load()
        XCTAssertEqual(try reopened.measurements(babyID: baby.id), [second, first])
        let root = try XCTUnwrap(reopened.babyObject(id: baby.id))
        XCTAssertEqual((root.value(forKey: "measurements") as? Set<NSManagedObject>)?.count, 2)
    }

    func testMeasurementUsesSharedBabyStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        try await persistence.load()
        let baby = Baby(name: "Общий")
        let context = persistence.container.viewContext
        let root = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
        try context.assign(root, to: XCTUnwrap(persistence.sharedStore))
        root.setValue(baby.id, forKey: "id")
        root.setValue(baby.name, forKey: "name")
        root.setValue(baby.birthDate, forKey: "birthDate")
        try root.setValue(JSONEncoder().encode(baby), forKey: "payload")
        try context.save()
        let measurement = ChildMeasurement(babyID: baby.id, type: .height, value: 52)
        try persistence.saveMeasurement(measurement)
        let records = try XCTUnwrap(root.value(forKey: "measurements") as? Set<NSManagedObject>)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.objectID.persistentStore, persistence.sharedStore)
        XCTAssertEqual(try persistence.measurements(babyID: baby.id), [measurement])
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
}
