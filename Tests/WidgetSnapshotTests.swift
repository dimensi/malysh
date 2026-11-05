@testable import Malysh
import XCTest

final class WidgetSnapshotTests: XCTestCase {
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
