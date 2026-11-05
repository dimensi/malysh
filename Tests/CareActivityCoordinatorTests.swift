import Foundation
@testable import Malysh
import XCTest

@MainActor
final class CareActivityCoordinatorTests: XCTestCase {
    private final class Backend: CareActivityBackend {
        let enabled = true
        let dismissedEventIDs = Set<UUID>()
        var activities: [CareActivityInstance] = []
        var requests = 0
        var endings: [String] = []
        var requestGate: (() async -> Void)?

        func instances() -> [CareActivityInstance] {
            activities
        }

        func request(attributes: CareActivityAttributes, content: CareActivityAttributes.ContentState) async throws {
            requests += 1
            if let requestGate {
                await requestGate()
            }
            activities.append(.init(id: UUID().uuidString, attributes: attributes, content: content, status: .active))
        }

        func update(id: String, content: CareActivityAttributes.ContentState) async {
            activities = activities.map {
                $0.id == id ? .init(id: id, attributes: $0.attributes, content: content, status: .active) : $0
            }
        }

        func end(id: String) async {
            endings.append(id)
            activities.removeAll { $0.id == id }
        }

        func insert(_ event: CareEvent, baby: Baby, id: String) {
            activities.append(.init(id: id, attributes: .init(eventID: event.id, babyID: baby.id),
                                    content: .init(kind: event.kind, start: event.start,
                                                   side: event.kind == .breast ? event.side : nil,
                                                   babyName: baby.name), status: .active))
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
}
