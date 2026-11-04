import SwiftUI

struct EventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: CareEvent
    @State private var errorMessage: String?

    private let onSave: (CareEvent) throws -> Void
    private let onDelete: (() throws -> Void)?

    init(
        event: CareEvent,
        onSave: @escaping (CareEvent) throws -> Void,
        onDelete: (() throws -> Void)? = nil
    ) {
        _draft = State(initialValue: event)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Время") {
                    DatePicker(
                        "Начало",
                        selection: $draft.start,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("editor.start")
                    if draft.kind == .sleep {
                        DatePicker(
                            "Пробуждение",
                            selection: sleepEnd,
                            in: draft.start ... max(draft.start, Date()),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        .accessibilityIdentifier("editor.end")
                    }
                }

                switch draft.kind {
                case .breast:
                    Section {
                        Stepper(value: leftMinutes, in: 0 ... 240, step: 1) {
                            durationLabel("Левая грудь", seconds: draft.leftSeconds)
                        }
                        .frame(minHeight: 44)
                        Stepper(value: rightMinutes, in: 0 ... 240, step: 1) {
                            durationLabel("Правая грудь", seconds: draft.rightSeconds)
                        }
                        .frame(minHeight: 44)
                    } header: {
                        Text("Кормление грудью")
                    } footer: {
                        Text(
                            "Укажите время кормления для каждой груди. Окончание рассчитывается от начала по общей длительности."
                        )
                    }
                case .bottle:
                    Section("Бутылочка") {
                        Picker("Содержимое", selection: $draft.bottleType) {
                            ForEach(BottleType.allCases, id: \.self) { type in
                                Text(type.label).tag(type)
                            }
                        }
                        Stepper(value: $draft.volumeML, in: 1 ... 500, step: 1) {
                            Text("Объём: \(draft.volumeML) мл")
                                .monospacedDigit()
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("editor.volume")
                    }
                case .diaper:
                    Section("Подгузник") {
                        Picker("Тип", selection: $draft.diaperType) {
                            ForEach(DiaperType.allCases, id: \.self) { type in
                                Text(type.label).tag(type)
                            }
                        }
                    }
                case .sleep:
                    Section {
                        Text("Продолжительность: \(sleepDuration)")
                    }
                }

                Section("Заметка") {
                    TextField("Необязательно", text: $draft.note, axis: .vertical)
                        .lineLimit(3 ... 8)
                        .accessibilityLabel("Заметка о событии")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityLabel("Ошибка: \(errorMessage)")
                    }
                }

                if onDelete != nil {
                    Section {
                        Button("Удалить запись", role: .destructive, action: delete)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("editor.delete")
                    }
                }
            }
            .navigationTitle(draft.kind.label)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                        .accessibilityIdentifier("editor.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить", action: save)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("editor.save")
                }
            }
            .onChange(of: draft.start) { _, newStart in
                if let end = draft.end, end < newStart {
                    draft.end = newStart
                }
            }
        }
    }

    private var sleepEnd: Binding<Date> {
        Binding(
            get: { draft.end ?? max(draft.start, Date()) },
            set: { draft.end = $0 }
        )
    }

    private var leftMinutes: Binding<Double> {
        Binding(get: { draft.leftSeconds / 60 }, set: { draft.leftSeconds = $0 * 60 })
    }

    private var rightMinutes: Binding<Double> {
        Binding(get: { draft.rightSeconds / 60 }, set: { draft.rightSeconds = $0 * 60 })
    }

    private var sleepDuration: String {
        let minutes = max(0, Int((sleepEnd.wrappedValue.timeIntervalSince(draft.start)) / 60))
        return "\(minutes / 60) ч \(minutes % 60) мин"
    }

    private func durationLabel(_ title: String, seconds: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Text("\(Int(seconds / 60)) мин")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func save() {
        var event = draft
        let now = Date()
        if event.kind == .breast {
            event.end = event.start.addingTimeInterval(event.leftSeconds + event.rightSeconds)
            event.sideStartedAt = nil
        } else if event.kind == .bottle || event.kind == .diaper {
            event.end = event.start
        } else if event.kind == .sleep, event.end == nil {
            event.end = max(event.start, now)
        }
        event.modifiedAt = now
        do {
            try event.validate(now: now)
            try onSave(event)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func delete() {
        guard let onDelete else { return }
        do {
            try onDelete()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
