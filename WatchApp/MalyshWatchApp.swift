import SwiftUI
import WatchKit

@main
struct MalyshWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var applicationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = WatchStore.shared

    var body: some Scene {
        WindowGroup {
            WatchDiaryView(store: store)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase, initial: true) {
                    if scenePhase == .active {
                        store.refresh()
                    }
                }
        }
    }
}

private struct WatchDiaryView: View {
    private enum Page: Hashable {
        case bottle(UUID)
        case timer(diaryID: UUID, eventID: UUID)
    }

    private struct DiaperChoice {
        let diaryID: UUID
        let eventID = UUID()
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let store: WatchStore
    @State private var path: [Page] = []
    @State private var feedingChoice: UUID?
    @State private var diaperChoice: DiaperChoice?
    @State private var lastRecordedDiaperID: UUID?
    @State private var showDiaries = false
    @State private var pendingRoute: WidgetRoute?
    @State private var routeMessage: String?
    @State private var errorPresented = false

    private let tileSpacing: CGFloat = 6

    private var usesSquareTiles: Bool {
        dynamicTypeSize < .xxLarge
    }

    var body: some View {
        NavigationStack(path: $path) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                        if let diary = store.selectedDiary {
                            if !usesSquareTiles {
                                diaryHeader(diary)
                            }
                            if !diary.canWrite {
                                Label("Только просмотр", systemImage: "lock")
                                    .font(AppDesign.Typography.note)
                                    .foregroundStyle(.secondary)
                            }
                            actions(diary, tileSide: squareSide(in: geometry.size.width))
                        } else {
                            emptyDiary
                        }
                        if let routeMessage {
                            Text(routeMessage)
                                .font(AppDesign.Typography.note)
                                .foregroundStyle(.secondary)
                        }
                        WatchSyncStatus(store: store)
                    }
                    .padding(.horizontal, AppDesign.Spacing.group)
                    .padding(.bottom, AppDesign.Spacing.group)
                }
                .contentMargins(.top, 0, for: .scrollContent)
            }
            .toolbar {
                if usesSquareTiles, let diary = store.selectedDiary {
                    ToolbarItem(placement: .topBarLeading) {
                        diaryHeader(diary)
                    }
                }
            }
            .navigationDestination(for: Page.self, destination: destination)
        }
        .onOpenURL { url in
            guard let route = WidgetRoute(url: url),
                  route.destination == .today || route.destination == .activity else { return }
            path = []
            feedingChoice = nil
            diaperChoice = nil
            showDiaries = false
            pendingRoute = route
            routeMessage = nil
            store.refresh()
            applyRoute()
        }
        .onChange(of: store.snapshotDate) { applyRoute() }
        .onChange(of: !path.isEmpty || feedingChoice != nil || diaperChoice != nil || showDiaries) { _, opened in
            if opened {
                pendingRoute = nil
                routeMessage = nil
            }
        }
        .task(id: pendingRoute) {
            guard let route = pendingRoute else { return }
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, pendingRoute == route else { return }
            pendingRoute = nil
            routeMessage = route.destination == .activity
                ? "Таймер завершён или недоступен." : "Этот дневник недоступен."
        }
        .onChange(of: store.statusMessage, initial: true) {
            if store.statusMessage != nil {
                errorPresented = true
            }
        }
        .alert("Дневник", isPresented: $errorPresented, presenting: store.statusMessage) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func squareSide(in width: CGFloat) -> CGFloat? {
        guard usesSquareTiles else { return nil }
        let contentWidth = width - 2 * AppDesign.Spacing.group
        return max(AppDesign.Metrics.minimumTouch, floor((contentWidth - tileSpacing) / 2))
    }

    @ViewBuilder
    private func diaryHeader(_ diary: WatchDiary) -> some View {
        if store.diaries.count > 1 {
            Button {
                showDiaries = true
            } label: {
                HStack(spacing: AppDesign.Spacing.related) {
                    diaryName(diary)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: usesSquareTiles ? nil : AppDesign.Metrics.minimumTouch)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isLuminanceReduced)
            .accessibilityIdentifier("watch.diary")
            .accessibilityHint("Выбрать дневник")
            .confirmationDialog("Дневник", isPresented: $showDiaries, titleVisibility: .visible) {
                ForEach(store.diaries) { candidate in
                    Button(candidate.name) { store.select(candidate.id) }
                }
                Button("Отмена", role: .cancel) {}
            }
        } else {
            diaryName(diary)
        }
    }

    private func diaryName(_ diary: WatchDiary) -> some View {
        Text(diary.name)
            .font(AppDesign.Typography.itemTitle)
            .accessibilityAddTraits(.isHeader)
            .privacySensitive()
            .redacted(reason: isLuminanceReduced ? .privacy : [])
    }

    private func actions(_ diary: WatchDiary, tileSide: CGFloat?) -> some View {
        let breast = diary.active(.breast)
        let sleep = diary.active(.sleep)
        let columns = if let tileSide {
            [GridItem(.fixed(tileSide), spacing: tileSpacing), GridItem(.fixed(tileSide))]
        } else {
            [GridItem(.flexible())]
        }

        return LazyVGrid(columns: columns, spacing: tileSpacing) {
            WatchCareTile(
                title: "Кормление", artwork: "WidgetFeedingArt", tint: AppDesign.Palette.feeding,
                tileSide: tileSide, running: breast != nil
            ) {
                if let breast {
                    path = [.timer(diaryID: diary.id, eventID: breast.id)]
                } else {
                    feedingChoice = diary.id
                }
            }
            .disabled(!diary.canWrite && breast == nil)
            .accessibilityIdentifier("watch.feed")
            .confirmationDialog(
                "Кормление",
                isPresented: choiceBinding($feedingChoice),
                titleVisibility: .visible,
                presenting: feedingChoice
            ) { diaryID in
                ForEach(BreastSide.allCases, id: \.self) { side in
                    Button("\(side.label) грудь") { startBreast(side, diaryID: diaryID) }
                }
                Button("Бутылочка") { path = [.bottle(diaryID)] }
                Button("Отмена", role: .cancel) {}
            }

            WatchCareTile(
                title: "Подгузник", artwork: "WidgetDiaperArt", tint: AppDesign.Palette.diaper,
                tileSide: tileSide
            ) {
                diaperChoice = DiaperChoice(diaryID: diary.id)
            }
            .disabled(!diary.canWrite)
            .accessibilityIdentifier("watch.diaper")
            .confirmationDialog(
                "Подгузник",
                isPresented: choiceBinding($diaperChoice),
                titleVisibility: .visible,
                presenting: diaperChoice
            ) { choice in
                ForEach(DiaperType.allCases, id: \.self) { type in
                    Button(type.label) { recordDiaper(type, choice: choice) }
                }
                Button("Отмена", role: .cancel) {}
            }

            WatchCareTile(
                title: "Сон", artwork: "WidgetSleepArt", tint: AppDesign.Palette.sleep,
                tileSide: tileSide, running: sleep != nil
            ) {
                openSleep(diaryID: diary.id)
            }
            .disabled(!diary.canWrite && sleep == nil)
            .accessibilityIdentifier("watch.sleep")

            WatchHomeStatus(diary: diary, breast: breast, sleep: sleep, tileSide: tileSide)
        }
        .disabled(isLuminanceReduced)
    }

    private var emptyDiary: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Text("Малыш").font(.headline).accessibilityAddTraits(.isHeader)
            if store.isCompanionInstalled == false {
                Text("Установите «Малыш» на iPhone.")
            } else if !store.hasSnapshot {
                Text("Откройте «Малыш» на iPhone.")
            } else {
                Text("Нет доступных дневников. Проверьте доступ в «Малыше» на iPhone.")
            }
            Button("Обновить", systemImage: "arrow.clockwise") { store.refresh() }
                .frame(minHeight: AppDesign.Metrics.minimumTouch)
                .accessibilityIdentifier("watch.refresh")
        }
    }

    @ViewBuilder
    private func destination(_ page: Page) -> some View {
        switch page {
        case let .bottle(diaryID):
            if let diary = store.selectedDiary, diary.id == diaryID, diary.canWrite {
                WatchBottleView(store: store, diaryID: diaryID)
            } else {
                unavailable("Запись в дневник недоступна")
            }
        case let .timer(diaryID, eventID):
            if let diary = store.selectedDiary, diary.id == diaryID,
               let event = diary.events.first(where: {
                   $0.id == eventID && $0.end == nil && ($0.kind == .breast || $0.kind == .sleep)
               })
            {
                WatchTimerView(store: store, event: event, canWrite: diary.canWrite) {
                    path = []
                }
            } else {
                unavailable("Таймер больше не активен")
            }
        }
    }

    private func unavailable(_ title: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                Text(title).font(AppDesign.Typography.itemTitle)
                WatchSyncStatus(store: store)
            }
        }
    }

    private func choiceBinding(_ selection: Binding<(some Any)?>) -> Binding<Bool> {
        Binding(
            get: { selection.wrappedValue != nil },
            set: {
                if !$0 {
                    selection.wrappedValue = nil
                }
            }
        )
    }

    private func recordDiaper(_ type: DiaperType, choice: DiaperChoice) {
        guard lastRecordedDiaperID != choice.eventID, store.selectedID == choice.diaryID else { return }
        if store.record(.diaper(type), eventID: choice.eventID) {
            lastRecordedDiaperID = choice.eventID
            WKInterfaceDevice.current().play(.click)
        }
    }

    private func startBreast(_ side: BreastSide, diaryID: UUID) {
        guard let diary = store.selectedDiary, diary.id == diaryID,
              diary.active(.breast) == nil else { return }
        let id = UUID()
        if store.record(.startBreast(side), eventID: id) {
            path = [.timer(diaryID: diaryID, eventID: id)]
        }
    }

    private func openSleep(diaryID: UUID) {
        guard let diary = store.selectedDiary, diary.id == diaryID else { return }
        if let event = diary.active(.sleep) {
            path = [.timer(diaryID: diaryID, eventID: event.id)]
        } else {
            let id = UUID()
            if store.record(.startSleep, eventID: id) {
                path = [.timer(diaryID: diaryID, eventID: id)]
            }
        }
    }

    private func applyRoute() {
        guard let route = pendingRoute,
              let diaryID = route.babyID ?? store.selectedID,
              let diary = store.diaries.first(where: { $0.id == diaryID }) else { return }
        guard let eventID = route.eventID else {
            _ = activateDiary(diaryID)
            return
        }
        guard diary.active(.breast)?.id == eventID || diary.active(.sleep)?.id == eventID else {
            routeMessage = "Ищем таймер на iPhone…"
            return
        }
        guard activateDiary(diaryID) else { return }
        path = [.timer(diaryID: diaryID, eventID: eventID)]
    }

    private func activateDiary(_ id: UUID) -> Bool {
        if store.selectedID != id {
            store.select(id)
        }
        guard store.selectedID == id else { return false }
        pendingRoute = nil
        routeMessage = nil
        return true
    }
}

