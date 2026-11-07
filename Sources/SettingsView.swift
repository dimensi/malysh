import CloudKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    @Bindable var store: AppStore
    private var cloudEnabled: Bool {
        store.cloudRequested
    }

    var inviteOnOpen = false
    @State private var invitedOnOpen = false
    @State private var confirmsCleanup = false
    @State private var redundantEventCount = 0
    @State private var cleanupError: String?
    @State private var exportDocument: DiaryExportDocument?
    @State private var preparingExport = false
    @State private var presentsExport = false
    @State private var exportError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Дневники") {
                    if store.visibleBabies.count > 1 {
                        Picker(
                            "Дневник",
                            selection: Binding(get: { store.selectedID }, set: {
                                if let id = $0 {
                                    store.select(id)
                                }
                            })
                        ) {
                            ForEach(store.visibleBabies) { baby in Text(baby.name).tag(Optional(baby.id)) }
                        }
                        .accessibilityIdentifier("diary-picker")
                    }
                    NavigationLink("Управление дневниками") {
                        DiaryManagementView(store: store)
                    }
                    .accessibilityIdentifier("diary.manage")
                    Button {
                        guard let diaryID = store.baby?.id else { return }
                        exportDiary(id: diaryID)
                    } label: {
                        HStack {
                            Label("Экспортировать дневник", systemImage: "square.and.arrow.up")
                            Spacer()
                            if preparingExport {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(store.baby == nil || preparingExport || presentsExport || store.cloudSwitchInProgress)
                    .accessibilityIdentifier("diary.export")
                }
                familySection
                FeedingReminderSettings(reminders: store.feedingReminders)
                Section {
                    Toggle("Копировать фото других участников в «Фото»", isOn: Binding(
                        get: { store.photoGallery.autoSaveReceived },
                        set: { enabled in Task { await store.photoGallery.setAutoSaveReceived(enabled) } }
                    ))
                    .accessibilityIdentifier("photo.autoSave")
                } header: { Text("Фотографии") } footer: {
                    Text("Снимки с камеры «Малыша» всегда сохраняются в «Фото».")
                }
                Section {
                    if inviteOnOpen, !store.persistence.cloudEnabled {
                        Text("Чтобы вести дневник вместе, включите iCloud.")
                    }
                    Toggle("Синхронизация через iCloud", isOn: Binding(
                        get: { cloudEnabled },
                        set: { store.requestCloud($0) }
                    ))
                    .disabled(!store.canChangeCloudMode || preparingExport)
                    .accessibilityIdentifier("cloud-toggle")
                    if store.cloudSwitchInProgress {
                        ProgressView(cloudEnabled ? "Подключаем iCloud" : "Отключаем iCloud")
                    } else {
                        Text(store.syncStatus).font(.subheadline).foregroundStyle(.secondary)
                        if store.canRetryCloud {
                            Button("Попробовать снова") {
                                Task { await store.retryRestoration() }
                            }
                            .disabled(!store.canChangeCloudMode || preparingExport)
                            .accessibilityIdentifier("cloud.retry")
                        }
                    }
                } header: { Text("iCloud") } footer: {
                    Text("Дневник хранится на этом iPhone. iCloud синхронизирует его между устройствами.")
                }
            }
            .navigationTitle("Настройки")
            .fileExporter(
                isPresented: $presentsExport,
                document: exportDocument,
                contentTypes: [.json],
                defaultFilename: "Дневник Малыша.json"
            ) { result in
                exportDocument = nil
                if case let .failure(error) = result {
                    let underlyingError = error as NSError
                    if underlyingError.domain != NSCocoaErrorDomain || underlyingError.code != NSUserCancelledError {
                        exportError = "Не удалось сохранить файл. Попробуйте экспортировать дневник снова."
                    }
                }
            } onCancellation: {
                exportDocument = nil
            }
            .alert("Не удалось экспортировать дневник", isPresented: Binding(
                get: { exportError != nil },
                set: {
                    if !$0 {
                        exportError = nil
                    }
                }
            )) {
                Button("Понятно", role: .cancel) { exportError = nil }
            } message: { Text(exportError ?? "") }
            .task(id: store.cloudSharingReady) {
                if inviteOnOpen, !invitedOnOpen, store.cloudSharingReady {
                    invitedOnOpen = true
                    await store.invite()
                }
            }
            .alert("Не удалось сохранить фотографии", isPresented: Binding(
                get: { store.photoGallery.errorMessage != nil },
                set: {
                    if !$0 {
                        store.photoGallery.errorMessage = nil
                    }
                }
            )) {
                Button("Понятно", role: .cancel) { store.photoGallery.errorMessage = nil }
            } message: { Text(store.photoGallery.errorMessage ?? "") }
            .alert("Удалить лишний «Малыш»?", isPresented: $confirmsCleanup) {
                Button("Удалить лишний «Малыш»", role: .destructive) {
                    do {
                        try store.removeRedundantDiaries()
                        cleanupError = nil
                    } catch {
                        cleanupError = "Не удалось удалить лишний профиль. Попробуйте снова."
                    }
                }
                .accessibilityIdentifier("family.cleanup.confirm")
                Button("Отмена", role: .cancel) {}
                    .accessibilityIdentifier("family.cleanup.cancel")
            } message: {
                Text(
                    "Записей для удаления: \(redundantEventCount). Семейный дневник останется. Восстановить удалённое не получится."
                )
            }
            .sheet(isPresented: Binding(
                get: { store.pendingShare != nil },
                set: {
                    if !$0 {
                        store.pendingShare = nil
                    }
                }
            )) {
                if let share = store.pendingShare {
                    ShareSheet(
                        share: share,
                        container: CKContainer(identifier: Persistence.containerIdentifier)
                    ) { error in
                        store.errorMessage = CloudFailure.message(for: error)
                    }
                }
            }
        }
    }

    private func exportDiary(id: UUID) {
        preparingExport = true
        Task {
            defer { preparingExport = false }
            do {
                exportDocument = try await store.photoGallery.withExclusiveAccess {
                    try await store.persistence.exportDiary(id: id)
                }
                presentsExport = true
            } catch {
                exportError = "Не удалось прочитать дневник. Проверьте, что он доступен, и попробуйте снова."
            }
        }
    }

    private var familySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    store.isSharedDiary ? "Общий дневник" : "Дневник на этом iPhone",
                    systemImage: store.isSharedDiary ? "person.2.fill" : "iphone"
                )
                .font(.headline)
                .accessibilityIdentifier("family.status")
                Text(store.isSharedDiary
                    ? "Записи этого малыша доступны участникам семьи и синхронизируются через iCloud."
                    : "Пригласите второго родителя, чтобы вместе вести дневник малыша.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let baby = store.baby, let members = store.family?.members ?? store.localParent.map({ [$0] }) {
                ForEach(members) { member in
                    if member.canEdit {
                        NavigationLink {
                            FamilyProfileEditor(store: store, baby: baby, member: member)
                        } label: {
                            familyMemberLabel(member)
                        }
                        .accessibilityIdentifier("family.member.\(member.id)")
                    } else {
                        familyMemberLabel(member)
                            .accessibilityIdentifier("family.member.\(member.id)")
                    }
                }
            } else if store.isSharedDiary {
                Label("Синхронизируем список участников", systemImage: "arrow.triangle.2.circlepath")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("family.loading")
            }
            Button {
                Task { await store.invite() }
            } label: {
                HStack {
                    Label(
                        store.family != nil ? "Управлять доступом" : "Пригласить второго родителя",
                        systemImage: store.family != nil ? "person.2.badge.gearshape" : "person.badge.plus"
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if store.cloudBusy {
                        ProgressView()
                    }
                }
                .frame(minHeight: AppDesign.Metrics.minimumTouch)
            }
            .disabled(!store.cloudSharingReady || !cloudEnabled || !store.canChangeCloudMode || store.baby == nil)
            .accessibilityIdentifier("invite-family")
            if !store.redundantBabies.isEmpty {
                Button("Удалить лишний «Малыш»", role: .destructive) {
                    do {
                        redundantEventCount = try store.redundantEventCount
                        cleanupError = nil
                        confirmsCleanup = true
                    } catch {
                        cleanupError = "Не удалось проверить записи лишнего профиля. Попробуйте снова."
                    }
                }
                .frame(minHeight: AppDesign.Metrics.minimumTouch)
                .accessibilityIdentifier("family.cleanup")
            }
            if let cleanupError {
                Text(cleanupError).foregroundStyle(AppDesign.Palette.error)
            }
        } header: {
            Text("Семья")
        } footer: {
            Text(
                "Для общего дневника нужен iCloud у обоих родителей. Приглашение даёт доступ только к выбранному профилю малыша."
            )
        }
    }

    private func familyMemberLabel(_ member: FamilyMember) -> some View {
        let hasName = !member.name.isEmpty && member.name != member.role
            && !["Вы", "Другой родитель"].contains(member.name)
        return VStack(alignment: .leading, spacing: 4) {
            Text(hasName ? member.name : member.role)
                .font(.body.weight(.medium))
            if hasName {
                Text(member.role).font(.subheadline)
            }
            if member.isCurrentUser {
                Text("Это вы").font(.subheadline).foregroundStyle(.secondary)
            }
            if !member.status.isEmpty {
                Text(member.status).font(.subheadline).foregroundStyle(.secondary)
            }
            if !hasName {
                if member.canEdit {
                    Text("Добавить имя").font(.subheadline).foregroundStyle(.tint)
                } else {
                    Text("Имя пока не указано").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct FeedingReminderSettings: View {
    let reminders: FeedingReminderService
    @Environment(\.openURL) private var openURL
    @State private var editsCustomInterval = false

    private var usesCustomInterval: Bool {
        editsCustomInterval || !FeedingReminderService.presets.contains(reminders.intervalMinutes)
    }

    var body: some View {
        Section {
            Toggle("Напоминать о кормлении", isOn: Binding(
                get: { reminders.enabled },
                set: { reminders.setEnabled($0) }
            ))
            .accessibilityIdentifier("feeding-reminder.enabled")
            if reminders.enabled {
                intervalPicker
                if usesCustomInterval {
                    customIntervalPickers
                }
                if reminders.authorization == .denied {
                    Button("Открыть настройки уведомлений") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .accessibilityIdentifier("feeding-reminder.notification-settings")
                }
            }
        } header: {
            Text("Напоминания")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(statusText)
                    .accessibilityIdentifier("feeding-reminder.status")
                if reminders.enabled {
                    Text(channelText)
                        .accessibilityIdentifier("feeding-reminder.channel")
                    Text(notificationText)
                        .accessibilityIdentifier("feeding-reminder.notification-status")
                }
            }
        }
    }

    private var intervalPicker: some View {
        Picker("Интервал", selection: Binding<Int?>(
            get: { usesCustomInterval ? nil : reminders.intervalMinutes },
            set: { minutes in
                editsCustomInterval = minutes == nil
                if let minutes {
                    reminders.setIntervalMinutes(minutes)
                }
            }
        )) {
            ForEach(FeedingReminderService.presets, id: \.self) { minutes in
                Text(FeedingReminderService.intervalLabel(minutes)).tag(Optional(minutes))
            }
            Text("Свой интервал").tag(nil as Int?)
        }
        .pickerStyle(.menu)
        .accessibilityValue(FeedingReminderService.intervalLabel(reminders.intervalMinutes))
        .accessibilityIdentifier("feeding-reminder.interval")
    }

    private var customIntervalPickers: some View {
        let range = FeedingReminderService.customRange
        let hours = reminders.intervalMinutes / 60
        let minutes = reminders.intervalMinutes % 60
        let maxHours = range.upperBound / 60
        let minMinutes = max(0, range.lowerBound - hours * 60)
        let maxMinutes = min(59, range.upperBound - hours * 60)
        return Group {
            Picker("Часы", selection: Binding(get: { hours }, set: { newHours in
                let total = newHours * 60 + minutes
                reminders.setIntervalMinutes(min(range.upperBound, max(range.lowerBound, total)))
            })) {
                ForEach(0 ... maxHours, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityValue("\(hours)")
            .accessibilityIdentifier("feeding-reminder.hours")

            Picker("Минуты", selection: Binding(get: { minutes }, set: { newMinutes in
                reminders.setIntervalMinutes(hours * 60 + newMinutes)
            })) {
                ForEach(Array(stride(from: minMinutes, through: maxMinutes, by: FeedingReminderService.customStep)),
                        id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.menu)
            .accessibilityValue("\(minutes)")
            .accessibilityIdentifier("feeding-reminder.minutes")
        }
    }

    private var statusText: String {
        guard reminders.enabled else { return "Одно напоминание после последнего кормления на этом устройстве." }

        switch reminders.status {
        case .off:
            return "Подготавливаем напоминание."
        case .noChild:
            return "Выберите дневник, чтобы получать напоминания."
        case .noFeeding:
            return "Напоминание появится после первого кормления."
        case .feedingActive:
            return "Напоминание появится после завершения кормления."
        case .overdue:
            return "Интервал после последнего кормления уже прошёл."
        case let .scheduled(date):
            return "Следующее напоминание — \(date.formatted(date: .abbreviated, time: .shortened))."
        case .unavailable:
            return "Не удалось запланировать напоминание."
        }
    }

    private var channelText: String {
        switch reminders.deliveryChannel {
        case .liveActivity:
            "Напоминание появится на экране блокировки."
        case .notification:
            "Напоминание придёт обычным уведомлением."
        case nil:
            reminders.liveActivitiesEnabled
                ? "Экран блокировки: эфиры включены."
                : "Эфиры на экране блокировки выключены."
        }
    }

    private var notificationText: String {
        switch reminders.authorization {
        case .notDetermined:
            "Для резервного напоминания разрешите уведомления."
        case .denied:
            "Резервные уведомления выключены в настройках iPhone."
        case .unavailable:
            "Не удалось проверить разрешение на уведомления."
        case .allowed:
            "Резервные уведомления разрешены."
        }
    }
}

@MainActor
private struct DiaryManagementView: View {
    let store: AppStore
    private var cloudEnabled: Bool {
        store.cloudRequested
    }

    @State private var confirmsReset = false
    @State private var errorMessage: String?

    private var canRemove: Bool {
        store.canChangeCloudMode && cloudEnabled == store.persistence.cloudEnabled
            && store.persistence.cloudStartupError == nil && (!cloudEnabled || store.cloudSharingReady)
    }

    var body: some View {
        List {
            Section {
                ForEach(store.babies) { baby in
                    DiaryRemovalRow(baby: baby, invited: store.persistence.isInvitedDiary(id: baby.id)) {
                        remove($0)
                    }
                }
            }
            Section {
                Button("Начать заново", role: .destructive) { confirmsReset = true }
                    .accessibilityIdentifier("diary.reset")
                    // A full reset keeps a visible Cancel button.
                    .alert("Начать заново?", isPresented: $confirmsReset) {
                        Button("Удалить и начать заново", role: .destructive) { remove(.all) }
                            .accessibilityIdentifier("diary.reset.confirm")
                        Button("Отмена", role: .cancel) {}
                    } message: {
                        Text(cloudEnabled
                            ? "Ваши дневники и их содержимое будут удалены из iCloud для всех участников. "
                            + "Вы выйдете из чужих дневников. После сброса откроется первоначальная настройка."
                            : "Дневники будут удалены с этого iPhone. Для сброса данных в iCloud сначала включите "
                            + "синхронизацию. После сброса откроется первоначальная настройка.")
                    }
            } footer: {
                if !canRemove {
                    Text(store.syncStatus)
                } else if !cloudEnabled {
                    Text("Чтобы сбросить дневники в iCloud, включите синхронизацию и дождитесь её готовности.")
                }
            }
        }
        .listStyle(.insetGrouped)
        .disabled(!canRemove || store.diaryRemovalInProgress)
        .overlay {
            if store.diaryRemovalInProgress {
                ProgressView("Обновляем дневники…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Дневники")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(store.diaryRemovalInProgress)
        .interactiveDismissDisabled(store.diaryRemovalInProgress)
        .alert("Не удалось завершить действие", isPresented: Binding(
            get: { errorMessage != nil },
            set: {
                if !$0 {
                    errorMessage = nil
                }
            }
        )) {
            Button("Понятно", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func remove(_ removal: AppStore.DiaryRemoval) {
        Task {
            do {
                try await store.removeDiaries(removal)
            } catch {
                let detail = error is Persistence.Failure
                    ? error.localizedDescription : "Проверьте подключение к iCloud и повторите действие."
                if case .all = removal {
                    errorMessage = "Часть дневников уже могла быть удалена. " + detail
                } else {
                    errorMessage = detail
                }
            }
        }
    }
}

@MainActor
private struct DiaryRemovalRow: View {
    let baby: Baby
    let invited: Bool
    let remove: (AppStore.DiaryRemoval) -> Void
    @State private var confirmsRemoval = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
            Text(baby.name).font(AppDesign.Typography.itemTitle)
            if baby.birthDateConfirmed {
                Text(baby.birthDate.formatted(date: .abbreviated, time: .omitted))
                    .font(AppDesign.Typography.detail)
                    .foregroundStyle(AppDesign.Palette.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button {
                confirmsRemoval = true
            } label: {
                Label(
                    invited ? "Выйти" : "Удалить",
                    systemImage: invited ? "rectangle.portrait.and.arrow.right" : "trash"
                )
            }
            .tint(AppDesign.Palette.error)
            .accessibilityIdentifier("diary.remove")
        }
        .confirmationDialog(
            invited ? "Выйти из дневника?" : "Удалить дневник?",
            isPresented: $confirmsRemoval,
            titleVisibility: .visible
        ) {
            Button(invited ? "Выйти" : "Удалить", role: .destructive) {
                remove(.one(baby.id, invited: invited))
            }
            .accessibilityIdentifier("diary.remove.confirm")
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(invited
                ? "Дневник «\(baby.name)» останется у владельца и других участников."
                : "Дневник «\(baby.name)» и всё его содержимое будут удалены. Участники потеряют доступ.")
        }
    }
}

@MainActor
private struct FamilyProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: AppStore
    let member: FamilyMember
    @State private var babyID: UUID
    @State private var name: String
    @State private var role: ParentRole
    @State private var errorMessage: String?

    init(store: AppStore, baby: Baby, member: FamilyMember) {
        self.store = store
        self.member = member
        _babyID = State(initialValue: baby.id)
        let profile = baby.parentProfiles[member.id]
        let fallbackName = member.name == member.role || ["Вы", "Другой родитель"].contains(member.name) ? "" : member
            .name
        _name = State(initialValue: profile?.name ?? fallbackName)
        _role = State(initialValue: profile?.role ?? ParentRole.allCases.first { $0.label == member.role } ?? .parent)
    }

    var body: some View {
        Form {
            Section {
                TextField("Имя", text: $name)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("family.profile.name")
                Picker("Роль", selection: $role) {
                    ForEach(ParentRole.allCases, id: \.self) { role in Text(role.label).tag(role) }
                }
                .accessibilityIdentifier("family.profile.role")
            } footer: {
                Text(store.isSharedDiary
                    ? "Имя и роль видны участникам семейного дневника."
                    : "Имя и роль будут видны в ваших записях.")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(AppDesign.Palette.error)
            }
            Button("Сохранить") {
                do {
                    try store.saveFamilyProfile(babyID: babyID, memberID: member.id, name: name, role: role)
                    dismiss()
                } catch {
                    errorMessage = "Не удалось сохранить имя и роль. Попробуйте снова."
                }
            }
            .frame(minHeight: AppDesign.Metrics.minimumTouch)
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("family.profile.save")
        }
        .navigationTitle("Имя и роль")
        .navigationBarTitleDisplayMode(.inline)
    }
}
