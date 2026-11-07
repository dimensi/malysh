import Foundation
@testable import Malysh
import XCTest

@MainActor
final class FeedingReminderServiceTests: XCTestCase {
    private enum ScheduleFailure: Error { case unavailable }

    private final class Scheduler: FeedingReminderScheduling {
        var rejectsInstall = false
        var liveActivitiesEnabled = false
        var rejectsLiveActivity = false
        var liveActivityRequests: [FeedingReminderRequest] = []
        var activities: [FeedingReminderLiveActivity] = []
        var permission: FeedingReminderAuthorization = .allowed
        var requestedPermission: FeedingReminderAuthorization = .denied
        var permissionRequests = 0
        var requests: [FeedingReminderRequest] = []
        var pending: FeedingReminderRequest?
        var delivered: FeedingReminderRequest?
        var beforeInstall: (() async -> Void)?

        func liveActivities() -> [FeedingReminderLiveActivity] {
            activities
        }

        func scheduleLiveActivity(_ request: FeedingReminderRequest) throws {
            if rejectsLiveActivity {
                throw ScheduleFailure.unavailable
            }
            liveActivityRequests.append(request)
            activities.append(.init(id: UUID().uuidString, token: request.token, state: .pending))
        }

        func endLiveActivities(except activityID: String?) async {
            activities.removeAll { $0.id != activityID }
        }

        func authorization() async -> FeedingReminderAuthorization {
            permission
        }

        func requestAuthorization() async throws {
            permissionRequests += 1
            permission = requestedPermission
        }

        func notificationState() async -> FeedingReminderNotificationState {
            .init(pendingToken: pending?.token, deliveredToken: delivered?.token)
        }

        func schedule(_ request: FeedingReminderRequest) async throws {
            if rejectsInstall {
                throw ScheduleFailure.unavailable
            }
            requests.append(request)
            if let beforeInstall {
                await beforeInstall()
            }
            pending = request
        }

        func removePending() {
            pending = nil
        }

        func removeDelivered() {
            delivered = nil
        }

        func deliver() {
            delivered = pending
            pending = nil
        }
    }

    @MainActor
    private final class Fixture {
        let suite = "FeedingReminderTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        let scheduler = Scheduler()
        let babyID = UUID()
        var now = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        }

        func service() -> FeedingReminderService {
            FeedingReminderService(defaults: defaults, scheduler: scheduler, now: { [unowned self] in now })
        }

