@testable import Malysh
import XCTest

@MainActor
final class AppStoreTests: XCTestCase {
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
