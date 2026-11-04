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

    private func close(_ persistence: Persistence) throws {
        persistence.container.viewContext.reset()
        for store in persistence.container.persistentStoreCoordinator.persistentStores {
            try persistence.container.persistentStoreCoordinator.remove(store)
        }
    }

    func testLegacyPayloadDecodesWithoutInventingAuthorsOrCreationDate() throws {
        let recorded = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = CareEvent(babyID: UUID(), kind: .bottle, start: recorded,
                               createdAt: recorded, modifiedAt: recorded)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "createdBy")
        json.removeValue(forKey: "lastEditedBy")
        let restored = try JSONDecoder().decode(CareEvent.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.createdBy)
        XCTAssertNil(restored.lastEditedBy)
        XCTAssertEqual(restored.createdAt, recorded)
    }

    func testBackdatedNewRecordUsesActualCreationTimeAndPrivateOwner() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        var baby = try XCTUnwrap(store.baby)
        baby.parentProfiles["owner"] = ParentProfile(name: "Никита", role: .father)
        try persistence.saveBaby(baby)
        try store.reload()
        let yesterday = Date().addingTimeInterval(-86400)
        let before = Date()
        try store.save(CareEvent(babyID: baby.id, kind: .bottle, start: yesterday, createdAt: yesterday))
        let saved = try XCTUnwrap(store.events.first)
        XCTAssertEqual(saved.start, yesterday)
        XCTAssertGreaterThanOrEqual(saved.createdAt, before)
        XCTAssertLessThanOrEqual(saved.createdAt, Date())
        XCTAssertEqual(saved.createdBy, EventAuthor(id: "owner", nameSnapshot: "Никита", role: .father))
        XCTAssertNil(saved.lastEditedBy)
    }

    func testEditingPreservesCreatorAndLegacyNilButRecordsKnownEditor() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let baby = try XCTUnwrap(store.baby)
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
            XCTAssertEqual(saved.lastEditedBy?.id, "owner")
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
        store.select(local.id)
        XCTAssertNil(try persistence.currentEventAuthor(babyID: shared.id))
        try store.save(CareEvent(babyID: shared.id, kind: .diaper))
        let saved = try XCTUnwrap(persistence.events(babyID: shared.id).first)
        XCTAssertNil(saved.createdBy)
        XCTAssertNil(store.eventAuthorLabel(for: saved))
        XCTAssertEqual(store.authorLabel(for: nil, babyID: shared.id), "Автор не указан")
        XCTAssertEqual(store.selectedID, local.id)
    }

    func testProvenSharedActorCacheSurvivesReopenAndClearsWithoutAffectingOtherDiary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Persistence(directory: directory)
        try await first.load()
        let shared = Baby(name: "Андрей")
        try insertSharedBaby(shared, into: first)
        let author = EventAuthor(id: "user-current", nameSnapshot: "Юлия", role: .mother)
        try EventAuthorCache(directory: directory, inMemory: false).remember(author, babyID: shared.id)
        XCTAssertEqual(try first.currentEventAuthor(babyID: shared.id), author)
        try close(first)

        let reopened = Persistence(directory: directory)
        try await reopened.load()
        XCTAssertEqual(try reopened.currentEventAuthor(babyID: shared.id), author)
        let unknown = Baby(name: "Другой дневник")
        try insertSharedBaby(unknown, into: reopened)
        XCTAssertNil(try reopened.currentEventAuthor(babyID: unknown.id))
        try reopened.clearEventAuthorCache()
        XCTAssertNil(try reopened.currentEventAuthor(babyID: shared.id))
        try close(reopened)
    }

    func testColdLiveActivityActionsUseTargetBabyCachedActorAndPreserveCreator() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        try await persistence.load()
        let local = Baby(name: "Личный дневник")
        try persistence.saveBaby(local)
        let shared = Baby(name: "Андрей")
        try insertSharedBaby(shared, into: persistence)
        let creator = EventAuthor(id: "owner", nameSnapshot: "Никита", role: .father)
        let editor = EventAuthor(id: "user-current", nameSnapshot: "Юлия", role: .mother)
        let original = CareEvent(babyID: shared.id, kind: .breast, start: Date().addingTimeInterval(-60),
                                 createdBy: creator)
        try persistence.saveEvent(original)
        try EventAuthorCache(directory: directory, inMemory: false).remember(editor, babyID: shared.id)
        let runtime = CareActivityRuntime(persistence: persistence, coordinator: AuthorTestCoordinator())
        await runtime.ensureReady()
        runtime.store.select(local.id)

        try await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            _ = try await SwitchCareSideIntent(eventID: original.id, babyID: shared.id, side: "right").perform()
        }
        var saved = try XCTUnwrap(persistence.events(babyID: shared.id).first)
        XCTAssertEqual(saved.side, .right)
        XCTAssertEqual(saved.createdBy, creator)
        XCTAssertEqual(saved.lastEditedBy, editor)
        try await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            _ = try await FinishCareActivityIntent(eventID: original.id, babyID: shared.id).perform()
        }
        saved = try XCTUnwrap(persistence.events(babyID: shared.id).first)
        XCTAssertNotNil(saved.end)
        XCTAssertEqual(saved.createdAt, original.createdAt)
        XCTAssertEqual(saved.createdBy, creator)
        XCTAssertEqual(saved.lastEditedBy, editor)
        XCTAssertEqual(runtime.store.selectedID, local.id)
        try close(persistence)
    }

    func testAuthorLabelPrefersCurrentSharedProfileAndFallsBackToSnapshot() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        var baby = try XCTUnwrap(store.baby)
        let author = EventAuthor(id: "owner", nameSnapshot: "Старое имя", role: .parent)
        baby.parentProfiles["owner"] = ParentProfile(name: "Никита", role: .father)
        try persistence.saveBaby(baby)
        try store.reload()
        XCTAssertEqual(store.authorLabel(for: author, babyID: baby.id), "Никита · Папа")
        XCTAssertEqual(store.authorLabel(for: author, babyID: UUID()), "Старое имя · Родитель")
    }
}

@MainActor
private final class AuthorTestCoordinator: CareActivityCoordinating {
    func reconcile(events _: [CareEvent], babies _: [Baby], allowStart _: Bool) {}
    func flush() async {}
}
