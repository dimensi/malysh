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

    func testDiaryDeletionAndResetRemoveContentsAndCreateNewStarter() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let starter = try XCTUnwrap(store.baby)
        let named = Baby(name: "Тестовый")
        try persistence.saveBaby(named)
        let event = CareEvent(babyID: starter.id, kind: .diaper, end: Date(), diaperType: .wet)
        try persistence.saveEvent(event)
        let photo = BabyPhoto(babyID: named.id, capturedAt: Date(), addedBy: "owner", pixelWidth: 20, pixelHeight: 30)
        try persistence.savePhoto(photo, imageData: Data([1]), thumbnailData: Data([2]))
        let measurement = ChildMeasurement(babyID: named.id, type: .weight, measuredAt: Date(), value: 4)
        try persistence.saveMeasurement(measurement)
        try store.reload()
        store.select(named.id)

        try await store.removeDiaries(.one(named.id, invited: false))
        XCTAssertEqual(store.selectedID, starter.id)
        XCTAssertEqual(store.events.map(\.id), [event.id])
        XCTAssertNil(try persistence.photoData(id: photo.id))
        XCTAssertTrue(try persistence.measurements(babyID: named.id).isEmpty)

        try await store.removeDiaries(.all)
        let replacement = try XCTUnwrap(store.baby)
        XCTAssertNotEqual(replacement.id, starter.id)
        XCTAssertEqual(try persistence.babies(), [replacement])
        XCTAssertTrue(try persistence.events(babyID: starter.id).isEmpty)
        XCTAssertTrue(store.events.isEmpty)
    }

    func testOfflineResetAndRemovalPreserveInvitedDiaryAndOwnedData() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let owned = Baby(name: "Личный")
        try persistence.saveBaby(owned)
        let invited = Baby(name: "Семейный")
        try insertSharedBaby(invited, persistence: persistence)
        let event = CareEvent(babyID: invited.id, kind: .diaper, end: Date(), diaperType: .wet)
        try persistence.saveEvent(event)
        try store.reload()

        for removal in [AppStore.DiaryRemoval.one(invited.id, invited: false), .one(invited.id, invited: true), .all] {
            do {
                try await store.removeDiaries(removal)
                XCTFail("Удаление чужого дневника без iCloud должно быть заблокировано")
            } catch is Persistence.Failure {}
        }
        XCTAssertEqual(Set(store.babies.map(\.id)), [owned.id, invited.id])
        XCTAssertEqual(try persistence.events(babyID: invited.id).map(\.id), [event.id])
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

    func testSharedImportKeepsCustomizedStarter() async throws {
        enum Customization: CaseIterable { case birthday, measurement, parentProfile }
        for customization in Customization.allCases {
            let persistence = Persistence(inMemory: true)
            let store = AppStore(persistence: persistence)
            await store.load()
            var starter = try XCTUnwrap(store.baby)
            switch customization {
            case .birthday:
                starter.birthDateConfirmed = true
                try persistence.saveBaby(starter)
            case .measurement:
                try persistence.saveMeasurement(ChildMeasurement(babyID: starter.id, type: .height, value: 50))
            case .parentProfile:
                try store.saveFamilyProfile(babyID: starter.id, memberID: "owner", name: "Никита", role: .father)
            }
            try insertSharedBaby(Baby(name: "Общий"), persistence: persistence)
            try store.reload()
            XCTAssertNotNil(try persistence.babyObject(id: starter.id))
            XCTAssertTrue(store.visibleBabies.contains { $0.id == starter.id })
            XCTAssertTrue(store.redundantBabies.isEmpty)
        }
    }

    func testBirthMeasurementsSaveAnyKnownSubsetAndRejectStaleReplay() async throws {
        let inputs: [[MeasurementType: Double]] = [
            [.weight: 3500],
            [.weight: 3500, .height: 52.5],
            [.weight: 3500, .height: 52.5, .headCircumference: 35],
        ]
        for values in inputs {
            let persistence = Persistence(inMemory: true)
            let store = AppStore(persistence: persistence)
            await store.load()
            let original = try XCTUnwrap(store.baby)
            let birthDate = Date(timeIntervalSinceNow: -86400)
            let calendar = Calendar.current
            let morning = try XCTUnwrap(calendar.date(bySettingHour: 7, minute: 23, second: 0, of: birthDate))
            let birthTime = values.count > 1 ? CivilTime(date: morning) : nil
            try store.updateChildProfile(
                babyID: original.id, name: original.name, birthDate: birthDate,
                birthDateConfirmed: true, birthTime: birthTime, replacing: original, birthMeasurements: values
            )
            let saved = try XCTUnwrap(store.baby)
            XCTAssertTrue(saved.birthMeasurementsCompleted)
            XCTAssertEqual(saved.birthTime, birthTime)
            let measurements = store.measurements
            XCTAssertEqual(measurements.count, values.count)
            for measurement in measurements {
                XCTAssertEqual(measurement.value, values[measurement.type])
                XCTAssertEqual(measurement.measuredAt, birthTime == nil ? calendar.startOfDay(for: birthDate) : morning)
            }

            XCTAssertThrowsError(try store.updateChildProfile(
                babyID: saved.id, name: saved.name, birthDate: birthDate,
                birthDateConfirmed: true, birthTime: birthTime, replacing: saved, birthMeasurements: values
            )) { XCTAssertEqual($0 as? ChildProfileError, .conflict) }
            try store.updateChildProfile(
                babyID: saved.id, name: "Новое имя", birthDate: birthDate.addingTimeInterval(-86400),
                birthDateConfirmed: true, replacing: saved
            )
            XCTAssertTrue(try XCTUnwrap(store.baby).birthMeasurementsCompleted)
            XCTAssertNil(store.baby?.birthTime)
            XCTAssertEqual(store.measurements, measurements)
        }
    }

    func testBirthMeasurementsNeedConfirmationAndCanBeSkippedWithoutBirthDate() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        await store.load()
        let original = try XCTUnwrap(store.baby)
        XCTAssertThrowsError(try store.updateChildProfile(
            babyID: original.id, name: "Новое имя", birthDate: original.birthDate,
            birthDateConfirmed: false, replacing: original, birthMeasurements: [.weight: 3500]
        )) { XCTAssertEqual($0 as? ChildProfileError, .missingConfirmedBirthday) }
        XCTAssertEqual(try persistence.babies(), [original])

        try store.updateChildProfile(
            babyID: original.id, name: "Новое имя", birthDate: original.birthDate,
            birthDateConfirmed: false, replacing: original
        )
        let saved = try XCTUnwrap(store.baby)
        XCTAssertEqual(saved.name, "Новое имя")
        XCTAssertFalse(saved.birthMeasurementsCompleted)
        XCTAssertTrue(store.measurements.isEmpty)

        try store.updateChildProfile(
            babyID: saved.id, name: saved.name, birthDate: saved.birthDate,
            birthDateConfirmed: false, replacing: saved, skipBirthMeasurements: true
        )
        let relaunched = AppStore(persistence: persistence)
        await relaunched.load()
        XCTAssertTrue(try XCTUnwrap(relaunched.baby).birthMeasurementsCompleted)
        XCTAssertFalse(try XCTUnwrap(relaunched.baby).birthDateConfirmed)
        XCTAssertTrue(relaunched.measurements.isEmpty)
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
}
