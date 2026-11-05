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
        XCTAssertNil(decoded.ageLabel())
        XCTAssertTrue(decoded.parentProfiles.isEmpty)
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
