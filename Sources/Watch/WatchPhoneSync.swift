import CloudKit
import CoreData
import Foundation

/// Keeps WatchConnectivity independent of the diary transaction and its recovery path.
@MainActor
final class WatchPhoneSync {
    private struct Outcome: Codable {
        let rejection: WatchRejection?
    }

    private struct Stream: Codable {
        var id = UUID()
        var revision: UInt64 = 0
    }

    let store: AppStore
    private let directory: URL
    private var lastSnapshot: WatchSnapshot?

    init(store: AppStore, directory: URL? = nil) {
        self.store = store
        self.directory = directory ?? URL.applicationSupportDirectory.appending(
            path: "WatchSync",
            directoryHint: .isDirectory
        )
    }

    func snapshot(refresh: Bool = false) throws -> WatchSnapshot {
        try checkReady()
        let diaries = try store.visibleBabies.compactMap { baby -> WatchDiary? in
            guard let canWrite = try access(babyID: baby.id) else { return nil }
            var diary = try WatchDiary(id: baby.id, name: baby.name, canWrite: canWrite,
                                       events: store.persistence.events(babyID: baby.id))
            var included = Set<UUID>()
            diary.events = [
                diary.latestFeeding,
                diary.latestCompletedFeeding,
                diary.active(.breast),
                diary.active(.sleep),
            ]
            .compactMap(\.self)
            .filter { included.insert($0.id).inserted }
            .map { event in
                var event = event
                event.createdBy = nil
                event.lastEditedBy = nil
                event.note = ""
                return event
            }
            return diary
        }
        let selectedID = diaries.first { $0.id == store.selectedID }?.id ?? diaries.first?.id
        if let lastSnapshot, !refresh, lastSnapshot.staleAt > .now,
           lastSnapshot.diaries == diaries, lastSnapshot.selectedID == selectedID
        {
            return lastSnapshot
        }

        // The stream is installation-local; restoring an earlier backup starts a new epoch.
        var streamDirectory = directory.appending(path: "Stream", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: streamDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try streamDirectory.setResourceValues(values)
        let streamURL = streamDirectory.appending(path: "checkpoint")
        var stream = try read(Stream.self, from: streamURL) ?? Stream()
        stream.revision += 1
        let snapshot = WatchSnapshot(
            streamID: stream.id,
            revision: stream.revision,
            generatedAt: Date(),
            selectedID: selectedID,
            diaries: diaries
        )
        try write(stream, to: streamURL)
        lastSnapshot = snapshot
        return snapshot
    }

    func receive(_ operation: WatchOperation) throws -> WatchReceipt {
        try checkReady()
        let url = directory.appending(path: operation.id.uuidString)
        let outcome: Outcome
        if let saved = try read(Outcome.self, from: url) {
            outcome = saved
        } else {
            let author = "Malysh.watch.\(operation.id.uuidString)"
            do {
                if try !hasCommitted(author: author) {
                    try apply(operation, author: author)
                }
                outcome = Outcome(rejection: nil)
            } catch let rejection as WatchRejection {
                outcome = Outcome(rejection: rejection)
            }
            // A crash before this write is recovered by the Core Data transaction author.
            // A saved outcome survives deletion, store purges and later timer transitions.
            try write(outcome, to: url)
        }
        return try WatchReceipt(operationID: operation.id, rejection: outcome.rejection, snapshot: snapshot())
    }

    private func apply(_ operation: WatchOperation, author: String) throws {
        try store.reload()
        guard store.visibleBabies.contains(where: { $0.id == operation.babyID }) else {
            throw WatchRejection.diaryUnavailable
        }
        let persistence = store.persistence
        let record = try persistence.babyObject(id: operation.babyID)
        if record?.objectID.persistentStore == persistence.sharedStore,
           persistence.cloudStartupError != nil, !persistence.cloudEnabled
        {
            throw Retry.storeUnavailable
        }
        guard try access(babyID: operation.babyID) == true else { throw WatchRejection.diaryUnavailable }
        let events = try store.persistence.events(babyID: operation.babyID)
        if operation.action.createsEvent, events.contains(where: { $0.id == operation.id }) {
            return
        }
        // Small clock discrepancies resolve on retry without rewriting recorded times.
        if operation.date > Date(), operation.date.timeIntervalSinceNow < 60 {
            throw Retry.clockSkew
        }
        let event = try operation.applying(to: events)
        try store.save(event, transactionAuthor: author)
    }

    private func hasCommitted(author: String) throws -> Bool {
        let context = store.persistence.container.viewContext
        guard let entity = NSPersistentHistoryTransaction.entityDescription(with: context) else {
            throw Retry.storeUnavailable
        }
        let fetch = NSFetchRequest<NSFetchRequestResult>()
        fetch.entity = entity
        fetch.predicate = NSPredicate(format: "author == %@", author)
        fetch.fetchLimit = 1
        let request = NSPersistentHistoryChangeRequest.fetchHistory(withFetch: fetch)
        request.resultType = .transactionsOnly
        let result = try context.execute(request) as? NSPersistentHistoryResult
        guard let transactions = result?.result as? [NSPersistentHistoryTransaction] else {
            throw Retry.storeUnavailable
        }
        return !transactions.isEmpty
    }

    /// A shared store may have several shares with different permissions.
    private func access(babyID: UUID) throws -> Bool? {
        let persistence = store.persistence
        guard let record = try persistence.babyObject(id: babyID) else { return nil }
        if record.objectID.persistentStore == persistence.privateStore {
            return true
        }
        // The same shared SQLite is retained when mirroring is off or fails to start.
        guard persistence.cloudEnabled else { return nil }
        let shares = try persistence.container.fetchShares(matching: [record.objectID])
        guard let participant = shares[record.objectID]?.currentUserParticipant,
              participant.acceptanceStatus == .accepted else { return nil }
        return participant.permission == .readWrite
    }

    private func checkReady() throws {
        guard store.ready, store.persistence.isLoaded, !store.diaryRemovalInProgress,
              !store.cloudSwitchInProgress
        else {
            throw Retry.storeUnavailable
        }
    }

    private func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        do {
            return try JSONDecoder().decode(type, from: Data(contentsOf: url))
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
    }

    private func write(_ value: some Encodable, to url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private enum Retry: Error { case storeUnavailable, clockSkew }
}
