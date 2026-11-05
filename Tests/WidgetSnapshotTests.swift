@testable import Malysh
import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testQuietDiaryRetainsLastWetOrMixedAndDirtyDiapersBehindRecentBottles() {
        let baby = Baby(name: "Малыш")
        let now = Date()
        let old = now.addingTimeInterval(-20 * 86400)
        for wetType in [DiaperType.wet, .mixed] {
            let wet = CareEvent(babyID: baby.id, kind: .diaper, start: old, diaperType: wetType)
            let dirty = CareEvent(babyID: baby.id, kind: .diaper, start: old.addingTimeInterval(60), diaperType: .dirty)
            let bottles = (0 ..< 3).map { index in
                CareEvent(babyID: baby.id, kind: .bottle, start: now.addingTimeInterval(-Double(index) * 3600))
            }
            let snapshot = WidgetSnapshot(baby: baby, events: [wet, dirty] + bottles, generatedAt: now)
            XCTAssertEqual(snapshot.summary(at: now).lastWetDiaper?.id, wet.id)
            XCTAssertEqual(snapshot.events.first { $0.kind == .diaper }?.id, dirty.id)
            XCTAssertEqual(snapshot.events.first { $0.kind == .diaper && $0.diaperType == .dirty }?.id, dirty.id)
            XCTAssertEqual(snapshot.summary(at: now).recentEvents.map(\.id), bottles.map(\.id))
            XCTAssertEqual(snapshot.summary(at: now).wetDiapers, 0)
        }
    }

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

    func testFullHistoryPreservesBothOldFeedAndSleepAnchors() {
        let baby = Baby(name: "Малыш")
        let now = Date()
        let old = now.addingTimeInterval(-20 * 86400)
        let feed = CareEvent(babyID: baby.id, kind: .bottle, start: old, end: old)
        let sleep = CareEvent(babyID: baby.id, kind: .sleep, start: old, end: old.addingTimeInterval(3600))
        let diapers = (0 ..< WidgetSnapshot.historyLimit).map { index in
            CareEvent(babyID: baby.id, kind: .diaper, start: now.addingTimeInterval(-Double(index)))
        }
        let snapshot = WidgetSnapshot(baby: baby, events: diapers + [feed, sleep], generatedAt: now)
        XCTAssertEqual(snapshot.events.count, WidgetSnapshot.historyLimit)
        XCTAssertEqual(snapshot.summary(at: now).lastFeeding?.id, feed.id)
        XCTAssertEqual(snapshot.summary(at: now).lastSleep?.id, sleep.id)
        XCTAssertEqual(snapshot.summary(at: now).recentEvents.map(\.id), Array(diapers.prefix(3)).map(\.id))
    }

    func testQuietDiaryRetainsLastSleepBeyondHistoryWindow() {
        let baby = Baby(name: "Малыш")
        let now = Date()
        let old = now.addingTimeInterval(-20 * 86400)
        let sleep = CareEvent(babyID: baby.id, kind: .sleep, start: old, end: old.addingTimeInterval(3600))
        let newer = (1 ... 4).map { index in
            CareEvent(babyID: baby.id, kind: .diaper, start: old.addingTimeInterval(Double(index) * 7200))
        }
        let snapshot = WidgetSnapshot(baby: baby, events: [sleep] + newer, generatedAt: now)
        XCTAssertEqual(snapshot.summary(at: now).lastSleep?.id, sleep.id)
        XCTAssertEqual(snapshot.summary(at: now).sleepSeconds, 0)
    }

    func testActiveTimersAndConfirmedBirthdayRoundTripAndLegacyDecode() throws {
        let now = Date()
        let baby = Baby(name: "Малыш", birthDate: now.addingTimeInterval(-86400), birthDateConfirmed: true)
        let event = CareEvent(babyID: baby.id, kind: .breast, start: now.addingTimeInterval(-60), side: .right)
        let snapshot = WidgetSnapshot(baby: baby, events: [event], generatedAt: now)
        XCTAssertEqual(snapshot.activeEvents.first?.id, event.id)
        XCTAssertEqual(snapshot.activeEvents.first?.sideStartedAt, event.start)
        XCTAssertEqual(snapshot.birthDate, baby.birthDate)
        XCTAssertEqual(snapshot.birthDay, baby.birthDay)
        XCTAssertEqual(snapshot.commandID(for: .wetDiaper), snapshot.commandID(for: .wetDiaper))
        XCTAssertNotEqual(snapshot.commandID(for: .wetDiaper), snapshot.commandID(for: .dirtyDiaper))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
        for key in ["birthDate", "birthDay", "activeEventValues", "actionToken"] {
            json.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(legacy.activeEvents.isEmpty)
        XCTAssertNil(legacy.birthDate)
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

    @MainActor
    func testBackgroundCalendarNotificationsRefreshSnapshotOnMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WidgetSnapshotStore(directory: directory)
        let store = AppStore(persistence: Persistence(inMemory: true), widgetSnapshotStore: cache)
        await store.load()
        XCTAssertTrue(store.ready)
        for name in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange] {
            // Removing the cache makes a subsequent successful write observable
            // without relying on wall-clock timestamp resolution.
            try FileManager.default.removeItem(at: directory)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    XCTAssertFalse(Thread.isMainThread)
                    NotificationCenter.default.post(name: name, object: nil)
                    continuation.resume()
                }
            }
            var refreshed: WidgetSnapshot?
            for _ in 0 ..< 100 {
                refreshed = try cache.read()
                if refreshed != nil {
                    break
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(try XCTUnwrap(refreshed).babyID, store.baby?.id,
                           "Background notification must recreate the snapshot: \(name.rawValue)")
        }
    }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
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

    func testImportedPointEventsNormalizeMissingOrBogusEndWhileTimersRemainExcluded() {
        let baby = Baby(name: "Малыш")
        let now = date("2026-11-04T12:00:00Z")
        let start = now.addingTimeInterval(-3600)
        let bottle = CareEvent(babyID: baby.id, kind: .bottle, start: start)
        let diaper = CareEvent(babyID: baby.id, kind: .diaper, start: start, diaperType: .mixed)
        let latestBottle = CareEvent(babyID: baby.id, kind: .bottle,
                                     start: start.addingTimeInterval(60), end: now.addingTimeInterval(86400))
        let bogusDiaper = CareEvent(babyID: baby.id, kind: .diaper,
                                    start: start, end: start.addingTimeInterval(-86400), diaperType: .wet)
        let events = [bottle, diaper, latestBottle, bogusDiaper,
                      CareEvent(babyID: baby.id, kind: .breast, start: start),
                      CareEvent(babyID: baby.id, kind: .sleep, start: start)]
        let snapshot = WidgetSnapshot(baby: baby, events: events, generatedAt: now)
        let summary = snapshot.summary(at: now, calendar: calendar())
        XCTAssertEqual(snapshot.events.count, 4)
        XCTAssertTrue(snapshot.events.allSatisfy { $0.end == $0.start })
        XCTAssertEqual(summary.feeds, 2)
        XCTAssertEqual(summary.wetDiapers, 2)
        XCTAssertEqual(summary.sleepSeconds, 0)
        XCTAssertEqual(summary.lastFeeding?.id, latestBottle.id)
        XCTAssertEqual(summary.lastFeeding?.end, latestBottle.start)
        XCTAssertFalse(snapshot.events.contains { $0.kind == .breast || $0.kind == .sleep })
    }

    func testOfflineNextDayAndTimezoneRecomputeSleepClippedAndUnioned() {
        let baby = Baby(name: "Малыш")
        let events = [
            CareEvent(babyID: baby.id, kind: .sleep, start: date("2026-11-03T23:00:00Z"),
                      end: date("2026-11-04T02:00:00Z")),
            CareEvent(babyID: baby.id, kind: .sleep, start: date("2026-11-04T01:00:00Z"),
                      end: date("2026-11-04T03:00:00Z")),
            CareEvent(babyID: baby.id, kind: .breast, start: date("2026-11-03T23:30:00Z"),
                      end: date("2026-11-03T23:45:00Z")),
        ]
        let snapshot = WidgetSnapshot(baby: baby, events: events, generatedAt: date("2026-11-04T04:00:00Z"))
        let utc = snapshot.summary(at: date("2026-11-04T12:00:00Z"), calendar: calendar())
        XCTAssertEqual(utc.sleepSeconds, 3 * 3600)
        XCTAssertEqual(utc.feeds, 0)
        let moscow = snapshot.summary(at: date("2026-11-04T12:00:00Z"), calendar: calendar("Europe/Moscow"))
        XCTAssertEqual(moscow.sleepSeconds, 4 * 3600)
        XCTAssertEqual(moscow.feeds, 1)
        let tomorrow = snapshot.summary(at: date("2026-11-05T12:00:00Z"), calendar: calendar())
        XCTAssertEqual(tomorrow.sleepSeconds, 0)
        XCTAssertEqual(tomorrow.feeds, 0)
        XCTAssertEqual(tomorrow.lastFeeding?.id, events[2].id)
    }

    func testAtomicCacheRoundTripAndReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WidgetSnapshotStore(directory: directory)
        XCTAssertNil(try store.read())
        let first = WidgetSnapshot(baby: Baby(name: "Первый"), events: [])
        try store.write(first)
        XCTAssertEqual(try store.read(), first)
        let next = WidgetSnapshot(baby: Baby(name: "Второй"), events: [])
        try store.write(next)
        XCTAssertEqual(try store.read(), next)
    }

    func testCorruptAndFutureVersionCacheAreSafeToIgnoreAndCanBeReplaced() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("diary-widget-v1.json")
        let cache = WidgetSnapshotStore(directory: directory)
        try Data("{incomplete".utf8).write(to: file)
        XCTAssertThrowsError(try cache.read())
        // The provider deliberately treats an unreadable cache as unavailable.
        XCTAssertNil(try? cache.read())
        let snapshot = WidgetSnapshot(baby: Baby(name: "Малыш"), events: [])
        let data = try JSONEncoder().encode(snapshot)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["version"] = WidgetSnapshot.currentVersion + 1
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        XCTAssertNil(try cache.read())
        try cache.write(snapshot)
        XCTAssertEqual(try cache.read(), snapshot)
    }

    func testDSTDaysUseCalendarBoundariesInsteadOfFixedTwentyFourHours() throws {
        let baby = Baby(name: "Малыш")
        let zone = calendar("America/New_York")
        let spans = [
            ("2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23.0),
            ("2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25.0),
        ]
        for (startValue, endValue, hours) in spans {
            let start = date(startValue)
            let end = date(endValue)
            let sleep = CareEvent(babyID: baby.id, kind: .sleep, start: start, end: end)
            let snapshot = WidgetSnapshot(baby: baby, events: [sleep], generatedAt: end)
            let day = try XCTUnwrap(zone.dateInterval(of: .day, for: start))
            XCTAssertEqual(day.duration, hours * 3600)
            let previousDaySummary = snapshot.summary(at: end, calendar: zone)
            XCTAssertEqual(previousDaySummary.sleepSeconds, 0)
            // Include a second completed sleep ending one second before midnight.
            let clipped = CareEvent(babyID: baby.id, kind: .sleep, start: start.addingTimeInterval(-3600),
                                    end: end.addingTimeInterval(-1))
            let completed = WidgetSnapshot(baby: baby, events: [clipped], generatedAt: end)
            XCTAssertEqual(completed.summary(at: end.addingTimeInterval(-1), calendar: zone).sleepSeconds,
                           hours * 3600 - 1)
        }
    }

    @MainActor
    func testLatestFeedingEditsAndImportedDeletionFallBackToPreviousFeed() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WidgetSnapshotStore(directory: directory)
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence, widgetSnapshotStore: cache)
        await store.load()
        let baby = try XCTUnwrap(store.baby)
        let now = Date()
        let previous = CareEvent(babyID: baby.id, kind: .bottle,
                                 start: now.addingTimeInterval(-7200), end: now.addingTimeInterval(-7200))
        var latest = CareEvent(babyID: baby.id, kind: .breast,
                               start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-3000))
        try store.save(previous)
        try store.save(latest)
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.id, latest.id)
        latest.start = now.addingTimeInterval(-1800)
        latest.end = now.addingTimeInterval(-1200)
        try store.save(latest)
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.start, latest.start)
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.end, latest.end)
        latest.kind = .bottle
        latest.volumeML = 125
        try store.save(latest)
        let edited = try XCTUnwrap(cache.read()?.summary().lastFeeding)
        XCTAssertEqual(edited.kind, .bottle)
        XCTAssertEqual(edited.volumeML, 125)
        XCTAssertEqual(edited.end, latest.start)
        // Imported changes reach this same reload path through the runtime's
        // existing remote-change/CloudKit subscriptions; no AppStore.save here.
        try persistence.deleteEvent(id: latest.id)
        try store.reload()
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.id, previous.id)
        var imported = previous
        imported.start = now.addingTimeInterval(-900)
        imported.end = imported.start
        imported.volumeML = 95
        try persistence.saveEvent(imported)
        try store.reload()
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.start, imported.start)
        XCTAssertEqual(try cache.read()?.summary().lastFeeding?.volumeML, 95)
        try store.delete(imported)
        XCTAssertNil(try cache.read()?.summary().lastFeeding)
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

    func testQuietDiaryKeepsRecentEventsAndLastFeedWithBoundedHistory() {
        let baby = Baby(name: "Малыш")
        let now = date("2026-11-04T12:00:00Z")
        let old = now.addingTimeInterval(-20 * 86400)
        let feed = CareEvent(babyID: baby.id, kind: .bottle, start: old, end: old)
        let recent = (1 ... 3).map { index in
            let start = old.addingTimeInterval(Double(index) * 3600)
            return CareEvent(babyID: baby.id, kind: .diaper, start: start, end: start)
        }
        let snapshot = WidgetSnapshot(baby: baby, events: [feed] + recent, generatedAt: now)
        let summary = snapshot.summary(at: now, calendar: calendar())
        XCTAssertEqual(summary.recentEvents.map(\.id), recent.reversed().map(\.id))
        XCTAssertEqual(summary.lastFeeding?.id, feed.id)
        XCTAssertEqual(summary.feeds, 0)
        let many = (0 ... WidgetSnapshot.historyLimit).map { index in
            let start = now.addingTimeInterval(-Double(index))
            return CareEvent(babyID: baby.id, kind: .diaper, start: start, end: start)
        }
        XCTAssertEqual(WidgetSnapshot(baby: baby, events: many, generatedAt: now).events.count,
                       WidgetSnapshot.historyLimit)
    }

    @MainActor
    func testAppStoreRefreshesAfterSaveDeleteSelectionAndReload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = WidgetSnapshotStore(directory: directory)
        let persistence = Persistence(inMemory: true)
        let store = AppStore(persistence: persistence, widgetSnapshotStore: cache)
        await store.load()
        let baby = try XCTUnwrap(store.baby)
        let event = CareEvent(babyID: baby.id, kind: .bottle, start: Date().addingTimeInterval(-60))
        try store.save(event)
        XCTAssertEqual(try cache.read()?.events.map(\.id), [event.id])
        try store.delete(event)
        XCTAssertEqual(try cache.read()?.events.count, 0)
        let other = Baby(name: "Другой")
        try persistence.saveBaby(other)
        try store.reload()
        store.select(other.id)
        XCTAssertEqual(try cache.read()?.babyID, other.id)
        let imported = CareEvent(babyID: other.id, kind: .diaper, start: Date().addingTimeInterval(-60), end: Date())
        try persistence.saveEvent(imported)
        try store.reload()
        XCTAssertEqual(try cache.read()?.events.map(\.id), [imported.id])
        let relaunched = AppStore(persistence: persistence, widgetSnapshotStore: cache)
        await relaunched.load()
        XCTAssertEqual(try cache.read()?.babyID, other.id)
    }
}
