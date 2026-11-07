import CoreData
@testable import Malysh
import XCTest

@MainActor
final class WatchSyncTests: XCTestCase {
    func testOfflineQueueReopensAndReplaysBothTimers() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "WatchDiary.json")
        let babyID = UUID()
        let start = Date().addingTimeInterval(-120)
        var state = WatchLocalState()
        state.receive(snapshot(1, babyID: babyID))
        let breast = WatchOperation(babyID: babyID, date: start, action: .startBreast(.left))
        let sleep = WatchOperation(babyID: babyID, date: start, action: .startSleep)
        try state.enqueue(breast)
        try state.enqueue(sleep)

        let initialBreast = try XCTUnwrap(state.selectedDiary?.active(.breast))
        let switchSide = WatchOperation(babyID: babyID, eventID: breast.id, date: start.addingTimeInterval(20),
                                        action: .switchBreast(to: .right, expected: WatchTimerVersion(initialBreast)))
        try state.enqueue(switchSide)
        try state.write(to: url)
        state = try WatchLocalState.read(from: url)
        XCTAssertEqual(state.pending, [breast, sleep, switchSide])
        XCTAssertEqual(state.selectedDiary?.active(.sleep)?.id, sleep.id)
        let switched = try XCTUnwrap(state.selectedDiary?.active(.breast))
        XCTAssertEqual(switched.leftSeconds, 20)
        XCTAssertEqual(switched.side, .right)

        let finishBreast = WatchOperation(babyID: babyID, eventID: breast.id, date: start.addingTimeInterval(50),
                                          action: .finish(expected: WatchTimerVersion(switched)))
        let activeSleep = try XCTUnwrap(state.selectedDiary?.active(.sleep))
        let finishSleep = WatchOperation(babyID: babyID, eventID: sleep.id, date: start.addingTimeInterval(60),
                                         action: .finish(expected: WatchTimerVersion(activeSleep)))
        try state.enqueue(finishBreast)
        try state.enqueue(finishSleep)
        try state.write(to: url)
        state = try WatchLocalState.read(from: url)
        let finished = try XCTUnwrap(state.selectedDiary?.latestFeeding)
        XCTAssertEqual(finished.leftSeconds, 20)
        XCTAssertEqual(finished.rightSeconds, 30)
        XCTAssertNil(state.selectedDiary?.active(.breast))
        XCTAssertNil(state.selectedDiary?.active(.sleep))
        XCTAssertEqual(state.pending, [breast, sleep, switchSide, finishBreast, finishSleep])
    }

    func testStaleAndOutOfOrderReceiptsCannotRestoreRevokedDiaryOrAdvanceTheWrongHead() throws {
        let babyID = UUID()
        let authorized = snapshot(1, babyID: babyID)
        let revoked = WatchSnapshot(streamID: streamID, revision: 2, generatedAt: Date(), selectedID: nil, diaries: [])
        let first = WatchOperation(babyID: babyID, action: .diaper(.mixed))
        let second = WatchOperation(babyID: babyID, action: .bottle(.formula, 60))
        var state = WatchLocalState()
        state.receive(authorized)
        try state.enqueue(first)
        try state.enqueue(second)
        state.receive(WatchReceipt(operationID: second.id, rejection: nil, snapshot: authorized))
        XCTAssertEqual(state.pending, [first, second])
        state.receive(revoked)
        state.receive(WatchReceipt(operationID: first.id, rejection: .diaryUnavailable, snapshot: authorized))
        XCTAssertEqual(state.pending, [second])
        XCTAssertNil(state.selectedDiary)
        XCTAssertEqual(state.rejection, .diaryUnavailable)
        XCTAssertThrowsError(try state.enqueue(WatchOperation(babyID: babyID, action: .startSleep)))

        let replacement = WatchSnapshot(
            streamID: UUID(),
            revision: 1,
            generatedAt: Date(),
            selectedID: nil,
            diaries: []
        )
        state.receive(replacement)
        state.receive(authorized)
        state.receive(WatchReceipt(operationID: second.id, rejection: nil, snapshot: revoked))
        XCTAssertEqual(state.snapshot, replacement)
        XCTAssertEqual(state.pending, [second])
        state.receive(WatchReceipt(operationID: second.id, rejection: .diaryUnavailable, snapshot: replacement))
        XCTAssertTrue(state.pending.isEmpty)
    }

    func testPhoneRetriesAfterCommitAndDeletionWithoutResurrectingEvent() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(persistence: Persistence(directory: directory))
        defer { closeStores(store.persistence) }
        await store.load(checkCloudAccount: false)
        try store.createFirstDiary(name: "Малыш", birthDate: nil)
        let baby = try XCTUnwrap(store.baby)
        let receipts = directory.appending(path: "receipts")
        let sync = WatchPhoneSync(store: store, directory: receipts)
        let operation = WatchOperation(babyID: baby.id, action: .diaper(.wet))
        let first = try sync.receive(operation)
        XCTAssertNil(first.rejection)
        let event = try XCTUnwrap(store.events.first)
        XCTAssertEqual(event.id, operation.id)

        // Model a process killed after the Core Data transaction but before its receipt file.
        try FileManager.default.removeItem(at: receipts.appending(path: operation.id.uuidString))
        try store.delete(event)
        closeStores(store.persistence)
        let reopened = AppStore(persistence: Persistence(directory: directory))
        defer { closeStores(reopened.persistence) }
        await reopened.load(checkCloudAccount: false)
        let restarted = WatchPhoneSync(store: reopened, directory: receipts)
        let retry = try restarted.receive(operation)
        XCTAssertNil(retry.rejection)
        XCTAssertGreaterThan(retry.snapshot.revision, first.snapshot.revision)
        XCTAssertTrue(reopened.events.isEmpty)
        XCTAssertNil(try restarted.receive(operation).rejection)
        XCTAssertTrue(reopened.events.isEmpty)
    }

    func testPhoneRejectsLateTimerEditsAndValidatesBottleVolume() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(persistence: Persistence(directory: directory))
        defer { closeStores(store.persistence) }
        await store.load(checkCloudAccount: false)
        try store.createFirstDiary(name: "Малыш", birthDate: nil)
        let baby = try XCTUnwrap(store.baby)
        let sync = WatchPhoneSync(store: store, directory: directory.appending(path: "receipts"))
        let start = Date().addingTimeInterval(-120)
        let breast = WatchOperation(babyID: baby.id, date: start, action: .startBreast(.left))
        let initial = try XCTUnwrap(sync.receive(breast).snapshot.diaries.first?.active(.breast))
        let switchSide = WatchOperation(babyID: baby.id, eventID: breast.id, date: start.addingTimeInterval(30),
                                        action: .switchBreast(to: .right, expected: WatchTimerVersion(initial)))
        let switched = try XCTUnwrap(sync.receive(switchSide).snapshot.diaries.first?.active(.breast))
        XCTAssertEqual(switched.leftSeconds, 30)
        XCTAssertNil(try sync.receive(switchSide).rejection)
        let lateFinish = WatchOperation(babyID: baby.id, eventID: breast.id, date: start.addingTimeInterval(45),
                                        action: .finish(expected: WatchTimerVersion(initial)))
        XCTAssertEqual(try sync.receive(lateFinish).rejection, .timerChanged)
        XCTAssertEqual(try sync.snapshot().diaries.first?.active(.breast), switched)
        let finish = WatchOperation(babyID: baby.id, eventID: breast.id, date: start.addingTimeInterval(60),
                                    action: .finish(expected: WatchTimerVersion(switched)))
        let finished = try sync.receive(finish)
        XCTAssertNil(finished.rejection)
        XCTAssertNil(finished.snapshot.diaries.first?.active(.breast))
        XCTAssertEqual(finished.snapshot.diaries.first?.latestFeeding?.rightSeconds, 30)
        let invalid = WatchOperation(babyID: baby.id, action: .bottle(.formula, 2001))
        XCTAssertEqual(try sync.receive(invalid).rejection, .invalidOperation)
        XCTAssertEqual(store.events.count, 1)
    }

    func testCachedSharedDiaryIsUnavailableWithCloudOffAndDoesNotBlockPrivateOperations() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        defer { closeStores(persistence) }
        let store = AppStore(persistence: persistence)
        await store.load(checkCloudAccount: false)
        try store.createFirstDiary(name: "Личный", birthDate: nil)
        let privateID = try XCTUnwrap(store.baby?.id)

        let shared = Baby(name: "Семейный")
        let context = persistence.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
        try context.assign(record, to: XCTUnwrap(persistence.sharedStore))
        record.setValue(shared.id, forKey: "id")
        record.setValue(shared.name, forKey: "name")
        record.setValue(shared.birthDate, forKey: "birthDate")
        try record.setValue(JSONEncoder().encode(shared), forKey: "payload")
        try context.save()
        try store.reload()
        XCTAssertTrue(store.visibleBabies.contains { $0.id == shared.id })

        let sync = WatchPhoneSync(store: store, directory: directory.appending(path: "receipts"))
        let pendingShared = WatchOperation(babyID: shared.id, action: .diaper(.mixed))
        let receipt = try sync.receive(pendingShared)
        XCTAssertEqual(receipt.rejection, .diaryUnavailable)
        XCTAssertEqual(receipt.snapshot.diaries.map(\.id), [privateID])
        XCTAssertTrue(try persistence.events(babyID: shared.id).isEmpty)

        let pendingPrivate = WatchOperation(babyID: privateID, action: .bottle(.expressed, 120))
        XCTAssertNil(try sync.receive(pendingPrivate).rejection)
        XCTAssertEqual(try persistence.events(babyID: privateID).map(\.id), [pendingPrivate.id])
    }

    private let streamID = UUID()

    private func snapshot(_ revision: UInt64, babyID: UUID) -> WatchSnapshot {
        WatchSnapshot(streamID: streamID, revision: revision, generatedAt: Date(), selectedID: babyID,
                      diaries: [WatchDiary(id: babyID, name: "Малыш", canWrite: true, events: [])])
    }

    private func closeStores(_ persistence: Persistence) {
        let context = persistence.container.viewContext
        context.reset()
        let coordinator = persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try? coordinator.remove(store)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
