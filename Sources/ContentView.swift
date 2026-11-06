import Charts
import SwiftUI

extension EventKind {
    var symbol: String {
        switch self {
        case .breast: "heart.fill"
        case .bottle: "waterbottle.fill"
        case .diaper: "drop.fill"
        case .sleep: "moon.zzz.fill"
        }
    }

    var tint: Color {
        switch self {
        case .breast, .bottle: AppDesign.Palette.feeding
        case .diaper: AppDesign.Palette.diaper
        case .sleep: AppDesign.Palette.sleep
        }
    }
}

func durationText(_ seconds: TimeInterval) -> String {
    let minutes = max(0, Int(seconds / 60))
    return minutes >= 60 ? "\(minutes / 60) ч \(minutes % 60) мин" : "\(minutes) мин"
}

extension CareEvent {
    var detail: String {
        switch kind {
        case .breast:
            let sides = breastDurations()
            return "Л \(durationText(sides.left)) · П \(durationText(sides.right))"
        case .bottle: return "\(bottleType.label) · \(volumeML) мл"
        case .diaper: return diaperType.label
        case .sleep: return end == nil ? "Спит сейчас" : durationText(elapsed())
        }
    }

    var isActive: Bool {
        end == nil && (kind == .breast || kind == .sleep)
    }
}

