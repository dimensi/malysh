import CoreData
@testable import Malysh
import XCTest

@MainActor
final class DiaryExportTests: XCTestCase {
    func testSelectedDiaryExportContainsOfflineDataWithoutCloudIdentityOrPhotos() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        try await persistence.load()

        let date = Date(timeIntervalSince1970: 1_704_067_200.125)
        let cloudID = "user-cloud-identity"
        let other = Baby(name: "Личный")
        try persistence.saveBaby(other)
        try persistence.saveEvent(CareEvent(babyID: other.id, kind: .diaper, start: date, note: "Личная запись"))

        let photoID = UUID()
        var baby = Baby(name: "Общий", birthDate: date, birthDateConfirmed: true, pinnedPhotoID: photoID)
        baby.birthDay = try CivilDay(date: date, timeZone: XCTUnwrap(TimeZone(secondsFromGMT: -3600)))
        let context = persistence.container.viewContext
        let root = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
        try context.assign(root, to: XCTUnwrap(persistence.sharedStore))
        root.setValue(baby.id, forKey: "id")
        root.setValue(true, forKey: "birthMeasurementsCompleted")
        try root.setValue(JSONEncoder().encode(baby), forKey: "payload")
        try context.save()

        try persistence.savePhoto(
            BabyPhoto(id: photoID, babyID: baby.id, capturedAt: date, addedBy: cloudID, pixelWidth: 1, pixelHeight: 1),
            imageData: Data([1]), thumbnailData: Data([2])
        )
        for (index, kind) in EventKind.allCases.enumerated() {
            let start = date.addingTimeInterval(Double(index))
            let end = kind == .breast ? nil : start.addingTimeInterval(30)
            let author = kind == .breast ? EventAuthor(id: cloudID, nameSnapshot: "Имя в момент записи") : nil
            try persistence.saveEvent(CareEvent(
                babyID: baby.id, kind: kind, start: start, end: end, side: .right,
                volumeML: 90, bottleType: .expressed, diaperType: .mixed, note: "Заметка", createdBy: author
            ))
        }
        for type in MeasurementType.allCases {
            try persistence.saveMeasurement(ChildMeasurement(
                babyID: baby.id, type: type, measuredAt: date, value: type == .weight ? 3600 : 49.25,
                note: "Примечание к измерению"
            ))
        }

        let document = try await persistence.exportDiary(id: baby.id)
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: document.data) as? [String: Any])
        XCTAssertEqual(archive["schemaVersion"] as? Int, 1)
        let profile = try XCTUnwrap(archive["profile"] as? [String: Any])
        XCTAssertEqual(profile["id"] as? String, baby.id.uuidString)
        XCTAssertEqual(profile["birthDate"] as? String, "2023-12-31")
        XCTAssertEqual(profile["birthMeasurementsCompleted"] as? Bool, true)

        let events = try XCTUnwrap(archive["events"] as? [[String: Any]])
        XCTAssertEqual(events.compactMap { $0["kind"] as? String }, EventKind.allCases.map(\.rawValue))
        let breast = try XCTUnwrap(events.first)
        XCTAssertEqual(breast["start"] as? String, "2024-01-01T00:00:00.125Z")
        XCTAssertEqual(breast["side"] as? String, "right")
        XCTAssertNil(breast["end"])
        XCTAssertEqual(breast["note"] as? String, "Заметка")
        XCTAssertEqual((breast["createdBy"] as? [String: String])?["name"], "Имя в момент записи")
        XCTAssertEqual(events[1]["volumeML"] as? Int, 90)
        XCTAssertEqual(events[1]["bottleType"] as? String, "expressed")
        XCTAssertEqual(events[2]["diaperType"] as? String, "mixed")
        XCTAssertNil(events[3]["createdBy"])
        XCTAssertNotNil(events[3]["end"])

        let measurements = try XCTUnwrap(archive["measurements"] as? [[String: Any]])
        XCTAssertEqual(measurements.count, MeasurementType.allCases.count)
        for measurement in measurements {
            let isWeight = measurement["type"] as? String == MeasurementType.weight.rawValue
            XCTAssertEqual(measurement["unit"] as? String, isWeight ? "g" : "cm")
            XCTAssertEqual(measurement["value"] as? Double, isWeight ? 3600 : 49.25)
            XCTAssertEqual(measurement["note"] as? String, "Примечание к измерению")
        }
        let json = try XCTUnwrap(String(bytes: document.data, encoding: .utf8))
        for excluded in [cloudID, other.id.uuidString, photoID.uuidString, "Личная запись"] {
            XCTAssertFalse(json.contains(excluded))
        }
        XCTAssertNil(archive["photos"])

        let otherDocument = try await persistence.exportDiary(id: other.id)
        let otherArchive = try XCTUnwrap(JSONSerialization.jsonObject(with: otherDocument.data) as? [String: Any])
        let otherProfile = try XCTUnwrap(otherArchive["profile"] as? [String: Any])
        XCTAssertEqual(otherProfile["id"] as? String, other.id.uuidString)
        XCTAssertNil(otherProfile["birthDate"])
        XCTAssertEqual((otherArchive["events"] as? [[String: Any]])?.first?["note"] as? String, "Личная запись")
    }

    func testCorruptSelectedDiaryFailsInsteadOfProducingPartialExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let persistence = Persistence(directory: directory)
        try await persistence.load()
        let baby = Baby(name: "Профиль")
        try persistence.saveBaby(baby)

        let context = persistence.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "EventRecord", into: context)
        try context.assign(record, to: XCTUnwrap(persistence.privateStore))
        record.setValue(baby.id, forKey: "babyID")
        try context.save()

        do {
            _ = try await persistence.exportDiary(id: baby.id)
            XCTFail("Corrupt data must fail the entire export.")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .coderReadCorrupt)
        }

        context.delete(record)
        try context.save()
        let emptyDiary = try await persistence.exportDiary(id: baby.id)
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyDiary.data) as? [String: Any])
        XCTAssertEqual((archive["events"] as? [Any])?.count, 0)
        XCTAssertEqual((archive["measurements"] as? [Any])?.count, 0)
    }
}
