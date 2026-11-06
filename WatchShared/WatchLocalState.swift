import Foundation

struct WatchLocalState: Codable, Equatable, Sendable {
    private(set) var snapshot: WatchSnapshot?
    private var retiredStreams: Set<UUID> = []
    private(set) var pending: [WatchOperation] = []
    private(set) var preferredDiaryID: UUID?
    private(set) var rejection: WatchRejection?

    static var fileURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "MalyshAppGroup") as? String else {
            return nil
        }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("WatchDiary.json")
    }

    var selectedID: UUID? {
        guard let snapshot else { return nil }
        let candidates = [preferredDiaryID, snapshot.selectedID, snapshot.diaries.first?.id]
        return candidates.compactMap(\.self).first { id in snapshot.diaries.contains { $0.id == id } }
    }

    var selectedDiary: WatchDiary? {
        diaries.first { $0.id == selectedID }
    }

    var diaries: [WatchDiary] {
        guard let snapshot else { return [] }
        return snapshot.diaries.map { diary in
            guard diary.canWrite else { return diary }
            var events = diary.events
            let now = Date()
            for operation in pending where operation.babyID == diary.id {
                if operation.action.createsEvent, events.contains(where: { $0.id == operation.eventID }) {
                    continue
                }
                if let event = try? operation.applying(to: events, now: max(now, operation.date)) {
                    events.removeAll { $0.id == event.id }
                    events.append(event)
                }
            }
            return WatchDiary(id: diary.id, name: diary.name, canWrite: diary.canWrite, events: events)
        }
    }

    static func read(from url: URL) throws -> Self {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    func write(to url: URL) throws {
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }

    mutating func select(_ id: UUID) {
        guard snapshot?.diaries.contains(where: { $0.id == id }) == true else { return }
        preferredDiaryID = id
    }

    mutating func enqueue(_ operation: WatchOperation) throws {
        guard let diary = diaries.first(where: { $0.id == operation.babyID }), diary.canWrite else {
            throw WatchRejection.diaryUnavailable
        }
        _ = try operation.applying(to: diary.events)
        pending.append(operation)
        rejection = nil
    }

    mutating func receive(_ snapshot: WatchSnapshot) {
        guard !retiredStreams.contains(snapshot.streamID) else { return }
        if let current = self.snapshot {
            if current.streamID == snapshot.streamID {
                guard snapshot.revision > current.revision else { return }
            } else {
                retiredStreams.insert(current.streamID)
            }
        }
        if let selectedID, !snapshot.diaries.contains(where: { $0.id == selectedID }) {
            preferredDiaryID = nil
            rejection = .diaryUnavailable
        }
        self.snapshot = snapshot
    }

    mutating func receive(_ receipt: WatchReceipt) {
        // Only a context or a fresh snapshot reply can establish a replacement phone stream.
        guard snapshot?.streamID == receipt.snapshot.streamID else { return }
        receive(receipt.snapshot)
        guard pending.first?.id == receipt.operationID else { return }
        pending.removeFirst()
        if let rejection = receipt.rejection {
            self.rejection = rejection
        }
    }
}
