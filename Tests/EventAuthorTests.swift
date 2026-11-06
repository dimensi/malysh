import CoreData
@testable import Malysh
import XCTest

@MainActor
final class EventAuthorTests: XCTestCase {
    private func insertSharedBaby(_ baby: Baby, into persistence: Persistence) throws {
        let context = persistence.container.viewContext
        let object = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
        try context.assign(object, to: XCTUnwrap(persistence.sharedStore))
        object.setValue(baby.id, forKey: "id")
        object.setValue(baby.name, forKey: "name")
        object.setValue(baby.birthDate, forKey: "birthDate")
        try object.setValue(JSONEncoder().encode(baby), forKey: "payload")
        try context.save()
    }

    func testEditingPreservesCreatorAndLegacyNilButRecordsKnownEditor() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        try store.createFirstDiary(name: "Малыш", birthDate: nil)
        let baby = try XCTUnwrap(store.baby)
        try store.saveFamilyProfile(babyID: baby.id, memberID: "owner", name: " Никита ", role: .father)
        let created = Date().addingTimeInterval(-3600)
        let creator = EventAuthor(id: "user-other", nameSnapshot: "Юлия", role: .mother)
        for originalCreator in [nil, creator] {
            let original = CareEvent(babyID: baby.id, kind: .diaper, start: created,
                                     createdAt: created, createdBy: originalCreator)
            try persistence.saveEvent(original)
            var edit = original
            edit.note = "Edited"
            edit.createdAt = Date()
            edit.createdBy = EventAuthor(id: "forged-creator")
            try store.save(edit)
            let saved = try XCTUnwrap(persistence.events(babyID: baby.id).first { $0.id == original.id })
            XCTAssertEqual(saved.createdBy, originalCreator)
            XCTAssertEqual(saved.createdAt, created)
            XCTAssertEqual(saved.lastEditedBy, EventAuthor(id: "owner", nameSnapshot: "Никита", role: .father))
            if originalCreator == nil {
                XCTAssertNil(store.eventAuthorLabel(for: saved))
            }
        }
    }

    func testUnknownSharedActorRemainsUnknownAndDoesNotUseSelectedPrivateOwner() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let local = Baby(
            name: "Личный дневник",
            parentProfiles: ["owner": ParentProfile(name: "Никита", role: .father)]
        )
        try persistence.saveBaby(local)
        let shared = Baby(name: "Андрей")
        try insertSharedBaby(shared, into: persistence)
        try store.reload()
        store.select(shared.id)
        XCTAssertNil(store.localParent)
        XCTAssertThrowsError(try store.saveFamilyProfile(
            babyID: shared.id, memberID: "owner", name: "Никита", role: .father
        ))
        store.select(local.id)
        XCTAssertNil(try persistence.currentEventAuthor(babyID: shared.id))
        try store.save(CareEvent(babyID: shared.id, kind: .diaper))
        let saved = try XCTUnwrap(persistence.events(babyID: shared.id).first)
        XCTAssertNil(saved.createdBy)
        XCTAssertNil(store.eventAuthorLabel(for: saved))
        XCTAssertEqual(store.authorLabel(for: nil, babyID: shared.id), "Автор не указан")
        XCTAssertEqual(store.selectedID, local.id)
    }
}
