import CryptoKit
import Foundation
import Observation
import Photos
#if DEBUG
    import UIKit
#endif

@MainActor @Observable
final class PhotoGalleryStore {
    private let persistence: Persistence
    private let library: any PhotoLibraryWriting
    private let directory: URL
    private var journal: Journal
    private var journalUnavailable = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    var isBusy = false
    var errorMessage: String?
    var revision = 0
    var pendingCount: Int {
        pendingPhotos.count
    }

    var pendingPhotos: [BabyPhoto] {
        let exports = ((try? persistence.babies()) ?? []).flatMap { (try? persistence.photos(babyID: $0.id)) ?? [] }
            .filter { journal.assets["saving:" + $0.id.uuidString] != nil }
        return journal.pending.map(\.photo) + exports
    }

    func needsReconciliation(_ photo: BabyPhoto) -> Bool {
        journal.pending.first(where: { $0.photo.id == photo.id })?.writing == true || journal
            .assets["saving:" + photo.id.uuidString] != nil
    }

    private(set) var autoSaveReceived: Bool {
        get { journal.autoSaveReceived }
        set { journal.autoSaveReceived = newValue; persistOrReport() }
    }

    private var fixtureBabyIDs: Set<UUID> = []
    private struct Pending: Codable {
        var photo: BabyPhoto
        var sourceKey: String
        var needsPhotos: Bool
        var writing = false
        var assetID: String?
    }

    private struct Journal: Codable {
        var pending: [Pending] = []
        var assets: [String: String] = [:]
        var imports: [String: UUID] = [:]
        var autoSaveReceived = false
    }

