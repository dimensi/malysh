import Charts
import SwiftUI

struct ChildProfileView: View {
    private enum Destination: Hashable {
        case edit, history(MeasurementType), photos
    }

    @Bindable var store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .subheadline) private var measurementIconHeight = 20.0
    @State private var choosesMeasurement = false
    @Binding var editingMeasurement: MeasurementPresentation?
    @Binding var photoAddPresentationBusy: Bool
    @Binding var albumPresentationBusy: Bool
    let onAlbumDismiss: () -> Void

    var body: some View {
        ScrollView {
            if let baby = store.baby {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
                    header(baby)
                    Divider()
                    measurements(babyID: baby.id)
                    Divider()
                    album(babyID: baby.id)
                }
                .padding(AppDesign.Spacing.contentInset)
            }
        }
        .background(AppDesign.Palette.groupedBackground)
        .navigationTitle("Малыш")
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .edit:
                if let baby = store.baby {
                    ChildProfileEditor(store: store, baby: baby)
                }
            case let .history(type):
                MeasurementHistoryView(store: store, type: type, editing: $editingMeasurement)
            case .photos:
                PhotoGalleryView(store: store, isPresenting: $albumPresentationBusy, onDismiss: onAlbumDismiss)
            }
        }
    }

    private func header(_ baby: Baby) -> some View {
        HStack(alignment: .top, spacing: AppDesign.Spacing.row) {
            NavigationLink(value: Destination.photos) {
                ChildPhotoAvatar(store: store)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Фотографии малыша")
            .accessibilityIdentifier("child.profile.avatar")
            .accessibilityValue(ChildPhotoAvatar.accessibilityValue(for: store))
            VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                Text(baby.name).font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("child.profile.name")
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let age = baby.ageLabel(now: context.date) {
                        Text(age)
                            .accessibilityIdentifier("child.profile.age")
                    } else {
                        Text("Дата рождения не указана")
                    }
                }
                .font(AppDesign.Typography.detail)
                .foregroundStyle(.secondary)
                Text(store.isSharedDiary ? "Семейный дневник" : "Личный дневник")
                    .font(AppDesign.Typography.detail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink(value: Destination.edit) {
                Image(systemName: "pencil")
                    .font(.body)
                    .frame(width: AppDesign.Metrics.minimumTouch, height: AppDesign.Metrics.minimumTouch)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Редактировать профиль")
            .accessibilityIdentifier("child.profile.edit")
        }
    }

    private func measurements(babyID: UUID) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: AppDesign.Spacing.group, alignment: .top),
            count: dynamicTypeSize >= .xxLarge ? 1 : 3
        )
        return VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
            Text("Измерения").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: AppDesign.Spacing.group) {
                ForEach(MeasurementType.allCases, id: \.self) { type in
                    measurementCard(type)
                }
            }
            Button {
                choosesMeasurement = true
            } label: {
                Label("Добавить измерение", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
                    .padding(.vertical, AppDesign.Spacing.related)
                    .foregroundStyle(AppDesign.Palette.primaryText)
                    .background(AppDesign.Palette.sleep, in: RoundedRectangle(cornerRadius: AppDesign.Radius.card))
                    .contentShape(RoundedRectangle(cornerRadius: AppDesign.Radius.card))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("child.measurement.add")
            .confirmationDialog("Что измерили?", isPresented: $choosesMeasurement, titleVisibility: .visible) {
                ForEach(MeasurementType.allCases, id: \.self) { type in
                    Button(type.label) {
                        editingMeasurement = MeasurementPresentation(
                            measurement: ChildMeasurement(babyID: babyID, type: type, value: 0),
                            isNew: true
                        )
                    }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
    }

    private func measurementCard(_ type: MeasurementType) -> some View {
        let symbol = switch type {
        case .weight: "scalemass"
        case .height: "ruler"
        case .headCircumference: "circle.dashed"
        }
        let latest = store.measurements.filter { $0.type == type }.min(by: ChildMeasurement.newestFirst)
        let value = latest.map(measurementValue) ?? "Нет данных"
        return NavigationLink(value: Destination.history(type)) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                Image(systemName: symbol)
                    .font(AppDesign.Typography.detail)
                    .frame(height: measurementIconHeight)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(type == .headCircumference && dynamicTypeSize < .xxLarge ? "Голова" : type.label)
                    .font(AppDesign.Typography.itemTitle)
                Text(value)
                    .font(AppDesign.Typography.detail)
                    .foregroundStyle(latest == nil ? AppDesign.Palette.secondaryText : AppDesign.Palette.primaryText)
            }
            .frame(minHeight: AppDesign.Metrics.minimumTouch, alignment: .topLeading)
            .foregroundStyle(AppDesign.Palette.primaryText)
            .diaryCard(color: AppDesign.Palette.cardBackground, inset: AppDesign.Spacing.row)
            .contentShape(RoundedRectangle(cornerRadius: AppDesign.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(type.label), \(value)")
        .accessibilityIdentifier("measurement.history.\(type)")
        .accessibilityHint("Открывает график и историю")
    }

    private func album(babyID: UUID) -> some View {
        let gallery = store.photoGallery
        _ = gallery.revision
        let photos = try? gallery.photos(babyID: babyID)
        let latest = Array((photos ?? []).sorted(by: BabyPhoto.newestFirst).prefix(3))
        return VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
            NavigationLink(value: Destination.photos) {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                    HStack {
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                            Text("Фотоальбом").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                            if let photos {
                                Text(photos.isEmpty ? "Пока нет фотографий" : "Количество фото: \(photos.count)")
                                    .font(AppDesign.Typography.detail).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("child.profile.photos.count")
                            } else {
                                Text("Фото пока недоступны").font(AppDesign.Typography.detail)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: AppDesign.Metrics.minimumTouch)
                    HStack(spacing: AppDesign.Spacing.group) {
                        ForEach(0 ..< 3) { index in
                            let data = latest.indices.contains(index) ? gallery.data(
                                for: latest[index],
                                thumbnail: true
                            ) :
                                nil
                            AppDesign.Palette.cardBackground
                                .aspectRatio(1, contentMode: .fit)
                                .overlay {
                                    if let data, let image = UIImage(data: data) {
                                        Image(uiImage: image).resizable().scaledToFill()
                                    } else {
                                        Image(systemName: "photo").foregroundStyle(.secondary)
                                    }
                                }
                                .clipShape(RoundedRectangle(cornerRadius: AppDesign.Metrics.brandMarkCornerRadius))
                        }
                    }
                    .accessibilityHidden(true)
                }
                .foregroundStyle(AppDesign.Palette.primaryText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("child.profile.photos")
            PhotoAddButton(
                store: store,
                isPresenting: $photoAddPresentationBusy,
                onDismiss: onAlbumDismiss,
                handlesServiceErrors: true,
                showsTitle: true
            )
        }
    }
}

private struct ChildProfileEditor: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var original: Baby
    @State private var name: String
    @State private var birthDate: Date
    @State private var hasBirthDate: Bool
    @State private var birthTimeSelection: Date?
    @State private var birthInputs: [MeasurementType: String] = [:]
    @State private var errorMessage: String?

    init(store: AppStore, baby: Baby) {
        self.store = store
        _original = State(initialValue: baby)
        _name = State(initialValue: baby.name)
        _birthDate = State(initialValue: baby.birthDateConfirmed ? baby.displayedBirthDate() : .now)
        _hasBirthDate = State(initialValue: baby.birthDateConfirmed)
        _birthTimeSelection = State(initialValue: baby.birthTime.map(Self.pickerDate(for:)))
    }

    private static var timePickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    /// DatePicker needs a Date. A fixed UTC day keeps its clock independent of DST.
    private static func pickerDate(for time: CivilTime) -> Date {
        Date(timeIntervalSince1970: TimeInterval(time.hour * 3600 + time.minute * 60))
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Имя") {
                TextField("Имя ребёнка", text: $name).textContentType(.givenName)
                    .accessibilityIdentifier("child.editor.name")
            }
            Section("Дата рождения") {
                if hasBirthDate {
                    DatePicker("Дата рождения", selection: $birthDate, in: ...Date(), displayedComponents: .date)
                        .accessibilityIdentifier("child.editor.birthDate")
                    if let birthTimeSelection {
                        DatePicker("Время рождения", selection: Binding(
                            get: { self.birthTimeSelection ?? birthTimeSelection },
                            set: { self.birthTimeSelection = $0 }
                        ), displayedComponents: .hourAndMinute)
                            .environment(\.calendar, Self.timePickerCalendar)
                            .environment(\.timeZone, .gmt)
                            .accessibilityIdentifier("child.editor.birthTime")
                        Button("Убрать время рождения") { self.birthTimeSelection = nil }
                            .frame(minHeight: AppDesign.Metrics.minimumTouch)
                            .accessibilityIdentifier("child.editor.removeBirthTime")
                    } else {
                        Button("Указать время рождения") {
                            birthTimeSelection = Self.pickerDate(for: CivilTime(date: .now))
                        }
                        .frame(minHeight: AppDesign.Metrics.minimumTouch)
                        .accessibilityIdentifier("child.editor.setBirthTime")
                    }
                    Button("Убрать дату рождения") {
                        hasBirthDate = false
                        birthTimeSelection = nil
                    }
                    .frame(minHeight: AppDesign.Metrics.minimumTouch)
                } else {
                    Button("Указать дату рождения") { hasBirthDate = true }
                        .frame(minHeight: AppDesign.Metrics.minimumTouch)
                        .accessibilityIdentifier("child.editor.setBirthDate")
                }
            }
            if !original.birthMeasurementsCompleted {
                Section {
                    ForEach(MeasurementType.allCases, id: \.self) { type in
                        let label = "\(type.label), \(type.unit)"
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                            Text(label).font(AppDesign.Typography.detail)
                                .accessibilityHidden(true)
                            TextField("Необязательно", text: Binding(
                                get: { birthInputs[type, default: ""] },
                                set: { birthInputs[type] = $0 }
                            ))
                            .keyboardType(.decimalPad)
                            .accessibilityLabel(label)
                            .accessibilityIdentifier("child.editor.birth.\(type)")
                        }
                    }
                    Button("Пропустить измерения при рождении") { save(skipBirthMeasurements: true) }
                        .frame(minHeight: AppDesign.Metrics.minimumTouch)
                        .disabled(!canSave || birthInputs.values.contains { !$0.isEmpty })
                        .accessibilityIdentifier("child.editor.skipBirthMeasurements")
                } header: {
                    Text("При рождении")
                } footer: {
                    Text("Эти значения автоматически добавятся в историю измерений.")
                }
            }
        }
        .navigationTitle("Изменить профиль").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") { save() }
                    .disabled(!canSave)
                    .accessibilityIdentifier("child.editor.save")
            }
        }
        .alert("Не удалось изменить профиль", isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )) {
            Button("Понятно", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func save(skipBirthMeasurements: Bool = false) {
        var values: [MeasurementType: Double] = [:]
        for (type, input) in birthInputs {
            let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else {
                errorMessage = "Проверьте введённые значения. Измерение должно быть больше нуля."
                return
            }
            values[type] = value
        }
        do {
            try store.updateChildProfile(
                babyID: original.id,
                name: name,
                birthDate: birthDate,
                birthDateConfirmed: hasBirthDate,
                birthTime: birthTimeSelection.map { CivilTime(date: $0, calendar: Self.timePickerCalendar) },
                replacing: original,
                birthMeasurements: values,
                skipBirthMeasurements: skipBirthMeasurements
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func measurementValue(_ measurement: ChildMeasurement) -> String {
    "\(measurement.value.formatted(.number.precision(.fractionLength(0 ... 2)))) \(measurement.type.unit)"
}

struct MeasurementPresentation: Identifiable {
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
    @Binding var editing: MeasurementPresentation?
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
    }
}

struct MeasurementEditor: View {
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
        .alert("Не удалось изменить измерение", isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )) {
            Button("Понятно", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
