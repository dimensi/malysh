import Charts
import SwiftUI

struct ChildProfileView: View {
    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var editingProfile: Baby?

    var body: some View {
        NavigationStack {
            Form {
                if let baby = store.baby {
                    Section("Ребёнок") {
                        LabeledContent("Имя", value: baby.name)
                            .accessibilityIdentifier("child.profile.name")
                        if baby.birthDateConfirmed {
                            LabeledContent(
                                "Дата рождения",
                                value: baby.displayedBirthDate().formatted(date: .abbreviated, time: .omitted)
                            )
                            TimelineView(.periodic(from: .now, by: 60)) { context in
                                if let age = baby.ageLabel(now: context.date) {
                                    LabeledContent("Возраст", value: age)
                                        .accessibilityIdentifier("child.profile.age")
                                }
                            }
                        } else {
                            Text("Дата рождения не указана")
                            Text("Укажите дату рождения, чтобы видеть возраст.").foregroundStyle(.secondary)
                        }
                        Button("Изменить профиль") { editingProfile = baby }
                            .accessibilityIdentifier("child.profile.edit")
                    }
                    Section {
                        ForEach(MeasurementType.allCases, id: \.self) { type in
                            NavigationLink {
                                MeasurementHistoryView(store: store, type: type)
                            } label: {
                                VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                                    Text(type.label)
                                    if let latest = store.measurements.filter({ $0.type == type })
                                        .sorted(by: ChildMeasurement.newestFirst).first
                                    {
                                        Text(
                                            "\(measurementValue(latest)) · \(latest.measuredAt.formatted(date: .abbreviated, time: .omitted))"
                                        )
                                        .font(AppDesign.Typography.detail).foregroundStyle(.secondary)
                                    } else {
                                        Text("Добавить первое измерение").font(AppDesign.Typography.detail)
                                            .foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, AppDesign.Spacing.related)
                            }.accessibilityIdentifier("measurement.history.\(type)")
                        }
                    } header: {
                        Text("Измерения")
                    } footer: {
                        Text("Ваши записи и их изменение со временем. Без оценок и сравнения с нормами.")
                    }
                }
            }
            .navigationTitle("Профиль ребёнка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }.accessibilityIdentifier("child.profile.close")
                }
            }
            .sheet(item: $editingProfile) { baby in
                ChildProfileEditor(store: store, baby: baby)
            }
        }
    }
}

private struct ChildProfileEditor: View {
    let store: AppStore
    let original: Baby
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var birthDate: Date
    @State private var confirmed: Bool
    @State private var errorMessage: String?

    init(store: AppStore, baby: Baby) {
        self.store = store
        original = baby
        _name = State(initialValue: baby.name)
        _birthDate = State(initialValue: baby.displayedBirthDate())
        _confirmed = State(initialValue: baby.birthDateConfirmed)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Имя") {
                    TextField("Имя ребёнка", text: $name).textContentType(.givenName)
                        .accessibilityIdentifier("child.editor.name")
                }
                Section {
                    DatePicker("Дата рождения", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("child.editor.birthDate")
                    Toggle("Дата рождения указана верно", isOn: $confirmed)
                        .accessibilityIdentifier("child.editor.confirmed")
                } footer: {
                    Text("Возраст появится после подтверждения даты рождения.")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(AppDesign.Palette.error)
                }
            }
            .navigationTitle("Изменить профиль").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        do {
                            try store.updateChildProfile(
                                babyID: original.id,
                                name: name,
                                birthDate: birthDate,
                                birthDateConfirmed: confirmed,
                                replacing: original
                            )
                            dismiss()
                        } catch { errorMessage = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("child.editor.save")
                }
            }
        }
    }
}

private func measurementValue(_ measurement: ChildMeasurement) -> String {
    "\(measurement.value.formatted(.number.precision(.fractionLength(0 ... 2)))) \(measurement.type.unit)"
}

private struct MeasurementPresentation: Identifiable {
    let measurement: ChildMeasurement
    let isNew: Bool
    var id: UUID {
        measurement.id
    }
}

private struct MeasurementHistoryView: View {
    @Bindable var store: AppStore
    let type: MeasurementType
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var editing: MeasurementPresentation?
    private var records: [ChildMeasurement] {
        store.measurements.filter { $0.type == type }.sorted(by: ChildMeasurement.newestFirst)
    }

