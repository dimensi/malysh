import CoreData
@testable import Malysh
import XCTest

@MainActor
final class AppStoreTests: XCTestCase {
    private func insertSharedBaby(_ baby: Baby, persistence: Persistence) throws {
        let context = persistence.container.viewContext
        let object = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
        try context.assign(object, to: XCTUnwrap(persistence.sharedStore))
        object.setValue(baby.id, forKey: "id")
        object.setValue(baby.name, forKey: "name")
        object.setValue(baby.birthDate, forKey: "birthDate")
        try object.setValue(JSONEncoder().encode(baby), forKey: "payload")
        try context.save()
    }

    func testSharedDiaryHidesOnlyEmptyDefaultAndPersistsSelection() async throws {
        let previous = UserDefaults.standard.object(forKey: "selectedBaby")
        defer { UserDefaults.standard.set(previous, forKey: "selectedBaby") }
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let placeholder = try XCTUnwrap(store.baby)
        let shared = Baby(name: "Семейный малыш")
        try insertSharedBaby(shared, persistence: persistence)
        try store.reload()
        XCTAssertEqual(store.visibleBabies.map(\.id), [shared.id])
        XCTAssertEqual(store.selectedID, shared.id)
        XCTAssertTrue(store.redundantBabies.isEmpty)
        XCTAssertTrue(store.isSharedDiary)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "selectedBaby"), shared.id.uuidString)
        XCTAssertEqual(try Set(persistence.babies().map(\.id)), [shared.id])
        XCTAssertNil(try persistence.babyObject(id: placeholder.id))

        let relaunched = AppStore(persistence: persistence)
        await relaunched.load()
        XCTAssertEqual(relaunched.visibleBabies.map(\.id), [shared.id])
        XCTAssertEqual(relaunched.selectedID, shared.id)
        XCTAssertTrue(relaunched.isSharedDiary)
    }

    func testSharedDiaryHidesRedundantDefaultWithoutDeletingRecordsUntilConfirmedAndRestoresAfterLeaving() async throws {
        let previous = UserDefaults.standard.object(forKey: "selectedBaby")
        defer { UserDefaults.standard.set(previous, forKey: "selectedBaby") }
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let local = try XCTUnwrap(store.baby)
        store.diaper(.mixed)
        let originalEvents = try persistence.events(babyID: local.id)
        XCTAssertEqual(originalEvents.count, 1)
        let namedLocal = Baby(name: "Личный малыш")
        try persistence.saveBaby(namedLocal)
        let shared = Baby(name: "Семейный малыш")
        try insertSharedBaby(shared, persistence: persistence)
        try store.reload()
        XCTAssertEqual(Set(store.visibleBabies.map(\.id)), [namedLocal.id, shared.id])
        XCTAssertEqual(store.redundantBabies, [local])
        XCTAssertEqual(try persistence.events(babyID: local.id), originalEvents)
        XCTAssertEqual(store.selectedID, shared.id)
        XCTAssertTrue(store.isSharedDiary)
        XCTAssertEqual(try persistence.events(babyID: local.id), originalEvents)
        XCTAssertEqual(try Set(persistence.babies().map(\.id)), [local.id, namedLocal.id, shared.id])

        let relaunched = AppStore(persistence: persistence)
        await relaunched.load()
        XCTAssertEqual(relaunched.selectedID, shared.id)
        XCTAssertEqual(relaunched.redundantBabies, [local])
        XCTAssertEqual(relaunched.visibleBabies.count, 2)
        relaunched.select(namedLocal.id)
        XCTAssertEqual(relaunched.selectedID, namedLocal.id)

        let object = try XCTUnwrap(persistence.babyObject(id: shared.id))
        persistence.container.viewContext.delete(object)
        try persistence.container.viewContext.save()
        try relaunched.reload()
        XCTAssertTrue(relaunched.redundantBabies.isEmpty)
        XCTAssertEqual(Set(relaunched.visibleBabies.map(\.id)), [local.id, namedLocal.id])
        XCTAssertEqual(try persistence.events(babyID: local.id), originalEvents)
        XCTAssertEqual(try Set(persistence.babies().map(\.id)), [local.id, namedLocal.id])
    }

    func testConfirmedRedundantDiaryRemovalDeletesOnlyPrivateStarterAndItsEvents() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let redundant = try XCTUnwrap(store.baby)
        store.diaper(.mixed)
        let named = Baby(name: "Личный малыш")
        try persistence.saveBaby(named)
        let namedEvent = CareEvent(babyID: named.id, kind: .bottle, volumeML: 90)
        try persistence.saveEvent(namedEvent)
        let shared = Baby(name: "Андрей")
        try insertSharedBaby(shared, persistence: persistence)
        let sharedEvent = CareEvent(babyID: shared.id, kind: .diaper)
        try persistence.saveEvent(sharedEvent)
        try store.reload()
        XCTAssertEqual(store.redundantBabies, [redundant])
        XCTAssertEqual(try store.redundantEventCount, 1)
        XCTAssertEqual(try persistence.events(babyID: redundant.id).count, 1)

        try store.removeRedundantDiaries()

        XCTAssertTrue(store.redundantBabies.isEmpty)
        XCTAssertEqual(try store.redundantEventCount, 0)
        XCTAssertNil(try persistence.babyObject(id: redundant.id))
        XCTAssertTrue(try persistence.events(babyID: redundant.id).isEmpty)
        XCTAssertEqual(try persistence.events(babyID: shared.id), [sharedEvent])
        XCTAssertEqual(try persistence.events(babyID: named.id), [namedEvent])
        XCTAssertEqual(try Set(persistence.babies().map(\.id)), [shared.id, named.id])
        try store.removeRedundantDiaries()
        XCTAssertEqual(try persistence.events(babyID: shared.id), [sharedEvent])
    }

    func testDeleteBabyBatchRejectsSharedProfileWithoutDeletingPrivateStarter() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        let local = Baby(name: "Малыш")
        try persistence.saveBaby(local)
        let localEvent = CareEvent(babyID: local.id, kind: .diaper)
        try persistence.saveEvent(localEvent)
        let shared = Baby(name: "Малыш")
        try insertSharedBaby(shared, persistence: persistence)
        XCTAssertThrowsError(try persistence.deleteBabyAndEvents(ids: [local.id, shared.id]))
        XCTAssertEqual(try Set(persistence.babies().map(\.id)), [local.id, shared.id])
        XCTAssertEqual(try persistence.events(babyID: local.id), [localEvent])
    }

    func testDefaultShareWithoutAcceptedOtherParentDoesNotKeepStartupDiaryInPicker() {
        let local = Baby(name: "Малыш")
        let owner = FamilyMember(id: "owner", name: "Вы", role: "Владелец дневника",
                                 status: "В семье", isCurrentUser: true)
        let pending = FamilyMember(id: "pending", name: "Другой родитель", role: "Родитель",
                                   status: "Приглашение отправлено", isCurrentUser: false)
        let accepted = FamilyMember(id: "accepted", name: "Другой родитель", role: "Мама",
                                    status: "В семье", isCurrentUser: false)
        XCTAssertTrue(AppStore.isPreSharedDefault(local, isShared: false, hasSharedDiary: true,
                                                  family: FamilySnapshot(isOwner: true, members: [owner])))
        XCTAssertTrue(AppStore.isPreSharedDefault(local, isShared: false, hasSharedDiary: true,
                                                  family: FamilySnapshot(isOwner: true, members: [owner, pending])))
        XCTAssertFalse(AppStore.isPreSharedDefault(local, isShared: false, hasSharedDiary: true,
                                                   family: FamilySnapshot(isOwner: true, members: [owner, accepted])))
        let ownerWithoutCurrentIdentity = FamilyMember(id: "owner", name: "Другой родитель", role: "Папа",
                                                       status: "В семье", isCurrentUser: false, isOwner: true)
        XCTAssertTrue(AppStore.isPreSharedDefault(local, isShared: false, hasSharedDiary: true,
                                                  family: FamilySnapshot(
                                                      isOwner: true,
                                                      members: [ownerWithoutCurrentIdentity]
                                                  )))
        XCTAssertFalse(AppStore.isPreSharedDefault(local, isShared: true, hasSharedDiary: true, family: nil))
        XCTAssertFalse(AppStore.isPreSharedDefault(local, isShared: false, hasSharedDiary: false, family: nil))
        XCTAssertFalse(AppStore.isPreSharedDefault(Baby(name: "Андрей"), isShared: false,
                                                   hasSharedDiary: true, family: nil))
    }

    func testRevokingLastSharedDiaryCreatesUsablePrivateStarterWithoutRelaunch() async throws {
        let previous = UserDefaults.standard.object(forKey: "selectedBaby")
        defer { UserDefaults.standard.set(previous, forKey: "selectedBaby") }
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let oldStarter = try XCTUnwrap(store.baby)
        let shared = Baby(name: "Андрей")
        try insertSharedBaby(shared, persistence: persistence)
        try store.reload()
        XCTAssertNil(try persistence.babyObject(id: oldStarter.id))
        XCTAssertEqual(store.selectedID, shared.id)

        let sharedObject = try XCTUnwrap(persistence.babyObject(id: shared.id))
        persistence.container.viewContext.delete(sharedObject)
        try persistence.container.viewContext.save()
        try store.reload()

        let replacement = try XCTUnwrap(store.baby)
        XCTAssertTrue(store.ready)
        XCTAssertEqual(replacement.name, "Малыш")
        XCTAssertNotEqual(replacement.id, oldStarter.id)
        XCTAssertEqual(store.visibleBabies, [replacement])
        XCTAssertEqual(store.selectedID, replacement.id)
        XCTAssertTrue(store.redundantBabies.isEmpty)
        XCTAssertFalse(store.isSharedDiary)
        XCTAssertEqual(try persistence.babies(), [replacement])
        let replacementObject = try XCTUnwrap(persistence.babyObject(id: replacement.id))
        XCTAssertEqual(replacementObject.objectID.persistentStore, persistence.privateStore)
    }

    func testDefaultBabyRemainsVisibleWithoutSharedDiary() async {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        XCTAssertEqual(store.visibleBabies, store.babies)
        XCTAssertEqual(store.visibleBabies.count, 1)
        XCTAssertEqual(store.baby?.name, "Малыш")
        XCTAssertFalse(store.isSharedDiary)
    }

    func testDisabledCloudExplainsHowToAcceptInvitation() {
        let message = CloudFailure.message(for: Persistence.Failure.cloudDisabled)
        XCTAssertTrue(message.contains("Включите iCloud"))
        XCTAssertTrue(message.contains("перезапустите приложение"))
        XCTAssertFalse(message.contains("временно недоступен"))
    }

    func testLocalLoadAndMixedDiaperPersistAcrossStoreReload() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        XCTAssertTrue(store.ready)
        XCTAssertFalse(persistence.cloudEnabled)
        XCTAssertNil(store.errorMessage)
        let baby = try XCTUnwrap(store.baby)

        store.diaper(.mixed)
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertEqual(event.diaperType, .mixed)
        XCTAssertEqual(event.babyID, baby.id)

        let reloaded = AppStore(persistence: persistence)
        await reloaded.load()
        XCTAssertTrue(reloaded.ready)
        XCTAssertEqual(reloaded.baby?.id, baby.id)
        XCTAssertEqual(reloaded.events, [event])
        XCTAssertFalse(reloaded.persistence.cloudEnabled)
    }

    func testDuplicateTimerIsRejectedAndFinishedTimersPersist() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        store.start(.sleep)
        let sleep = try XCTUnwrap(store.active.first)
        store.start(.sleep)
        XCTAssertEqual(store.events.count, 1)
        XCTAssertNotNil(store.errorMessage)
        store.finish(sleep)
        XCTAssertTrue(store.active.isEmpty)
        XCTAssertNotNil(store.events.first?.end)

        store.start(.breast)
        let breast = try XCTUnwrap(store.active.first)
        XCTAssertEqual(breast.side, .left)
        store.switchSide(breast)
        let switched = try XCTUnwrap(store.active.first)
        XCTAssertEqual(switched.id, breast.id)
        XCTAssertEqual(switched.side, .right)
        store.finish(switched)
        XCTAssertTrue(store.active.isEmpty)
        try store.reload()
        XCTAssertEqual(store.events.count, 2)
        XCTAssertTrue(store.events.allSatisfy { $0.end != nil })
    }

    func testInvalidBottleVolumeNeverReachesPersistence() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let baby = try XCTUnwrap(store.baby)
        let invalid = CareEvent(babyID: baby.id, kind: .bottle, volumeML: 0)
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertTrue(store.events.isEmpty)
        XCTAssertTrue(try persistence.events(babyID: baby.id).isEmpty)
        try store.reload()
        XCTAssertTrue(store.events.isEmpty)
    }

    func testBackdatedPointEventUsesItsRecordedTime() async throws {
        let store = AppStore(persistence: Persistence(inMemory: true))
        await store.load()
        let baby = try XCTUnwrap(store.baby)
        let yesterday = Date().addingTimeInterval(-86400)
        for kind in [EventKind.bottle, .diaper] {
            let event = CareEvent(babyID: baby.id, kind: kind, start: yesterday, end: Date())
            try store.save(event)
            let saved = try XCTUnwrap(store.events.first { $0.id == event.id })
            XCTAssertEqual(saved.start, yesterday)
            XCTAssertEqual(saved.end, yesterday)
        }
    }

    func testFailedLoadCanBeRetriedWithoutDeletingData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("blocker".utf8).write(to: directory)
        let store = AppStore(persistence: Persistence(directory: directory))
        await store.load()
        XCTAssertFalse(store.ready)
        XCTAssertTrue(store.loadFailed)
        store.errorMessage = nil
        XCTAssertTrue(store.loadFailed)
        try FileManager.default.removeItem(at: directory)
        await store.load()
        XCTAssertTrue(store.ready)
        XCTAssertFalse(store.loadFailed)
        XCTAssertNotNil(store.baby)
    }
}