private struct WatchCareTile: View {
    @Environment(\.isEnabled) private var isEnabled
    let title: String
    let artwork: String
    let tint: Color
    let tileSide: CGFloat?
    var running = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppDesign.Spacing.group) {
                let imageSide = tileSide.map { $0 * 0.63 } ?? 32
                Image(artwork)
                    .resizable()
                    .scaledToFit()
                    .frame(width: imageSide, height: imageSide)
                    .accessibilityHidden(true)
                if tileSide == nil {
                    Text(title).font(AppDesign.Typography.itemTitle)
                }
            }
            .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
            .frame(width: tileSide, height: tileSide)
            .background {
                RoundedRectangle(cornerRadius: AppDesign.Radius.card)
                    .fill(tint.opacity(0.21))
                    .environment(\.colorScheme, .light)
            }
            .overlay(alignment: .topTrailing) {
                if running {
                    Circle()
                        .fill(tint)
                        .frame(width: 5, height: 5)
                        .padding(AppDesign.Spacing.cardContent)
                        .environment(\.colorScheme, .light)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect(cornerRadius: AppDesign.Radius.card))
            .opacity(isEnabled ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(running ? "Таймер запущен" : "")
    }
}

private struct WatchHomeStatus: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let diary: WatchDiary
    let breast: CareEvent?
    let sleep: CareEvent?
    let tileSide: CGFloat?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 2) {
                if let breast, let sleep {
                    Text("Сейчас")
                    timerRow(breast, at: context.date, artwork: "WidgetFeedingArt", tint: AppDesign.Palette.feeding)
                    timerRow(sleep, at: context.date, artwork: "WidgetSleepArt", tint: AppDesign.Palette.sleep)
                } else if let breast {
                    Text("Грудь")
                    value(breast.elapsed(now: context.date), tint: AppDesign.Palette.feeding)
                    Text(breast.side.label)
                        .accessibilityLabel("\(breast.side.label) грудь")
                        .privacySensitive()
                        .redacted(reason: isLuminanceReduced ? .privacy : [])
                } else if let sleep {
                    Text("Сон")
                    value(sleep.elapsed(now: context.date), tint: AppDesign.Palette.sleep)
                } else if let latest = diary.latestCompletedFeeding {
                    ViewThatFits(in: .horizontal) {
                        Text("Кормили").fixedSize()
                        Text("Еда").fixedSize()
                    }
                    .accessibilityLabel("Последнее кормление")
                    value(context.date.timeIntervalSince(latest.feedingReferenceDate), tint: .white)
                        .accessibilityIdentifier("watch.lastFeeding.elapsed")
                    HStack(spacing: 2) {
                        Text("назад")
                        feedingMark(latest)
                            .privacySensitive()
                            .redacted(reason: isLuminanceReduced ? .privacy : [])
                    }
                } else {
                    Text("Пока пусто")
                        .accessibilityLabel("Кормлений пока нет")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .frame(width: tileSide, height: tileSide, alignment: .leading)
            .background(.white.opacity(0.10), in: .rect(cornerRadius: AppDesign.Radius.card))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("watch.status")
        }
    }

    private func value(_ elapsed: TimeInterval, tint: Color, font: Font = .subheadline) -> some View {
        ViewThatFits(in: .horizontal) {
            Text(compactWatchDuration(elapsed)).fixedSize()
            Text(compactWatchDuration(elapsed, minuteSuffix: "м")).fixedSize()
        }
        .font(font.weight(.semibold))
        .monospacedDigit()
        .foregroundStyle(tint)
        .environment(\.colorScheme, .light)
        .accessibilityLabel(elapsed < 60 ? "Меньше минуты" : watchMinutes(elapsed))
    }

    private func timerRow(_ event: CareEvent, at date: Date, artwork: String, tint: Color) -> some View {
        let elapsed = event.elapsed(now: date)
        return HStack(spacing: 2) {
            Image(artwork)
                .resizable()
                .scaledToFit()
                .frame(width: 11, height: 11)
                .accessibilityHidden(true)
            value(elapsed, tint: tint, font: .caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(event.kind == .sleep ? "Сон" : "Кормление"), \(elapsed < 60 ? "меньше минуты" : watchMinutes(elapsed))"
        )
    }

    @ViewBuilder
    private func feedingMark(_ event: CareEvent) -> some View {
        if event.kind == .bottle {
            Image("WidgetFeedingArt")
                .resizable()
                .scaledToFit()
                .frame(width: 12, height: 12)
                .accessibilityLabel("Бутылочка, \(event.bottleType.label), \(event.volumeML) миллилитров")
        } else {
            Image(systemName: "heart.fill")
                .foregroundStyle(AppDesign.Palette.feeding)
                .environment(\.colorScheme, .light)
                .accessibilityLabel("Грудь")
        }
    }
}