struct ContentView: View {
    @Bindable var store: AppStore
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var tab = 0
    @State private var actionGridFitsTwoColumns = true
    @State private var showFeed = false
    @State private var showDiaper = false
    @State private var showWidgetSleep = false
    @State private var showSettings = false
    @State private var inviteOnOpen = false
    @State private var childPath = NavigationPath()
    @State private var editingMeasurement: MeasurementPresentation?
    @State private var showPhotos = false
    @State private var photoPresentationBusy = false
    @State private var profilePhotoAddBusy = false
    @State private var albumPresentationBusy = false
    @State private var editing: CareEvent?
    @State private var pendingWidgetRoute: WidgetRoute?
    @State private var widgetRouteInbox = WidgetRouteInbox.shared
    @State private var widgetRouteAwaitsSheetDismissal = false
    @State private var visibleWidgetActions: Set<String> = []
    @State private var widgetActionScrollRequest = 0
    @State private var activityScrollTarget: UUID?
    @State private var activityScrollRequest = 0
    @State private var activityTargetTab = 0
    @State private var handledTodayActivityScrollRequest = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { today }
                .tabItem { Label("Сегодня", systemImage: "sun.max.fill") }.tag(0)
            NavigationStack {
                HistoryView(store: store, edit: edit,
                            activityTarget: activityTargetTab == 1 ? activityScrollTarget : nil,
                            activityScrollRequest: $activityScrollRequest)
            }
            .tabItem { Label("История", systemImage: "clock.fill") }.tag(1)
            NavigationStack { StatisticsView(store: store) }
                .tabItem { Label("Статистика", systemImage: "chart.bar.fill") }.tag(2)
            NavigationStack(path: $childPath) {
                ChildProfileView(
                    store: store,
                    editingMeasurement: $editingMeasurement,
                    photoAddPresentationBusy: $profilePhotoAddBusy,
                    albumPresentationBusy: $albumPresentationBusy,
                    onAlbumDismiss: resumeWidgetRouteAfterSheet
                )
            }
            .tabItem {
                Label {
                    Text("Малыш")
                } icon: {
                    Image("BabyBear").renderingMode(.template)
                }
            }.tag(3)
        }
        .tint(AppDesign.Palette.accent)
        .sheet(item: $editing, onDismiss: resumeWidgetRouteAfterSheet) { event in
            EventEditor(event: event,
                        creatorLabel: store.authorLabel(for: event.createdBy, babyID: event.babyID),
                        lastEditorLabel: event.lastEditedBy.map { store.authorLabel(
                            for: $0,
                            babyID: event.babyID
                        ) },
                        onSave: { try store.save($0) },
                        onDelete: store.events
                            .contains(where: { $0.id == event.id }) ? { try store.delete(event) } : nil)
        }
        .sheet(item: $editingMeasurement, onDismiss: resumeWidgetRouteAfterSheet) { presentation in
            MeasurementEditor(store: store, measurement: presentation.measurement, isNew: presentation.isNew)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            inviteOnOpen = false
            resumeWidgetRouteAfterSheet()
        }) {
            SettingsView(store: store, inviteOnOpen: inviteOnOpen)
        }
        .sheet(isPresented: $showPhotos, onDismiss: resumeWidgetRouteAfterSheet) {
            NavigationStack { PhotoGalleryView(
                store: store,
                isPresentedModally: true,
                isPresenting: .constant(false)
            ) }
        }
        .onChange(of: store.selectedID) {
            childPath = NavigationPath()
            editingMeasurement = nil
            showPhotos = false
            photoPresentationBusy = false
            profilePhotoAddBusy = false
            albumPresentationBusy = false
        }
        .onChange(of: store.joinedDiaryID) { _, id in
            if id != nil {
                tab = 0
            }
        }
        .onChange(of: store.invitationNotice, initial: true) { _, notice in
            if let notice {
                store.errorMessage = notice
            }
        }
        .onAppear { receiveWidgetRoute() }
        .onChange(of: widgetRouteInbox.pending) { receiveWidgetRoute() }
        .alert(
            "Не удалось выполнить действие",
            isPresented: Binding(get: { store.errorMessage != nil }, set: {
                if !$0 {
                    store.errorMessage = nil
                }
            })
        ) {
            Button("Понятно") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var today: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: AppDesign.Spacing.section) {
                    HStack(spacing: AppDesign.Spacing.row) {
                        Button { showPhotos = true } label: {
                            ChildPhotoAvatar(store: store)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Фотографии малыша")
                        .accessibilityIdentifier("photo.gallery.open")
                        .accessibilityValue(ChildPhotoAvatar.accessibilityValue(for: store))
                        Button(action: openChildProfile) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(store.baby?.name ?? "Малыш").font(.title3.bold())
                                    if store.isSharedDiary {
                                        Image(systemName: "person.2.fill")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .accessibilityLabel("Семейный дневник")
                                            .accessibilityIdentifier("family.header")
                                    }
                                }
                                TimelineView(.periodic(from: .now, by: 60)) { context in
                                    if let age = store.baby?.ageLabel(now: context.date) {
                                        Text(age).foregroundStyle(.secondary)
                                    } else {
                                        Text(context.date, format: .dateTime.day().month(.wide))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(minHeight: AppDesign.Metrics.minimumTouch, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("child.profile.open")
                        .accessibilityHint("Открывает профиль ребёнка и измерения")
                        Spacer()
                        PhotoAddButton(
                            store: store,
                            isPresenting: $photoPresentationBusy,
                            onDismiss: resumeWidgetRouteAfterSheet,
                            handlesServiceErrors: true
                        )
                    }
                    if let suggestionID = store.inviteSuggestionID, suggestionID == store.selectedID {
                        inviteSuggestion
                    }
                    if store.active.isEmpty {
                        lastFeed
                    } else {
                        ForEach(store.active) { event in
                            TimerCard(
                                event: event,
                                finish: { store.finish(event) },
                                switchSide: { store.switchSide(event) }
                            )
                            .id("activity.\(event.id.uuidString)")
                        }
                    }

                    LazyVGrid(columns: dynamicTypeSize.isAccessibilitySize || !actionGridFitsTwoColumns
                        ? [GridItem(.flexible())]
                        : [GridItem(.flexible()), GridItem(.flexible())], spacing: AppDesign.Spacing.row)
                    {
                        ActionTile(
                            title: "Кормление",
                            subtitle: "Грудь или бутылочка",
                            symbol: "heart.fill",
                            color: AppDesign.Palette.feeding,
                            id: "action.feed"
                        ) { showFeed = true }
                            .id("widget.breast")
                            .onScrollVisibilityChange(threshold: 0.8) { updateWidgetActionVisibility(
                                "breast",
                                visible: $0
                            ) }
                            .confirmationDialog("Кормление", isPresented: $showFeed, titleVisibility: .visible) {
                                Button("Левая грудь") { store.start(.breast, side: .left) }
                                    .accessibilityIdentifier("feed.left")
                                Button("Правая грудь") { store.start(.breast, side: .right) }
                                    .accessibilityIdentifier("feed.right")
                                Button("Бутылочка") { addManual(.bottle) }.accessibilityIdentifier("feed.bottle")
                            }
                        ActionTile(
                            title: "Подгузник",
                            subtitle: "Записать смену",
                            symbol: "drop.fill",
                            color: AppDesign.Palette.diaper,
                            id: "action.diaper"
                        ) { showDiaper = true }
                            .id("widget.diaper")
                            .onScrollVisibilityChange(threshold: 0.8) { updateWidgetActionVisibility(
                                "diaper",
                                visible: $0
                            ) }
                            .confirmationDialog("Подгузник", isPresented: $showDiaper, titleVisibility: .visible) {
                                ForEach(DiaperType.allCases, id: \.self) { type in
                                    Button(type.label) { store.diaper(type) }
                                        .accessibilityIdentifier("diaper.\(type.rawValue)")
                                }
                            }
                        ActionTile(
                            title: "Сон",
                            subtitle: store.active
                                .contains(where: { $0.kind == .sleep }) ? "Таймер уже идёт" : "Начать таймер",
                            symbol: "moon.zzz.fill",
                            color: AppDesign.Palette.sleep,
                            id: "action.sleep"
                        ) { store.start(.sleep) }
                            .id("widget.sleep")
                            .onScrollVisibilityChange(threshold: 0.8) { updateWidgetActionVisibility(
                                "sleep",
                                visible: $0
                            ) }
                            .confirmationDialog("Сон", isPresented: $showWidgetSleep, titleVisibility: .visible) {
                                if !store.active.contains(where: { $0.kind == .sleep }) {
                                    Button("Начать сон") { store.start(.sleep) }
                                        .accessibilityIdentifier("widget.sleep.start")
                                }
                                Button("Отмена", role: .cancel) {}
                            }
                        ActionTile(
                            title: "Сводка",
                            subtitle: "Как прошёл день",
                            symbol: "chart.bar.fill",
                            color: AppDesign.Palette.cardBackground,
                            id: "action.summary"
                        ) { tab = 2 }
                    }
                    VStack(alignment: .leading, spacing: AppDesign.Spacing.row) {
                        HStack {
                            Text("Последние события").font(.title3.bold())
                            Spacer()
                            Button("Все") { tab = 1 }.frame(
                                minWidth: AppDesign.Metrics.minimumTouch,
                                minHeight: AppDesign.Metrics.minimumTouch
                            )
                        }
                        if store.events.isEmpty {
                            Text("Первый день вашей истории").font(.headline)
                            Text("Запишите кормление, смену подгузника или начало сна. Всё сохранится на iPhone сразу.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(Array(store.events.prefix(8))) { event in
                                EventRow(event: event, authorLabel: store.eventAuthorLabel(for: event)) { edit(event) }
                                if event.id != store.events.prefix(8).last?.id {
                                    Divider()
                                }
                            }
                        }
                    }
                }
                .onGeometryChange(for: Bool.self) { geometry in
                    geometry.size.width >= 2 * 140 + AppDesign.Spacing.row
                } action: { fits in
                    actionGridFitsTwoColumns = fits
                }
                .padding(AppDesign.Spacing.contentInset)
            }
            .background(AppDesign.Palette.groupedBackground)
            .onAppear {
                if let route = pendingWidgetRoute {
                    scrollProxy.scrollTo("widget." + route.destination.rawValue, anchor: .center)
                }
                if tab == 0, activityTargetTab == 0, let activityScrollTarget,
                   handledTodayActivityScrollRequest != activityScrollRequest
                {
                    handledTodayActivityScrollRequest = activityScrollRequest
                    scrollProxy.scrollTo("activity." + activityScrollTarget.uuidString, anchor: .center)
                }
            }
            .onChange(of: widgetActionScrollRequest) {
                if let route = pendingWidgetRoute {
                    scrollProxy.scrollTo("widget." + route.destination.rawValue, anchor: .center)
                }
            }
            .onChange(of: activityScrollRequest) {
                if tab == 0, activityTargetTab == 0, let activityScrollTarget,
                   handledTodayActivityScrollRequest != activityScrollRequest
                {
                    handledTodayActivityScrollRequest = activityScrollRequest
                    let request = activityScrollRequest
                    Task { @MainActor in
                        await Task.yield()
                        guard request == activityScrollRequest else { return }
                        scrollProxy.scrollTo("activity." + activityScrollTarget.uuidString, anchor: .center)
                    }
                }
            }
            .navigationTitle("Сегодня")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Настройки").accessibilityIdentifier("settings.open")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(EventKind.allCases, id: \.self) { kind in
                            Button("\(kind.label) вручную") { addManual(kind) }
                        }
                    } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Добавить запись за прошлое время")
                        .accessibilityIdentifier("manual.add")
                }
            }
        }
    }

    private var lastFeed: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let event = store.events.first(where: { $0.kind == .breast || $0.kind == .bottle }) {
                Label("Последнее кормление", systemImage: "heart.fill").font(.headline)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(
                        "\(durationText(context.date.timeIntervalSince(event.kind == .bottle ? event.start : (event.end ?? event.start)))) назад"
                    )
                    .font(.title.bold()).monospacedDigit()
                }
                Text(
                    "\(event.kind.label) · \(event.start.formatted(date: .omitted, time: .shortened)) · \(event.detail)"
                )
                .font(.subheadline)
            } else {
                Label("Рядом, день за днём", systemImage: "heart.fill").font(.title2.bold())
                Text("Всё важное о кормлении, сне и заботе — в одном месте.").font(.body)
            }
        }
        .foregroundStyle(AppDesign.Palette.primaryText)
        .diaryCard(color: AppDesign.Palette.feeding)
    }

    private var inviteSuggestion: some View {
        VStack(alignment: .leading, spacing: AppDesign.Spacing.group) {
            Label("Ведите дневник вместе", systemImage: "person.2")
                .font(.headline)
            Text("Пригласите второго родителя, чтобы записи были доступны вам обоим")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AppDesign.Spacing.row) { inviteSuggestionActions }
                VStack(alignment: .leading) { inviteSuggestionActions }
            }
            .buttonStyle(.borderless)
        }
        .diaryCard(color: AppDesign.Palette.cardBackground)
    }

    @ViewBuilder
    private var inviteSuggestionActions: some View {
        Button("Пригласить") {
            inviteOnOpen = true
            showSettings = true
        }
        .frame(minHeight: AppDesign.Metrics.minimumTouch)
        Button("Позже") { store.dismissInviteSuggestion() }
            .frame(minHeight: AppDesign.Metrics.minimumTouch)
            .accessibilityIdentifier("onboarding.invite.later")
    }

    private func openChildProfile() {
        childPath = NavigationPath()
        tab = 3
    }

    private func receiveWidgetRoute() {
        guard let route = widgetRouteInbox.take() else { return }
        activityScrollTarget = nil
        activityScrollRequest += 1
        pendingWidgetRoute = route
        openPendingWidgetRoute()
    }

    private func openPendingWidgetRoute() {
        guard store.ready, !widgetRouteAwaitsSheetDismissal, let route = pendingWidgetRoute else { return }
        guard route.destination == .activity || route.babyID == nil || route.babyID == store.baby?.id else {
            pendingWidgetRoute = nil
            return
        }
        // UIKit must finish dismissing the current sheet before its presenter
        // can show a widget action's anchored confirmation dialog.
        if editing != nil || editingMeasurement != nil || showSettings || showPhotos || photoPresentationBusy
            || profilePhotoAddBusy || albumPresentationBusy
        {
            widgetRouteAwaitsSheetDismissal = true
            editing = nil
            editingMeasurement = nil
            showSettings = false
            showPhotos = false
            photoPresentationBusy = false
            profilePhotoAddBusy = false
            albumPresentationBusy = false
            return
        }
        if route.destination == .activity {
            openActivityRoute(route)
            return
        }
        let needsAction = route.destination == .breast || route.destination == .diaper ||
            (route.destination == .sleep && !store.active.contains(where: { $0.kind == .sleep }))
        if needsAction, !visibleWidgetActions.contains(route.destination.rawValue) {
            tab = 0
            widgetActionScrollRequest += 1
            return
        }
        pendingWidgetRoute = nil
        activityScrollTarget = nil
        showFeed = false
        showDiaper = false
        showWidgetSleep = false
        tab = route.destination == .history ? 1 : 0
        switch route.destination {
        case .breast: showFeed = true
        case .diaper: showDiaper = true
        case .sleep:
            showWidgetSleep = !store.active.contains(where: { $0.kind == .sleep })
        case .today, .history, .activity: break
        }
    }

    private func openActivityRoute(_ route: WidgetRoute) {
        pendingWidgetRoute = nil
        guard let babyID = route.babyID, let eventID = route.eventID else {
            store.errorMessage = "Дневник недоступен. Проверьте доступ к нему и попробуйте ещё раз."
            return
        }
        do {
            guard !store.diaryRemovalInProgress else { throw AppStore.ActivityActionFailure.unavailable }
            try store.reload()
            guard store.babies.contains(where: { $0.id == babyID }) else {
                store.errorMessage = "Дневник недоступен. Проверьте доступ к нему и попробуйте ещё раз."
                return
            }
            if store.selectedID != babyID {
                try store.selectAndReload(babyID)
            }
        } catch {
            store.errorMessage = error.localizedDescription
            return
        }
        guard store.baby?.id == babyID,
              let event = store.events.first(where: { $0.id == eventID && $0.babyID == babyID }),
              event.kind == .sleep || event.kind == .breast
        else {
            store.errorMessage = "Запись недоступна. Возможно, она была удалена или доступ к дневнику изменился."
            return
        }
        showFeed = false
        showDiaper = false
        showWidgetSleep = false
        activityScrollTarget = event.id
        activityTargetTab = event.isActive ? 0 : 1
        tab = activityTargetTab
        activityScrollRequest += 1
    }

    private func updateWidgetActionVisibility(_ action: String, visible: Bool) {
        if visible {
            visibleWidgetActions.insert(action)
        } else {
            visibleWidgetActions.remove(action)
        }
        if visible {
            openPendingWidgetRoute()
        }
    }

    private func resumeWidgetRouteAfterSheet() {
        widgetRouteAwaitsSheetDismissal = false
        openPendingWidgetRoute()
    }

    private func addManual(_ kind: EventKind) {
        guard let baby = store.baby else { return }
        let now = Date()
        let start = (kind == .sleep || kind == .breast) ? now.addingTimeInterval(-600) : now
        editing = CareEvent(babyID: baby.id, kind: kind, start: start, end: now,
                            leftSeconds: kind == .breast ? 600 : 0)
    }

    private func edit(_ event: CareEvent) {
        guard !event.isActive else {
            store.errorMessage = "Сначала завершите таймер на экране «Сегодня», затем исправьте запись в истории."
            return
        }
        editing = event
    }
}

