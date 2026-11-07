import CoreData
import Foundation
@testable import Malysh
import XCTest

@MainActor
final class CareActivityActionTests: XCTestCase {
    // FR: A cold notification response waits for the local diary and its replacement request.
    func testColdSnoozeUsesLatestPersistedFeedingBeforeReturning() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "feeding-reminder-runtime-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = IsolatedFeedingReminderScheduler(authorization: .allowed)
        let firstFeeding = Date(timeIntervalSinceReferenceDate: 810_000_000)
        let setup = Persistence(directory: directory)
        let service = FeedingReminderService(defaults: defaults, scheduler: scheduler, now: { firstFeeding })
        let first = CareActivityRuntime(
            persistence: setup,
            coordinator: RecordingCareCoordinator(),
            feedingReminders: service
        )
        await first.ensureReady(checkCloudAccount: false)
        try first.store.createFirstDiary(name: "Малыш", birthDate: nil)
        let babyID = try XCTUnwrap(first.store.selectedID)
        try first.store.save(CareEvent(babyID: babyID, kind: .bottle, start: firstFeeding))
        service.setEnabled(true)
        await service.flush()
        let previous = try XCTUnwrap(scheduler.pending)

        // Simulate a newly imported feeding without going through the first AppStore.
        let latestFeeding = previous.due.addingTimeInterval(-30 * 60)
        try setup.saveEvent(CareEvent(babyID: babyID, kind: .bottle, start: latestFeeding, end: latestFeeding))
        let reopened = CareActivityRuntime(
            persistence: Persistence(directory: directory), coordinator: RecordingCareCoordinator(),
            feedingReminders: FeedingReminderService(defaults: defaults, scheduler: scheduler, now: { previous.due })
        )
        await reopened.snoozeFeedingReminder(token: previous.token, babyID: babyID)

