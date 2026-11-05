import Foundation
import ImageIO
@testable import Malysh
import Photos
import Synchronization
import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class PhotoWorkflowTests: XCTestCase {
    private final class Writer: PhotoLibraryWriting {
        var calls = 0
        var error: Error?
        var onSave: (() throws -> Void)?
        var holdFirstWrite = false
        var firstWriteContinuation: CheckedContinuation<Void, Never>?
        var firstStartedWaiter: CheckedContinuation<Void, Never>?
        func waitForFirstWrite() async {
            if firstWriteContinuation != nil {
                return
            }
            await withCheckedContinuation { firstStartedWaiter = $0 }
        }

        func authorizeAdding() async -> Bool {
            error == nil
        }

        func saveOriginal(_: Data, capturedAt _: Date, requestPermission _: Bool) async throws -> String {
            calls += 1
            if holdFirstWrite, calls == 1 {
                await withCheckedContinuation { continuation in
                    firstWriteContinuation = continuation
                    firstStartedWaiter?.resume()
                    firstStartedWaiter = nil
                }
            }
            if let error {
                throw error
            }
            try onSave?()
            return "asset-\(calls)"
        }
    }

    private func image() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16), format: format).image { c in
            UIColor.orange.setFill(); c.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        }.jpegData(compressionQuality: 0.9)!
    }

    func testDeniedOriginalNeverEntersGalleryAndRetrySavesOnce() async throws {
        let persistence = Persistence(inMemory: true)
        try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer(); writer.error = PhotoFailure.permission
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await gallery.capture(data: image(), babyID: baby.id)
        XCTAssertTrue(try gallery.photos(babyID: baby.id).isEmpty)
        XCTAssertEqual(gallery.pendingCount, 1)
        writer.error = nil
        await gallery.retryPending()
        await gallery.retryPending()
        XCTAssertEqual(try gallery.photos(babyID: baby.id).count, 1)
        XCTAssertEqual(writer.calls, 2)
    }

    func testImportDoesNotWritePhotosDeduplicatesAndAllowsReimportAfterDeletion() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer()
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        for _ in 0 ..< 2 {
            await gallery.importPhoto(
                data: image(),
                assetIdentifier: "existing",
                babyID: baby.id,
                capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
        XCTAssertEqual(writer.calls, 0)
        let photo = try XCTUnwrap(gallery.photos(babyID: baby.id).first)
        try gallery.delete(photo)
        await gallery.importPhoto(
            data: image(),
            assetIdentifier: "existing",
            babyID: baby.id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(try gallery.photos(babyID: baby.id).count, 1)
        XCTAssertEqual(writer.calls, 0)
    }

    func testUnknownWriteRemainsDurableAndDoesNotBlindlyRetry() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer(); writer.error = PhotoFailure.unknownWrite
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await gallery.capture(data: image(), babyID: baby.id)
        writer.error = nil
        let reopened = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await reopened.retryPending()
        XCTAssertEqual(writer.calls, 1)
        XCTAssertTrue(try reopened.photos(babyID: baby.id).isEmpty)
    }

    func testAutoSaveDisabledByDefaultAndNeverPromptsInBackground() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let photo = BabyPhoto(
            babyID: baby.id,
            capturedAt: Date(),
            addedBy: "user-other",
            pixelWidth: 16,
            pixelHeight: 16
        )
        try persistence.savePhoto(photo, imageData: image(), thumbnailData: image())
        let writer = Writer()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await gallery.saveReceivedIfEnabled(); XCTAssertEqual(writer.calls, 0)
        await gallery.setAutoSaveReceived(true); XCTAssertEqual(writer.calls, 1)
        await gallery.saveReceivedIfEnabled(); XCTAssertEqual(writer.calls, 1)
    }

    func testFamilyMediaKeepsOriginalDimensionsDateAndStripsGPS() throws {
        let original = image()
        let source = try XCTUnwrap(CGImageSourceCreateWithData(original as CFData, nil))
        let bytes = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            bytes,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 55.0, kCGImagePropertyGPSLongitude: 37.0],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2026:11:01 12:30:00",
                "OffsetTimeOriginal": "+03:00",
            ],
        ]
        CGImageDestinationAddImageFromSource(destination, source, 0, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let media = try PhotoMedia.prepare(bytes as Data)
        XCTAssertEqual(media.width, 16)
        XCTAssertEqual(media.height, 16)
        XCTAssertEqual(media.capturedAt, ISO8601DateFormatter().date(from: "2026-11-01T09:30:00Z"))
        let familySource = try XCTUnwrap(CGImageSourceCreateWithData(media.image as CFData, nil))
        let familyProperties = CGImageSourceCopyPropertiesAtIndex(familySource, 0, nil) as? [CFString: Any]
        XCTAssertNil(familyProperties?[kCGImagePropertyGPSDictionary])
    }

    func testCorruptJournalFailsClosedWithoutPhotosWrite() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent("journal.json"))
        let writer = Writer()
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await gallery.capture(data: image(), babyID: baby.id)
        XCTAssertEqual(writer.calls, 0)
        XCTAssertNotNil(gallery.errorMessage)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("journal.json"), encoding: .utf8),
            "corrupt"
        )
    }

    func testConfirmedPhotosWriteSurvivesFamilySaveFailureAndRelaunch() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Малыш"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer()
        writer.onSave = { try persistence.deleteBabyAndEvents(ids: [baby.id]) }
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await gallery.capture(data: image(), babyID: baby.id)
        XCTAssertEqual(writer.calls, 1)
        XCTAssertNil(try persistence.babyObject(id: baby.id))
        XCTAssertEqual(gallery.pendingCount, 1)
        try persistence.saveBaby(baby)
        writer.onSave = nil
        let reopened = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await reopened.retryPending()
        XCTAssertEqual(writer.calls, 1)
        XCTAssertEqual(try reopened.photos(babyID: baby.id).count, 1)
    }

    func testImportWithoutAssetIdentifierStillNeverWritesBackToPhotos() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer()
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        await gallery.importPhoto(
            data: image(),
            assetIdentifier: nil,
            babyID: baby.id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let photo = try XCTUnwrap(gallery.photos(babyID: baby.id).first)
        XCTAssertTrue(gallery.hasLocalAsset(photo))
        await gallery.saveToPhotos(photo)
        XCTAssertEqual(writer.calls, 0)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let other = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20), format: format)
            .image { context in
                UIColor.blue.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
            }.jpegData(compressionQuality: 0.9))
        await gallery.importPhoto(
            data: other,
            assetIdentifier: nil,
            babyID: baby.id,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(try gallery.photos(babyID: baby.id).count, 2)
        XCTAssertEqual(writer.calls, 0)
    }

    func testReceivedNotificationDuringBusyWriteQueuesFreshRescan() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let bytes = image()
        let first = BabyPhoto(
            babyID: baby.id,
            capturedAt: Date(),
            addedBy: "user-other",
            pixelWidth: 16,
            pixelHeight: 16
        )
        try persistence.savePhoto(first, imageData: bytes, thumbnailData: bytes)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer(); writer.holdFirstWrite = true
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        let enabling = Task { await gallery.setAutoSaveReceived(true) }
        await writer.waitForFirstWrite()
        let second = BabyPhoto(
            babyID: baby.id,
            capturedAt: Date(),
            addedBy: "user-other",
            pixelWidth: 16,
            pixelHeight: 16
        )
        try persistence.savePhoto(second, imageData: bytes, thumbnailData: bytes)
        let receivedNotification = Task { await gallery.saveReceivedIfEnabled() }
        await Task.yield()
        writer.firstWriteContinuation?.resume()
        writer.firstWriteContinuation = nil
        await enabling.value
        await receivedNotification.value
        XCTAssertEqual(writer.calls, 2)
        XCTAssertTrue(gallery.hasLocalAsset(first))
        XCTAssertTrue(gallery.hasLocalAsset(second))
    }

    private func jpegImagePayload(_ data: Data) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xD8 else { throw PhotoFailure.invalidImage }
        var result = Data(bytes.prefix(2))
        var offset = 2
        while offset < bytes.count {
            let start = offset
            guard bytes[offset] == 0xFF else { throw PhotoFailure.invalidImage }
            while offset < bytes.count, bytes[offset] == 0xFF {
                offset += 1
            }
            guard offset < bytes.count else { throw PhotoFailure.invalidImage }
            let marker = bytes[offset]
            offset += 1
            if marker == 0xDA || marker == 0xD9 {
                result.append(contentsOf: bytes[start...])
                return result
            }
            guard offset + 2 <= bytes.count else { throw PhotoFailure.invalidImage }
            let length = Int(bytes[offset]) * 256 + Int(bytes[offset + 1])
            guard length >= 2, offset + length <= bytes.count else { throw PhotoFailure.invalidImage }
            offset += length
            if !(0xE0 ... 0xEF).contains(marker), marker != 0xFE {
                result.append(contentsOf: bytes[start ..< offset])
            }
        }
        throw PhotoFailure.invalidImage
    }

    func testRealPhotoKitWritesExactOriginalOnTransactionQueue() async throws {
        guard ProcessInfo.processInfo.environment["MALYSH_PHOTOKIT_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "Opt-in integration test requires a dedicated simulator with Photos permissions already granted."
            )
        }
        #if targetEnvironment(simulator)
            XCTAssertEqual(PHPhotoLibrary.authorizationStatus(for: .addOnly), .authorized)
            guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else { return }
            let bytes = image()
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try bytes.write(to: documents.appendingPathComponent("PhotoKitIntegrationExpected.jpg"), options: .atomic)
            let capturedAt = Date(timeIntervalSince1970: 1_234_567_890)
            let identifier = try await PhotoLibraryService().saveOriginal(
                bytes,
                capturedAt: capturedAt,
                requestPermission: false
            )
            XCTAssertFalse(identifier.isEmpty)
            let canRead = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized
            let receipt: [String: Any] = [
                "assetIdentifier": identifier,
                "capturedAt": capturedAt.timeIntervalSince1970,
                "readVerificationPerformed": canRead,
            ]
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(
                to: documents.appendingPathComponent("PhotoKitIntegrationReceipt.json"), options: .atomic
            )
            // The shipped app deliberately declares add-only access. When read access
            // is unavailable, the dedicated simulator's original is compared from the host.
            guard canRead else { return }
            let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject)
            XCTAssertEqual(
                asset.creationDate?.timeIntervalSince1970 ?? 0,
                capturedAt.timeIntervalSince1970,
                accuracy: 1
            )
            let resource = try XCTUnwrap(PHAssetResource.assetResources(for: asset).first(where: { $0.type == .photo }))
            let buffer = Mutex(Data())
            let restored: Data = try await withCheckedThrowingContinuation { continuation in
                PHAssetResourceManager.default().requestData(
                    for: resource,
                    options: nil,
                    dataReceivedHandler: { @Sendable chunk in
                        buffer.withLock { $0.append(chunk) }
                    },
                    completionHandler: { @Sendable error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume(returning: buffer.withLock { $0 })
                        }
                    }
                )
            }
            // Photos can enrich EXIF APP segments; the encoded image must remain unchanged.
            XCTAssertEqual(try jpegImagePayload(restored), try jpegImagePayload(bytes))
        #else
            throw XCTSkip("This integration test only writes to a dedicated simulator library.")
        #endif
    }
}
