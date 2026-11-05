import Foundation
@testable import Malysh
import XCTest

final class DomainTests: XCTestCase {
    private let babyID = UUID()
    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    func testSwitchingSidesAndFinishingAccumulatesOnce() throws {
        var event = CareEvent(babyID: babyID, kind: .breast, start: origin)
        event.switchSide(at: origin.addingTimeInterval(60))
        event.switchSide(at: origin.addingTimeInterval(90))
        event.finish(at: origin.addingTimeInterval(120))
        event.finish(at: origin.addingTimeInterval(200))
        let durations = event.breastDurations(now: origin.addingTimeInterval(300))
        XCTAssertEqual(durations.left, 90)
        XCTAssertEqual(durations.right, 30)
        XCTAssertEqual(event.elapsed(now: origin.addingTimeInterval(300)), 120)
        try event.validate(now: origin.addingTimeInterval(300))
    }

    func testMidnightClippingOverlapAndFutureEvents() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let midnight = calendar.startOfDay(for: origin)
        let now = midnight.addingTimeInterval(3600)
        let events = [
            CareEvent(
                babyID: babyID,
                kind: .sleep,
                start: midnight.addingTimeInterval(-600),
                end: midnight.addingTimeInterval(600)
            ),
            CareEvent(
                babyID: babyID,
                kind: .sleep,
                start: midnight.addingTimeInterval(300),
                end: midnight.addingTimeInterval(1200)
            ),
            CareEvent(babyID: babyID, kind: .sleep, start: midnight.addingTimeInterval(1800)),
            CareEvent(babyID: babyID, kind: .bottle, start: midnight, volumeML: 90),
            CareEvent(babyID: babyID, kind: .diaper, start: midnight, diaperType: .mixed),
            CareEvent(babyID: babyID, kind: .bottle, start: now.addingTimeInterval(1)),
        ]
        let stats = DailyStatistics(events: events, day: midnight, calendar: calendar, now: now)
        XCTAssertEqual(stats.sleepSeconds, 3000)
        XCTAssertEqual(stats.feeds, 1)
        XCTAssertEqual(stats.bottleML, 90)
        XCTAssertEqual(stats.wetDiapers, 1)
        XCTAssertEqual(stats.dirtyDiapers, 1)
    }

    func testDaylightSavingDaysUseCalendarBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day)))
            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: date))
            let event = CareEvent(
                babyID: babyID,
                kind: .sleep,
                start: interval.start.addingTimeInterval(-60),
                end: interval.end.addingTimeInterval(60)
            )
            let stats = DailyStatistics(
                events: [event],
                day: date,
                calendar: calendar,
                now: interval.end.addingTimeInterval(120)
            )
            XCTAssertEqual(stats.sleepSeconds, Double(hours * 3600))
        }
    }

    func testValidationRejectsInvalidInputs() {
        var event = CareEvent(babyID: babyID, kind: .bottle, start: origin)
        XCTAssertThrowsError(try event.validate(now: origin.addingTimeInterval(-1)))
        event.volumeML = 0
        XCTAssertThrowsError(try event.validate(now: origin))
        event.volumeML = 60
        event.end = origin.addingTimeInterval(-1)
        XCTAssertThrowsError(try event.validate(now: origin))
        event.end = nil
        event.leftSeconds = .infinity
        XCTAssertThrowsError(try event.validate(now: origin))
        event.leftSeconds = 0
        event.sideStartedAt = origin.addingTimeInterval(-1)
        XCTAssertThrowsError(try event.validate(now: origin))
    }
}
