import CoreData
@testable import Malysh
import XCTest

@MainActor
final class PersistenceTests: XCTestCase {
    func testLightweightMigrationFromBaselineV2PreservesBabyAndEvent() async throws {
        try await verifyMigration(storeName: "private", modelName: "Malysh")
        try await verifyMigration(storeName: "shared", modelName: "Malysh")
    }

    func testLightweightMigrationFromV4PreservesPrivateAndSharedData() async throws {
        try await verifyMigration(storeName: "private", modelName: "MalyshV4")
        try await verifyMigration(storeName: "shared", modelName: "MalyshV4")
    }

    private func verifyMigration(storeName: String, modelName: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelDirectory = try XCTUnwrap(Bundle.main.url(forResource: "Malysh", withExtension: "momd"))
        let oldModel =
            try XCTUnwrap(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("\(modelName).mom")))
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
        let photo = BabyPhoto(babyID: baby.id, capturedAt: Date(), addedBy: "parent", pixelWidth: 1, pixelHeight: 1)
        let measurement = ChildMeasurement(babyID: baby.id, type: .height, value: 52.5)
        if modelName == "MalyshV4" {
            let photoObject = NSEntityDescription.insertNewObject(forEntityName: "PhotoRecord", into: old.viewContext)
            photoObject.setValue(photo.id, forKey: "id")
            photoObject.setValue(baby.id, forKey: "babyID")
            photoObject.setValue(photo.capturedAt, forKey: "capturedAt")
            try photoObject.setValue(JSONEncoder().encode(photo), forKey: "payload")
            photoObject.setValue(Data([42]), forKey: "imageData")
            photoObject.setValue(babyObject, forKey: "baby")
            let measureObject = NSEntityDescription.insertNewObject(
                forEntityName: "MeasurementRecord", into: old.viewContext
            )
            measureObject.setValue(measurement.id, forKey: "id")
            measureObject.setValue(baby.id, forKey: "babyID")
            measureObject.setValue(measurement.measuredAt, forKey: "measuredAt")
            measureObject.setValue(measurement.modifiedAt, forKey: "modifiedAt")
            try measureObject.setValue(JSONEncoder().encode(measurement), forKey: "payload")
            measureObject.setValue(babyObject, forKey: "baby")
        }
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
        XCTAssertEqual(
            migratedBaby.objectID.persistentStore,
            storeName == "private" ? current.privateStore : current.sharedStore
        )
        XCTAssertNil(migratedBaby.value(forKey: "birthMeasurementsCompleted"))
        let related = try XCTUnwrap(migratedBaby.value(forKey: "events") as? Set<NSManagedObject>)
        XCTAssertEqual(related.count, 1)
        XCTAssertEqual((related.first?.value(forKey: "schemaVersion") as? NSNumber)?.intValue, 1)
        var updated = event
        updated.volumeML = 150
        try current.saveEvent(updated)
        XCTAssertEqual(try current.events(babyID: baby.id), [updated])
        if modelName == "MalyshV4" {
            XCTAssertEqual(try current.photos(babyID: baby.id), [photo])
            XCTAssertEqual(try current.photoData(id: photo.id), Data([42]))
            XCTAssertEqual(try current.measurements(babyID: baby.id), [measurement])
        }
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

    func testBirthMeasurementUsesSharedStoreAndCompletionSurvivesPayloadReplacementAndDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        try await persistence.load()
        let date = Calendar.current.startOfDay(for: Date())
        let baby = Baby(name: "Общий", birthDate: date, birthDateConfirmed: true)
        let context = persistence.container.viewContext
        let root = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
        try context.assign(root, to: XCTUnwrap(persistence.sharedStore))
        root.setValue(baby.id, forKey: "id")
        root.setValue(baby.name, forKey: "name")
        root.setValue(baby.birthDate, forKey: "birthDate")
        try root.setValue(JSONEncoder().encode(baby), forKey: "payload")
        try context.save()
        let measurement = ChildMeasurement(babyID: baby.id, type: .height, measuredAt: date, value: 52)
        try persistence.saveChildProfile(baby, initialMeasurements: [measurement])
        let records = try XCTUnwrap(root.value(forKey: "measurements") as? Set<NSManagedObject>)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.objectID.persistentStore, persistence.sharedStore)
        XCTAssertEqual(try persistence.measurements(babyID: baby.id), [measurement])

        // Simulate an older app's incoming profile payload, which has no completion field.
        var renamed = baby
        renamed.name = "Имя второго родителя"
        root.setValue(renamed.name, forKey: "name")
        try root.setValue(JSONEncoder().encode(renamed), forKey: "payload")
        try context.save()
        var edited = measurement
        edited.value = 53
        try persistence.saveMeasurement(edited)
        XCTAssertEqual(try persistence.measurements(babyID: baby.id), [edited])
        try persistence.deleteMeasurement(id: measurement.id)
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
        let reopened = Persistence(directory: directory)
        try await reopened.load()
        let reloaded = try XCTUnwrap(reopened.babies().first)
        XCTAssertEqual(reloaded.name, renamed.name)
        XCTAssertTrue(reloaded.birthMeasurementsCompleted)
        XCTAssertTrue(try reopened.measurements(babyID: baby.id).isEmpty)
    }

    func testBirthMeasurementsRollBackProfileAndMeasurementsOnStoreSaveFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        try await persistence.load()
        let date = Calendar.current.startOfDay(for: Date())
        let original = Baby(name: "До сохранения")
        try persistence.saveBaby(original)
        let updated = Baby(id: original.id, name: "После сохранения", birthDate: date, birthDateConfirmed: true)
        let measurements = [
            ChildMeasurement(babyID: original.id, type: .height, measuredAt: date, value: 52),
            ChildMeasurement(babyID: original.id, type: .weight, measuredAt: date, value: 3500),
        ]
        let store = try XCTUnwrap(persistence.privateStore)
        store.isReadOnly = true
        XCTAssertThrowsError(try persistence.saveChildProfile(updated, initialMeasurements: measurements))
        store.isReadOnly = false
        XCTAssertEqual(try persistence.babies(), [original])
        XCTAssertTrue(try persistence.measurements(babyID: original.id).isEmpty)
        XCTAssertFalse(persistence.container.viewContext.hasChanges)

        try persistence.saveChildProfile(updated, initialMeasurements: measurements)
        XCTAssertTrue(try XCTUnwrap(persistence.babies().first).birthMeasurementsCompleted)
        XCTAssertEqual(try Set(persistence.measurements(babyID: original.id).map(\.id)), Set(measurements.map(\.id)))
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
