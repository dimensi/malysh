import Foundation
@testable import Malysh
import XCTest

@MainActor
final class CareActivityCoordinatorTests: XCTestCase {
    private final class Backend: CareActivityBackend {
        var enabled = true
        var dismissedEventIDs = Set<UUID>()
        var activities: [CareActivityInstance] = []
        var requests = 0
        var updates = 0
        var endings: [String] = []
        var operations: [String] = []
        var failRequest = false
        var ignoreUpdates = false
        var requestGate: (() async -> Void)?
        var updateGate: (() async -> Void)?

        func instances() -> [CareActivityInstance] {
            activities
        }

        func request(attributes: CareActivityAttributes, content: CareActivityAttributes.ContentState) async throws {
            requests += 1
            operations.append("request")
            if let requestGate {
                await requestGate()
            }
            if failRequest {
                throw CocoaError(.fileWriteUnknown)
            }
            activities.append(.init(id: UUID().uuidString, attributes: attributes, content: content, status: .active))
        }

        func update(id: String, content: CareActivityAttributes.ContentState) async {
            updates += 1
            if let updateGate {
                await updateGate()
            }
            guard !ignoreUpdates else { return }
            activities = activities.map {
                $0.id == id ? .init(id: id, attributes: $0.attributes, content: content, status: .active) : $0
            }
        }

        func end(id: String) async {
            endings.append(id)
            operations.append("end:\(id)")
            activities.removeAll { $0.id == id }
        }

        func insert(_ event: CareEvent, baby: Baby, id: String, status: CareActivityInstance.Status = .active) {
            activities.append(.init(id: id, attributes: .init(eventID: event.id, babyID: baby.id),
                                    content: .init(kind: event.kind, start: event.start,
                                                   side: event.kind == .breast ? event.side : nil,
                                                   babyName: baby.name), status: status))
        }
    }

    func testRestoresRunningEventsAcrossAllDiariesAndIgnoresPointEvents() async {
        let backend = Backend()
        let coordinator = CareActivityCoordinator(backend: backend)
        let babies = [Baby(name: "Первый"), Baby(name: "Второй")]
        let events = [CareEvent(babyID: babies[0].id, kind: .sleep),
                      CareEvent(babyID: babies[1].id, kind: .breast),
                      CareEvent(babyID: babies[0].id, kind: .diaper),
                      CareEvent(babyID: babies[1].id, kind: .bottle)]
        coordinator.reconcile(events: events, babies: babies, allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 2)
        XCTAssertEqual(Set(backend.activities.map(\.attributes.babyID)), Set(babies.map(\.id)))
    }