private struct TimerCard: View {
    let event: CareEvent
    let finish: () -> Void
    let switchSide: () -> Void
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 14) {
                Label(
                    event.kind == .sleep ? "Малыш спит" : "Кормление · \(event.side.label.lowercased()) грудь",
                    systemImage: event.kind.symbol
                )
                .font(.headline)
                Text(event.start, style: .timer).font(.largeTitle.bold()).monospacedDigit()
                    .accessibilityLabel("Прошло \(durationText(event.elapsed(now: context.date)))")
                if event.kind == .breast {
                    let sides = event.breastDurations(now: context.date)
                    Text("Левая: \(durationText(sides.left)) · Правая: \(durationText(sides.right))").font(.subheadline)
                    Button("Сменить грудь", action: switchSide).buttonStyle(.bordered).controlSize(.large)
                        .accessibilityIdentifier("timer.switch.\(event.id.uuidString)")
                }
                Button(event.kind == .sleep ? "Завершить сон" : "Завершить кормление", action: finish)
                    .buttonStyle(.borderedProminent).controlSize(.large).tint(AppDesign.Palette.accent)
                    .foregroundStyle(AppDesign.Palette.onAccent)
                    .accessibilityIdentifier("timer.finish.\(event.id.uuidString)")
            }
            .diaryCard(color: event.kind.tint)
        }
    }
}

