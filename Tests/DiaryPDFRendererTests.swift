@testable import Malysh
import PDFKit
import XCTest

final class DiaryPDFRendererTests: XCTestCase {
    func testWeeklySummaryFitsA4AndDetailedAppendixAddsNotesOnlyWhenRequested() throws {
        let name = "Андрей Александр Константинович Воронцов-Дашков"
        let fixture = try Fixture(name: name)
        let report = try fixture.report(start: fixture.first, end: fixture.today)
        let brief = try render(report, detailed: false, notes: true)
        let detailed = try render(report, detailed: true, notes: false)
        let annotated = try render(report, detailed: true, notes: true)

        XCTAssertEqual(brief.pageCount, 1)
        let page = try XCTUnwrap(brief.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 595.28, accuracy: 0.1)
        XCTAssertEqual(page.bounds(for: .mediaBox).height, 841.89, accuracy: 0.1)
        let summary = try XCTUnwrap(page.string)
        XCTAssertTrue(summary.split(whereSeparator: \.isWhitespace).joined(separator: " ").contains(name))
        XCTAssertTrue(summary.contains("Последние измерения"))
        XCTAssertFalse(summary.contains("продолжается"))
        XCTAssertEqual(detailed.page(at: 0)?.string, summary)
        XCTAssertEqual(annotated.page(at: 0)?.string, summary)
        for phrase in ["Андрей", "1–7 ноября 2026", "сегодня", "до 13:20", "UTC+3",
                       "Записи за 1 из 6 дней", "Нет записей за день", "31 декабря 2025 · до периода"]
        {
            XCTAssertTrue(summary.contains(phrase), "Missing summary phrase: \(phrase)")
        }
        let text = try XCTUnwrap(detailed.string)
        XCTAssertGreaterThan(detailed.pageCount, brief.pageCount)
        for phrase in ["Подробные записи", "Смесь, 60 мл", "01.11.2026 23:50", "02.11.2026 02:10",
                       "Левая 1 мин 5 с", "продолжается", "49,25 см"]
        {
            XCTAssertTrue(text.contains(phrase), "Missing detailed phrase: \(phrase)")
        }
        XCTAssertFalse(text.contains("Секретная"))
        XCTAssertFalse(summary.contains("Секретная"))
        let annotatedText = try XCTUnwrap(annotated.string)
        XCTAssertTrue(annotatedText.contains("Секретная заметка о кормлении"))
        XCTAssertTrue(annotatedText.contains("Секретная заметка к измерению"))
        XCTAssertFalse(annotatedText.contains("Внутренняя личность"))
    }

    func testLongPeriodAndUnbrokenNoteContinueAcrossPagesWithSelectableText() throws {
        let fixture = try Fixture()
        let first = try XCTUnwrap(fixture.calendar.date(byAdding: .day, value: -45, to: fixture.today))
        let noteBody = String(repeating: "ABCXYZ", count: 1200)
        let note = "Начало заметки\n\(noteBody)\nКонец заметки"
        let report = try fixture.report(start: first, end: fixture.today, note: note)
        let brief = try render(report, detailed: false, notes: false)
        let detailed = try render(report, detailed: true, notes: true)
        let summary = try XCTUnwrap(brief.string)
        XCTAssertGreaterThan(brief.pageCount, 1)
        XCTAssertTrue(summary.contains("Записи по дням · продолжение"))
        XCTAssertTrue(summary.contains("23 сентября — 7 ноября 2026"))
        XCTAssertTrue(summary.contains("Записи за 1 из 45 дней"))
        XCTAssertEqual(detailed.page(at: brief.pageCount - 1)?.string, brief.page(at: brief.pageCount - 1)?.string)

        let text = try XCTUnwrap(detailed.string)
        XCTAssertTrue(text.contains("Начало заметки"))
        XCTAssertTrue(text.contains("Заметка · продолжение"))
        XCTAssertTrue(text.contains("Конец заметки"))
        // A word can straddle pages. Collect just its alphabet and remove PDFKit's line breaks.
        let extracted = text.split(separator: "\n").filter { line in
            !line.isEmpty && line.allSatisfy { "ABCXYZ".contains($0) || $0.isWhitespace }
        }.joined().filter { !$0.isWhitespace }
        XCTAssertEqual(extracted.count, noteBody.count)
        XCTAssertTrue(extracted == noteBody, "The long note must preserve characters in order.")
    }

    private func render(_ report: DiaryPDFReport, detailed: Bool, notes: Bool) throws -> PDFDocument {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DiaryPDFRenderer.write(report, detailed: detailed, includesNotes: notes, to: url)
        return try XCTUnwrap(PDFDocument(data: Data(contentsOf: url)))
    }

    private struct Fixture {
        let calendar: Calendar
        let baby: Baby
        let first: Date
        let today: Date
        let generated: Date

        init(name: String = "Андрей") throws {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 10800))
            self.calendar = calendar
            first = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
            today = try XCTUnwrap(calendar.date(byAdding: .day, value: 6, to: first))
            generated = today.addingTimeInterval(13 * 3600 + 20 * 60)
            baby = Baby(name: name, birthDate: first.addingTimeInterval(-20 * 86400), birthDateConfirmed: true)
        }

        func report(start: Date, end: Date, note: String = "Секретная заметка о кормлении") throws -> DiaryPDFReport {
            let events = [
                CareEvent(babyID: baby.id, kind: .bottle, start: first.addingTimeInterval(8 * 3600),
                          volumeML: 60, note: note, createdBy: EventAuthor(id: "Внутренняя личность")),
                CareEvent(babyID: baby.id, kind: .breast, start: first.addingTimeInterval(9 * 3600),
                          end: first.addingTimeInterval(9 * 3600 + 135), leftSeconds: 65, rightSeconds: 70),
                CareEvent(babyID: baby.id, kind: .sleep, start: first.addingTimeInterval(23 * 3600 + 50 * 60),
                          end: first.addingTimeInterval(26 * 3600 + 10 * 60)),
                CareEvent(babyID: baby.id, kind: .sleep, start: today.addingTimeInterval(13 * 3600)),
            ]
            let measurements = try [
                ChildMeasurement(
                    babyID: baby.id,
                    type: .weight,
                    measuredAt: XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))),
                    value: 3650
                ),
                ChildMeasurement(babyID: baby.id, type: .height, measuredAt: first.addingTimeInterval(3600),
                                 value: 49.25, note: "Секретная заметка к измерению"),
            ]
            return try DiaryPDFReport(
                snapshot: DiarySnapshot(baby: baby, events: events, measurements: measurements),
                startDate: start, endDate: end, generatedAt: generated, calendar: calendar
            )
        }
    }
}
