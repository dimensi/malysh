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

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
                    if let diary = store.selectedDiary {
                        diaryOverview(diary)
                        if !diary.canWrite {
                            Label("Только просмотр", systemImage: "lock")
                                .font(AppDesign.Typography.note)
                                .foregroundStyle(.secondary)
                        }
                        actions(diary)
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

    @ViewBuilder
    private func diaryOverview(_ diary: WatchDiary) -> some View {
        if store.diaries.count > 1 {
            Button {
                showDiaries = true
            } label: {
                overviewContent(diary, showsPicker: true)
                    .frame(minHeight: AppDesign.Metrics.minimumTouch)
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
            overviewContent(diary, showsPicker: false)
        }
    }

    private func overviewContent(_ diary: WatchDiary, showsPicker: Bool) -> some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
            HStack(spacing: AppDesign.Spacing.related) {
                Text(diary.name)
                    .font(AppDesign.Typography.itemTitle)
                    .accessibilityAddTraits(.isHeader)
                    .privacySensitive()
                    .redacted(reason: isLuminanceReduced ? .privacy : [])
                if showsPicker {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if let latest = diary.latestFeeding {
                TimelineView(.everyMinute) { context in
                    let now = context.date
                    let elapsed = relativeFeedingTime(latest.feedingReferenceDate, now: now)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AppDesign.Spacing.group) {
                            feedingSummary(elapsed, event: latest, now: now)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        HStack(spacing: AppDesign.Spacing.group) {
                            feedingSummary(elapsed, event: latest, now: now, compact: true)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        VStack(alignment: .leading, spacing: AppDesign.Spacing.related) {
                            feedingSummary(elapsed, event: latest, now: now)
                        }
                    }
                }
            } else {
                Text("Кормлений пока нет")
                    .font(AppDesign.Typography.note)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func feedingSummary(_ elapsed: String, event: CareEvent, now: Date, compact: Bool = false) -> some View {
        let detail = compact
            ? (event.kind == .bottle ? "\(event.volumeML) мл" : event.kind.label)
            : feedingDetail(event, now: now, abbreviated: true)
        Text(elapsed)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .accessibilityLabel("Последнее кормление, \(elapsed)")
            .accessibilityIdentifier("watch.lastFeeding.elapsed")
        Text(detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel(feedingDetail(event, now: now, abbreviated: false))
            .privacySensitive()
            .redacted(reason: isLuminanceReduced ? .privacy : [])
    }

    private func actions(_ diary: WatchDiary) -> some View {
        let breast = diary.active(.breast)
        let sleep = diary.active(.sleep)
        let secondaryLayout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: AppDesign.Spacing.related))
            : AnyLayout(HStackLayout(spacing: AppDesign.Spacing.related))
        return VStack(spacing: AppDesign.Spacing.related) {
            WatchActionButton(
                title: "Кормление", symbol: "heart.fill", tint: AppDesign.Palette.feeding,
                prominent: true, timer: breast
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

            secondaryLayout {
                WatchActionButton(title: "Подгузник", symbol: "drop.fill", tint: AppDesign.Palette.diaper) {
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

                WatchActionButton(title: "Сон", symbol: "moon.zzz.fill", tint: AppDesign.Palette.sleep, timer: sleep) {
                    openSleep(diaryID: diary.id)
                }
                .disabled(!diary.canWrite && sleep == nil)
                .accessibilityIdentifier("watch.sleep")
            }
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

private func relativeFeedingTime(_ date: Date, now: Date) -> String {
    let elapsed = max(0, now.timeIntervalSince(date))
    if elapsed < 60 {
        return "Только что"
    }
    let formatter = RelativeDateTimeFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.unitsStyle = .short
    return formatter.localizedString(fromTimeInterval: -elapsed)
}

private func feedingDetail(_ event: CareEvent, now: Date, abbreviated: Bool) -> String {
    if event.kind == .bottle {
        if abbreviated {
            let type = event.bottleType == .formula ? "Смесь" : "Молоко"
            return "\(type) · \(event.volumeML) мл"
        }
        return "Бутылочка · \(event.bottleType.label) · \(event.volumeML) мл"
    }
    if abbreviated {
        return "Грудь · \(watchMinutes(event.elapsed(now: now)))"
    }
    let sides = event.breastDurations(now: now)
    return "Грудь · левая \(watchMinutes(sides.left)), правая \(watchMinutes(sides.right))"
}

private struct WatchActionButton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    let title: String
    let symbol: String
    let tint: Color
    var prominent = false
    var timer: CareEvent?
    let action: () -> Void

    var body: some View {
        if prominent {
            Button(action: action) {
                prominentLabel
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(tint.opacity(0.9))
            .foregroundStyle(AppDesign.Palette.onAccent)
            .environment(\.colorScheme, .light)
        } else {
            Button(action: action) {
                secondaryLabel
                    .background {
                        RoundedRectangle(cornerRadius: AppDesign.Radius.card)
                            .fill(tint.opacity(0.20))
                            .environment(\.colorScheme, .light)
                    }
                    .contentShape(.rect(cornerRadius: AppDesign.Radius.card))
                    .opacity(isEnabled ? 1 : 0.55)
            }
            .buttonStyle(.plain)
        }
    }

    private var prominentLabel: some View {
        let stacked = timer != nil && dynamicTypeSize.isAccessibilitySize
        let layout = stacked
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: AppDesign.Spacing.related))
        return layout {
            symbolImage
            if let timer {
                Text(timer.side.label)
                    .accessibilityLabel(timer.side.label + " грудь")
                    .privacySensitive()
                    .redacted(reason: isLuminanceReduced ? .privacy : [])
                WatchElapsedText(start: timer.start, compact: true)
                    .font(.caption2)
                    .opacity(0.82)
            } else {
                Text(title)
            }
        }
        .font(AppDesign.Typography.itemTitle)
        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
        .accessibilityElement(children: .combine)
    }

    private var secondaryLabel: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(HStackLayout(spacing: AppDesign.Spacing.group))
            : AnyLayout(VStackLayout(spacing: 2))
        return layout {
            symbolImage
                .foregroundStyle(tint)
                .environment(\.colorScheme, .light)
            if let timer {
                WatchElapsedText(start: timer.start, compact: true)
                    .accessibilityLabel(Text("Сон, \(timer.start, style: .timer)"))
            } else {
                Text(title)
                    .fontWidth(.condensed)
            }
        }
        .font(.caption2.weight(.medium))
        .frame(maxWidth: .infinity, minHeight: AppDesign.Metrics.minimumTouch)
        .accessibilityElement(children: .combine)
    }

    private var symbolImage: some View {
        Image(systemName: symbol)
            .font(.body.weight(.semibold))
            .accessibilityHidden(true)
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
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: isLuminanceReduced || compact ? 60 : 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(start))
            let precise = !isLuminanceReduced && !compact && context.cadence <= .seconds
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
