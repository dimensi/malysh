import Combine
import PDFKit
import SwiftUI

struct DiaryPDFReportView: View {
    let store: AppStore
    let diaryID: UUID
    let generation: UUID

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var settings = PDFReportSettings()
    @State private var localDay = LocalDay()
    @State private var phase: Phase = .loading
    @State private var showsSettings = false
    @State private var sharedFile: DiaryPDFFile?
    @State private var attempt = 0
    @State private var invalidated = false

    private struct Request: Equatable {
        let settings: PDFReportSettings
        let day: LocalDay
        let attempt: Int
    }

    private struct LocalDay: Equatable {
        let calendar: Calendar
        let start: Date

        init(now: Date = .now) {
            calendar = PDFReportSettings.localCalendar
            start = calendar.startOfDay(for: now)
        }
    }

    private enum Phase {
        case loading
        case empty
        case failed
        case ready(DiaryPDFFile, PDFDocument)
    }

    private var hasAccess: Bool {
        store.ready && !store.cloudSwitchInProgress && !store.diaryRemovalInProgress
            && store.selectedID == diaryID && store.visibleBabies.contains(where: { $0.id == diaryID })
            && store.persistence.isLoaded && store.persistence.generation == generation
    }

    private var request: Request {
        Request(settings: settings, day: localDay, attempt: attempt)
    }

    var body: some View {
        let job = request
        VStack(spacing: 0) {
            if hasAccess, !invalidated {
                Button {
                    showsSettings = true
                } label: {
                    HStack(spacing: AppDesign.Spacing.row) {
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                            Text(settings.periodSummary).font(AppDesign.Typography.itemTitle)
                            Text(settings.detailed ? "Подробный отчёт" : "Краткий отчёт")
                                .font(AppDesign.Typography.detail)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "slider.horizontal.3").accessibilityHidden(true)
                    }
                    .frame(minHeight: AppDesign.Metrics.minimumTouch)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, AppDesign.Spacing.contentInset)
                .padding(.vertical, AppDesign.Spacing.group)
                .background(AppDesign.Palette.cardBackground)
                .accessibilityIdentifier("diary.pdf.settings")
                .accessibilityHint("Настроить период и содержание")
                Divider()
                preview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppDesign.Palette.groupedBackground)
        .navigationTitle("Отчёт для педиатра")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if hasAccess, !invalidated, case .ready = phase {
                    Button {
                        guard refreshDay(), hasAccess, !invalidated, case let .ready(file, _) = phase else { return }
                        sharedFile = file
                    } label: {
                        Label("Поделиться PDF", systemImage: "square.and.arrow.up")
                    }
                    .accessibilityIdentifier("diary.pdf.share")
                }
            }
        }
        .sheet(isPresented: $showsSettings) {
            PDFReportSettingsView(settings: settings) { updated in
                guard updated != settings else { return }
                phase = .loading
                settings = updated
            }
        }
        .sheet(item: $sharedFile) { file in
            DiaryPDFShareSheet(file: file)
        }
        .onChange(of: hasAccess, initial: true) { _, available in
            guard !available else { return }
            invalidated = true
            phase = .loading
            showsSettings = false
            sharedFile = nil
            dismiss()
        }
        .onDisappear {
            phase = .loading
            showsSettings = false
            sharedFile = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification))
            .receive(on: DispatchQueue.main))
        { _ in
            refreshDay()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                refreshDay()
            }
        }
        .task(id: job) { await generate(job) }
    }

    @ViewBuilder private var preview: some View {
        switch phase {
        case .loading:
            ProgressView("Готовим PDF…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView {
                Label("За этот период нет записей", systemImage: "doc.text")
            } description: {
                Text("Выберите другие даты, чтобы подготовить отчёт.")
            } actions: {
                Button("Изменить период") { showsSettings = true }
            }
        case .failed:
            ContentUnavailableView {
                Label("Не удалось подготовить PDF", systemImage: "exclamationmark.circle")
            } description: {
                Text("Попробуйте сформировать отчёт ещё раз.")
            } actions: {
                Button("Попробовать снова") {
                    phase = .loading
                    attempt += 1
                }
            }
        case let .ready(file, document):
            DiaryPDFPreview(file: file, document: document)
                .id(file.id)
        }
    }

    private func generate(_ job: Request) async {
        do {
            try checkAccess(for: job)
            guard refreshDay() else { return }
            phase = .loading

            let snapshot = try await store.photoGallery.withExclusiveAccess {
                try checkAccess(for: job)
                return try await store.persistence.readDiarySnapshot(id: diaryID)
            }
            try checkAccess(for: job)
            let now = Date()
            guard refreshDay(now: now) else { return }
            let calendar = job.day.calendar
            guard let dates = job.settings.dateRange(endingAt: now, calendar: calendar) else {
                phase = .failed
                return
            }

            let worker = Task.detached(priority: .userInitiated) { () throws -> DiaryPDFFile? in
                try Task.checkCancellation()
                let report = try DiaryPDFReport(
                    snapshot: snapshot, startDate: dates.lowerBound, endDate: dates.upperBound,
                    generatedAt: now, calendar: calendar
                )
                guard report.hasContent else { return nil }
                try Task.checkCancellation()
                let file = try DiaryPDFFile()
                try DiaryPDFRenderer.write(
                    report, detailed: job.settings.detailed, includesNotes: job.settings.includesNotes, to: file.url
                )
                try file.protectContents()
                try Task.checkCancellation()
                return file
            }
            let file = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            try checkAccess(for: job)
            guard refreshDay() else { return }
            if let file {
                guard let document = PDFDocument(url: file.url), document.pageCount > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                phase = .ready(file, document)
            } else {
                phase = .empty
            }
        } catch {
            guard (try? checkAccess(for: job)) != nil, refreshDay() else { return }
            phase = .failed
        }
    }

    @discardableResult
    private func refreshDay(now: Date = .now) -> Bool {
        let current = LocalDay(now: now)
        guard current != localDay else { return true }
        phase = .loading
        sharedFile = nil
        localDay = current
        return false
    }

    private func checkAccess(for job: Request) throws {
        try Task.checkCancellation()
        guard hasAccess, !invalidated, job == request else { throw CancellationError() }
    }
}

