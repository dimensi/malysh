import CloudKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var store: AppStore
    let openChildProfile: () -> Void
    @AppStorage("cloudEnabled") private var cloudEnabled = false
    @State private var confirmsCleanup = false
    @State private var redundantEventCount = 0
    @State private var cleanupError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Профиль малыша") {
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
                    Button(action: openChildProfile) {
                        HStack {
                            Label(store.baby?.name ?? "Малыш", systemImage: "face.smiling")
                                .accessibilityIdentifier("settings.child.name")
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote).accessibilityHidden(true)
                        }
                        .frame(minHeight: AppDesign.Metrics.minimumTouch)
                        .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("settings.child.open")
                    .accessibilityHint("Открывает вкладку «Малыш»")
                }
                familySection
                Section {
                    Toggle("Сохранять полученные фотографии в Фото", isOn: Binding(
                        get: { store.photoGallery.autoSaveReceived },
                        set: { enabled in Task { await store.photoGallery.setAutoSaveReceived(enabled) } }
                    ))
                    .accessibilityIdentifier("photo.autoSave")
                    Link("Общая медиатека Apple", destination: URL(string: "https://support.apple.com/118229")!)
                        .accessibilityIdentifier("photo.sharedLibrary.help")
                } header: { Text("Фотографии") } footer: {
                    Text(
                        "Только на этом устройстве. Фотографии из семейного дневника сохраняются отдельными копиями в вашей медиатеке Фото. "
                            + "Общая медиатека настраивается в системе: Настройки → Приложения → Фото → Общая медиатека. "
                            + "Существующие снимки можно перенести в неё в приложении Фото."
                    )
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
            if let family = store.family {
                ForEach(family.members) { member in
                    if member.canEdit {
                        NavigationLink {
                            FamilyProfileEditor(store: store, member: member)
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
            Text(member.status).font(.subheadline).foregroundStyle(.secondary)
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
private struct FamilyProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    let store: AppStore
    let member: FamilyMember
    @State private var name: String
    @State private var role: ParentRole
    @State private var errorMessage: String?

    init(store: AppStore, member: FamilyMember) {
        self.store = store
        self.member = member
        let profile = store.baby?.parentProfiles[member.id]
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
                Text("Имя и роль видны обоим родителям")
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(AppDesign.Palette.error)
            }
            Button("Сохранить") {
                do {
                    try store.saveFamilyProfile(memberID: member.id, name: name, role: role)
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