    var body: some View {
        List {
            if records.isEmpty {
                ContentUnavailableView(
                    "Пока нет измерений",
                    systemImage: "ruler",
                    description: Text("Добавьте первое измерение. Оно сохранится в дневнике ребёнка.")
                )
            } else {
                Section {
                    Chart(records.sorted { $0.measuredAt < $1.measuredAt }) { record in
                        LineMark(x: .value("Дата", record.measuredAt), y: .value(type.unit, record.value))
                        PointMark(x: .value("Дата", record.measuredAt), y: .value(type.unit, record.value))
                    }
                    .foregroundStyle(AppDesign.Palette.accent)
                    .frame(height: dynamicTypeSize.isAccessibilitySize ? 280 : 200)
                    .padding(.vertical, AppDesign.Spacing.row)
                    .accessibilityLabel("\(type.label), \(type.unit). График ваших измерений")
                } header: { Text("\(type.label), \(type.unit)") }
                Section("История измерений") {
                    ForEach(records) { record in
                        Button { editing = MeasurementPresentation(measurement: record, isNew: false) } label: {
                            VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                                Text(measurementValue(record)).font(.headline)
                                Text(record.measuredAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(AppDesign.Typography.detail).foregroundStyle(.secondary)
                                if let note = record.note,
                                   !note.isEmpty
                                {
                                    Text(note).font(AppDesign.Typography.detail)
                                }
                            }.foregroundStyle(AppDesign.Palette.primaryText)
                        }
                        .accessibilityIdentifier("measurement.row.\(record.id)")
                        .swipeActions {
                            Button("Удалить", role: .destructive) {
                                store.perform { try store.deleteMeasurement(id: record.id) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(type.label)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard let baby = store.baby else { return }
                    editing = MeasurementPresentation(
                        measurement: ChildMeasurement(babyID: baby.id, type: type, value: 0),
                        isNew: true
                    )
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Добавить измерение").accessibilityIdentifier("measurement.add")
            }
        }
        .sheet(item: $editing) { presentation in
            MeasurementEditor(store: store, measurement: presentation.measurement, isNew: presentation.isNew)
        }
    }
}

private struct MeasurementEditor: View {
    let store: AppStore
    let measurement: ChildMeasurement
    let isNew: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var value: String
    @State private var measuredAt: Date
    @State private var note: String
    @State private var kilograms = false
    @State private var errorMessage: String?

    init(store: AppStore, measurement: ChildMeasurement, isNew: Bool) {
        self.store = store
        self.measurement = measurement
        self.isNew = isNew
        _value = State(initialValue: isNew ? "" : ChildMeasurement.editorText(value: measurement.value))
        _measuredAt = State(initialValue: measurement.measuredAt)
        _note = State(initialValue: measurement.note ?? "")
    }

    private var numericValue: Double? {
        Double(value.replacingOccurrences(of: ",", with: "."))
    }

    private var valid: Bool {
        numericValue.map { $0.isFinite && $0 > 0 } ?? false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(measurement.type.label) {
                    TextField("Значение", text: $value).keyboardType(.decimalPad)
                        .accessibilityIdentifier("measurement.editor.value")
                    if measurement.type == .weight {
                        Picker("Единица измерения", selection: $kilograms) {
                            Text("г").tag(false)
                            Text("кг").tag(true)
                        }.accessibilityIdentifier("measurement.editor.unit")
                            .onChange(of: kilograms) { old, new in
                                if let converted = ChildMeasurement.convertedWeightText(
                                    value,
                                    toKilograms: new && !old
                                ) {
                                    value = converted
                                }
                            }
                    } else {
                        LabeledContent("Единица измерения", value: measurement.type.unit)
                    }
                    DatePicker(
                        "Дата измерения",
                        selection: $measuredAt,
                        in: ...Date(),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .accessibilityIdentifier("measurement.editor.date")
                }
                Section("Заметка") {
                    TextField("Необязательно", text: $note, axis: .vertical)
                        .accessibilityIdentifier("measurement.editor.note")
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(AppDesign.Palette.error)
                }
                if !isNew {
                    Section {
                        Button("Удалить запись", role: .destructive) {
                            do {
                                try store.deleteMeasurement(id: measurement.id)
                                dismiss()
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }.accessibilityIdentifier("measurement.editor.delete")
                    }
                }
            }
            .navigationTitle(isNew ? "Новое измерение" : "Изменить измерение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let number = numericValue else { return }
                        let record = ChildMeasurement(id: measurement.id, babyID: measurement.babyID,
                                                      type: measurement.type, measuredAt: measuredAt,
                                                      value: number * (kilograms ? 1000 : 1),
                                                      createdAt: measurement.createdAt,
                                                      modifiedAt: Date(),
                                                      note: note.trimmingCharacters(in: .whitespacesAndNewlines)
                                                          .isEmpty ? nil : note)
                        do {
                            try store.saveMeasurement(record, replacing: isNew ? nil : measurement)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }.disabled(!valid).accessibilityIdentifier("measurement.editor.save")
                }
            }
        }
    }
}