    func testRestorationKeepsOneExistingInstanceAndEndsDuplicates() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let event = CareEvent(babyID: baby.id, kind: .sleep)
        backend.insert(event, baby: baby, id: "a")
        backend.insert(event, baby: baby, id: "b")
        let coordinator = CareActivityCoordinator(backend: backend)
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.map(\.id), ["a"])
        XCTAssertEqual(backend.endings, ["b"])
        XCTAssertEqual(backend.requests, 0)
    }

    func testChangesStartSideKindAndNameWithoutReplacingActivity() async {
        let backend = Backend()
        var baby = Baby(name: "Малыш")
        var event = CareEvent(babyID: baby.id, kind: .breast)
        backend.insert(event, baby: baby, id: "existing")
        let coordinator = CareActivityCoordinator(backend: backend)
        event.start = event.start.addingTimeInterval(-60)
        event.side = .right
        baby.name = "Новое имя"
        coordinator.reconcile(events: [event], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.first?.content.start, event.start)
        XCTAssertEqual(backend.activities.first?.content.side, .right)
        XCTAssertEqual(backend.activities.first?.content.babyName, baby.name)
        event.kind = .sleep
        coordinator.reconcile(events: [event], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.first?.content.kind, .sleep)
        XCTAssertNil(backend.activities.first?.content.side)
        XCTAssertEqual(backend.activities.first?.id, "existing")
        XCTAssertEqual(backend.updates, 2)
        XCTAssertEqual(backend.requests, 0)
    }

    func testFinishingDeletingAndLosingDiaryAccessEndActivities() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let events = (0 ..< 3).map { _ in CareEvent(babyID: baby.id, kind: .sleep) }
        for (index, event) in events.enumerated() {
            backend.insert(event, baby: baby, id: "\(index)")
        }
        var finished = events[0]
        finished.finish()
        let coordinator = CareActivityCoordinator(backend: backend)
        // One finished, one deleted, one still running.
        coordinator.reconcile(events: [finished, events[2]], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.map(\.id), ["2"])
        coordinator.reconcile(events: [events[2]], babies: [], allowStart: true)
        await coordinator.flush()
        XCTAssertTrue(backend.activities.isEmpty)
        XCTAssertEqual(backend.endings.count, 3)
    }

    func testDismissedEventStaysDismissedButSystemEndedEventRestoresOnForeground() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let dismissed = CareEvent(babyID: baby.id, kind: .breast)
        let ended = CareEvent(babyID: baby.id, kind: .sleep)
        backend.dismissedEventIDs.insert(dismissed.id)
        backend.insert(dismissed, baby: baby, id: "dismissed", status: .dismissed)
        backend.insert(ended, baby: baby, id: "expired", status: .ended)
        let coordinator = CareActivityCoordinator(backend: backend)
        coordinator.reconcile(events: [dismissed, ended], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 0)
        coordinator.reconcile(events: [dismissed, ended], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 1)
        XCTAssertEqual(backend.activities.filter { $0.status == .active }.map(\.attributes.eventID), [ended.id])
    }

    func testPermissionAndRequestFailureRetryOnNextForegroundSnapshot() async {
        let backend = Backend()
        backend.enabled = false
        let baby = Baby(name: "Малыш")
        let event = CareEvent(babyID: baby.id, kind: .sleep)
        let coordinator = CareActivityCoordinator(backend: backend)
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 0)
        backend.enabled = true
        backend.failRequest = true
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 1)
        backend.failRequest = false
        coordinator.reconcile(events: [event], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 1)
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 2)
        XCTAssertEqual(backend.activities.count, 1)
    }

    func testSystemEndedPresentationIsRemovedBeforeRestoringRunningEvent() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let event = CareEvent(babyID: baby.id, kind: .sleep)
        backend.insert(event, baby: baby, id: "expired", status: .ended)
        let coordinator = CareActivityCoordinator(backend: backend)
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.operations, ["end:expired", "request"])
        XCTAssertEqual(backend.activities.count, 1)
        XCTAssertEqual(backend.activities.first?.status, .active)
        XCTAssertEqual(backend.activities.first?.attributes.eventID, event.id)
        XCTAssertTrue(backend.dismissedEventIDs.isEmpty)
    }

    func testSystemEndedPresentationIsRemovedForDeletedEventWithoutReplacement() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let event = CareEvent(babyID: baby.id, kind: .sleep)
        backend.insert(event, baby: baby, id: "expired", status: .ended)
        let coordinator = CareActivityCoordinator(backend: backend)
        coordinator.reconcile(events: [], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.operations, ["end:expired"])
        XCTAssertTrue(backend.activities.isEmpty)
        XCTAssertTrue(backend.dismissedEventIDs.isEmpty)
    }

    func testSnapshotArrivingDuringRequestRemovesObsoleteActivityBeforeFlushReturns() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let event = CareEvent(babyID: baby.id, kind: .sleep)
        let coordinator = CareActivityCoordinator(backend: backend)
        var resume: CheckedContinuation<Void, Never>?
        backend.requestGate = {
            await withCheckedContinuation { resume = $0 }
        }
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        while resume == nil {
            await Task.yield()
        }
        coordinator.reconcile(events: [], babies: [baby], allowStart: true)
        resume?.resume()
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 1)
        XCTAssertEqual(backend.endings.count, 1)
        XCTAssertTrue(backend.activities.isEmpty)
    }

    func testQueuedSnapshotsCoalesceBeforeStartingWork() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let coordinator = CareActivityCoordinator(backend: backend)
        coordinator.reconcile(events: [CareEvent(babyID: baby.id, kind: .sleep)], babies: [baby], allowStart: true)
        coordinator.reconcile(events: [], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 0)
    }

    func testIgnoredUpdateAttemptsOncePerSnapshotAndFlushReturns() async {
        let backend = Backend()
        backend.ignoreUpdates = true
        let baby = Baby(name: "Малыш")
        var event = CareEvent(babyID: baby.id, kind: .breast)
        backend.insert(event, baby: baby, id: "existing")
        let coordinator = CareActivityCoordinator(backend: backend)
        event.side = .right
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.updates, 1)
        XCTAssertEqual(backend.activities.first?.content.side, .left)
        backend.ignoreUpdates = false
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.updates, 2)
        XCTAssertEqual(backend.activities.first?.content.side, .right)
    }

    func testOversizedNameUsesBoundedDisplayProjectionWithoutChangingBaby() async {
        let backend = Backend()
        let originalName = String(repeating: "🍼", count: 2000)
        let baby = Baby(name: originalName)
        let event = CareEvent(babyID: baby.id, kind: .sleep)
        let coordinator = CareActivityCoordinator(backend: backend)
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.first?.content.babyName, String(repeating: "🍼", count: 120))
        XCTAssertEqual(baby.name, originalName)
        XCTAssertLessThan(backend.activities.first?.content.babyName.utf8.count ?? 0, 500)
    }

    func testSnapshotDuringUpdateFinishesWithLatestPersistedContent() async {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        var event = CareEvent(babyID: baby.id, kind: .breast)
        backend.insert(event, baby: baby, id: "existing")
        let coordinator = CareActivityCoordinator(backend: backend)
        var resume: CheckedContinuation<Void, Never>?
        backend.updateGate = {
            await withCheckedContinuation { resume = $0 }
        }
        event.side = .right
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        while resume == nil {
            await Task.yield()
        }
        event.kind = .sleep
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        backend.updateGate = nil
        resume?.resume()
        await coordinator.flush()
        XCTAssertEqual(backend.updates, 2)
        XCTAssertEqual(backend.activities.first?.content.kind, .sleep)
        XCTAssertNil(backend.activities.first?.content.side)
        XCTAssertEqual(backend.requests, 0)
    }
}
