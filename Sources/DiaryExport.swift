@preconcurrency import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct DiaryExportDocument: FileDocument, Sendable {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct DiaryExport: Encodable {
    struct Profile: Encodable {
        let id: UUID
        let name: String
        let birthDate: String?
        let birthTime: CivilTime?
        let birthTimeZone: String?
        let birthMeasurementsCompleted: Bool

        init(_ baby: Baby, birthMeasurementsCompleted: Bool) {
            id = baby.id
            name = baby.name
            if baby.birthDateConfirmed {
                let day = baby.birthDay ?? CivilDay(date: baby.birthDate)
                birthDate = String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
            } else {
                birthDate = nil
            }
            birthTime = baby.birthTime
            birthTimeZone = baby.birthTimeZoneIdentifier
            self.birthMeasurementsCompleted = birthMeasurementsCompleted
        }
    }

    struct Author: Encodable {
        let name: String?
        let role: ParentRole?

        init?(_ author: EventAuthor) {
            guard author.nameSnapshot != nil || author.role != nil else { return nil }
            name = author.nameSnapshot
            role = author.role
        }
    }

    struct Event: Encodable {
        let id: UUID
        let kind: EventKind
        let start: Date
        let end: Date?
        let createdAt: Date
        let modifiedAt: Date
        let createdBy: Author?
        let lastEditedBy: Author?
        let side: BreastSide?
        let sideStartedAt: Date?
        let leftSeconds: TimeInterval?
        let rightSeconds: TimeInterval?
        let volumeML: Int?
        let bottleType: BottleType?
        let diaperType: DiaperType?
        let note: String

        init(_ event: CareEvent) {
            id = event.id
            kind = event.kind
            start = event.start
            end = event.end
            createdAt = event.createdAt
            modifiedAt = event.modifiedAt
            createdBy = event.createdBy.flatMap(Author.init)
            lastEditedBy = event.lastEditedBy.flatMap(Author.init)
            side = event.kind == .breast ? event.side : nil
            sideStartedAt = event.kind == .breast ? event.sideStartedAt : nil
            leftSeconds = event.kind == .breast ? event.leftSeconds : nil
            rightSeconds = event.kind == .breast ? event.rightSeconds : nil
            volumeML = event.kind == .bottle ? event.volumeML : nil
            bottleType = event.kind == .bottle ? event.bottleType : nil
            diaperType = event.kind == .diaper ? event.diaperType : nil
            note = event.note
        }
    }

    struct Measurement: Encodable {
        let id: UUID
        let type: MeasurementType
        let measuredAt: Date
        let value: Double
        let unit: String
        let createdAt: Date
        let modifiedAt: Date
        let note: String?

        init(_ measurement: ChildMeasurement) {
            id = measurement.id
            type = measurement.type
            measuredAt = measurement.measuredAt
            value = measurement.value
            unit = measurement.type == .weight ? "g" : "cm"
            createdAt = measurement.createdAt
            modifiedAt = measurement.modifiedAt
            note = measurement.note
        }
    }

    let schemaVersion = 1
    let exportedAt = Date()
    let profile: Profile
    let events: [Event]
    let measurements: [Measurement]

    init(id: UUID, context: NSManagedObjectContext) throws {
        let roots = NSFetchRequest<NSManagedObject>(entityName: "BabyRecord")
        roots.predicate = NSPredicate(format: "id == %@", id as NSUUID)
        roots.fetchLimit = 2
        let matches = try context.fetch(roots)
        guard !matches.isEmpty else { throw Persistence.Failure.missingBaby }
        guard matches.count == 1, let root = matches.first, let store = root.objectID.persistentStore else {
            throw Persistence.Failure.diaryChanged
        }

        let decoder = JSONDecoder()
        let baby: Baby = try Self.decode(root, using: decoder)
        guard baby.id == id else { throw CocoaError(.coderReadCorrupt) }
        profile = Profile(
            baby,
            birthMeasurementsCompleted: root.value(forKey: "birthMeasurementsCompleted") as? Bool == true
        )
        let predicate = NSPredicate(format: "babyID == %@", id as NSUUID)

        let eventRequest = NSFetchRequest<NSManagedObject>(entityName: "EventRecord")
        eventRequest.predicate = predicate
        eventRequest.affectedStores = [store]
        let storedEvents: [CareEvent] = try context.fetch(eventRequest).map { try Self.decode($0, using: decoder) }
        guard storedEvents.allSatisfy({ $0.babyID == id }) else { throw CocoaError(.coderReadCorrupt) }
        events = storedEvents.sorted {
            $0.start == $1.start ? $0.id.uuidString < $1.id.uuidString : $0.start < $1.start
        }.map(Event.init)

        let measurementRequest = NSFetchRequest<NSManagedObject>(entityName: "MeasurementRecord")
        measurementRequest.predicate = predicate
        measurementRequest.affectedStores = [store]
        let storedMeasurements: [ChildMeasurement] = try context.fetch(measurementRequest).map {
            try Self.decode($0, using: decoder)
        }
        guard storedMeasurements.allSatisfy({ $0.babyID == id }) else { throw CocoaError(.coderReadCorrupt) }
        measurements = storedMeasurements.sorted(by: ChildMeasurement.newestFirst).map(Measurement.init)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var value = encoder.singleValueContainer()
            let style = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
            try value.encode(date.ISO8601Format(style))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    private static func decode<T: Decodable>(_ object: NSManagedObject, using decoder: JSONDecoder) throws -> T {
        guard let data = object.value(forKey: "payload") as? Data else { throw CocoaError(.coderReadCorrupt) }
        return try decoder.decode(T.self, from: data)
    }
}

extension Persistence {
    func exportDiary(id: UUID) async throws -> DiaryExportDocument {
        guard isLoaded else { throw Failure.notLoaded }
        let context = container.newBackgroundContext()
        let data = try await context.perform {
            // Pin all three fetches to the same committed SQLite snapshot.
            try context.setQueryGenerationFrom(.current)
            return try DiaryExport(id: id, context: context).encoded()
        }
        return DiaryExportDocument(data: data)
    }
}
