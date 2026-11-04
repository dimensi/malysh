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
                    if store.babies.count > 1 {
                        Picker(
                            "Дневник",
                            selection: Binding(get: { store.selectedID }, set: {
                                if let id = $0 {
                                    store.select(id)
                                }
                            })
                        ) {
                            ForEach(store.babies) { baby in Text(baby.name).tag(Optional(baby.id)) }
                        }
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
                Section {
                    Button {
                        Task { await store.invite() }
                    } label: {
                        HStack {
                            Label("Пригласить близкого", systemImage: "person.badge.plus")
                            Spacer()
                            if store.cloudBusy {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(!store.cloudSharingReady || !cloudEnabled || store.cloudBusy || store.baby == nil)
                    .accessibilityIdentifier("invite-family")
                } header: { Text("Общий дневник") } footer: {
                    Text(
                        "Близкий сможет читать и добавлять записи выбранного малыша. "
                            + "Для приглашения нужен iCloud у обоих участников."
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
