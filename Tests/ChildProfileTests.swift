import Foundation
@testable import Malysh
import XCTest

final class ChildProfileTests: XCTestCase {
    func testLegacyBabyPayloadPreservesUnconfirmedBirthDateAndDefaultsParentProfiles() throws {
        struct LegacyBaby: Encodable { let id: UUID; let name: String; let birthDate: Date }
        let original = LegacyBaby(id: UUID(), name: "Малыш", birthDate: Date(timeIntervalSince1970: 12345))
        let decoded = try JSONDecoder().decode(Baby.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.birthDate, original.birthDate)
        XCTAssertFalse(decoded.birthDateConfirmed)
        XCTAssertNil(decoded.birthTime)
        XCTAssertFalse(decoded.birthMeasurementsCompleted)
        XCTAssertNil(decoded.ageLabel())
        XCTAssertTrue(decoded.parentProfiles.isEmpty)
    }

    func testBirthTimeRoundTripsAsLocalClockTimeAcrossTimeZones() throws {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Moscow"))
        var destination = source
        destination.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for (month, day) in [(1, 15), (3, 8)] {
            let components = DateComponents(year: 2026, month: month, day: day, hour: 2, minute: 30)
            let birth = try XCTUnwrap(source.date(from: components))
            var baby = Baby(name: "Малыш", birthDate: birth, birthDateConfirmed: true)
            baby.birthDay = CivilDay(date: birth, timeZone: source.timeZone)
            baby.birthTime = CivilTime(date: birth, calendar: source)
            baby.birthTimeZoneIdentifier = source.timeZone.identifier
            let decoded = try JSONDecoder().decode(Baby.self, from: JSONEncoder().encode(baby))
            let clock = try XCTUnwrap(decoded.birthTime)
            let birthDay = try XCTUnwrap(decoded.birthDay)
            XCTAssertEqual(clock.hour, 2)
            XCTAssertEqual(clock.minute, 30)
            XCTAssertEqual(
                clock.date(on: birthDay, calendar: destination, recordedTimeZone: decoded.birthTimeZoneIdentifier),
                birth
            )
            if month == 3 {
                XCTAssertNil(clock.date(on: birthDay, calendar: destination))
            }
        }
    }

    func testEditorPreservesFractionalPrecisionAcrossUnitsAndNoteOnlyEdits() throws {
        for value in [3500.5, 0.4, 52.123456789] {
            XCTAssertEqual(Double(ChildMeasurement.editorText(value: value)), value)
            let kilograms = try XCTUnwrap(ChildMeasurement.convertedWeightText(String(value), toKilograms: true))
            let grams = try XCTUnwrap(ChildMeasurement.convertedWeightText(kilograms, toKilograms: false))
            XCTAssertEqual(try XCTUnwrap(Double(grams)), value, accuracy: 0.000000001)
        }
    }
}
