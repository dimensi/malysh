import CoreData
@testable import Malysh
import XCTest

@MainActor
final class PersistenceTests: XCTestCase {
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