private struct HistoryView: View {
    @Bindable var store: AppStore
    let edit: (CareEvent) -> Void
    let activityTarget: UUID?
    @Binding var activityScrollRequest: Int
    @State private var filter: EventKind?
    @State private var handledActivityScrollRequest = 0
    private var filtered: [CareEvent] {
        store.events.filter { filter == nil || $0.kind == filter }
    }

    private var days: [Date] {
        Array(Set(filtered.map { Calendar.current.startOfDay(for: $0.start) })).sorted(by: >)
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            List {
                Section {
                    Picker("Показать", selection: $filter) {
                        Text("Все события").tag(EventKind?.none)
                        ForEach(EventKind.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                    }.accessibilityIdentifier("history.filter")
                }
                if filtered.isEmpty {
                    ContentUnavailableView(
                        "Пока нет записей",
                        systemImage: "clock",
                        description: Text("Новые события появятся здесь.")
                    )
                }
                ForEach(days, id: \.self) { day in
                    Section(day.formatted(date: .complete, time: .omitted)) {
                        ForEach(filtered.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }) { event in
                            EventRow(event: event, authorLabel: store.eventAuthorLabel(for: event)) { edit(event) }
                                .id("activity.\(event.id.uuidString)")
                                .swipeActions {
                                    Button("Удалить", role: .destructive) { store.perform { try store.delete(event) } }
                                }
                        }
                    }
                }
            }
            .onAppear {
                if let activityTarget, handledActivityScrollRequest != activityScrollRequest {
                    handledActivityScrollRequest = activityScrollRequest
                    filter = nil
                    let request = activityScrollRequest
                    Task { @MainActor in
                        await Task.yield()
                        guard request == activityScrollRequest else { return }
                        scrollProxy.scrollTo("activity." + activityTarget.uuidString, anchor: .center)
                    }
                }
            }
            .onChange(of: activityScrollRequest) {
                if let activityTarget, handledActivityScrollRequest != activityScrollRequest {
                    handledActivityScrollRequest = activityScrollRequest
                    filter = nil
                    let request = activityScrollRequest
                    Task { @MainActor in
                        await Task.yield()
                        guard request == activityScrollRequest else { return }
                        scrollProxy.scrollTo("activity." + activityTarget.uuidString, anchor: .center)
                    }
                }
            }
        }.navigationTitle("История")
    }
}

