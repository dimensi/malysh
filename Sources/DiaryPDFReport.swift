import Foundation

struct DiaryPDFReport: Sendable {
    enum PeriodError: LocalizedError {
        case invalidDates

        var errorDescription: String? {
            "Укажите период, который заканчивается не позже сегодняшнего дня."
        }
    }

    struct Day: Sendable {
        let date: Date
        let breastFeeds: Int?
        let bottleFeeds: Int?
        let bottleVolumeML: Int?
        let sleepSeconds: TimeInterval?
        let wetDiapers: Int?
        let dirtyDiapers: Int?
        let entries: [Entry]

        init(date: Date, entries: [Entry], completedSleeps: [CareEvent], calendar: Calendar, generatedAt: Date) {
            self.date = date
            self.entries = entries

            let events = entries.compactMap { entry -> CareEvent? in
                guard case let .event(event) = entry, event.kind != .sleep else { return nil }
                return event
            }
            let statistics = DailyStatistics(events: events, day: date, calendar: calendar, now: generatedAt)
            let bottles = events.count { $0.kind == .bottle }
            let hasDiapers = events.contains { $0.kind == .diaper }
            breastFeeds = statistics.feeds > 0 ? statistics.feeds - bottles : nil
            bottleFeeds = statistics.feeds > 0 ? bottles : nil
            bottleVolumeML = statistics.feeds > 0 ? statistics.bottleML : nil
            wetDiapers = hasDiapers ? statistics.wetDiapers : nil
            dirtyDiapers = hasDiapers ? statistics.dirtyDiapers : nil
            sleepSeconds = completedSleeps.isEmpty ? nil : DailyStatistics(
                events: completedSleeps, day: date, calendar: calendar, now: generatedAt
            ).sleepSeconds
        }
    }

    enum Entry: Sendable {
        case event(CareEvent)
        case measurement(ChildMeasurement)

        private var date: Date {
            switch self {
            case let .event(event): event.start
            case let .measurement(measurement): measurement.measuredAt
            }
        }

        private var id: UUID {
            switch self {
            case let .event(event): event.id
            case let .measurement(measurement): measurement.id
            }
        }

        static func chronological(_ lhs: Self, _ rhs: Self) -> Bool {
            lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date < rhs.date
        }
    }

    struct Average: Sendable {
        let value: Double?
        let recordedDays: Int

        init(_ values: [Double]) {
            recordedDays = values.count
            value = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
    }

    struct MeasurementSummary: Sendable {
        let latest: ChildMeasurement
        let firstInPeriod: ChildMeasurement?
        let change: Double?
    }

    let name: String
    let age: String?
    let startDate: Date
    let endDate: Date
    let generatedAt: Date
    let calendar: Calendar
    let days: [Day]
    let measurementSummaries: [MeasurementSummary]
    let feedAverage: Average
    let wetAverage: Average
    let sleepAverage: Average
    let pastDayCount: Int
    let formulaML: Int?
    let expressedML: Int?
    let breastMedianSeconds: TimeInterval?
    let breastDurationCount: Int

    var hasContent: Bool {
        days.contains { !$0.entries.isEmpty }
    }