private func compactWatchDuration(_ elapsed: TimeInterval, minuteSuffix: String = " мин") -> String {
    let minutes = max(0, Int(elapsed / 60))
    return switch minutes {
    case 0: "<1\(minuteSuffix)"
    case 1 ..< 60: "\(minutes)\(minuteSuffix)"
    case 60 ..< 1440: "\(minutes / 60) ч"
    default: "\(minutes / 1440) д"
    }
}

private struct WatchBottleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @FocusState private var volumeFocused: Bool
    @State private var type: BottleType = .formula
    @State private var showTypes = false
    @State private var volume = 60.0
    @State private var eventID = UUID()
    @State private var didSave = false
    let store: WatchStore
    let diaryID: UUID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                Button {
                    showTypes = true
                } label: {
                    Label(type.label, systemImage: "chevron.down")
                        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Тип молока")
                .accessibilityValue(type.label)
                .accessibilityIdentifier("watch.bottle.type")
                .confirmationDialog("Тип молока", isPresented: $showTypes, titleVisibility: .visible) {
                    ForEach(BottleType.allCases, id: \.self) { option in
                        Button(option.label) {
                            type = option
                            volumeFocused = true
                        }
                    }
                    Button("Отмена", role: .cancel) {}
                }

                if dynamicTypeSize.isAccessibilitySize {
                    volumeValue
                    HStack(spacing: AppDesign.Spacing.related) {
                        volumeButton(increment: false)
                        volumeButton(increment: true)
                    }
                } else {
                    HStack(spacing: AppDesign.Spacing.related) {
                        volumeButton(increment: false)
                        volumeValue
                        volumeButton(increment: true)
                    }
                }

                Button {
                    guard !didSave, store.selectedID == diaryID else { return }
                    didSave = store.record(.bottle(type, Int(volume.rounded())), eventID: eventID)
                    if didSave {
                        dismiss()
                    }
                } label: {
                    Text("Сохранить")
                        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppDesign.Palette.accent)
                .foregroundStyle(AppDesign.Palette.onAccent)
                .disabled(isLuminanceReduced)
                .accessibilityIdentifier("watch.bottle.save")

                WatchSyncStatus(store: store)
            }
            .padding(.horizontal, AppDesign.Spacing.group)
        }
        .focusable(false)
        .navigationTitle("Бутылочка")
        .defaultFocus($volumeFocused, true)
        .onAppear { volumeFocused = true }
    }

    private var volumeValue: some View {
        VStack(spacing: AppDesign.Spacing.related) {
            Text(Int(volume.rounded()), format: .number.grouping(.never))
                .font(.title3.bold())
                .monospacedDigit()
            Text("мл")
                .font(AppDesign.Typography.note)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
        .contentShape(.rect)
        .onTapGesture { volumeFocused = true }
        .focusable()
        .focused($volumeFocused)
        .digitalCrownRotation(detent: $volume, from: 1, through: 2000, by: 1, sensitivity: .high)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Объём")
        .accessibilityValue("\(Int(volume.rounded())) миллилитров")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: adjustVolume(by: 1)
            case .decrement: adjustVolume(by: -1)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("watch.bottle.volume")
    }

    private func volumeButton(increment: Bool) -> some View {
        Button {
            adjustVolume(by: increment ? 10 : -10)
            volumeFocused = true
        } label: {
            Image(systemName: increment ? "plus" : "minus")
                .frame(width: AppDesign.Metrics.minimumTouch, height: AppDesign.Metrics.minimumTouch)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(isLuminanceReduced || (increment ? volume >= 2000 : volume <= 1))
        .accessibilityLabel(increment ? "Прибавить 10 миллилитров" : "Убавить 10 миллилитров")
        .accessibilityIdentifier(increment ? "watch.bottle.volume.plus" : "watch.bottle.volume.minus")
    }

    private func adjustVolume(by step: Double) {
        volume = min(2000, max(1, volume + step))
    }
}

private struct WatchTimerView: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var lastSwitch: ContinuousClock.Instant?
    let store: WatchStore
    let event: CareEvent
    let canWrite: Bool
    let onFinish: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                Label(
                    event.kind == .sleep ? "Малыш спит" : "\(event.side.label) грудь",
                    systemImage: event.kind == .sleep ? "moon.zzz.fill" : "heart.fill"
                )
                .font(AppDesign.Typography.itemTitle)
                .accessibilityAddTraits(.isHeader)
                .privacySensitive(event.kind == .breast)
                .redacted(reason: isLuminanceReduced ? .privacy : [])

                WatchElapsedText(start: event.start)
                    .font(.largeTitle.bold())
                    .accessibilityIdentifier("watch.timer.elapsed")

                if event.kind == .breast {
                    TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 60 : 1)) { context in
                        let sides = event.breastDurations(now: context.date)
                        let precise = !isLuminanceReduced && context.cadence <= .seconds
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                            Text("Левая: \(timerDuration(sides.left, precise: precise))")
                                .accessibilityLabel("Левая грудь: \(spokenTimerDuration(sides.left, precise: precise))")
                            Text("Правая: \(timerDuration(sides.right, precise: precise))")
                                .accessibilityLabel(
                                    "Правая грудь: \(spokenTimerDuration(sides.right, precise: precise))"
                                )
                        }
                        .font(AppDesign.Typography.detail)
                        .monospacedDigit()
                        .privacySensitive()
                        .redacted(reason: isLuminanceReduced ? .privacy : [])
                    }

                    Button {
                        let now = ContinuousClock.now
                        if let lastSwitch, lastSwitch.duration(to: now) < .milliseconds(350) {
                            return
                        }
                        let side: BreastSide = event.side == .left ? .right : .left
                        if store
                            .record(.switchBreast(to: side, expected: WatchTimerVersion(event)), eventID: event.id)
                        {
                            lastSwitch = now
                        }
                    } label: {
                        Text("Сменить грудь")
                            .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canWrite || isLuminanceReduced)
                    .accessibilityIdentifier("watch.timer.switch")
                }

                Button {
                    if store.record(.finish(expected: WatchTimerVersion(event)), eventID: event.id) {
                        onFinish()
                    }
                } label: {
                    Text(event.kind == .sleep ? "Завершить сон" : "Завершить кормление")
                        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppDesign.Palette.accent)
                .foregroundStyle(AppDesign.Palette.onAccent)
                .disabled(!canWrite || isLuminanceReduced)
                .accessibilityIdentifier("watch.timer.finish")

                WatchSyncStatus(store: store)
            }
            .padding(.horizontal, AppDesign.Spacing.group)
        }
        .navigationTitle(event.kind == .sleep ? "Сон" : "Кормление")
    }
}

