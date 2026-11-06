import CloudKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var store: AppStore
    @AppStorage("cloudEnabled") private var cloudEnabled = false
    @State private var confirmsCleanup = false
    @State private var redundantEventCount = 0
    @State private var cleanupError: String?

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
                }
                familySection
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
                    Toggle("Синхронизация через iCloud", isOn: $cloudEnabled)
                        .accessibilityIdentifier("cloud-toggle")
                    Text(store.syncStatus).font(.subheadline).foregroundStyle(.secondary)
                    if cloudEnabled != store.persistence.cloudEnabled {
                        Text("Перезапустите приложение, чтобы применить настройку iCloud.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                } header: { Text("iCloud") } footer: {
                    Text(
                        "Дневник хранится на этом iPhone. iCloud синхронизирует его между устройствами. "
                            + "После изменения настройки перезапустите приложение."
                    )
                }
            }
            .navigationTitle("Настройки")
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
            .disabled(!store.cloudSharingReady || !cloudEnabled || store.cloudBusy || store.baby == nil)
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
private struct DiaryManagementView: View {
    let store: AppStore
    @AppStorage("cloudEnabled") private var cloudEnabled = false
    @State private var confirmsReset = false
    @State private var errorMessage: String?

    private var canRemove: Bool {
        cloudEnabled == store.persistence.cloudEnabled && store.persistence.cloudStartupError == nil
            && (!cloudEnabled || store.cloudSharingReady) && !store.cloudBusy
    }

    var body: some View {
        Form {
            Section("Дневники") {
                ForEach(store.babies) { baby in
                    DiaryRemovalRow(baby: baby, invited: store.persistence.isInvitedDiary(id: baby.id)) {
                        remove($0)
                    }
                }
            }
            Section {
                Button("Начать заново", role: .destructive) { confirmsReset = true }
                    .accessibilityIdentifier("diary.reset")
                    .alert("Начать заново?", isPresented: $confirmsReset) {
                        Button("Удалить и начать заново", role: .destructive) { remove(.all) }
                            .accessibilityIdentifier("diary.reset.confirm")
                        Button("Отмена", role: .cancel) {}
                    } message: {
                        Text(cloudEnabled
                            ? "Ваши дневники и их содержимое будут удалены из iCloud для всех участников. "
                            + "Вы выйдете из чужих дневников. Приложение создаст один пустой дневник."
                            : "Дневники будут удалены с этого iPhone. Для сброса данных в iCloud сначала включите "
                            + "синхронизацию. Приложение создаст один пустой дневник.")
                    }
            } footer: {
                if !canRemove {
                    Text(cloudEnabled == store.persistence.cloudEnabled
                        ? store.syncStatus : "Перезапустите приложение, чтобы применить настройку iCloud.")
                } else if !cloudEnabled {
                    Text("Чтобы сбросить дневники в iCloud, включите синхронизацию и перезапустите приложение.")
                }
            }
        }
        .disabled(!canRemove || store.diaryRemovalInProgress)
        .overlay {
            if store.diaryRemovalInProgress {
                ProgressView("Обновляем дневники…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .navigationTitle("Управление дневниками")
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
        VStack(alignment: .leading, spacing: 4) {
            Text(baby.name).font(.headline)
            if baby.birthDateConfirmed {
                Text(baby.birthDate.formatted(date: .abbreviated, time: .omitted))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Button(invited ? "Выйти из дневника" : "Удалить дневник", role: .destructive) {
                confirmsRemoval = true
            }
            .buttonStyle(.borderless)
            .frame(minHeight: AppDesign.Metrics.minimumTouch)
            .accessibilityIdentifier("diary.remove")
            .alert(invited ? "Выйти из дневника?" : "Удалить дневник?", isPresented: $confirmsRemoval) {
                Button(invited ? "Выйти" : "Удалить", role: .destructive) {
                    remove(.one(baby.id, invited: invited))
                }
                .accessibilityIdentifier("diary.remove.confirm")
                Button("Отмена", role: .cancel) {}
            } message: {
                Text(invited
                    ? "Дневник «\(baby.name)» останется у владельца и других участников."
                    :
                    "Дневник «\(baby.name)» и его содержимое будут удалены. Если у дневника есть участники, они потеряют доступ.")
            }
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