private struct StatisticsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var store: AppStore
    @State private var day = Date()
    private var stats: DailyStatistics {
        DailyStatistics(events: store.events, day: day)
    }

    private var dayInterval: DateInterval {
        Calendar.current.dateInterval(of: .day, for: day) ?? DateInterval(start: day, duration: 86400)
    }

    private var dayEvents: [CareEvent] {
        store.events.filter { event in
            guard event.start <= Date() else { return false }
            if event.kind == .sleep {
                return event.start < dayInterval.end && (event.end ?? Date()) > dayInterval.start
            }
            return dayInterval.contains(event.start) && event.start < dayInterval.end
        }
    }

    var body: some View {
        List {
            Section {
                DatePicker("За день", selection: $day, in: ...Date(), displayedComponents: .date)
            }
            Section("Итоги дня") {
                metric("Кормления", value: "\(stats.feeds)", symbol: "heart.fill")
                metric("Из бутылочки", value: "\(stats.bottleML) мл", symbol: "waterbottle.fill")
                metric("Мокрые подгузники", value: "\(stats.wetDiapers)", symbol: "drop.fill")
                metric("Стул", value: "\(stats.dirtyDiapers)", symbol: "checkmark.circle.fill")
                metric("Сон", value: durationText(stats.sleepSeconds), symbol: "moon.zzz.fill")
            }
            Section("Ритм дня") {
                if dayEvents.isEmpty {
                    Text("Запишите первое событие, чтобы увидеть ритм дня.").foregroundStyle(.secondary)
                } else {
                    Chart(dayEvents) { event in
                        if event.kind == .sleep {
                            RuleMark(
                                xStart: .value("Начало", max(event.start, dayInterval.start)),
                                xEnd: .value("Конец", min(event.end ?? Date(), Date(), dayInterval.end)),
                                y: .value("Событие", event.kind.label)
                            )
                            .lineStyle(StrokeStyle(lineWidth: 8, lineCap: .round))
                            .foregroundStyle(by: .value("Тип", event.kind.label))
                        } else {
                            PointMark(x: .value("Время", event.start), y: .value("Событие", event.kind.label))
                                .foregroundStyle(by: .value("Тип", event.kind.label)).symbolSize(90)
                        }
                    }
                    .chartXScale(domain: dayInterval.start ... dayInterval.end)
                    .chartForegroundStyleScale(
                        domain: ["Грудь", "Бутылочка", "Подгузник", "Сон"],
                        range: [
                            AppDesign.Palette.chartFeeding,
                            AppDesign.Palette.chartFeeding,
                            AppDesign.Palette.chartDiaper,
                            AppDesign.Palette.chartSleep,
                        ]
                    )
                    .chartXAxis { AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                        AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
                    } }
                    .chartLegend(.hidden).frame(height: dynamicTypeSize.isAccessibilitySize ? 320 : 200).padding(
                        .vertical,
                        12
                    )
                    .accessibilityLabel("Временная шкала событий за день")
                    ForEach(dayEvents.sorted { $0.start < $1.start }) { event in
                        HStack {
                            Text(event.start, style: .time); Text(event.kind.label); Spacer(); Text(event.detail)
                                .foregroundStyle(.secondary)
                        }
                        .font(.subheadline).accessibilityElement(children: .combine)
                    }
                }
            }
        }.navigationTitle("Статистика")
    }

    private func metric(_ label: String, value: String, symbol: String) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    Label(label, systemImage: symbol)
                    Text(value).fontWeight(.semibold).monospacedDigit()
                }
            } else {
                HStack {
                    Label(label, systemImage: symbol); Spacer(); Text(value).fontWeight(.semibold).monospacedDigit()
                }
            }
        }.padding(.vertical, 4).accessibilityElement(children: .combine)
    }
}