private struct WatchElapsedText: View {
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced ? 60 : 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            let precise = !isLuminanceReduced && context.cadence <= .seconds
            Text(timerDuration(elapsed, precise: precise))
                .monospacedDigit()
                .accessibilityLabel("Прошло \(spokenTimerDuration(elapsed, precise: precise))")
        }
    }
}

private func timerDuration(_ elapsed: TimeInterval, precise: Bool) -> String {
    guard precise else { return watchMinutes(elapsed) }
    return Duration.seconds(elapsed).formatted(.time(pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond))
}

private func spokenTimerDuration(_ elapsed: TimeInterval, precise: Bool) -> String {
    let minutes = watchMinutes(elapsed)
    return precise ? "\(minutes) \(Int(elapsed) % 60) сек" : minutes
}

private func watchMinutes(_ elapsed: TimeInterval) -> String {
    let minutes = max(0, Int(elapsed / 60))
    return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
}

private struct WatchSyncStatus: View {
    let store: WatchStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
            if let message = store.statusMessage {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(AppDesign.Palette.error)
                    .accessibilityIdentifier("watch.sync.error")
            }
            if store.pendingCount > 0 {
                Label("На часах, ждут iPhone: \(store.pendingCount)", systemImage: "arrow.trianglehead.clockwise")
                    .accessibilityIdentifier("watch.sync.pending")
            }
            if store.hasSnapshot, store.isCompanionInstalled == false {
                Label("Установите «Малыш» на iPhone", systemImage: "iphone.slash")
            } else if store.hasSnapshot, !store.isReachable {
                Label("iPhone недоступен", systemImage: "iphone.slash")
            }
            if let date = store.snapshotDate, store.selectedDiary != nil {
                TimelineView(.everyMinute) { context in
                    let isStale = context.date.timeIntervalSince(date) >= WatchSnapshot.freshnessInterval
                    if isStale || !store.isReachable {
                        let timestamp = date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
                        Text(isStale ? "Данные могли устареть · \(timestamp)" : "Данные с iPhone: \(timestamp)")
                            .accessibilityIdentifier("watch.sync.snapshotDate")
                    } else if store.pendingCount == 0, store.statusMessage == nil {
                        Label("Синхронизировано с iPhone", systemImage: "checkmark")
                    }
                }
            }
        }
        .font(AppDesign.Typography.note)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
