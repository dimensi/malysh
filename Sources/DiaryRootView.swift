import SwiftUI

struct DiaryRootView: View {
    let store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var step: Step = .welcome
    @State private var name = ""
    @State private var born = false
    @State private var birthday = Date()
    @FocusState private var nameFocused: Bool

    private enum Step {
        case welcome, create, waitForInvitation
    }

    var body: some View {
        if store.launchState == .diary {
            ContentView(store: store)
                .onAppear {
                    step = .welcome
                    name = ""
                    born = false
                    birthday = Date()
                }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
                    screen
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(AppDesign.Spacing.contentInset)
                .padding(.vertical, AppDesign.Spacing.row)
                .frame(maxWidth: .infinity)
            }
            .id(step)
            .scrollDismissesKeyboard(.interactively)
            .background(AppDesign.Palette.groupedBackground.ignoresSafeArea())
            .tint(AppDesign.Palette.accent)
            .alert("Не удалось выполнить действие", isPresented: Binding(
                get: { store.ready && store.errorMessage != nil },
                set: {
                    if !$0 {
                        store.errorMessage = nil
                    }
                }
            )) {
                Button("Понятно", role: .cancel) { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
        }
    }

    @ViewBuilder private var screen: some View {
        switch store.launchState {
        case .loading:
            heading("Открываем дневник", symbol: "moon.stars")
            ProgressView()
        case .loadFailed:
            heading("Не удалось открыть дневник", symbol: "exclamationmark.icloud")
            Text("Попробуйте открыть хранилище ещё раз.").foregroundStyle(.secondary)
            primary("Попробовать снова", id: "onboarding.storage.retry") {
                Task {
                    await CareActivityRuntime.shared.ensureReady(checkCloudAccount: false)
                    await store.resumeInvitation()
                    await CareActivityRuntime.shared.ensureReady()
                }
            }
        case .restoring:
            if store.disablingCloud {
                heading("Дневник без iCloud", symbol: "iphone")
                restartInstructions("После перезапуска можно будет создать дневник на этом iPhone.")
            } else {
                heading("Восстанавливаем дневники", symbol: "icloud.and.arrow.down")
                if store.needsCloudRestart {
                    restartInstructions("Приложение проверит дневники в iCloud.")
                } else {
                    ProgressView("Проверяем iCloud")
                }
            }
            useLocalButton
        case let .restoreFailed(message):
            heading("Не удалось восстановить дневники", symbol: "exclamationmark.icloud")
            Text(message).foregroundStyle(.secondary)
            if store.persistence.cloudEnabled {
                primary("Проверить снова", id: "onboarding.restore.retry") {
                    Task { await store.retryRestoration() }
                }
            } else {
                restartInstructions("Приложение повторит проверку iCloud.")
            }
            useLocalButton
        case .joining:
            join(received: true)
        case .welcome:
            switch step {
            case .welcome: welcome
            case .create: create
            case .waitForInvitation: join(received: false)
            }
        case .diary:
            EmptyView()
        }
    }

    private var welcome: some View {
        let logoSize: CGFloat = dynamicTypeSize.isAccessibilitySize ? 72 : 124
        return VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
            Image("BrandMark")
                .resizable()
                .scaledToFit()
                .frame(width: logoSize, height: logoSize)
                .clipShape(.rect(cornerRadius: AppDesign.Radius.card))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                Text("Добро пожаловать в Малыш")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Всё важное о первых днях жизни малыша — в одном месте")
                    .font(.subheadline)
                    .foregroundStyle(AppDesign.Palette.primaryText.opacity(0.78))
            }
            VStack(spacing: AppDesign.Spacing.row) {
                choice("Создать дневник", detail: "Для своего малыша", symbol: "book.closed",
                       prominent: true) { step = .create }
                choice("Присоединиться к семье", detail: "Если другой родитель уже создал дневник",
                       symbol: "person.2", prominent: false) { step = .waitForInvitation }
            }
            if !store.persistence.cloudEnabled {
                Button("Восстановить из iCloud") { store.requestCloud(true) }
                    .frame(minHeight: AppDesign.Metrics.minimumTouch)
                    .accessibilityIdentifier("onboarding.restore")
            }
        }
        .padding(.top, AppDesign.Spacing.section)
    }

    private var create: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
            backButton { step = .welcome }
            heading("Создать дневник", symbol: "book.closed")
            VStack(alignment: .leading, spacing: AppDesign.Spacing.actionInset) {
                nameField
                Divider()
                Toggle("Малыш уже родился", isOn: $born)
                    .frame(minHeight: AppDesign.Metrics.minimumTouch)
                    .accessibilityIdentifier("onboarding.born")
                if born {
                    DatePicker("Дата рождения", selection: $birthday, in: ...Date(), displayedComponents: .date)
                        .frame(minHeight: AppDesign.Metrics.minimumTouch)
                        .accessibilityIdentifier("onboarding.birthday")
                }
            }
            .diaryCard(color: AppDesign.Palette.cardBackground)
            primary("Создать дневник", id: "onboarding.save") {
                store.perform { try store.createFirstDiary(name: name, birthDate: born ? birthday : nil) }
            }
        }
    }

    private var nameField: some View {
        let outline = RoundedRectangle(cornerRadius: 12)
        return VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("Имя ребёнка").font(.headline)
                .accessibilityHidden(true)
            TextField("Имя ребёнка", text: $name,
                      prompt: Text("Малыш").foregroundStyle(AppDesign.Palette.primaryText.opacity(0.72)))
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .textFieldStyle(.plain)
                .submitLabel(.done)
                .focused($nameFocused)
                .onSubmit { nameFocused = false }
                .padding(.horizontal, AppDesign.Spacing.row)
                .frame(minHeight: 48)
                .background(Color(uiColor: .tertiarySystemFill), in: outline)
                .overlay {
                    outline.strokeBorder(
                        nameFocused ? AppDesign.Palette.accent : Color(uiColor: .separator),
                        lineWidth: nameFocused ? 1.5 : 0.5
                    )
                    .allowsHitTesting(false)
                }
                .accessibilityIdentifier("onboarding.name")
        }
    }

    private func join(received: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
            if !received {
                backButton { step = .welcome }
            }
            heading("Присоединиться к семье", symbol: "person.2")
            if received {
                receivedInvitationStatus
            } else {
                Text("Попросите другого родителя отправить приглашение из настроек семейного дневника. "
                    + "Откройте полученную ссылку на этом iPhone.")
                Label("Ожидаем приглашение", systemImage: "envelope")
                    .font(.headline)
                    .diaryCard(color: AppDesign.Palette.sleep)
            }
            if !store.isConnectingFamily, !store.isImportingFamily || store.familyConnectionFailure != nil {
                Button("Создать свой дневник") {
                    store.cancelInvitation()
                    if !store.persistence.cloudEnabled {
                        store.requestCloud(false)
                    }
                    step = .create
                }
                .frame(minHeight: AppDesign.Metrics.minimumTouch)
                .accessibilityIdentifier("onboarding.join.create")
            }
        }
    }

    @ViewBuilder private var receivedInvitationStatus: some View {
        if let failure = store.familyConnectionFailure {
            Text(failure).foregroundStyle(.secondary)
            if store.persistence.cloudEnabled, store.invitation != nil {
                primary("Попробовать снова", id: "onboarding.join.retry") {
                    Task {
                        await store.retryRestoration()
                        await store.resumeInvitation()
                    }
                }
            } else if store.invitation != nil {
                restartInstructions("Приложение повторит подключение к семейному дневнику.")
            }
        } else if store.needsCloudRestart {
            restartInstructions("Приглашение сохранено. Приложение продолжит подключение.")
        } else if store.isImportingFamily {
            ProgressView("Синхронизируем семейный дневник")
            Text("Записи могут появиться через несколько минут. Можно свернуть приложение.")
                .foregroundStyle(.secondary)
            Button("Проверить снова") { store.perform { try store.reload() } }
                .frame(minHeight: AppDesign.Metrics.minimumTouch)
        } else {
            ProgressView("Подключаем семейный дневник")
        }
    }

    private var useLocalButton: some View {
        Button(store.cloudRequested ? "Пользоваться без iCloud" : "Вернуть подключение к iCloud") {
            store.requestCloud(!store.cloudRequested)
            step = .welcome
        }
        .frame(minHeight: AppDesign.Metrics.minimumTouch)
        .accessibilityIdentifier("onboarding.restore.local")
    }

    private func restartInstructions(_ description: String) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("Закройте и снова откройте «Малыш»").font(.headline)
            Text(description).foregroundStyle(.secondary)
        }
        .diaryCard(color: AppDesign.Palette.cardBackground)
    }

    private func heading(_ title: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(AppDesign.Palette.accent)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(AppDesign.Palette.onAccent)
        .accessibilityIdentifier(id)
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Назад", systemImage: "chevron.backward")
                .frame(minHeight: AppDesign.Metrics.minimumTouch)
        }
        .accessibilityIdentifier("onboarding.back")
    }

    private func choice(_ title: String, detail: String, symbol: String, prominent: Bool,
                        action: @escaping () -> Void) -> some View
    {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                Label(title, systemImage: symbol).font(.headline)
                Text(detail).font(.subheadline)
            }
            .foregroundStyle(prominent ? AppDesign.Palette.onAccent : AppDesign.Palette.primaryText)
            .diaryCard(color: prominent ? AppDesign.Palette.accent : AppDesign.Palette.sleep)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(prominent ? "onboarding.create" : "onboarding.join")
    }
}