    init(persistence: Persistence, library: (any PhotoLibraryWriting)? = nil, directory: URL? = nil) {
        self.persistence = persistence
        #if DEBUG
            self
                .library = library ??
                (ProcessInfo.processInfo.arguments
                    .contains("--ui-testing") ? FixturePhotoWriter() : PhotoLibraryService())
        #else
            self.library = library ?? PhotoLibraryService()
        #endif
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
                "PhotoWorkflow",
                isDirectory: true
            )
        let url = self.directory.appendingPathComponent("journal.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            } catch {
                journal = Journal(); journalUnavailable = true; errorMessage =
                    "Не удалось прочитать журнал сохранения фото. Сохранение остановлено, чтобы не создавать дубликаты."
            }
        } else {
            journal = Journal()
        }
        if !journalUnavailable {
            do { try prepareDirectory() } catch { errorMessage = error.localizedDescription }
            let retained = Set(journal.pending.map { $0.photo.id.uuidString + ".original" })
            for file in (try? FileManager.default.contentsOfDirectory(
                at: self.directory,
                includingPropertiesForKeys: nil
            )) ?? []
                where file.pathExtension == "original" && !retained.contains(file.lastPathComponent)
            {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    func setAutoSaveReceived(_ enabled: Bool) async {
        if enabled,
           await !(library.authorizeAdding())
        {
            errorMessage = PhotoFailure.permission.localizedDescription; return
        }
        autoSaveReceived = enabled
        if enabled {
            await saveReceivedIfEnabled()
        }
    }

    func hasLocalAsset(_ photo: BabyPhoto) -> Bool {
        journal.assets[photo.id.uuidString] != nil
    }

    /// Resolve an interrupted write only after the user explicitly selects its existing original.
    func reconcilePending(_ id: UUID, existingAssetIdentifier: String) async {
        await acquire(); defer { release() }
        guard !existingAssetIdentifier.isEmpty else { return }
        if journal.assets["saving:" + id.uuidString] != nil {
            journal.assets[id.uuidString] = existingAssetIdentifier
            journal.assets.removeValue(forKey: "saving:" + id.uuidString)
            persistOrReport()
            revision += 1
            return
        }
        guard let index = journal.pending.firstIndex(where: { $0.photo.id == id }) else { return }
        journal.pending[index].assetID = existingAssetIdentifier
        journal.pending[index].writing = false
        do { try persist(); try await finish(id) } catch { errorMessage = error.localizedDescription }
    }

    func photos(babyID: UUID) throws -> [BabyPhoto] {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
               ProcessInfo.processInfo.arguments.contains("--photo-fixtures"), !fixtureBabyIDs.contains(babyID)
            {
                fixtureBabyIDs.insert(babyID)
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
                for index in 0 ..< 2 {
                    let image = renderer.image { context in
                        (index == 0 ? UIColor.systemOrange : UIColor.systemTeal).setFill()
                        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))
                    }.jpegData(compressionQuality: 0.8)!
                    let photo = BabyPhoto(
                        id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index + 1)")!,
                        babyID: babyID,
                        capturedAt: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 86400),
                        addedBy: index == 0 ? "owner" : "user-fixture",
                        pixelWidth: 240,
                        pixelHeight: 240
                    )
                    try persistence.savePhoto(photo, imageData: image, thumbnailData: image)
                }
            }
        #endif
        return try persistence.photos(babyID: babyID)
    }

    func data(for photo: BabyPhoto, thumbnail: Bool = false) -> Data? {
        try? persistence.photoData(
            id: photo.id,
            thumbnail: thumbnail
        )
    }

    func capture(data: Data, babyID: UUID) async {
        await add(
            data: data,
            assetIdentifier: nil,
            babyID: babyID,
            camera: true
        )
    }

    func importPhoto(data: Data, assetIdentifier: String?, babyID: UUID, capturedAt: Date? = nil) async {
        await add(
            data: data,
            assetIdentifier: assetIdentifier,
            babyID: babyID,
            camera: false,
            capturedAt: capturedAt
        )
    }

    func importDate(for data: Data, assetIdentifier: String?) async -> Date? {
        if let metadataDate = await Task.detached(operation: { PhotoMedia.metadataDate(data) }).value {
            return metadataDate
        }
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard let assetIdentifier, status == .authorized || status == .limited else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject?.creationDate
    }

    private func add(data: Data, assetIdentifier: String?, babyID: UUID, camera: Bool, capturedAt: Date? = nil) async {
        guard !journalUnavailable else { return }
        await acquire()
        defer { release() }
        do {
            let key = babyID.uuidString + ":" + (assetIdentifier ?? SHA256.hash(data: data).map { String(
                format: "%02x",
                $0
            ) }.joined())
            if let existingID = journal.imports[key],
               try persistence.photos(babyID: babyID).contains(where: { $0.id == existingID })
            {
                return
            }
            if let assetIdentifier,
               try persistence.photos(babyID: babyID)
                   .contains(where: { journal.assets[$0.id.uuidString] == assetIdentifier })
            {
                return
            }
            if let pending = journal.pending.first(where: {
                $0.photo.babyID == babyID && assetIdentifier != nil && $0.assetID == assetIdentifier
            }) {
                try await finish(pending.photo.id)
                return
            }
            if let pending = journal.pending
                .first(where: { $0.sourceKey == key })
            {
                try await finish(pending.photo.id); return
            }
            let stagedBytes = journal.pending.reduce(0) { total, item in
                let attributes = try? FileManager.default.attributesOfItem(atPath: originalURL(item.photo.id).path)
                return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
            }
            guard journal.pending.count < 30, stagedBytes + data.count <= 256_000_000 else {
                throw PhotoFailure.storageFull
            }
            let knownDate = await importDate(for: data, assetIdentifier: assetIdentifier)
            let sourceDate = knownDate ?? capturedAt
            guard camera || sourceDate != nil else { throw PhotoFailure.missingDate }
            let media = try await Task.detached { try PhotoMedia.prepare(data, fallbackDate: sourceDate) }.value
            let photo = BabyPhoto(
                babyID: babyID,
                capturedAt: media.capturedAt,
                addedBy: "",
                pixelWidth: media.width,
                pixelHeight: media.height
            )
            try prepareDirectory()
            try data.write(
                to: originalURL(photo.id),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            journal.pending.append(Pending(photo: photo, sourceKey: key, needsPhotos: camera, assetID: assetIdentifier))
            try persist()
            try await finish(photo.id)
        } catch { errorMessage = error.localizedDescription }
    }

    func retryPending() async {
        guard !journalUnavailable else { return }
        await acquire()
        defer { release() }
        for id in journal.pending.map(\.photo.id) {
            do { try await finish(id) } catch { errorMessage = error.localizedDescription }
        }
    }

    private func finish(_ id: UUID) async throws {
        guard let index = journal.pending.firstIndex(where: { $0.photo.id == id }) else { return }
        var pending = journal.pending[index]
        let original = try Data(contentsOf: originalURL(id))
        if pending.needsPhotos, pending.assetID == nil {
            guard !pending.writing else { throw PhotoFailure.unknownWrite }
            journal.pending[index].writing = true
            try persist()
            do {
                let asset = try await library.saveOriginal(
                    original,
                    capturedAt: pending.photo.capturedAt,
                    requestPermission: true
                )
                journal.pending[index].assetID = asset
                journal.pending[index].writing = false
                // A persistence failure after confirmed Photos success must not reset to an unsafe retry.
                try persist()
                pending = journal.pending[index]
            } catch {
                // A known Photos failure can retry. Unknown outcome remains quarantined.
                if journal.pending[index].assetID == nil,
                   !(error is PhotoFailure && (error as? PhotoFailure) == .unknownWrite)
                {
                    journal.pending[index].writing = false
                    try? persist()
                }
                throw error
            }
        }
        if pending.photo.addedBy.isEmpty {
            guard let author = try persistence.currentEventAuthor(babyID: pending.photo.babyID) else {
                throw PhotoFailure.missingAuthor
            }
            pending.photo.addedBy = author.id
            journal.pending[index].photo = pending.photo
            try persist()
        }
        let media = try await Task.detached { try PhotoMedia.prepare(original) }.value
        try persistence.savePhoto(pending.photo, imageData: media.image, thumbnailData: media.thumbnail)
        journal.imports[pending.sourceKey] = id
        if let asset = pending.assetID {
            journal.assets[id.uuidString] = asset
            journal.imports[pending.photo.babyID.uuidString + ":" + asset] = id
        } else if !pending.needsPhotos {
            // Picker data already comes from Photos even when its identifier is unavailable.
            journal.assets[id.uuidString] = "picker-existing-no-identifier"
        }
        journal.pending.removeAll { $0.photo.id == id }
        try persist()
        try? FileManager.default.removeItem(at: originalURL(id))
        revision += 1
    }

    func saveToPhotos(_ photo: BabyPhoto, requestPermission: Bool = true) async {
        await acquire(); defer { release() }
        await saveToPhotosImpl(photo, requestPermission: requestPermission)
    }

    private func saveToPhotosImpl(_ photo: BabyPhoto, requestPermission: Bool) async {
        guard !journalUnavailable, journal.assets[photo.id.uuidString] == nil else { return }
        let key = "saving:" + photo.id.uuidString
        guard journal.assets[key] == nil else { errorMessage = PhotoFailure.unknownWrite.localizedDescription; return }
        do {
            guard let bytes = try persistence.photoData(id: photo.id) else { throw PhotoFailure.invalidImage }
            journal.assets[key] = "pending"; try persist()
            do {
                let asset = try await library.saveOriginal(
                    bytes,
                    capturedAt: photo.capturedAt,
                    requestPermission: requestPermission
                )
                journal.assets[photo.id.uuidString] = asset
                journal.assets.removeValue(forKey: key)
                try persist()
            } catch {
                if !(error is PhotoFailure && (error as? PhotoFailure) == .unknownWrite) {
                    journal.assets.removeValue(forKey: key); try? persist()
                }
                throw error
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func saveReceivedIfEnabled() async {
        guard autoSaveReceived else { return }
        await acquire(); defer { release() }
        guard autoSaveReceived else { return }
        do {
            for baby in try persistence.babies() {
                guard let current = try persistence.currentEventAuthor(babyID: baby.id)?.id else { continue }
                for photo in try photos(babyID: baby.id) where photo.addedBy != current {
                    guard autoSaveReceived else { return }
                    await saveToPhotosImpl(photo, requestPermission: false)
                }
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func delete(_ photo: BabyPhoto) throws {
        try persistence.deletePhoto(id: photo.id); revision += 1
    }

    func toggleFavorite(_ photo: BabyPhoto) throws {
        var value = photo; value.isFavorite.toggle(); try persistence.updatePhoto(value); revision += 1
    }

    func pin(_ photo: BabyPhoto?, babyID: UUID) throws {
        guard var baby = try persistence.babies().first(where: { $0.id == babyID }) else { return }
        baby.pinnedPhotoID = photo?.id
        try persistence.saveBaby(baby); revision += 1
    }

    private func acquire() async {
        while isBusy {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        isBusy = true
    }

    private func release() {
        isBusy = false
        let waiters = idleWaiters; idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func originalURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".original")
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
    }

    private func persist() throws {
        guard !journalUnavailable else { throw PhotoFailure.unknownWrite }
        try prepareDirectory()
        try JSONEncoder().encode(journal).write(
            to: directory.appendingPathComponent("journal.json"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    private func persistOrReport() {
        do { try persist() } catch { errorMessage = error.localizedDescription }
    }
}

#if DEBUG
    @MainActor
    private final class FixturePhotoWriter: PhotoLibraryWriting {
        func authorizeAdding() async -> Bool {
            true
        }

        func saveOriginal(_: Data, capturedAt _: Date, requestPermission _: Bool) async throws -> String {
            "fixture-" + UUID().uuidString
        }
    }
#endif