private struct PDFReportSettings: Equatable, Sendable {
    enum Period: Int, CaseIterable, Sendable {
        case three = 3
        case seven = 7
        case thirty = 30
        case custom = 0

        var label: String {
            switch self {
            case .three: "3 дня"
            case .seven: "7 дней"
            case .thirty: "30 дней"
            case .custom: "Выбрать даты"
            }
        }
    }

    var period = Period.seven
    var detailed = false
    var includesNotes = false
    // The picker stores calendar dates in GMT so a timezone change preserves both selected dates.
    var startDate: Date
    var endDate: Date

    var periodSummary: String {
        guard period == .custom else { return period.label }
        let formatter = DateIntervalFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = Self.selectionCalendar
        formatter.timeZone = .gmt
        formatter.dateTemplate = "dMMMy"
        return formatter.string(from: startDate, to: endDate)
    }

    init(now: Date = .now) {
        let today = Self.selectionDay(for: now)
        endDate = today
        startDate = Self.selectionCalendar.date(byAdding: .day, value: -6, to: today) ?? today
    }

    static var localCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    static var selectionCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func selectionDay(for now: Date) -> Date {
        let components = localCalendar.dateComponents([.year, .month, .day], from: now)
        return selectionCalendar.date(from: components) ?? now
    }

    func dateRange(endingAt now: Date, calendar: Calendar) -> ClosedRange<Date>? {
        let today = calendar.startOfDay(for: now)
        if period == .custom {
            let components: Set<Calendar.Component> = [.year, .month, .day]
            let selection = Self.selectionCalendar
            guard let start = calendar.date(from: selection.dateComponents(components, from: startDate)),
                  let end = calendar.date(from: selection.dateComponents(components, from: endDate)),
                  start <= end, end <= today else { return nil }
            return start ... end
        }
        guard let start = calendar.date(byAdding: .day, value: 1 - period.rawValue, to: today) else { return nil }
        return start ... today
    }
}

