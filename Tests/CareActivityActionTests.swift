import Foundation
@testable import Malysh
import XCTest

@MainActor
final class CareActivityActionTests: XCTestCase {
    func testActionsUseLatestPersistedSideAndDuplicateRequestsAreIdempotent() async throws {
        let store = AppStore(persistence: Persistence(inMemory: true))
        await store.load()
        let babyID = try XCTUnwrap(store.baby?.id)
        let start = Date().addingTimeInterval(-120)
        let event = CareEvent(babyID: babyID, kind: .breast, start: start)
        try store.save(event)
        try store.switchSide(eventID: event.id, babyID: babyID, to: .right, at: start.addingTimeInterval(30))
        try store.switchSide(eventID: event.id, babyID: babyID, to: .right, at: start.addingTimeInterval(50))
        try store.finish(eventID: event.id, babyID: babyID, at: start.addingTimeInterval(90))
        try store.finish(eventID: event.id, babyID: babyID, at: start.addingTimeInterval(100))
        try store.switchSide(eventID: event.id, babyID: babyID, to: .left)
        let saved = try XCTUnwrap(store.events.first)
        XCTAssertEqual(saved.leftSeconds, 30)
        XCTAssertEqual(saved.rightSeconds, 60)
        XCTAssertEqual(saved.end, start.addingTimeInterval(90))
        XCTAssertEqual(saved.side, .right)
    }

    func testDeletedAndWrongDiaryActionsCannotRecreateEvents() async throws {
        let store = AppStore(persistence: Persistence(inMemory: true))
        await store.load()
        store.start(.breast)
        let event = try XCTUnwrap(store.active.first)
        XCTAssertThrowsError(try store.finish(eventID: event.id, babyID: UUID()))
        XCTAssertThrowsError(try store.switchSide(eventID: event.id, babyID: UUID(), to: .right))
        try store.delete(event)
        XCTAssertThrowsError(try store.finish(eventID: event.id, babyID: event.babyID))
        XCTAssertThrowsError(try store.switchSide(eventID: event.id, babyID: event.babyID, to: .right))
        XCTAssertTrue(try store.persistence.events(babyID: event.babyID).isEmpty)
    }

    func testRestartRestoresTwoTimersAndActionsIgnoreSelectedDiary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var firstStore: AppStore? = AppStore(persistence: Persistence(directory: directory))
        await firstStore?.load()
        let initial = try XCTUnwrap(firstStore)
        initial.start(.breast)
        initial.start(.sleep)
        let babyID = try XCTUnwrap(initial.baby?.id)
        let breast = try XCTUnwrap(initial.active.first { $0.kind == .breast })
        let sleep = try XCTUnwrap(initial.active.first { $0.kind == .sleep })
        let other = Baby(name: "Другой малыш")
        try initial.persistence.saveBaby(other)
        initial.select(other.id)
        XCTAssertTrue(initial.active.isEmpty)
        firstStore = nil
        let restored = AppStore(persistence: Persistence(directory: directory))
        await restored.load()
        XCTAssertEqual(restored.selectedID, other.id)
        try restored.finish(eventID: sleep.id, babyID: babyID)
        try restored.switchSide(eventID: breast.id, babyID: babyID, to: .right)
        let persisted = try restored.persistence.events(babyID: babyID)
        XCTAssertNotNil(persisted.first { $0.id == sleep.id }?.end)
        XCTAssertEqual(persisted.first { $0.id == breast.id }?.side, .right)
        XCTAssertTrue(restored.events.isEmpty)
    }
}
