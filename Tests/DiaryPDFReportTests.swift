import Foundation
@testable import Malysh
import XCTest

final class DiaryPDFReportTests: XCTestCase {
    func testMissingDaysAreNotZerosAndTodayDoesNotChangeAverages() throws {
        let baby = Baby(name: "Малыш")
        let calendar = try calendar(in: "UTC")
        let first = try date(1, 0, in: calendar)
        let today = try date(3, 12, in: calendar)
        let events: [CareEvent] = try [
            CareEvent(babyID: baby.id, kind: .bottle, start: date(1, 8, in: calendar), volumeML: 90),
            CareEvent(babyID: baby.id, kind: .diaper, start: date(1, 9, in: calendar), diaperType: .dirty),
            CareEvent(babyID: baby.id, kind: .diaper, start: date(3, 8, in: calendar), diaperType: .mixed),
            CareEvent(babyID: baby.id, kind: .bottle, start: date(3, 9, in: calendar), volumeML: 60,
                      bottleType: .expressed),
            CareEvent(babyID: baby.id, kind: .breast, start: date(3, 10, in: calendar),
                      end: date(3, 11, in: calendar), leftSeconds: 180, rightSeconds: 120),
            CareEvent(babyID: baby.id, kind: .breast, start: date(3, 11, in: calendar)),
            CareEvent(babyID: baby.id, kind: .bottle, start: date(3, 13, in: calendar)),
        ]
        let report = try DiaryPDFReport(
            snapshot: DiarySnapshot(baby: baby, events: events, measurements: []),
            startDate: first, endDate: today, generatedAt: today, calendar: calendar
        )

        XCTAssertNil(report.age)
        XCTAssertEqual(report.pastDayCount, 2)
        XCTAssertEqual(report.days.count, 3)
        XCTAssertEqual(report.days[0].breastFeeds, 0)
        XCTAssertEqual(report.days[0].wetDiapers, 0)
        XCTAssertNil(report.days[1].breastFeeds)
        XCTAssertNil(report.days[1].wetDiapers)
        XCTAssertEqual(report.days[2].wetDiapers, 1)
        XCTAssertEqual(report.days[2].dirtyDiapers, 1)
        XCTAssertEqual(report.days[2].breastFeeds, 2)
        XCTAssertEqual(report.days[2].bottleFeeds, 1)
        XCTAssertEqual(report.days[2].bottleVolumeML, 60)
        XCTAssertEqual(report.feedAverage.value, 1)
        XCTAssertEqual(report.feedAverage.recordedDays, 1)
        XCTAssertEqual(report.wetAverage.value, 0)
        XCTAssertEqual(report.wetAverage.recordedDays, 1)
        XCTAssertNil(report.sleepAverage.value)
        XCTAssertEqual(report.sleepAverage.recordedDays, 0)
        XCTAssertEqual(report.formulaML, 90)
        XCTAssertEqual(report.expressedML, 60)
        XCTAssertEqual(report.breastMedianSeconds, 300)
        XCTAssertEqual(report.breastDurationCount, 1)
    }

    func testOverlappingSleepIsClippedAndSplitAcrossDSTMidnights() throws {
        let baby = Baby(name: "Малыш")
        let calendar = try calendar(in: "America/New_York")
        let start = try date(9, 0, in: calendar)
        let end = try date(11, 0, in: calendar)
        let generatedAt = try date(11, 14, in: calendar)
        let first = try CareEvent(babyID: baby.id, kind: .sleep, start: date(8, 23, in: calendar),
                                  end: date(9, 10, in: calendar))
        let second = try CareEvent(babyID: baby.id, kind: .sleep, start: date(9, 9, in: calendar),
                                   end: date(10, 2, in: calendar))
        let active = try CareEvent(babyID: baby.id, kind: .sleep, start: date(11, 2, in: calendar))
        let futureEnd = try CareEvent(babyID: baby.id, kind: .sleep, start: date(11, 4, in: calendar),
                                      end: date(11, 16, in: calendar))
        let report = try DiaryPDFReport(
            snapshot: DiarySnapshot(baby: baby, events: [futureEnd, active, second, first], measurements: []),
            startDate: start, endDate: end, generatedAt: generatedAt, calendar: calendar
        )

        XCTAssertTrue(report.hasContent)
        XCTAssertEqual(report.days.map(\.sleepSeconds), [23 * 3600, 2 * 3600, nil])
        XCTAssertEqual(report.sleepAverage.value, 12.5 * 3600)
        XCTAssertEqual(report.sleepAverage.recordedDays, 2)
        let entries = report.days.map { day in
            day.entries.compactMap { entry -> CareEvent? in
                guard case let .event(event) = entry else { return nil }
                return event
            }
        }
        XCTAssertEqual(entries, [[first, second], [], [active, futureEnd]])
    }

    func testMeasurementsUseLatestAtPeriodEndAndDeltaOnlyWithinPeriod() throws {
        let calendar = try calendar(in: "UTC")
        let birthday = try date(1, 0, in: calendar)
        var baby = Baby(name: "Малыш", birthDate: birthday, birthDateConfirmed: true)
        baby.birthDay = CivilDay(date: birthday, timeZone: calendar.timeZone)
        let start = try date(3, 0, in: calendar)
        let end = try date(5, 0, in: calendar)
        let generatedAt = try date(9, 12, in: calendar)
        let oldHeight = try ChildMeasurement(babyID: baby.id, type: .height, measuredAt: date(2, 0, in: calendar),
                                             value: 52)
        let firstWeight = ChildMeasurement(babyID: baby.id, type: .weight, measuredAt: start, value: 3300)
        let lastWeight = ChildMeasurement(babyID: baby.id, type: .weight, measuredAt: end, value: 3400)
        let laterWeight = try ChildMeasurement(babyID: baby.id, type: .weight, measuredAt: date(6, 0, in: calendar),
                                               value: 3500)
        let report = try DiaryPDFReport(
            snapshot: DiarySnapshot(baby: baby, events: [],
                                    measurements: [lastWeight, oldHeight, firstWeight, laterWeight]),
            startDate: start, endDate: end, generatedAt: generatedAt, calendar: calendar
        )

        XCTAssertTrue(report.hasContent)
        XCTAssertEqual(report.age, "4 дн.")
        XCTAssertEqual(report.measurementSummaries.map(\.latest), [lastWeight, oldHeight])
        XCTAssertEqual(report.measurementSummaries.map(\.firstInPeriod), [firstWeight, nil])
        XCTAssertEqual(report.measurementSummaries.map(\.change), [100, nil])
        XCTAssertEqual(report.days.map(\.entries.count), [1, 0, 1])

        let empty = try DiaryPDFReport(
            snapshot: DiarySnapshot(baby: baby, events: [], measurements: [oldHeight]),
            startDate: start, endDate: end, generatedAt: generatedAt, calendar: calendar
        )
        XCTAssertFalse(empty.hasContent)
        XCTAssertEqual(empty.measurementSummaries.map(\.latest), [oldHeight])
    }

    private func calendar(in timeZone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, in calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 3, day: day, hour: hour)))
    }
}