private struct PDFReportSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State var settings: PDFReportSettings
    let apply: (PDFReportSettings) -> Void

    var body: some View {
        let now = Date()
        let calendar = PDFReportSettings.localCalendar
        let today = PDFReportSettings.selectionDay(for: now)
        NavigationStack {
            Form {
                Section("Период") {
                    Picker("Даты отчёта", selection: $settings.period) {
                        ForEach(PDFReportSettings.Period.allCases, id: \.self) { period in
                            Text(period.label).tag(period)
                        }
                    }
                    .accessibilityIdentifier("diary.pdf.period")
                    if settings.period == .custom {
                        DatePicker("Начало", selection: $settings.startDate, in: ...today, displayedComponents: .date)
                            .accessibilityIdentifier("diary.pdf.startDate")
                        DatePicker("Конец", selection: $settings.endDate, in: ...today, displayedComponents: .date)
                            .accessibilityIdentifier("diary.pdf.endDate")
                        if settings.startDate > settings.endDate {
                            Text("Дата начала должна быть не позже даты окончания.")
                                .font(AppDesign.Typography.detail)
                                .foregroundStyle(AppDesign.Palette.error)
                        }
                    }
                }
                Section("Содержание") {
                    Picker("Вид отчёта", selection: $settings.detailed) {
                        Text("Краткий").tag(false)
                        Text("Подробный").tag(true)
                    }
                    .accessibilityIdentifier("diary.pdf.format")
                    if settings.detailed {
                        Toggle("Включить заметки", isOn: $settings.includesNotes)
                            .accessibilityIdentifier("diary.pdf.notes")
                    }
                }
            }
            .environment(\.calendar, PDFReportSettings.selectionCalendar)
            .environment(\.timeZone, .gmt)
            .navigationTitle("Настройки отчёта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") {
                        if !settings.detailed {
                            settings.includesNotes = false
                        }
                        apply(settings)
                        dismiss()
                    }
                    .disabled(settings.dateRange(endingAt: now, calendar: calendar) == nil)
                    .accessibilityIdentifier("diary.pdf.settings.done")
                }
            }
        }
    }
}

private struct DiaryPDFPreview: UIViewRepresentable {
    let file: DiaryPDFFile
    let document: PDFDocument

    /// Keep the URL backing PDFKit alive until UIKit dismantles the preview.
    func makeCoordinator() -> DiaryPDFFile {
        file
    }

    func makeUIView(context _: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.backgroundColor = .systemGroupedBackground
        view.document = document
        view.autoScales = true
        view.accessibilityIdentifier = "diary.pdf.preview"
        return view
    }

    func updateUIView(_: PDFView, context _: Context) {}
}

private struct DiaryPDFShareSheet: UIViewControllerRepresentable {
    let file: DiaryPDFFile
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> DiaryPDFFile {
        file
    }

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [file.url], applicationActivities: nil)
        // SwiftUI supplies the sheet on iPad too. Both the coordinator and controller retain the file.
        controller.completionWithItemsHandler = { [file, dismiss] _, _, _, _ in
            withExtendedLifetime(file) { dismiss() }
        }
        return controller
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) {}
}

final class DiaryPDFFile: Identifiable, Sendable {
    private static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiaryPDFReports", isDirectory: true)
    private static let sessionDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)

    let id = UUID()
    let url: URL
    private let directory: URL

    init() throws {
        directory = Self.sessionDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        url = directory.appendingPathComponent("Отчёт для педиатра.pdf")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    func protectContents() throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
    }

    static func removeAbandonedFiles() {
        let manager = FileManager.default
        guard let directories = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return
        }
        for directory in directories where directory != sessionDirectory {
            try? manager.removeItem(at: directory)
        }
    }
}