    init(snapshot: DiarySnapshot, startDate: Date, endDate: Date, generatedAt: Date, calendar: Calendar) throws {
        let startDate = calendar.startOfDay(for: startDate)
        let endDate = calendar.startOfDay(for: endDate)
        let today = calendar.startOfDay(for: generatedAt)
        guard startDate <= endDate, endDate <= today,
              let lastDay = calendar.dateInterval(of: .day, for: endDate)
        else { throw PeriodError.invalidDates }

        let endExclusive = lastDay.end
        func isWithinPeriod(_ date: Date) -> Bool {
            date >= startDate && date < endExclusive && date <= generatedAt
        }

        name = snapshot.baby.name
        age = snapshot.baby.ageLabel(now: endDate, calendar: calendar)
        self.startDate = startDate
        self.endDate = endDate
        self.generatedAt = generatedAt
        self.calendar = calendar

        let events = snapshot.events.filter { $0.kind != .sleep && isWithinPeriod($0.start) }
        let measurements = snapshot.measurements.filter { $0.measuredAt < endExclusive && $0.measuredAt <= generatedAt }
        let sleeps = snapshot.events.filter { event in
            event.kind == .sleep && (isWithinPeriod(event.start) ||
                (event.start < startDate && min(event.end ?? generatedAt, generatedAt) > startDate))
        }
        days = try Self.makeDays(
            events: events + sleeps, measurements: measurements,
            period: DateInterval(start: startDate, end: endExclusive), generatedAt: generatedAt, calendar: calendar
        )
        measurementSummaries = Self.summarizeMeasurements(measurements, startDate: startDate)

        let bottles = Dictionary(grouping: events.filter { $0.kind == .bottle }, by: \.bottleType)
        formulaML = bottles[.formula]?.reduce(0) { $0 + max(0, $1.volumeML) }
        expressedML = bottles[.expressed]?.reduce(0) { $0 + max(0, $1.volumeML) }

        let durations = events.compactMap { event -> TimeInterval? in
            guard event.kind == .breast, let end = event.end, end <= generatedAt else { return nil }
            let sides = event.breastDurations(now: generatedAt)
            let duration = sides.left + sides.right
            return duration > 0 ? duration : nil
        }.sorted()
        breastDurationCount = durations.count
        breastMedianSeconds = Self.median(of: durations)

        let pastDays = days.filter { $0.date < today }
        pastDayCount = pastDays.count
        feedAverage = Average(pastDays.compactMap { day in
            day.breastFeeds.map { Double($0 + (day.bottleFeeds ?? 0)) }
        })
        wetAverage = Average(pastDays.compactMap { $0.wetDiapers.map(Double.init) })
        sleepAverage = Average(pastDays.compactMap(\.sleepSeconds))
    }

    private static func median(of sortedDurations: [TimeInterval]) -> TimeInterval? {
        guard !sortedDurations.isEmpty else { return nil }
        let upper = sortedDurations.count / 2
        let lower = (sortedDurations.count - 1) / 2
        return (sortedDurations[lower] + sortedDurations[upper]) / 2
    }

    private static func makeDays(
        events: [CareEvent], measurements: [ChildMeasurement], period: DateInterval,
        generatedAt: Date, calendar: Calendar
    ) throws -> [Day] {
        var entriesByDay: [Date: [Entry]] = [:]
        for measurement in measurements where measurement.measuredAt >= period.start {
            try Task.checkCancellation()
            let date = calendar.startOfDay(for: measurement.measuredAt)
            entriesByDay[date, default: []].append(.measurement(measurement))
        }
        var sleepsByDay: [Date: [CareEvent]] = [:]
        for event in events {
            try Task.checkCancellation()
            var date = calendar.startOfDay(for: max(event.start, period.start))
            entriesByDay[date, default: []].append(.event(event))
            guard event.kind == .sleep, let end = event.end, end <= generatedAt else { continue }
            let sleepEnd = min(end, period.end)
            // A completed zero-length sleep is a recorded zero on its start day.
            repeat {
                try Task.checkCancellation()
                sleepsByDay[date, default: []].append(event)
                guard let interval = calendar.dateInterval(of: .day, for: date) else { break }
                date = interval.end
            } while date < sleepEnd
        }

        var days: [Day] = []
        var date = period.start
        while date < period.end, let interval = calendar.dateInterval(of: .day, for: date) {
            try Task.checkCancellation()
            days.append(Day(
                date: date, entries: (entriesByDay[date] ?? []).sorted(by: Entry.chronological),
                completedSleeps: sleepsByDay[date] ?? [], calendar: calendar, generatedAt: generatedAt
            ))
            date = interval.end
        }
        return days
    }

    private static func summarizeMeasurements(
        _ measurements: [ChildMeasurement], startDate: Date
    ) -> [MeasurementSummary] {
        MeasurementType.allCases.compactMap { type in
            let candidates = measurements.filter { $0.type == type }.sorted(by: ChildMeasurement.newestFirst)
            guard let latest = candidates.first else { return nil }
            let inPeriod = candidates.prefix { $0.measuredAt >= startDate }
            let first = inPeriod.last
            return MeasurementSummary(
                latest: latest,
                firstInPeriod: first,
                change: inPeriod.count > 1 ? first.map { latest.value - $0.value } : nil
            )
        }
    }
}
