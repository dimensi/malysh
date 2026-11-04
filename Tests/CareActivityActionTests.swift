import Foundation
@testable import Malysh
import XCTest

@MainActor
final class CareActivityActionTests: XCTestCase {
    func testIntentPerformLoadsDiaryMutatesPersistenceAndFlushes() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        let baby = Baby(name: "Малыш")
        try persistence.saveBaby(baby)
        let event = CareEvent(babyID: baby.id, kind: .breast, start: Date().addingTimeInterval(-60))
        try persistence.saveEvent(event)
        let coordinator = RecordingCareCoordinator()
        let runtime = CareActivityRuntime(persistence: persistence, coordinator: coordinator)
        XCTAssertFalse(runtime.store.ready)
        try await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            _ = try await SwitchCareSideIntent(eventID: event.id, babyID: baby.id, side: "right").perform()
            _ = try await FinishCareActivityIntent(eventID: event.id, babyID: baby.id).perform()
        }
        let saved = try XCTUnwrap(persistence.events(babyID: baby.id).first)
        XCTAssertTrue(runtime.store.ready)
        XCTAssertEqual(saved.side, .right)
        XCTAssertNotNil(saved.end)
        XCTAssertEqual(coordinator.flushes, 2)
        XCTAssertTrue(coordinator.allowStart)
    }

    func testDeletedEventIntentReconcilesAndFlushesBeforeThrowing() async throws {
        let coordinator = RecordingCareCoordinator()
        let runtime = CareActivityRuntime(persistence: Persistence(inMemory: true), coordinator: coordinator)
        await runtime.ensureReady()
        runtime.store.start(.breast)
        let event = try XCTUnwrap(runtime.store.active.first)
        // Simulate an imported deletion before the UI's remote-change callback runs.
        try runtime.store.persistence.deleteEvent(id: event.id)
        XCTAssertTrue(runtime.store.active.contains { $0.id == event.id })
        var failed = false
        await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            do {
                _ = try await FinishCareActivityIntent(eventID: event.id, babyID: event.babyID).perform()
            } catch {
                failed = true
            }
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(coordinator.events.contains { $0.id == event.id })
        XCTAssertEqual(coordinator.flushes, 1)
        XCTAssertTrue(try runtime.store.persistence.events(babyID: event.babyID).isEmpty)
    }

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

    func testWrongKindAndUnavailableStoreFailWithoutSaving() async throws {
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence)
        XCTAssertThrowsError(try store.finish(eventID: UUID(), babyID: UUID()))
        await store.load()
        let babyID = try XCTUnwrap(store.baby?.id)
        let bottle = CareEvent(babyID: babyID, kind: .bottle)
        try store.save(bottle)
        XCTAssertThrowsError(try store.finish(eventID: bottle.id, babyID: babyID))
        store.start(.sleep)
        let sleep = try XCTUnwrap(store.active.first)
        XCTAssertThrowsError(try store.switchSide(eventID: sleep.id, babyID: babyID, to: .right))
        XCTAssertEqual(store.events.count, 2)
        XCTAssertNil(store.active.first?.end)
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

    func testReconciliationIncludesOtherDiariesAndOnlyFollowsSuccessfulSave() async throws {
        let coordinator = RecordingCareCoordinator()
        let store = AppStore(persistence: Persistence(inMemory: true), activityCoordinator: coordinator)
        store.allowsActivityStart = { true }
        await store.load()
        store.start(.breast)
        store.start(.sleep)
        let eventIDs = Set(store.active.map(\.id))
        let other = Baby(name: "Другой малыш")
        try store.persistence.saveBaby(other)
        store.select(other.id)
        XCTAssertEqual(Set(coordinator.events.filter { $0.end == nil }.map(\.id)), eventIDs)
        XCTAssertTrue(coordinator.allowStart)
        let previousCalls = coordinator.calls
        XCTAssertThrowsError(try store.save(CareEvent(babyID: other.id, kind: .bottle, volumeML: 0)))
        XCTAssertEqual(coordinator.calls, previousCalls)
        XCTAssertEqual(coordinator.babies.count, 2)
    }
}

@MainActor
private final class RecordingCareCoordinator: CareActivityCoordinating {
    var events: [CareEvent] = []
    var babies: [Baby] = []
    var allowStart = false
    var calls = 0
    var flushes = 0

    func reconcile(events: [CareEvent], babies: [Baby], allowStart: Bool) {
        self.events = events
        self.babies = babies
        self.allowStart = allowStart
        calls += 1
    }

    func flush() async {
        flushes += 1
    }
}
