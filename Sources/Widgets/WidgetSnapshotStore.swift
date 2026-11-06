import Foundation

struct WidgetSnapshotStore: Sendable {
    static let appGroupIdentifier = AppConfiguration.appGroup
    static let widgetKind = "MalyshDiary"
    private let directory: URL?
    private var fileURL: URL? {
        directory?.appendingPathComponent("diary-widget-v1.json")
    }

    static var defaultDirectory: URL? {
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        #if DEBUG
            if UserDefaults(suiteName: appGroupIdentifier)?.bool(forKey: "debug.widgetTestingSession") == true {
                return group?.appendingPathComponent("UITesting", isDirectory: true)
            }
        #endif
        return group
    }

    init(directory: URL? = WidgetSnapshotStore.defaultDirectory) {
        self.directory = directory
    }

    func read() throws -> WidgetSnapshot? {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        // This is a bounded cache, never a general-purpose diary import.
        guard data.count <= 2_000_000 else { return nil }
        let snapshot = try JSONDecoder().decode(WidgetSnapshot.self, from: data)
        guard snapshot.version == WidgetSnapshot.currentVersion,
              snapshot.events.count <= WidgetSnapshot.historyLimit else { return nil }
        return snapshot
    }

    @discardableResult
    func write(_ snapshot: WidgetSnapshot) throws -> Bool {
        guard let directory, let fileURL else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        // Available to Lock Screen widgets after first unlock; protected during boot.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var excluded = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return true
    }
}
