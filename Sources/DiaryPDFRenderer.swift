import CoreText
import UIKit

enum DiaryPDFRenderer {
    static func write(_ report: DiaryPDFReport, detailed: Bool, includesNotes: Bool, to url: URL) throws {
        try Task.checkCancellation()
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: "Дневник для педиатра",
            kCGPDFContextCreator as String: "Малыш",
        ]
        let renderer = UIGraphicsPDFRenderer(bounds: Layout.page, format: format)
        do {
            var drawingError: (any Error)?
            try renderer.writePDF(to: url) { context in
                do {
                    let layout = Layout(report: report, context: context)
                    try layout.drawSummary()
                    if detailed {
                        try layout.drawAppendix(includesNotes: includesNotes)
                    }
                } catch {
                    drawingError = error
                }
            }
            if let drawingError {
                throw drawingError
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private struct Title {
        let lines: [CTLine]
        let size: CGFloat
        let leading: CGFloat
    }

    private struct EntryRow {
        var time: String
        var endTime: String?
        var title: String
        var detail: String
        var note: String?
    }

    private enum Face {
        case regular, strong, serif

        var name: String {
            switch self {
            case .regular: "HelveticaNeue"
            case .strong: "HelveticaNeue-Medium"
            case .serif: "Georgia"
            }
        }
    }

    private enum Alignment { case left, center, right }

    private final class Layout {
        static let page = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        private let margin: CGFloat = 36
        private let bodyEnd: CGFloat = 750
        private let columns: [CGFloat] = [104, 52, 71, 68, 83, 74, 71]
        private let paper = CGColor(gray: 1, alpha: 1)
        private let ink = CGColor(red: 0.18, green: 0.18, blue: 0.21, alpha: 1)
        private let muted = CGColor(red: 0.38, green: 0.37, blue: 0.41, alpha: 1)
        private let gold = CGColor(red: 0.55, green: 0.36, blue: 0.08, alpha: 1)
        private let rule = CGColor(red: 0.88, green: 0.85, blue: 0.82, alpha: 1)
        private let neutral = CGColor(red: 0.96, green: 0.95, blue: 0.92, alpha: 1)
        private let feeding = CGColor(red: 0.97, green: 0.94, blue: 0.87, alpha: 1)
        private let sleep = CGColor(red: 0.95, green: 0.93, blue: 0.97, alpha: 1)
        private let diaper = CGColor(red: 0.92, green: 0.95, blue: 0.97, alpha: 1)

        private let report: DiaryPDFReport
        private let context: UIGraphicsPDFRendererContext
        private let locale = Locale(identifier: "ru_RU")
        private let dateFormatter = DateFormatter()
        private let numberFormatter = NumberFormatter()
        private var y: CGFloat = 0
        private var pageNumber = 0

        private var width: CGFloat {
            Self.page.width - margin * 2
        }

        private var right: CGFloat {
            Self.page.width - margin
        }

        private var canvas: CGContext {
            context.cgContext
        }

        init(report: DiaryPDFReport, context: UIGraphicsPDFRendererContext) {
            self.report = report
            self.context = context
            dateFormatter.locale = locale
            dateFormatter.calendar = report.calendar
            dateFormatter.timeZone = report.calendar.timeZone
            numberFormatter.locale = locale
            numberFormatter.numberStyle = .decimal
        }

        func drawSummary() throws {
            try beginPage()
            y = 63
            let title = titleLayout()
            for line in title.lines {
                if y + title.leading > bodyEnd {
                    try beginPage()
                    y = 63
                }
                draw(line, x: margin, baseline: y + title.size)
                y += title.leading
            }
            if y + 398 > bodyEnd {
                try beginPage()
                y = 63
            }
            if let age = report.age {
                label(age, at: margin, y: y, width: width / 2, size: 15, color: muted)
            }
            label(period, at: margin + width / 2, y: y, width: width / 2, size: 15, face: .strong, align: .right)
            y += 36
            drawMeasurements()
            label("Записи по дням", at: margin, y: y, size: 25, face: .serif)
            y += 39
            drawDailyHeaders()

            // Reserve space for full-period statistics on the summary page.
            let firstPageRows = max(0, Int((bodyEnd - y - 145) / 29))
            let summaryPage = pageNumber
            for day in report.days.prefix(firstPageRows) {
                drawDay(day)
            }
            drawStatistics()

            for day in report.days.dropFirst(firstPageRows) {
                if y + 29 > bodyEnd || pageNumber == summaryPage {
                    try beginPage()
                    label("Записи по дням · продолжение", at: margin, y: 64, size: 25, face: .serif)
                    label(period, at: margin, y: 98, size: 13, color: muted)
                    y = 127
                    drawDailyHeaders()
                }
                drawDay(day)
            }
        }

        private func titleLayout() -> Title {
            let large: CGFloat = 45
            let largeLines = lines(report.name, width: width, size: large, face: .serif, color: ink)
            if largeLines.count <= 1 {
                return Title(lines: largeLines, size: large, leading: 52)
            }

            // Two compact lines take at most 72 points, keeping seven daily rows on A4.
            let sizes: [CGFloat] = [32, 26, 22]
            for size in sizes {
                let wrapped = lines(report.name, width: width, size: size, face: .serif, color: ink)
                let leading = size + 4
                if CGFloat(wrapped.count) * leading <= 72 {
                    return Title(lines: wrapped, size: size, leading: leading)
                }
            }
            let compact = lines(report.name, width: width, size: 18, face: .serif, color: ink)
            return Title(lines: compact, size: 18, leading: 22)
        }

        private func drawMeasurements() {
            guard !report.measurementSummaries.isEmpty else { return }
            let columnWidth = (width - 28) / CGFloat(report.measurementSummaries.count)
            let available = columnWidth - 9
            let dates = report.measurementSummaries.map { item in
                lines(measurementDates(item), width: available, size: 11, face: .regular, color: muted)
            }
            let dateRows = dates.map(\.count).max() ?? 0
            let height = max(110, 94 + CGFloat(max(0, dateRows - 1)) * 13)
            panel(CGRect(x: margin, y: y, width: width, height: height), color: neutral, radius: 9)
            label("Последние измерения", at: margin + 14, y: y + 9, size: 17, face: .strong)

            for (index, item) in report.measurementSummaries.enumerated() {
                let measurement = item.latest
                let x = margin + 14 + CGFloat(index) * columnWidth
                if index > 0 {
                    divider(x: x - 7, from: y + 38, to: y + height - 14)
                }
                label(measurement.type.label, at: x, y: y + 34, width: available, size: 12, color: muted)
                label(measurementText(measurement), at: x, y: y + 49, width: available, size: 25, face: .strong)
                for (offset, line) in dates[index].enumerated() {
                    draw(line, x: x, baseline: y + 87 + CGFloat(offset) * 13)
                }
            }
            y += height + 16
        }

        private func measurementDates(_ item: DiaryPDFReport.MeasurementSummary) -> String {
            let measurement = item.latest
            let latest = measurementDate(measurement.measuredAt)
            let dateLabel = measurement.measuredAt < report.startDate ? "\(latest) · до периода" : latest
            guard let delta = item.change, let first = item.firstInPeriod else { return dateLabel }
            let sign = delta > 0 ? "+" : ""
            return "\(dateLabel)\n\(sign)\(number(delta)) \(measurement.type.unit) с \(measurementDate(first.measuredAt))"
        }

        private func measurementDate(_ value: Date) -> String {
            let sameYear = report.calendar.isDate(value, equalTo: report.endDate, toGranularity: .year)
            return date(value, sameYear ? "d MMMM" : "d MMMM yyyy")
        }

        private func drawDailyHeaders() {
            let groups = [("Кормления", 1 ..< 4, feeding), ("Сон", 4 ..< 5, sleep), ("Подгузники", 5 ..< 7, diaper)]
            for (title, range, color) in groups {
                let x = columnStart(range.lowerBound)
                let available = columns[range].reduce(0, +)
                panel(CGRect(x: x + 2, y: y, width: available - 4, height: 23), color: color, radius: 4)
                label(title, at: x, y: y + 4, width: available, size: 13, face: .strong, align: .center)
            }
            let captions = [
                ("День", ""), ("Грудью", "раз"), ("Из бутылочки", "раз"), ("Объём", "мл из бутылочки"),
                ("Всего сна", "ч и мин"), ("С мочой", "шт."), ("Со стулом", "шт."),
            ]
            for (index, caption) in captions.enumerated() {
                let x = columnStart(index) + (index == 0 ? 10 : 0)
                let alignment: Alignment = index == 0 ? .left : .center
                label(caption.0, at: x, y: y + 25, width: columns[index], size: 10, face: .strong, align: alignment)
                label(caption.1, at: x, y: y + 37, width: columns[index], size: 8, color: muted, align: alignment)
            }
            y += 51
            horizontalRule(at: y)
        }

        private func drawDay(_ day: DiaryPDFReport.Day) {
            let today = isToday(day.date)
            if today {
                panel(CGRect(x: margin, y: y, width: width, height: 29), color: neutral, radius: 3)
            }
            let dayText = date(day.date, "d MMM")
            label(dayText, at: margin + 10, y: y + (today ? 2 : 7),
                  width: columns[0] - 13, size: 12, face: today ? .strong : .regular)
            if today {
                label("сегодня до \(date(report.generatedAt, "HH:mm"))", at: margin + 10, y: y + 16,
                      width: columns[0] - 13, size: 10, color: muted)
            }
            let values: [String?] = [
                day.breastFeeds.map(String.init), day.bottleFeeds.map(String.init),
                day.bottleVolumeML.map(String.init), day.sleepSeconds.map { duration($0) },
                day.wetDiapers.map(String.init), day.dirtyDiapers.map(String.init),
            ]
            if values.allSatisfy({ $0 == nil }) {
                let empty = day.entries.isEmpty ? "Нет записей за день" : "Нет данных для сводки"
                label(empty, at: columnStart(1), y: y + 7, width: width - columns[0], size: 11,
                      color: muted, align: .center)
            } else {
                for (offset, value) in values.enumerated() {
                    let index = offset + 1
                    label(value ?? "—", at: columnStart(index), y: y + 7, width: columns[index], size: 12,
                          face: today ? .strong : .regular, color: value == nil ? muted : ink, align: .center)
                }
            }
            y += 29
            horizontalRule(at: y)
        }

        private func drawStatistics() {
            y += 15
            label("В среднем за прошедшие дни", at: margin, y: y, size: 16, face: .strong)
            y += 26
            let statistics = [
                (report.feedAverage, "Кормления"),
                (report.sleepAverage, "Сон"),
                (report.wetAverage, "Подгузники с мочой"),
            ]
            let available = width / 3
            for (index, statistic) in statistics.enumerated() {
                let (average, title) = statistic
                let x = margin + CGFloat(index) * available
                let value = average.value.map { index == 1 ? duration($0) : number($0, digits: 1) } ?? "—"
                label(title, at: x, y: y, width: available - 5, size: 11, color: muted)
                label(value, at: x, y: y + 13, width: available - 5, size: 17, face: .strong)
                label("Записи за \(average.recordedDays) из \(report.pastDayCount) дней", at: x, y: y + 33,
                      width: available - 5, size: 10, color: muted)
            }
            y += 56
            horizontalRule(at: y)
            let formula = report.formulaML.map { "\(number(Double($0))) мл" } ?? "—"
            let expressed = report.expressedML.map { "\(number(Double($0))) мл" } ?? "—"
            let breast = report.breastMedianSeconds.map {
                "\(duration($0)) · медиана по записям с длительностью (\(report.breastDurationCount))"
            } ?? "—"
            label("Из бутылочки", at: margin, y: y + 9, size: 12, face: .strong)
            label("Смесь \(formula) · Сцеженное молоко \(expressed)", at: margin + 140, y: y + 9,
                  width: width - 140, size: 12)
            label("Грудь", at: margin, y: y + 29, size: 12, face: .strong)
            label(breast, at: margin + 140, y: y + 29, width: width - 140, size: 12)
        }

        func drawAppendix(includesNotes: Bool) throws {
            try beginAppendixPage()
            for day in report.days {
                if y + 61 > bodyEnd {
                    try beginAppendixPage()
                }
                drawDayHeading(day.date, continued: false)
                if day.entries.isEmpty {
                    label("Нет подробных записей за день", at: margin + 10, y: y + 5, size: 11, color: muted)
                    y += 26
                }
                for entry in day.entries {
                    try Task.checkCancellation()
                    let row = rowContent(entry)
                    let details = lines(row.detail, width: width - 241, size: 11, face: .regular, color: ink)
                    let times = [row.time, row.endTime].compactMap(\.self).flatMap {
                        lines($0, width: 108, size: 10, face: .regular, color: muted)
                    }
                    let timeHeight = 10 + CGFloat(times.count) * 12
                    let height = max(timeHeight, 8 + CGFloat(details.count) * 13)
                    if y + height > bodyEnd {
                        try beginAppendixPage()
                        drawDayHeading(day.date, continued: true)
                    }
                    for (index, line) in times.enumerated() {
                        draw(line, x: margin + 10, baseline: y + 14 + CGFloat(index) * 12)
                    }
                    label(row.title, at: margin + 120, y: y + 4, width: 109, size: 11, face: .strong)
                    for (index, line) in details.enumerated() {
                        draw(line, x: margin + 234, baseline: y + 15 + CGFloat(index) * 13)
                    }
                    y += height
                    if includesNotes, let note = row.note,
                       !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    {
                        try drawNote(note, on: day.date)
                    }
                    horizontalRule(at: y)
                }
            }
        }

        private func rowContent(_ entry: DiaryPDFReport.Entry) -> EntryRow {
            switch entry {
            case let .measurement(measurement):
                return EntryRow(time: date(measurement.measuredAt, "HH:mm"), title: "Измерение",
                                detail: "\(measurement.type.label) · \(measurementText(measurement))",
                                note: measurement.note)
            case let .event(event):
                let start = date(event.start, "HH:mm")
                var row = EntryRow(time: start, title: event.kind.label, detail: "", note: event.note)
                switch event.kind {
                case .bottle:
                    row.detail = "\(event.bottleType.label), \(event.volumeML) мл"
                case .diaper:
                    switch event.diaperType {
                    case .wet: row.detail = "С мочой"
                    case .dirty: row.detail = "Со стулом"
                    case .mixed: row.detail = "С мочой и стулом"
                    }
                case .breast, .sleep:
                    describeTimedEvent(event, row: &row)
                }
                return row
            }
        }

        private func describeTimedEvent(_ event: CareEvent, row: inout EntryRow) {
            let end = min(event.end ?? report.generatedAt, report.generatedAt)
            let active = event.end == nil || end != event.end
            if active {
                if !report.calendar.isDate(event.start, inSameDayAs: report.generatedAt) {
                    row.time = date(event.start, "dd.MM.yyyy HH:mm")
                }
            } else {
                let range = completedRange(start: event.start, end: end)
                row.time = range.start
                row.endTime = range.end
            }
            if event.kind == .breast {
                row.title = "Кормление грудью"
                let sides = event.breastDurations(now: report.generatedAt)
                row.detail = "Левая \(duration(sides.left, seconds: true)) · правая \(duration(sides.right, seconds: true))"
            } else {
                row.detail = active ? "" : duration(event.elapsed(now: report.generatedAt), seconds: true)
            }
            if active {
                row.detail += row.detail.isEmpty ? "Сон продолжается" : " · продолжается"
            }
        }

        private func completedRange(start: Date, end: Date) -> (start: String, end: String?) {
            let sameDay = report.calendar.isDate(start, inSameDayAs: end)
            let format = sameDay ? "HH:mm" : "dd.MM.yyyy HH:mm"
            let startTime = date(start, format)
            let endTime = date(end, format)
            let startZone = utcOffset(at: start)
            let endZone = utcOffset(at: end)
            if startZone != endZone {
                return ("\(startTime) (\(startZone))", "– \(endTime) (\(endZone))")
            }
            return sameDay ? ("\(startTime)–\(endTime)", nil) : (startTime, "– \(endTime)")
        }

        private func beginAppendixPage() throws {
            try beginPage()
            label("Подробные записи", at: margin, y: 62, size: 27, face: .serif)
            label("\(report.name) · \(period)", at: margin, y: 97, width: width, size: 13, color: muted)
            panel(CGRect(x: margin, y: 123, width: width, height: 24), color: neutral, radius: 4)
            label("Время", at: margin + 10, y: 128, size: 11, face: .strong)
            label("Событие", at: margin + 120, y: 128, size: 11, face: .strong)
            label("Подробности", at: margin + 234, y: 128, size: 11, face: .strong)
            y = 151
        }

        private func drawDayHeading(_ day: Date, continued: Bool) {
            var title = date(day, "d MMMM yyyy")
            if isToday(day) {
                title += " · сегодня до \(date(report.generatedAt, "HH:mm"))"
            }
            if continued {
                title += " · продолжение"
            }
            y += 7
            label(title, at: margin + 10, y: y, width: width - 20, size: 13, face: .strong)
            y += 21
        }

        private func drawNote(_ note: String, on day: Date) throws {
            let x = margin + 234
            let available = width - 244
            let attributed = attributed("Заметка. \(note)", size: 10, face: .regular, color: muted)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var offset = 0
            while offset < attributed.length {
                try Task.checkCancellation()
                if y + 16 > bodyEnd {
                    try beginAppendixPage()
                    drawDayHeading(day, continued: true)
                    label("Заметка · продолжение", at: x, y: y, size: 10, face: .strong)
                    y += 15
                }
                let length = lineLength(typesetter, attributed: attributed, offset: offset, width: available)
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length))
                draw(line, x: x, baseline: y + 10)
                y += 13
                offset += length
            }
            y += 4
        }

        private func beginPage() throws {
            try Task.checkCancellation()
            context.beginPage()
            pageNumber += 1
            canvas.setFillColor(paper)
            canvas.fill(Self.page)
            label("Дневник для педиатра", at: margin, y: 36, size: 15, face: .strong, color: gold)
            horizontalRule(at: 761)
            label("— Нет записей в категории. Смешанный подгузник учтён в обеих колонках.",
                  at: margin, y: 771, width: width, size: 10, color: muted)
            let generated = date(report.generatedAt, "d MMMM yyyy, HH:mm")
            let zone = utcOffset(at: report.generatedAt)
            label(
                "«Малыш» · записи на этом iPhone · сформировано \(generated) (\(zone))",
                at: margin,
                y: 788,
                width: width - 28,
                size: 10,
                color: muted
            )
            label("Стр. \(pageNumber)", at: right - 40, y: 788, width: 40, size: 10, color: muted, align: .right)
        }

        private var period: String {
            let first = report.startDate
            let last = report.endDate
            if report.calendar.isDate(first, inSameDayAs: last) {
                return date(first, "d MMMM yyyy")
            }
            if report.calendar.isDate(first, equalTo: last, toGranularity: .month) {
                return "\(date(first, "d"))–\(date(last, "d MMMM yyyy"))"
            }
            let firstFormat = report.calendar.isDate(first, equalTo: last, toGranularity: .year) ? "d MMMM" : "d MMMM yyyy"
            return "\(date(first, firstFormat)) — \(date(last, "d MMMM yyyy"))"
        }

        private func utcOffset(at date: Date) -> String {
            let offset = report.calendar.timeZone.secondsFromGMT(for: date)
            guard offset != 0 else { return "UTC" }
            let minutes = abs(offset) / 60
            let fraction = minutes % 60 == 0 ? "" : String(format: ":%02d", minutes % 60)
            return "UTC\(offset < 0 ? "−" : "+")\(minutes / 60)\(fraction)"
        }

        private func date(_ value: Date, _ format: String) -> String {
            dateFormatter.dateFormat = format
            return dateFormatter.string(from: value)
        }

        private func isToday(_ day: Date) -> Bool {
            report.calendar.isDate(day, inSameDayAs: report.generatedAt)
        }

        private func number(_ value: Double, digits: Int = 10) -> String {
            numberFormatter.maximumFractionDigits = digits
            return numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
        }

        private func measurementText(_ measurement: ChildMeasurement) -> String {
            "\(number(measurement.value, digits: 340)) \(measurement.type.unit)"
        }

        private func duration(_ value: TimeInterval, seconds: Bool = false) -> String {
            let rounded = (seconds ? value : value / 60).rounded()
            guard rounded.isFinite, rounded >= 0, let count = Int(exactly: rounded) else { return "—" }
            let wholeMinutes = seconds ? count / 60 : count
            let remainder = seconds ? count % 60 : 0
            let hours = wholeMinutes / 60
            let minutes = wholeMinutes % 60
            var parts: [String] = []
            if hours > 0 {
                parts.append("\(hours) ч")
            }
            if minutes > 0 {
                parts.append("\(minutes) мин")
            }
            if seconds, remainder > 0 || parts.isEmpty {
                parts.append("\(remainder) с")
            }
            return parts.isEmpty ? "0 мин" : parts.joined(separator: " ")
        }

        private func columnStart(_ column: Int) -> CGFloat {
            margin + columns.prefix(column).reduce(0, +)
        }

        private func attributed(_ value: String, size: CGFloat, face: Face, color: CGColor) -> NSAttributedString {
            NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                    face.name as CFString,
                    size,
                    nil
                ),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ])
        }

        private func label(_ value: String, at x: CGFloat, y: CGFloat, width: CGFloat? = nil, size: CGFloat,
                           face: Face = .regular, color: CGColor? = nil, align: Alignment = .left)
        {
            let available = width ?? right - x
            let color = color ?? ink
            let line = CTLineCreateWithAttributedString(attributed(value, size: size, face: face, color: color))
            let ellipsis = CTLineCreateWithAttributedString(attributed("…", size: size, face: face, color: color))
            let fitted = CTLineCreateTruncatedLine(line, Double(available), .end, ellipsis) ?? line
            let lineWidth = CGFloat(CTLineGetTypographicBounds(fitted, nil, nil, nil))
            let inset: CGFloat = switch align {
            case .left: 0
            case .center: (available - lineWidth) / 2
            case .right: available - lineWidth
            }
            draw(fitted, x: x + inset, baseline: y + size)
        }

        private func lines(_ value: String, width: CGFloat, size: CGFloat, face: Face, color: CGColor) -> [CTLine] {
            let attributed = attributed(value, size: size, face: face, color: color)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            var result: [CTLine] = []
            var offset = 0
            while offset < attributed.length {
                let length = lineLength(typesetter, attributed: attributed, offset: offset, width: width)
                result.append(CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length)))
                offset += length
            }
            return result
        }

        private func lineLength(_ typesetter: CTTypesetter, attributed: NSAttributedString,
                                offset: Int, width: CGFloat) -> Int
        {
            let length = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
            if length > 0 {
                return length
            }
            let clusterLength = CTTypesetterSuggestClusterBreak(typesetter, offset, Double(width))
            if clusterLength > 0 {
                return clusterLength
            }
            return (attributed.string as NSString).rangeOfComposedCharacterSequence(at: offset).length
        }

        private func draw(_ line: CTLine, x: CGFloat, baseline: CGFloat) {
            canvas.saveGState()
            canvas.translateBy(x: x, y: baseline)
            canvas.scaleBy(x: 1, y: -1)
            canvas.textMatrix = .identity
            canvas.textPosition = .zero
            CTLineDraw(line, canvas)
            canvas.restoreGState()
        }

        private func panel(_ rect: CGRect, color: CGColor, radius: CGFloat) {
            canvas.setFillColor(color)
            canvas.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            canvas.fillPath()
        }

        private func horizontalRule(at y: CGFloat) {
            canvas.setFillColor(rule)
            canvas.fill(CGRect(x: margin, y: y, width: width, height: 0.5))
        }

        private func divider(x: CGFloat, from start: CGFloat, to end: CGFloat) {
            canvas.setFillColor(rule)
            canvas.fill(CGRect(x: x, y: start, width: 0.5, height: end - start))
        }
    }
}
