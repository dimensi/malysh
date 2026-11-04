import CloudKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @Bindable var store: AppStore
    @AppStorage("cloudEnabled") private var cloudEnabled = false
    @State private var babyName = ""
    @State private var saveError: String?
    @State private var saved = false

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
                    TextField("Имя малыша", text: $babyName)
                        .textContentType(.givenName)
                        .accessibilityIdentifier("baby-name")
                    Button("Сохранить имя") { saveName() }
                        .disabled(babyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.baby == nil)
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    }
                    if saved {
                        Label("Имя сохранено", systemImage: "checkmark.circle").foregroundStyle(.green)
                    }
                }
                familySection
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
            .onAppear { babyName = store.baby?.name ?? "" }
            .onChange(of: store.selectedID) { _, _ in
                babyName = store.baby?.name ?? ""
                saved = false
                saveError = nil
            }
            .onChange(of: babyName) { _, _ in saved = false }
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.isCurrentUser && member.name != "Вы" ? "\(member.name) (вы)" : member.name)
                            .font(.body.weight(.medium))
                        Text(member.role)
                            .font(.subheadline)
                        Text(member.status)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("family.member.\(member.id)")
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
                .frame(minHeight: 44)
            }
            .disabled(!store.cloudSharingReady || !cloudEnabled || store.cloudBusy || store.baby == nil)
            .accessibilityIdentifier("invite-family")
        } header: {
            Text("Семья")
        } footer: {
            Text(
                "Для общего дневника нужен iCloud у обоих родителей. Приглашение даёт доступ только к выбранному профилю малыша."
            )
        }
    }

    private func saveName() {
        guard var baby = store.baby else { return }
        baby.name = babyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !baby.name.isEmpty else { return }
        do {
            try store.persistence.saveBaby(baby)
            try store.reload()
            saveError = nil
            saved = true
        } catch { saveError = "Не удалось сохранить имя: \(error.localizedDescription)" }
    }
}