        let replacement = try XCTUnwrap(scheduler.pending)
        XCTAssertNotEqual(replacement.token, previous.token)
        XCTAssertEqual(replacement.due, latestFeeding.addingTimeInterval(180 * 60))
    }

    // FR: Both side buttons share one durable command, and the old card cannot restart it.
    func testReminderIntentStartsOnePersistedTimerAndIgnoresOppositeSideReplay() async throws {
        let suite = "feeding-reminder-runtime-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scheduler = IsolatedFeedingReminderScheduler(authorization: .denied, liveActivitiesEnabled: true)
        let coordinator = RecordingCareCoordinator()
        let start = Date().addingTimeInterval(-180 * 60)
        var now = start
        let service = FeedingReminderService(defaults: defaults, scheduler: scheduler, now: { now })
        let runtime = CareActivityRuntime(persistence: Persistence(inMemory: true), coordinator: coordinator,
                                          feedingReminders: service)
        await runtime.ensureReady(checkCloudAccount: false)
        try runtime.store.createFirstDiary(name: "Малыш", birthDate: nil)
        let babyID = try XCTUnwrap(runtime.store.selectedID)
        try runtime.store.save(CareEvent(babyID: babyID, kind: .bottle, start: start))
        service.setEnabled(true)
        await service.flush()
        let reminder = try XCTUnwrap(scheduler.activityRequest)
        let eventID = try XCTUnwrap(UUID(uuidString: reminder.token))
        now = reminder.due
        scheduler.showScheduledActivity()

        try await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            _ = try await StartFeedingFromReminderIntent(token: reminder.token, babyID: babyID, side: .left).perform()
            _ = try await StartFeedingFromReminderIntent(token: reminder.token, babyID: babyID, side: .right).perform()
            let stored = try runtime.store.persistence.events(babyID: babyID).filter { $0.kind == .breast }
            XCTAssertEqual(stored.map(\.id), [eventID])
            let active = try XCTUnwrap(stored.first)
            XCTAssertEqual(active.side, .left)
            XCTAssertNil(active.end)
            XCTAssertNil(scheduler.activityRequest)
            XCTAssertTrue(coordinator.allowStart)
            XCTAssertTrue(coordinator.events.contains { $0.id == eventID && $0.end == nil })

            try runtime.store.delete(active)
            _ = try await StartFeedingFromReminderIntent(token: reminder.token, babyID: babyID, side: .right).perform()
            XCTAssertFalse(try runtime.store.persistence.events(babyID: babyID).contains { $0.kind == .breast })
        }
    }

    func testCapturedSleepControlReplayCannotToggleOrFinishNewerTimer() async throws {
        let runtime = CareActivityRuntime(
            persistence: Persistence(inMemory: true),
            coordinator: RecordingCareCoordinator()
        )
        await runtime.ensureReady()
        try runtime.store.createFirstDiary(name: "Малыш", birthDate: nil)
        let babyID = try XCTUnwrap(runtime.store.baby?.id)
        try await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            let start = SleepCareControlIntent(babyID: babyID, commandID: UUID(), eventID: nil)
            _ = try await start.perform()
            _ = try await start.perform()
            let sleep = try XCTUnwrap(runtime.store.active.first { $0.kind == .sleep })
            let stop = SleepCareControlIntent(babyID: babyID, commandID: UUID(), eventID: sleep.id)
            _ = try await stop.perform()
            _ = try await stop.perform()
            XCTAssertTrue(runtime.store.active.isEmpty)
            _ = try await SleepCareControlIntent(babyID: babyID, commandID: UUID(), eventID: nil).perform()
            let newer = try XCTUnwrap(runtime.store.active.first)
            XCTAssertNotEqual(newer.id, sleep.id)
            _ = try await stop.perform()
            XCTAssertEqual(runtime.store.active.first?.id, newer.id)
        }
    }

    func testWidgetCommandsUseExactDiaryAndSurviveReplayAfterDeletion() async throws {
        let persistence = Persistence(inMemory: true)
        let runtime = CareActivityRuntime(persistence: persistence, coordinator: RecordingCareCoordinator())
        await runtime.ensureReady()
        try runtime.store.createFirstDiary(name: "Малыш", birthDate: nil)
        let babyID = try XCTUnwrap(runtime.store.baby?.id)
        let other = Baby(name: "Другой")
        try persistence.saveBaby(other)
        runtime.store.select(other.id)
        let command = UUID()
        try await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            let intent = WidgetCareIntent(babyID: babyID, commandID: command, action: .wetDiaper)
            _ = try await intent.perform()
            _ = try await intent.perform()
        }
        XCTAssertEqual(try persistence.events(babyID: babyID).map(\.id), [command])
        XCTAssertTrue(try persistence.events(babyID: other.id).isEmpty)
        try persistence.deleteEvent(id: command)
        let restarted = AppStore(persistence: persistence)
        await restarted.load()
        try restarted.recordWidgetAction(.wetDiaper, babyID: babyID, commandID: command)
        XCTAssertTrue(try persistence.events(babyID: babyID).isEmpty)
    }

    func testReadOnlyCoreDataSaveFailureThrowsAndDoesNotConsumeCommand() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bootstrap = Persistence(directory: directory)
        try await bootstrap.load()
        let baby = Baby(name: "Малыш")
        try bootstrap.saveBaby(baby)
        func detach(_ persistence: Persistence) throws {
            persistence.container.viewContext.reset()
            for store in persistence.container.persistentStoreCoordinator.persistentStores {
                try persistence.container.persistentStoreCoordinator.remove(store)
            }
        }
        try detach(bootstrap)
        let readOnly = Persistence(directory: directory)
        for description in readOnly.container.persistentStoreDescriptions {
            description.setOption(true as NSNumber, forKey: NSReadOnlyPersistentStoreOption)
        }
        let coordinator = RecordingCareCoordinator()
        let runtime = CareActivityRuntime(persistence: readOnly, coordinator: coordinator)
        await runtime.ensureReady()
        XCTAssertTrue(runtime.store.ready)
        let command = UUID()
        var failure: Error?
        await CareActivityRuntime.$actionRuntime.withValue(runtime) {
            do {
                _ = try await WidgetCareIntent(babyID: baby.id, commandID: command, action: .wetDiaper).perform()
            } catch {
                failure = error
            }
        }
        let error = try XCTUnwrap(failure) as NSError
        XCTAssertEqual(error.domain, NSCocoaErrorDomain)
        XCTAssertFalse(failure is EventValidationError)
        XCTAssertFalse(readOnly.container.viewContext.hasChanges, "Failed save must roll back inserted events")
        XCTAssertTrue(try readOnly.events(babyID: baby.id).isEmpty)
        XCTAssertTrue(runtime.store.events.isEmpty)
        XCTAssertEqual(coordinator.flushes, 1)
        XCTAssertFalse((UserDefaults.standard.stringArray(forKey: "widgetCommands.\(baby.id.uuidString)") ?? [])
            .contains(command.uuidString))
        try detach(readOnly)
        let writable = Persistence(directory: directory)
        let restored = CareActivityRuntime(persistence: writable, coordinator: RecordingCareCoordinator())
        try await restored.recordWidgetAction(.wetDiaper, babyID: baby.id, commandID: command)
        XCTAssertEqual(try writable.events(babyID: baby.id).map(\.id), [command])
        try detach(writable)
    }

    func testWidgetStartsRejectSecondActiveTimerAndWrongDiary() async throws {
        let store = AppStore(persistence: Persistence(inMemory: true))
        await store.load()
        try store.createFirstDiary(name: "Малыш", birthDate: nil)
        let babyID = try XCTUnwrap(store.baby?.id)
        try store.recordWidgetAction(.startBreastRight, babyID: babyID, commandID: UUID())
        let staleStart = UUID()
        try store.recordWidgetAction(.startBreastLeft, babyID: babyID, commandID: staleStart)
        try store.recordWidgetAction(.startSleep, babyID: babyID, commandID: UUID())
        XCTAssertEqual(store.active.count, 2)
        XCTAssertEqual(store.active.first { $0.kind == .breast }?.side, .right)
        XCTAssertThrowsError(try store.recordWidgetAction(.dirtyDiaper, babyID: UUID(), commandID: UUID()))
        XCTAssertEqual(store.events.count, 2)
        let breast = try XCTUnwrap(store.active.first { $0.kind == .breast })
        try store.finish(eventID: breast.id, babyID: babyID)
        try store.recordWidgetAction(.startBreastLeft, babyID: babyID, commandID: staleStart)
        XCTAssertFalse(store.active.contains { $0.kind == .breast })
    }

    func testActionsUseLatestPersistedSideAndDuplicateRequestsAreIdempotent() async throws {
        let store = AppStore(persistence: Persistence(inMemory: true))
        await store.load()
        try store.createFirstDiary(name: "Малыш", birthDate: nil)
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
        try store.createFirstDiary(name: "Малыш", birthDate: nil)
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
        try initial.createFirstDiary(name: "Малыш", birthDate: nil)
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
