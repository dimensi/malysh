import Foundation

/// Local device knowledge of the last proven current participant for each diary.
/// This file is never included in the shared Baby payload.
@MainActor
final class EventAuthorCache {
    private let url: URL?
    private var entries: [String: EventAuthor]?

    init(directory: URL, inMemory: Bool) {
        url = inMemory ? nil : directory.appendingPathComponent("EventAuthors.json")
    }

    func author(babyID: UUID) throws -> EventAuthor? {
        try loadIfNeeded()
        return entries?[babyID.uuidString]
    }

    func remember(_ author: EventAuthor, babyID: UUID) throws {
        try loadIfNeeded()
        var updated = entries ?? [:]
        guard updated[babyID.uuidString] != author else { return }
        updated[babyID.uuidString] = author
        try write(updated)
    }

    func retain(babyIDs: Set<UUID>) throws {
        try loadIfNeeded()
        let keys = Set(babyIDs.map(\.uuidString))
        let updated = (entries ?? [:]).filter { keys.contains($0.key) }
        if updated != entries {
            try write(updated)
        }
    }

    func forget(babyIDs: Set<UUID>) throws {
        try loadIfNeeded()
        var updated = entries ?? [:]
        for id in babyIDs {
            updated.removeValue(forKey: id.uuidString)
        }
        try write(updated)
    }

    func clear() throws {
        // Invalidate memory even if a disk write fails; never reuse a previous account.
        entries = [:]
        try write([:])
    }

    private func loadIfNeeded() throws {
        guard entries == nil else { return }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            entries = [:]
            return
        }
        entries = try JSONDecoder().decode([String: EventAuthor].self, from: Data(contentsOf: url))
    }

    private func write(_ updated: [String: EventAuthor]) throws {
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(updated).write(
                to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        }
        entries = updated
    }
}
