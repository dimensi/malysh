@testable import Malysh
import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testFullHistoryPreservesDiaperAnchorsAlongsideFeedAndSleep() {
        let baby = Baby(name: "Малыш")
        let now = Date()
        let old = now.addingTimeInterval(-20 * 86400)
        let wet = CareEvent(babyID: baby.id, kind: .diaper, start: old, diaperType: .mixed)
        let dirty = CareEvent(babyID: baby.id, kind: .diaper, start: old.addingTimeInterval(60), diaperType: .dirty)
        let sleep = CareEvent(babyID: baby.id, kind: .sleep, start: old, end: old.addingTimeInterval(3600))
        let bottles = (0 ..< WidgetSnapshot.historyLimit).map { index in
            CareEvent(babyID: baby.id, kind: .bottle, start: now.addingTimeInterval(-Double(index)))
        }
        let snapshot = WidgetSnapshot(baby: baby, events: bottles + [wet, dirty, sleep], generatedAt: now)
        XCTAssertEqual(snapshot.events.count, WidgetSnapshot.historyLimit)
        XCTAssertEqual(Set(snapshot.events.map(\.id)).count, WidgetSnapshot.historyLimit)
        XCTAssertEqual(snapshot.summary(at: now).lastFeeding?.id, bottles.first?.id)
        XCTAssertEqual(snapshot.summary(at: now).lastSleep?.id, sleep.id)
        XCTAssertEqual(snapshot.summary(at: now).lastWetDiaper?.id, wet.id)
        XCTAssertEqual(snapshot.events.first { $0.kind == .diaper && $0.diaperType == .dirty }?.id, dirty.id)
        XCTAssertEqual(snapshot.summary(at: now).recentEvents.map(\.id), Array(bottles.prefix(3)).map(\.id))
    }

    func testActiveTimersAndConfirmedBirthdayRoundTripAndLegacyDecode() throws {
        let now = Date()
        let baby = Baby(name: "Малыш", birthDate: now.addingTimeInterval(-86400), birthDateConfirmed: true)
        let event = CareEvent(babyID: baby.id, kind: .breast, start: now.addingTimeInterval(-60), side: .right)
        let finished = CareEvent(babyID: baby.id, kind: .breast, start: now.addingTimeInterval(-1200),
                                 end: now.addingTimeInterval(-600), side: .right)
        let snapshot = WidgetSnapshot(baby: baby, events: [event, finished], generatedAt: now)
        XCTAssertEqual(snapshot.activeEvents.first?.id, event.id)
        XCTAssertEqual(snapshot.activeEvents.first?.sideStartedAt, event.start)
        XCTAssertEqual(snapshot.birthDate, baby.birthDate)
        XCTAssertEqual(snapshot.birthDay, baby.birthDay)
        XCTAssertNotEqual(snapshot.commandID(for: .wetDiaper), snapshot.commandID(for: .dirtyDiaper))
        let encoded = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(WidgetSnapshot.self, from: encoded)
        XCTAssertEqual(restored.summary(at: now).lastFeeding?.side, .right)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var completed = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(completed.count, 1)
        completed[0].removeValue(forKey: "side")
        json["events"] = completed
        for key in ["birthDate", "birthDay", "activeEventValues", "actionToken"] {
            json.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.activeEvents.isEmpty)
        XCTAssertNil(legacy.birthDate)
        XCTAssertEqual(legacy.summary(at: now).lastFeeding?.id, finished.id)
        XCTAssertNil(legacy.summary(at: now).lastFeeding?.side)
        XCTAssertNil(WidgetSnapshot(baby: Baby(name: "Legacy"), events: []).birthDate)
    }

    @MainActor
    func testFailedStaleWidgetActionPublishesReconciledSnapshotAndReleasesBatch() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WidgetSnapshotStore(directory: directory)
        let store = AppStore(persistence: Persistence(inMemory: true), widgetSnapshotStore: cache)
        await store.load()
        store.start(.breast)
        let event = try XCTUnwrap(store.active.first)
        XCTAssertEqual(try cache.read()?.activeEvents.first?.id, event.id)
        try store.persistence.deleteEvent(id: event.id)
        XCTAssertThrowsError(try store.finish(eventID: event.id, babyID: event.babyID))
        XCTAssertTrue(try XCTUnwrap(cache.read()).activeEvents.isEmpty)
        let command = UUID()
        try store.recordWidgetAction(.wetDiaper, babyID: event.babyID, commandID: command)
        XCTAssertEqual(try cache.read()?.events.map(\.id), [command])
    }

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testCompletedEventsOnlyAndPrivateFieldsAreNotSerialized() throws {
        let baby = Baby(name: "Малыш")
        let now = date("2026-11-04T12:00:00Z")
        let start = now.addingTimeInterval(-3600)
        let events = [
            CareEvent(babyID: baby.id, kind: .breast, start: start, note: "SECRET"),
            CareEvent(babyID: baby.id, kind: .sleep, start: start),
            CareEvent(babyID: baby.id, kind: .bottle, start: start, end: start, note: "SECRET"),
            CareEvent(babyID: baby.id, kind: .diaper, start: start, end: start, diaperType: .mixed),
            CareEvent(babyID: UUID(), kind: .bottle, start: start, end: start),
        ]
        let snapshot = WidgetSnapshot(baby: baby, events: events, generatedAt: now)
        let summary = snapshot.summary(at: now, calendar: calendar())
        XCTAssertEqual(snapshot.events.count, 2)
        XCTAssertEqual(summary.feeds, 1)
        XCTAssertEqual(summary.wetDiapers, 1)
        XCTAssertEqual(summary.sleepSeconds, 0)
        XCTAssertEqual(summary.lastFeeding?.kind, .bottle)
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        XCTAssertFalse(json.contains("SECRET"))
        XCTAssertFalse(json.contains("parentProfiles"))
        XCTAssertFalse(json.contains("note"))
    }

    @MainActor
    func testOfflineDiskRelaunchRebuildsDeletedCacheFromSQLite() async throws {
        let previousSelection = UserDefaults.standard.object(forKey: "selectedBaby")
        defer { UserDefaults.standard.set(previousSelection, forKey: "selectedBaby") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("Database")
        let widgetDirectory = root.appendingPathComponent("Widgets")
        let cache = WidgetSnapshotStore(directory: widgetDirectory)
        let original = Persistence(directory: database, cloudEnabled: false)
        let store = AppStore(persistence: original, widgetSnapshotStore: cache)
        await store.load()
        let baby = try XCTUnwrap(store.baby)
        let start = Date().addingTimeInterval(-600)
        let feed = CareEvent(babyID: baby.id, kind: .bottle, start: start, end: start, volumeML: 110)
        try store.save(feed)
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: database.appendingPathComponent("Malysh-private.sqlite").path))
        original.container.viewContext.reset()
        for persistentStore in original.container.persistentStoreCoordinator.persistentStores {
            try original.container.persistentStoreCoordinator.remove(persistentStore)
        }
        try FileManager.default.removeItem(at: widgetDirectory)
        XCTAssertNil(try cache.read())
        let reopened = Persistence(directory: database, cloudEnabled: false)
        let relaunched = AppStore(persistence: reopened, widgetSnapshotStore: cache)
        await relaunched.load()
        XCTAssertTrue(relaunched.ready)
        XCTAssertFalse(reopened.cloudEnabled)
        XCTAssertEqual(relaunched.baby?.id, baby.id)
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.id, feed.id)
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.volumeML, 110)
    }

    @MainActor
    func testSnapshotFollowsSelectedDiaryAcrossRelaunch() async throws {
        let previousSelection = UserDefaults.standard.object(forKey: "selectedBaby")
        defer { UserDefaults.standard.set(previousSelection, forKey: "selectedBaby") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WidgetSnapshotStore(directory: directory)
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence, widgetSnapshotStore: cache)
        await store.load()
        let baby = try XCTUnwrap(store.baby)
        XCTAssertEqual(try cache.read()?.babyID, baby.id)
        let other = Baby(name: "Другой")
        try persistence.saveBaby(other)
        let event = CareEvent(babyID: other.id, kind: .diaper, start: Date().addingTimeInterval(-60), end: Date())
        try persistence.saveEvent(event)
        try store.reload()
        store.select(other.id)
        XCTAssertEqual(try cache.read()?.babyID, other.id)
        XCTAssertEqual(try cache.read()?.events.map(\.id), [event.id])

        let relaunched = AppStore(persistence: persistence, widgetSnapshotStore: cache)
        await relaunched.load()
        XCTAssertEqual(relaunched.selectedID, other.id)
        XCTAssertEqual(try cache.read()?.babyID, other.id)
    }
}
