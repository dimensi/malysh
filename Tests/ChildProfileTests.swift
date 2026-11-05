import Foundation
@testable import Malysh
import XCTest

final class ChildProfileTests: XCTestCase {
    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testLegacyDateRemainsUnconfirmedAndPreserved() throws {
        let original = Baby(name: "Малыш", birthDate: Date(timeIntervalSince1970: 12345))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        json.removeValue(forKey: "birthDateConfirmed")
        json.removeValue(forKey: "birthDay")
        let decoded = try JSONDecoder().decode(Baby.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.birthDateConfirmed)
        XCTAssertNil(decoded.ageLabel())
        XCTAssertEqual(decoded.birthDate, original.birthDate)
    }

    func testCalendarAgeBoundariesAndNoNegativeAge() {
        let utc = calendar()
        var baby = Baby(name: "Тест", birthDate: date(2024, 1, 31, calendar: utc), birthDateConfirmed: true)
        baby.birthDay = CivilDay(date: baby.birthDate, timeZone: utc.timeZone)
        XCTAssertEqual(baby.ageLabel(now: date(2024, 2, 6, calendar: utc), calendar: utc), "6 дн.")
        XCTAssertEqual(baby.ageLabel(now: date(2024, 2, 7, calendar: utc), calendar: utc), "1 нед. 0 дн.")
        XCTAssertEqual(baby.ageLabel(now: date(2024, 2, 29, calendar: utc), calendar: utc), "1 мес.")
        XCTAssertEqual(baby.ageLabel(now: date(2025, 1, 31, calendar: utc), calendar: utc), "1 г.")
        XCTAssertEqual(baby.ageLabel(now: date(2023, 1, 1, calendar: utc), calendar: utc), "0 дн.")
    }

    func testCivilBirthdaySurvivesTravelAndDSTDayRollover() {
        let la = calendar("America/Los_Angeles")
        let tokyo = calendar("Asia/Tokyo")
        var baby = Baby(name: "Тест", birthDate: date(2024, 3, 9, calendar: la), birthDateConfirmed: true)
        baby.birthDay = CivilDay(date: baby.birthDate, timeZone: la.timeZone)
        XCTAssertEqual(baby.ageLabel(now: date(2024, 3, 10, calendar: la), calendar: la), "1 дн.")
        XCTAssertEqual(baby.ageLabel(now: date(2024, 3, 11, calendar: la), calendar: la), "2 дн.")
        XCTAssertEqual(baby.ageLabel(now: date(2024, 3, 10, calendar: tokyo), calendar: tokyo), "1 дн.")
        XCTAssertEqual(tokyo.component(.day, from: baby.displayedBirthDate(calendar: tokyo)), 9)
    }

    func testEditorPreservesFractionalPrecisionAcrossUnitsAndNoteOnlyEdits() throws {
        for value in [3500.5, 0.4, 52.123456789] {
            XCTAssertEqual(Double(ChildMeasurement.editorText(value: value)), value)
            let kilograms = try XCTUnwrap(ChildMeasurement.convertedWeightText(String(value), toKilograms: true))
            let grams = try XCTUnwrap(ChildMeasurement.convertedWeightText(kilograms, toKilograms: false))
            XCTAssertEqual(try XCTUnwrap(Double(grams)), value, accuracy: 0.000000001)
        }
    }

    func testMeasurementValidationAndStableSorting() throws {
        let id = UUID()
        let date = Date().addingTimeInterval(-60)
        let first = ChildMeasurement(babyID: id, type: .weight, measuredAt: date, value: 3500)
        var second = first
        second.id = UUID()
        second.measuredAt = date.addingTimeInterval(1)
        XCTAssertEqual([first, second].sorted(by: ChildMeasurement.newestFirst).first?.id, second.id)
        for value in [0, -1, Double.nan, .infinity] {
            var invalid = first
            invalid.value = value
            XCTAssertThrowsError(try invalid.validate())
        }
        var future = first
        future.measuredAt = Date().addingTimeInterval(100)
        XCTAssertThrowsError(try future.validate())
        try first.validate()
    }
}
