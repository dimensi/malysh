import CoreData
import Foundation
@testable import Malysh
import XCTest

final class ParentProfileTests: XCTestCase {
    @MainActor
    private func importPayload(_ baby: Baby, into persistence: Persistence) throws {
        let object = try XCTUnwrap(persistence.babyObject(id: baby.id))
        try object.setValue(JSONEncoder().encode(baby), forKey: "payload")
        try persistence.container.viewContext.save()
    }

    @MainActor
    func testOfflineParentsEditingDifferentEntriesConvergeAfterPayloadExchange() async throws {
        let first = Persistence(inMemory: true)
        let second = Persistence(inMemory: true)
        try await first.load()
        try await second.load()
        let original = Baby(name: "Семейный малыш")
        var fatherEdit = original
        fatherEdit.parentProfiles["owner"] = ParentProfile(name: "Алексей", role: .father,
                                                           updatedAt: Date(timeIntervalSince1970: 1000))
        var motherEdit = original
        motherEdit.parentProfiles["user-second"] = ParentProfile(name: "Анна", role: .mother,
                                                                 updatedAt: Date(timeIntervalSince1970: 1001))
        try first.saveBaby(fatherEdit)
        try second.saveBaby(motherEdit)
        // Simulate CloudKit replacing the entire JSON attribute with the other offline edit.
        try importPayload(motherEdit, into: first)
        try importPayload(fatherEdit, into: second)
        let repairedFirst = try XCTUnwrap(first.babies().first)
        let repairedSecond = try XCTUnwrap(second.babies().first)
        XCTAssertEqual(repairedFirst, repairedSecond)
        XCTAssertEqual(repairedFirst.parentProfiles.count, 2)
        try importPayload(repairedFirst, into: second)
        XCTAssertEqual(try second.babies(), [repairedFirst])
        XCTAssertEqual(try first.babies(), [repairedFirst])
    }

    @MainActor
    func testOldPayloadWipeIsRepairedFromDurableCacheAfterReopening() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baby = Baby(name: "Семейный малыш", parentProfiles: [
            "owner": ParentProfile(name: "Алексей", role: .father),
        ])
        do {
            let persistence = Persistence(directory: directory)
            try await persistence.load()
            try persistence.saveBaby(baby)
            var oldClientPayload = baby
            oldClientPayload.parentProfiles = [:]
            try importPayload(oldClientPayload, into: persistence)
            persistence.container.viewContext.reset()
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        let reopened = Persistence(directory: directory)
        try await reopened.load()
        XCTAssertEqual(try reopened.babies(), [baby])
        let object = try XCTUnwrap(reopened.babyObject(id: baby.id))
        let repairedData = try XCTUnwrap(object.value(forKey: "payload") as? Data)
        XCTAssertEqual(try JSONDecoder().decode(Baby.self, from: repairedData), baby)
        // Re-reading an already converged payload must not produce another write.
        let before = repairedData
        XCTAssertEqual(try reopened.babies(), [baby])
        XCTAssertEqual(object.value(forKey: "payload") as? Data, before)
        reopened.container.viewContext.reset()
        for store in reopened.container.persistentStoreCoordinator.persistentStores {
            try reopened.container.persistentStoreCoordinator.remove(store)
        }
    }
}