        func event(_ kind: EventKind = .bottle, babyID: UUID? = nil, startMinutes: Int,
                   endMinutes: Int? = nil) -> CareEvent
        {
            CareEvent(babyID: babyID ?? self.babyID, kind: kind,
                      start: now.addingTimeInterval(TimeInterval(startMinutes * 60)),
                      end: endMinutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) })
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
        }
    }

    // FR: a stale or unrelated feed must not anchor the reminder, and active nursing cancels it.
    func testSelectedChildUsesLatestCompletionAndSuppressesDuringNursing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        service.update(babyID: fixture.babyID, events: [])
        await service.flush()
        XCTAssertEqual(service.status, .off)
        XCTAssertNil(fixture.scheduler.pending)

        service.setEnabled(true)
        await service.flush()
        XCTAssertEqual(service.status, .noFeeding)

        let bottle = fixture.event(startMinutes: -20)
        service.update(babyID: fixture.babyID, events: [bottle])
        await service.flush()
        XCTAssertEqual(service.status, .scheduled(fixture.now.addingTimeInterval(160 * 60)))

        let feeds = [
            bottle,
            fixture.event(.breast, startMinutes: -40, endMinutes: -10),
            fixture.event(.breast, startMinutes: -5, endMinutes: 10),
            fixture.event(babyID: UUID(), startMinutes: -1),
            fixture.event(.breast, babyID: UUID(), startMinutes: -1),
        ]
        service.update(babyID: fixture.babyID, events: feeds)
        await service.flush()
        XCTAssertEqual(service.status, .scheduled(fixture.now.addingTimeInterval(170 * 60)))

        var nursing = fixture.event(.breast, startMinutes: -5)
        service.update(babyID: fixture.babyID, events: feeds + [nursing])
        await service.flush()
        XCTAssertEqual(service.status, .feedingActive)
        XCTAssertNil(fixture.scheduler.pending)

        nursing.finish(at: fixture.now)
        service.update(babyID: fixture.babyID, events: feeds + [nursing])
        await service.flush()
        XCTAssertEqual(service.status, .scheduled(fixture.now.addingTimeInterval(180 * 60)))

        service.update(babyID: fixture.babyID, events: feeds)
        await service.flush()
        XCTAssertEqual(service.status, .scheduled(fixture.now.addingTimeInterval(170 * 60)))

        var editedBottle = bottle
        editedBottle.start = fixture.now.addingTimeInterval(-180 * 60)
        service.update(babyID: fixture.babyID, events: [editedBottle])
        await service.flush()
        XCTAssertEqual(service.status, .overdue)
        XCTAssertNil(fixture.scheduler.pending)
    }

    // FR: prompting stays opt-in, including after relaunch, and external settings are honored.
    func testPermissionIsRequestedOnlyOnEnableAndSettingsPersist() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scheduler = fixture.scheduler
        let service = fixture.service()
        let feeds = [fixture.event(startMinutes: -10)]
        scheduler.permission = .notDetermined
        service.update(babyID: fixture.babyID, events: feeds)
        await service.flush()
        XCTAssertEqual(scheduler.permissionRequests, 0)
        XCTAssertEqual(service.intervalMinutes, 180)

        service.setEnabled(true)
        service.setIntervalMinutes(135)
        service.setIntervalMinutes(16)
        await service.flush()
        XCTAssertEqual(service.authorization, .denied)
        XCTAssertEqual(service.status, .unavailable)
        XCTAssertEqual(scheduler.permissionRequests, 1)
        XCTAssertNil(scheduler.pending)

        let restored = fixture.service()
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.intervalMinutes, 135)
        restored.update(babyID: fixture.babyID, events: feeds)
        await restored.flush()
        XCTAssertEqual(scheduler.permissionRequests, 1)
        scheduler.permission = .allowed
        restored.update(babyID: fixture.babyID, events: feeds)
        await restored.flush()
        XCTAssertEqual(restored.status, .scheduled(fixture.now.addingTimeInterval(125 * 60)))
    }

    // FR: changing the selected diary while iOS accepts a request cannot leave a stale notification.
    func testInFlightScheduleIsReplacedByNewDiary() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        let newBaby = UUID()
        let newFeed = fixture.event(babyID: newBaby, startMinutes: -60)
        fixture.scheduler.beforeInstall = { [weak service, weak scheduler = fixture.scheduler] in
            scheduler?.beforeInstall = nil
            service?.update(babyID: newBaby, events: [newFeed])
        }
        service.update(babyID: fixture.babyID, events: [fixture.event(startMinutes: -10)])
        service.setEnabled(true)
        await service.flush()
        XCTAssertEqual(fixture.scheduler.requests.map(\.babyID), [fixture.babyID, newBaby])
        XCTAssertEqual(fixture.scheduler.pending?.babyID, newBaby)
        service.update(babyID: newBaby, events: [newFeed])
        await service.flush()
        XCTAssertEqual(fixture.scheduler.requests.count, 2)
    }

    // FR: a failed same-ID replacement must not leave the old feeding's alert queued.
    func testFailedReplacementCancelsObsoleteRequestAndRetriesOnReload() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        let feeding = fixture.event(startMinutes: -20)
        service.update(babyID: fixture.babyID, events: [feeding])
        service.setEnabled(true)
        await service.flush()
        XCTAssertNotNil(fixture.scheduler.pending)

        fixture.scheduler.rejectsInstall = true
        service.setIntervalMinutes(120)
        await service.flush()
        XCTAssertEqual(service.status, .unavailable)
        XCTAssertNil(fixture.scheduler.pending)

        fixture.scheduler.rejectsInstall = false
        service.update(babyID: fixture.babyID, events: [feeding])
        await service.flush()
        XCTAssertEqual(fixture.scheduler.pending?.due, fixture.now.addingTimeInterval(100 * 60))
        service.setEnabled(false)
        await service.flush()
        XCTAssertNil(fixture.scheduler.pending)
    }

    // FR: a delivered token survives cold launch and clock rollback, can be snoozed once, and is
    // invalidated by a newer snapshot before its successor's action is handled.
    func testDeliveredIdentitySurvivesReloadAndRejectsReplayOrEditedFeed() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let service = fixture.service()
        var feed = fixture.event(startMinutes: -160)
        service.update(babyID: fixture.babyID, events: [feed])
        service.setEnabled(true)
        await service.flush()
        let first = try XCTUnwrap(fixture.scheduler.pending)
        await service.snooze(token: first.token)
        XCTAssertEqual(fixture.scheduler.requests.count, 1)

        fixture.now = first.due
        fixture.scheduler.deliver()
        let restored = fixture.service()
        restored.update(babyID: fixture.babyID, events: [feed])
        await restored.flush()
        XCTAssertEqual(fixture.scheduler.delivered, first)
        fixture.now = fixture.now.addingTimeInterval(-60)
        restored.update(babyID: fixture.babyID, events: [feed])
        await restored.flush()
        XCTAssertNil(fixture.scheduler.pending)
        XCTAssertTrue(restored.canOpen(token: first.token, babyID: fixture.babyID))

        await restored.snooze(token: first.token)
        let snoozed = try XCTUnwrap(fixture.scheduler.pending)
        XCTAssertNotEqual(snoozed.token, first.token)
        XCTAssertEqual(snoozed.due, fixture.now.addingTimeInterval(15 * 60))
        XCTAssertNil(fixture.scheduler.delivered)
        await restored.snooze(token: first.token)
        XCTAssertEqual(fixture.scheduler.pending, snoozed)

        fixture.now = snoozed.due
        fixture.scheduler.deliver()
        await restored.snooze(token: snoozed.token)
        let successor = try XCTUnwrap(fixture.scheduler.pending)
        fixture.now = successor.due
        fixture.scheduler.deliver()
        feed.modifiedAt = fixture.now
        restored.update(babyID: fixture.babyID, events: [feed])
        await restored.snooze(token: successor.token)
        XCTAssertNil(fixture.scheduler.pending)
        XCTAssertNil(fixture.scheduler.delivered)
    }

    // FR: the preferred route works with notification authorization denied, migrates when
    // ActivityKit availability changes, and falls back if the OS rejects a new request.
    func testOnlyOneDeliveryChannelSurvivesCapabilityChangesAndRequestFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scheduler = fixture.scheduler
        let service = fixture.service()
        let feed = fixture.event(startMinutes: -20)
        scheduler.liveActivitiesEnabled = true
        scheduler.permission = .denied
        service.update(babyID: fixture.babyID, events: [feed], babyName: "Саша")
        service.setEnabled(true)
        await service.flush()
        XCTAssertEqual(service.deliveryChannel, .liveActivity)
        XCTAssertEqual(scheduler.liveActivityRequests.last?.babyName, "Саша")
        XCTAssertEqual(scheduler.activities.count, 1)
        XCTAssertNil(scheduler.pending)

        scheduler.liveActivitiesEnabled = false
        scheduler.permission = .allowed
        service.update(babyID: fixture.babyID, events: [feed])
        await service.flush()
        XCTAssertEqual(service.deliveryChannel, .notification)
        XCTAssertNotNil(scheduler.pending)
        XCTAssertTrue(scheduler.activities.isEmpty)

        scheduler.liveActivitiesEnabled = true
        service.update(babyID: fixture.babyID, events: [feed])
        await service.flush()
        XCTAssertEqual(service.deliveryChannel, .liveActivity)
        XCTAssertEqual(scheduler.activities.count, 1)
        XCTAssertNil(scheduler.pending)

        scheduler.rejectsLiveActivity = true
        service.setIntervalMinutes(120)
        await service.flush()
        XCTAssertEqual(service.deliveryChannel, .notification)
        XCTAssertNotNil(scheduler.pending)
        XCTAssertTrue(scheduler.activities.isEmpty)
    }

    // FR: a shown activity survives cold launch and can be snoozed once, even with
    // notifications denied. The previous activity is removed before its replacement.
    func testShownActivityCanSnoozeAcrossLaunchWithNotificationsDenied() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let scheduler = fixture.scheduler
        let service = fixture.service()
        let feed = fixture.event(startMinutes: -175)
        scheduler.liveActivitiesEnabled = true
        scheduler.permission = .denied
        service.update(babyID: fixture.babyID, events: [feed])
        service.setEnabled(true)
        await service.flush()
        let first = try XCTUnwrap(scheduler.liveActivityRequests.last)
        let initialActivity = try XCTUnwrap(scheduler.activities.first)
        fixture.now = first.due
        scheduler.activities = [.init(id: initialActivity.id, token: first.token, state: .shown)]

        let restored = fixture.service()
        restored.update(babyID: fixture.babyID, events: [feed])
        await restored.flush()
        XCTAssertEqual(scheduler.liveActivityRequests.count, 1)
        XCTAssertEqual(scheduler.activities.first?.id, initialActivity.id)
        XCTAssertTrue(restored.canOpen(token: first.token, babyID: fixture.babyID))

        await restored.snooze(token: first.token)
        let replacement = try XCTUnwrap(scheduler.liveActivityRequests.last)
        XCTAssertNotEqual(replacement.token, first.token)
        XCTAssertEqual(replacement.due, fixture.now.addingTimeInterval(15 * 60))
        XCTAssertEqual(scheduler.activities.map(\.token), [replacement.token])
        XCTAssertNil(scheduler.pending)
        await restored.snooze(token: first.token)
        XCTAssertEqual(scheduler.liveActivityRequests.count, 2)
    }
}
