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
        var finishes: [(id: String, dismissalDate: Date)] = []
        var requestGate: (() async -> Void)?
        var finishGate: (() async -> Void)?
        var delayFinalContent = false
        var delayFinalStatus = false
        var finalContents: [String: CareActivityAttributes.ContentState] = [:]

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

        func finish(id: String, content: CareActivityAttributes.ContentState, dismissalDate: Date) async {
            finishes.append((id, dismissalDate))
            finalContents[id] = content
            if let finishGate {
                await finishGate()
            }
            activities = activities.map {
                $0.id == id ? .init(id: id, attributes: $0.attributes,
                                    content: delayFinalContent ? $0.content : content,
                                    status: delayFinalStatus ? .active : .ended) : $0
            }
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

    func testRestorationKeepsOneExistingInstanceAndEndsDuplicates() async throws {
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

        // An ActivityKit timeout has no committed end and must not stop the event.
        let existing = try XCTUnwrap(backend.activities.first)
        backend.activities = [.init(id: existing.id, attributes: existing.attributes,
                                    content: existing.content, status: .ended)]
        coordinator.reconcile(events: [event], babies: [baby], allowStart: true)
        await coordinator.flush()
        XCTAssertEqual(backend.requests, 1)
        XCTAssertEqual(backend.activities.first?.status, .active)

        // Existing ActivityKit payloads did not have an end field.
        let oldContent = existing.content
        let encoded = try JSONEncoder().encode(oldContent)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "end")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(CareActivityAttributes.ContentState.self, from: legacyData)
        XCTAssertEqual(decoded, oldContent)
        XCTAssertNil(decoded.end)
    }

    func testFinishingDeletingAndLosingDiaryAccessEndActivities() async throws {
        let backend = Backend()
        let baby = Baby(name: "Малыш")
        let start = Date().addingTimeInterval(-120)
        let events = (0 ..< 3).map { _ in CareEvent(babyID: baby.id, kind: .sleep, start: start) }
        for (index, event) in events.enumerated() {
            backend.insert(event, baby: baby, id: "\(index)")
        }
        var finished = events[0]
        finished.finish(at: start.addingTimeInterval(90))
        let coordinator = CareActivityCoordinator(backend: backend)
        // One finished, one deleted, one still running.
        coordinator.reconcile(events: [finished, events[2]], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.map(\.id).sorted(), ["0", "2"])
        XCTAssertEqual(backend.finishes.map(\.id), ["0"])
        let finalContent = try XCTUnwrap(backend.activities.first { $0.id == "0" }?.content)
        XCTAssertEqual(finalContent.start, start)
        XCTAssertEqual(finalContent.end, start.addingTimeInterval(90))
        XCTAssertEqual(try XCTUnwrap(finalContent.end).timeIntervalSince(finalContent.start), 90)
        XCTAssertEqual(backend.finishes.first?.dismissalDate, finished.end?.addingTimeInterval(15 * 60))
        let finalData = try JSONEncoder().encode(finalContent)
        XCTAssertEqual(
            try JSONDecoder().decode(CareActivityAttributes.ContentState.self, from: finalData),
            finalContent
        )

        // Duplicate and already-expired cards are not kept as misleading summaries.
        let final = try XCTUnwrap(backend.activities.first { $0.id == "0" })
        backend.activities.append(.init(id: "duplicate", attributes: final.attributes,
                                        content: final.content, status: .ended))
        coordinator.reconcile(events: [finished, events[2]], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.filter { $0.attributes.eventID == finished.id }.count, 1)

        var renamedBaby = baby
        renamedBaby.name = "Другое имя"
        coordinator.reconcile(events: [finished, events[2]], babies: [renamedBaby], allowStart: false)
        await coordinator.flush()
        XCTAssertFalse(backend.activities.contains { $0.attributes.eventID == finished.id })
        backend.activities.append(final)
        var editedFinished = finished
        editedFinished.start = finished.start.addingTimeInterval(-60)
        coordinator.reconcile(events: [editedFinished, events[2]], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertFalse(backend.activities.contains { $0.attributes.eventID == finished.id })

        var oldFinished = finished
        oldFinished.end = Date().addingTimeInterval(-16 * 60)
        oldFinished.start = try XCTUnwrap(oldFinished.end).addingTimeInterval(-120)
        var oldContent = final.content
        oldContent.start = oldFinished.start
        oldContent.end = oldFinished.end
        backend.activities.append(.init(id: final.id, attributes: final.attributes,
                                        content: oldContent, status: .ended))
        coordinator.reconcile(events: [oldFinished, events[2]], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.map(\.id), ["2"])

        coordinator.reconcile(events: [events[2]], babies: [], allowStart: true)
        await coordinator.flush()
        XCTAssertTrue(backend.activities.isEmpty)
        XCTAssertEqual(Set(backend.endings), Set(["0", "1", "2", "duplicate"]))
    }

    func testSnapshotArrivingDuringRequestRemovesObsoleteActivityBeforeFlushReturns() async throws {
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

        // A deletion arriving while the final state is being published must remove that card.
        backend.requestGate = nil
        backend.insert(event, baby: baby, id: "finishing")
        var finished = event
        finished.finish()
        var resumeFinish: CheckedContinuation<Void, Never>?
        backend.finishGate = { await withCheckedContinuation { resumeFinish = $0 } }
        coordinator.reconcile(events: [finished], babies: [baby], allowStart: false)
        while resumeFinish == nil {
            await Task.yield()
        }
        coordinator.reconcile(events: [], babies: [baby], allowStart: false)
        resumeFinish?.resume()
        await coordinator.flush()
        XCTAssertTrue(backend.activities.isEmpty)

        // ActivityKit may report .ended before its final content becomes observable.
        backend.finishGate = nil
        backend.delayFinalContent = true
        backend.insert(event, baby: baby, id: "delayed")
        coordinator.reconcile(events: [finished], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.map(\.id), ["delayed"])
        XCTAssertEqual(backend.activities.first?.status, .ended)
        coordinator.reconcile(events: [finished], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.map(\.id), ["delayed"])
        XCTAssertEqual(backend.finishes.filter { $0.id == "delayed" }.count, 1)
        var edited = finished
        edited.start = finished.start.addingTimeInterval(-60)
        coordinator.reconcile(events: [edited], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertTrue(backend.activities.isEmpty)

        // A delayed status must not cause a second finish on a later reconciliation.
        backend.delayFinalStatus = true
        backend.insert(event, baby: baby, id: "pending")
        coordinator.reconcile(events: [finished], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.first?.status, .active)
        coordinator.reconcile(events: [finished], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.finishes.filter { $0.id == "pending" }.count, 1)
        let pending = try XCTUnwrap(backend.activities.first)
        let publishedContent = try XCTUnwrap(backend.finalContents["pending"])
        backend.activities = [.init(id: pending.id, attributes: pending.attributes,
                                    content: publishedContent, status: .ended)]
        coordinator.reconcile(events: [finished], babies: [baby], allowStart: false)
        await coordinator.flush()
        XCTAssertEqual(backend.activities.first?.status, .ended)
        XCTAssertEqual(backend.finishes.filter { $0.id == "pending" }.count, 1)
    }
}
