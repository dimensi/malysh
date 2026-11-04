import Foundation

/// Keeps per-parent revisions independently of CloudKit's whole-payload conflict resolution.
@MainActor
final class ParentProfileCache {
    private let url: URL?
    private var entries: [String: [String: ParentProfile]]?

    init(directory: URL, inMemory: Bool) {
        url = inMemory ? nil : directory.appendingPathComponent("ParentProfiles.json")
    }

    func profiles(babyID: UUID) throws -> [String: ParentProfile] {
        try loadIfNeeded()
        return entries?[babyID.uuidString] ?? [:]
    }

    func remember(babyID: UUID, profiles: [String: ParentProfile]) throws {
        try loadIfNeeded()
        let previous = entries ?? [:]
        var updated = previous
        let key = babyID.uuidString
        let merged = ParentProfile.merging(previous[key] ?? [:], profiles)
        guard !merged.isEmpty, previous[key] != merged else { return }
        updated[key] = merged
        try write(updated)
    }

    func forget(babyIDs: Set<UUID>) throws {
        try loadIfNeeded()
        var updated = entries ?? [:]
        for id in babyIDs {
            updated.removeValue(forKey: id.uuidString)
        }
        guard updated != entries else { return }
        try write(updated)
    }

    private func loadIfNeeded() throws {
        guard entries == nil else { return }
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            entries = [:]
            return
        }
        entries = try JSONDecoder().decode([String: [String: ParentProfile]].self, from: Data(contentsOf: url))
    }

    private func write(_ updated: [String: [String: ParentProfile]]) throws {
        if let url {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(updated)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        entries = updated
    }
}
