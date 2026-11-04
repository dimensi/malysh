import CoreData
import Foundation
@testable import Malysh
import XCTest

final class ParentProfileTests: XCTestCase {
    func testExistingBabyPayloadLoadsWithoutProfiles() throws {
        struct LegacyBaby: Encodable { let id: UUID; let name: String; let birthDate: Date }
        let old = LegacyBaby(id: UUID(), name: "Малыш", birthDate: Date(timeIntervalSince1970: 1000))
        let baby = try JSONDecoder().decode(Baby.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(baby.id, old.id)
        XCTAssertEqual(baby.name, old.name)
        XCTAssertEqual(baby.birthDate, old.birthDate)
        XCTAssertTrue(baby.parentProfiles.isEmpty)
    }

    func testNamesAndRolesPersistInExistingBabyPayload() throws {
        let baby = Baby(name: "Семейный малыш", parentProfiles: [
            "owner": ParentProfile(name: " Алексей ", role: .father),
            "user-second": ParentProfile(name: "Анна", role: .mother),
        ])
        let decoded = try JSONDecoder().decode(Baby.self, from: JSONEncoder().encode(baby))
        XCTAssertEqual(decoded, baby)
        XCTAssertEqual(decoded.parentProfiles["owner"]?.name, "Алексей")
        XCTAssertEqual(decoded.parentProfiles["user-second"]?.role, .mother)
    }

    func testSharedProfileProvidesNameWhenCloudKitHasNoName() {
        let member = FamilyMember.make(id: "owner", nameComponents: nil, isOwner: true,
                                       acceptanceStatus: .accepted, isCurrentUser: false,
                                       profile: ParentProfile(name: "Алексей", role: .father))
        XCTAssertEqual(member.name, "Алексей")
        XCTAssertEqual(member.role, "Папа")
        XCTAssertTrue(member.isOwner)
        let current = FamilyMember.make(id: "user-second", nameComponents: nil, isOwner: false,
                                        acceptanceStatus: .accepted, isCurrentUser: true,
                                        profile: ParentProfile(name: "Анна", role: .mother))
        XCTAssertEqual(current.name, "Анна")
        XCTAssertEqual(current.role, "Мама")
        XCTAssertTrue(current.isCurrentUser)
    }

    func testFamilyRoleIsIndependentOfShareOwnership() {
        let mother = FamilyMember.make(id: "owner", nameComponents: nil, isOwner: true,
                                       acceptanceStatus: .accepted, isCurrentUser: true,
                                       profile: ParentProfile(name: "Анна", role: .mother))
        XCTAssertEqual(mother.role, "Мама")
        XCTAssertTrue(mother.isOwner)
    }

    @MainActor
    func testProfileFieldsSurviveLocalPersistenceAndBabyRename() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        var baby = Baby(name: "Малыш", parentProfiles: ["owner": ParentProfile(name: "Алексей", role: .father)])
        try persistence.saveBaby(baby)
        baby = try XCTUnwrap(persistence.babies().first)
        baby.name = "Семейный малыш"
        try persistence.saveBaby(baby)
        let saved = try XCTUnwrap(persistence.babies().first)
        XCTAssertEqual(saved.name, "Семейный малыш")
        XCTAssertEqual(saved.parentProfiles["owner"], baby.parentProfiles["owner"])
    }

    func testLegacyProfileHasAnOlderRevisionThanNewEdits() throws {
        struct LegacyProfile: Encodable { let name: String; let role: ParentRole }
        let old = LegacyProfile(name: "Анна", role: .parent)
        let decoded = try JSONDecoder().decode(ParentProfile.self, from: JSONEncoder().encode(old))
        XCTAssertEqual(decoded.updatedAt, .distantPast)
        let edit = ParentProfile(name: "Анна", role: .mother, updatedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(ParentProfile.merging(["user": decoded], ["user": edit])["user"], edit)
    }

    func testSameParentRevisionUsesDeterministicWinner() {
        let date = Date(timeIntervalSince1970: 1000)
        let first = ParentProfile(name: "Анна", role: .mother, updatedAt: date)
        let second = ParentProfile(name: "Аня", role: .parent, updatedAt: date)
        let forward = ParentProfile.merging(["user": first], ["user": second])
        let reverse = ParentProfile.merging(["user": second], ["user": first])
        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(ParentProfile.merging(forward, reverse), forward)
        let newer = ParentProfile(name: "Анна", role: .mother, updatedAt: date.addingTimeInterval(1))
        XCTAssertEqual(ParentProfile.merging(forward, ["user": newer])["user"], newer)
    }

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

    @MainActor
    func testStaleRenamePreservesFreshParentProfile() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        var stale = Baby(name: "Малыш")
        try persistence.saveBaby(stale)
        var edited = stale
        edited.parentProfiles["owner"] = ParentProfile(name: "Алексей", role: .father)
        try persistence.saveBaby(edited)
        stale.name = "Андрей"
        try persistence.saveBaby(stale)
        let saved = try XCTUnwrap(persistence.babies().first)
        XCTAssertEqual(saved.name, "Андрей")
        XCTAssertEqual(saved.parentProfiles, edited.parentProfiles)
    }
}
