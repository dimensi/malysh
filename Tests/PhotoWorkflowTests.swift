import Foundation
import ImageIO
@testable import Malysh
import UIKit
import UniformTypeIdentifiers
import XCTest

@MainActor
final class PhotoWorkflowTests: XCTestCase {
    private final class Writer: PhotoLibraryWriting {
        var calls = 0
        var error: Error?
        var delay = false
        var onSave: (() throws -> Void)?
        func authorizeAdding() async -> Bool {
            error == nil
        }

        func saveOriginal(_: Data, capturedAt _: Date, requestPermission _: Bool) async throws -> String {
            calls += 1
            if delay {
                try await Task.sleep(for: .milliseconds(20))
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
            await gallery.importPhoto(data: image(), assetIdentifier: "existing", babyID: baby.id)
        }
        XCTAssertEqual(writer.calls, 0)
        let photo = try XCTUnwrap(gallery.photos(babyID: baby.id).first)
        try gallery.delete(photo)
        await gallery.importPhoto(data: image(), assetIdentifier: "existing", babyID: baby.id)
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

    func testConcurrentCapturesAreQueuedInsteadOfDropped() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer(); writer.delay = true
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        let bytes = image()
        async let first: Void = gallery.capture(data: bytes, babyID: baby.id)
        async let second: Void = gallery.importPhoto(data: bytes, assetIdentifier: "picker-second", babyID: baby.id)
        _ = await (first, second)
        XCTAssertEqual(try gallery.photos(babyID: baby.id).count, 2)
        XCTAssertEqual(writer.calls, 1)
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
        await gallery.importPhoto(data: image(), assetIdentifier: nil, babyID: baby.id)
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
        await gallery.importPhoto(data: other, assetIdentifier: nil, babyID: baby.id)
        XCTAssertEqual(try gallery.photos(babyID: baby.id).count, 2)
        XCTAssertEqual(writer.calls, 0)
    }

    func testImportOfPreviouslyCapturedAssetDoesNotDuplicateFamilyPhoto() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = Writer()
        let gallery = PhotoGalleryStore(persistence: persistence, library: writer, directory: directory)
        let bytes = image()
        await gallery.capture(data: bytes, babyID: baby.id)
        await gallery.importPhoto(data: bytes, assetIdentifier: "asset-1", babyID: baby.id)
        XCTAssertEqual(try gallery.photos(babyID: baby.id).count, 1)
        XCTAssertEqual(writer.calls, 1)
    }

    func testLocalWorkflowJournalIsExcludedFromDeviceBackup() async throws {
        let persistence = Persistence(inMemory: true); try await persistence.load()
        let baby = Baby(name: "Test"); try persistence.saveBaby(baby)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gallery = PhotoGalleryStore(persistence: persistence, library: Writer(), directory: directory)
        await gallery.importPhoto(data: image(), assetIdentifier: "existing", babyID: baby.id)
        XCTAssertNil(gallery.errorMessage)
        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
