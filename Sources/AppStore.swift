import CloudKit
import Combine
import CoreData
import Observation
import SwiftUI
import UIKit
import WidgetKit

@MainActor @Observable
final class AppStore {
    @ObservationIgnored private var storedPhotoGallery: PhotoGalleryStore?
    var photoGallery: PhotoGalleryStore {
        if let storedPhotoGallery {
            return storedPhotoGallery
        }
        let arguments = ProcessInfo.processInfo.arguments
        let directory = arguments.contains("--ui-testing") ? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("UITesting/PhotoWorkflow", isDirectory: true) : nil
        let gallery = PhotoGalleryStore(persistence: persistence, directory: directory)
        storedPhotoGallery = gallery
        return gallery
    }

    let persistence: Persistence
    let feedingReminders: FeedingReminderService
    private let activityCoordinator: (any CareActivityCoordinating)?
    private let widgetSnapshotStore: WidgetSnapshotStore
    private let reloadsWidgetTimelines: Bool
    private let selectionPreferenceKey: String
    private var widgetRefreshObservers: Set<AnyCancellable> = []
    @ObservationIgnored private var widgetSnapshotBatchDepth = 0
    @ObservationIgnored private var widgetSnapshotRefreshPending = false
    var allowsActivityStart: () -> Bool = { false }
    private var loading = false
    var babies: [Baby] = []
    var visibleBabies: [Baby] = []
    var redundantBabies: [Baby] = []
    var family: FamilySnapshot?
    var selectedID: UUID?
    var events: [CareEvent] = []
    var measurements: [ChildMeasurement] = []
    var ready = false
    var loadFailed = false
    var errorMessage: String?
    var syncStatus = "Записи сохраняются на этом iPhone"
    var cloudBusy = false
    private var acceptingInvitation = false
    private var cloudAccountCheckID: UUID?
    @ObservationIgnored private var cloudSwitchTask: Task<Void, Never>?
    private(set) var cloudSwitchInProgress = false
    private(set) var cloudSwitchFailure: String?
    private var failedCloudTarget: Bool?
    private var cloudAccountFailure: String?
    private var cloudImport = CloudSetupState()
    private let storesPreferences: Bool
    private(set) var cloudRequested = false
    private(set) var invitation: PendingFamilyInvitation?
    private(set) var invitationFailure: String?
    private(set) var joinedDiaryID: UUID?
    private(set) var inviteSuggestionID: UUID?
    private(set) var diaryRemovalInProgress = false
    private var cloudSetup = CloudSetupState()
    private var cloudAccountAvailable = false
    var pendingShare: CKShare?
    #if DEBUG
        private var testingFamily: FamilySnapshot?
    #endif
    var baby: Baby? {
        babies.first { $0.id == selectedID }
    }

    var isSharedDiary: Bool {
        guard let selectedID else { return false }
        if family != nil {
            return true
        }
        guard let sharedStore = persistence.sharedStore,
              let object = try? persistence.babyObject(id: selectedID) else { return false }
        return object.objectID.persistentStore == sharedStore
    }

    var localParent: FamilyMember? {
        guard family == nil, let baby, let privateStore = persistence.privateStore,
              let record = try? persistence.babyObject(id: baby.id),
              record.objectID.persistentStore == privateStore else { return nil }
        let profile = baby.parentProfiles["owner"]
        return FamilyMember(id: "owner", name: profile?.name ?? "",
                            role: (profile?.role ?? .parent).label, status: "",
                            isCurrentUser: true, isOwner: true)
    }

    var active: [CareEvent] {
        events.filter { $0.end == nil && ($0.kind == .breast || $0.kind == .sleep) }
    }

    enum LaunchState: Equatable {
        case loading, loadFailed, welcome, restoring, restoreFailed(String), joining, diary
    }

    var launchState: LaunchState {
        if !ready {
            return loadFailed ? .loadFailed : .loading
        }
        if baby != nil, invitation == nil || hasOpenedDiary {
            return .diary
        }
        if invitation != nil || invitationFailure != nil {
            return .joining
        }
        if cloudSwitchInProgress {
            return .restoring
        }
        if let cloudSwitchFailure {
            return .restoreFailed(cloudSwitchFailure)
        }
        if !cloudRequested {
            return .welcome
        }
        if let restorationFailure {
            return .restoreFailed(restorationFailure)
        }
        return cloudImport.isReady(expected: expectedCloudStores) && cloudSharingReady ? .welcome : .restoring
    }

    private var hasOpenedDiary = false

    var canChangeCloudMode: Bool {
        ready && !cloudSwitchInProgress && !cloudBusy && !acceptingInvitation && !diaryRemovalInProgress
            && pendingShare == nil
    }

    var canRetryCloud: Bool {
        cloudSwitchFailure != nil || (cloudRequested && restorationFailure != nil)
    }

    private var restorationFailure: String? {
        persistence.cloudStartupError.map(CloudFailure.message(for:))
            ?? cloudAccountFailure
            ?? cloudSetup.failure(expected: expectedCloudStores)
            ?? cloudImport.failure(expected: expectedCloudStores)
    }

    var familyConnectionFailure: String? {
        if let invitationFailure {
            return invitationFailure
        }
        if cloudSwitchInProgress || acceptingInvitation {
            return nil
        }
        if let cloudSwitchFailure {
            return cloudSwitchFailure
        }
        if let cloudError = persistence.cloudStartupError {
            return CloudFailure.message(for: cloudError)
        }
        if let cloudAccountFailure {
            return cloudAccountFailure
        }
        guard let sharedStore = persistence.sharedStore else { return nil }
        let shared: Set<String> = [sharedStore.identifier]
        return cloudSetup.failure(expected: shared) ?? cloudImport.failure(expected: shared)
    }

    var invitationNotice: String? {
        invitation == nil ? invitationFailure : nil
    }

    var isConnectingFamily: Bool {
        acceptingInvitation
    }

    var isImportingFamily: Bool {
        invitation?.accepted == true
    }

    private var expectedCloudStores: Set<String> {
        guard persistence.isLoaded else { return [] }
        return Set(persistence.container.persistentStoreCoordinator.persistentStores.map(\.identifier))
    }

    var cloudMirroringEnabled: Bool {
        ready && !cloudSwitchInProgress && persistence.cloudEnabled
    }

    var cloudSharingReady: Bool {
        cloudMirroringEnabled && cloudAccountAvailable && cloudSetup.isReady(expected: expectedCloudStores)
    }

    private func updateCloudStatus() {
        if let cloudSwitchFailure {
            syncStatus = cloudSwitchFailure
        } else if let error = persistence.cloudStartupError {
            syncStatus = CloudFailure.message(for: error)
        } else if !persistence.cloudEnabled {
            syncStatus = "Записи сохраняются на этом iPhone"
        } else if let failure = cloudSetup.failure(expected: expectedCloudStores) {
            syncStatus = failure
        } else if let cloudAccountFailure {
            syncStatus = cloudAccountFailure
        } else if !cloudAccountAvailable {
            syncStatus = "Проверяем доступ к iCloud · записи доступны локально"
        } else if !cloudSharingReady {
            syncStatus = "Подготавливаем iCloud · записи доступны локально"
        } else {
            syncStatus = "iCloud готов · доставка изменений может занять время"
        }
    }

    func handleCloudEvent(_ event: NSPersistentCloudKitContainer.Event) {
        guard persistence.cloudEnabled else { return }
        if event.type == .setup {
            cloudSetup.record(event)
            updateCloudStatus()
            if cloudSharingReady, invitation != nil {
                Task { await resumeInvitation() }
            }
            return
        }
        if event.type == .import {
            cloudImport.record(event)
        }
        if let error = event.error, cloudSwitchFailure == nil {
            syncStatus = CloudFailure.message(for: error)
        } else if event.endDate != nil, event.succeeded {
            if cloudSharingReady, cloudSwitchFailure == nil {
                syncStatus = "Последняя синхронизация: \((event.endDate ?? Date()).formatted(date: .omitted, time: .shortened))"
            }
            if ready {
                perform { try reload() }
            }
        }
    }

    init(persistence injectedPersistence: Persistence? = nil,
         activityCoordinator: (any CareActivityCoordinating)? = nil,
         widgetSnapshotStore: WidgetSnapshotStore? = nil,
         feedingReminders: FeedingReminderService? = nil)
    {
        self.activityCoordinator = activityCoordinator
        let arguments = ProcessInfo.processInfo.arguments
        var testing = arguments.contains("--ui-testing")
        var widgetTesting = false
        #if DEBUG
            if injectedPersistence == nil {
                widgetTesting = Self.configureWidgetTesting(arguments: arguments, testing: testing)
                testing = testing || widgetTesting
            }
        #endif
        selectionPreferenceKey = testing ? "debug.selectedBabyUITesting" : "selectedBaby"
        storesPreferences = injectedPersistence == nil && !testing
        self.feedingReminders = feedingReminders ?? Self.makeFeedingReminders(
            usesAppPreferences: storesPreferences, testing: testing, arguments: arguments
        )
        let publishesWidgets = injectedPersistence == nil && (!testing || widgetTesting)
        reloadsWidgetTimelines = publishesWidgets
        self.widgetSnapshotStore = widgetSnapshotStore ?? (publishesWidgets
            ? WidgetSnapshotStore() : WidgetSnapshotStore(directory: nil))
        if let injectedPersistence {
            persistence = injectedPersistence
            cloudRequested = injectedPersistence.cloudEnabled
            storedPhotoGallery = PhotoGalleryStore(
                persistence: injectedPersistence,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("PhotoWorkflowTests-" + UUID().uuidString)
            )
            observeCalendarChanges()
            return
        }
        var directory: URL?
        if testing {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UITesting", isDirectory: true)
            if ProcessInfo.processInfo.arguments.contains("--reset-data"), let directory {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let savedInvitation = testing ? nil : Self.savedInvitation()
        let requested = !testing &&
            (UserDefaults.standard.bool(forKey: "cloudEnabled") || (try? savedInvitation?.get()) != nil)
        persistence = Persistence(
            directory: directory,
            cloudEnabled: requested,
            configureStoreDescription: testing ? { $0.cloudKitContainerOptions = nil } : nil
        )
        cloudRequested = requested
        if storesPreferences {
            restoreLaunchPreferences(savedInvitation)
        }
        observeCalendarChanges()
    }

    private static func makeFeedingReminders(usesAppPreferences: Bool, testing: Bool,
                                             arguments: [String]) -> FeedingReminderService
    {
        if usesAppPreferences {
            return FeedingReminderService()
        }
        let suite = testing ? "dev.dimensi.malysh.feeding-reminders.ui-testing" :
            "dev.dimensi.malysh.feeding-reminders.injected-persistence"
        let defaults = UserDefaults(suiteName: suite)!
        if testing, arguments.contains("--reset-data") {
            defaults.removePersistentDomain(forName: suite)
        }
        #if DEBUG
            let authorization: FeedingReminderAuthorization = if testing,
                                                                 arguments.contains("--feeding-reminders-authorized")
            {
                .allowed
            } else if testing, arguments.contains("--feeding-reminders-denied") {
                .denied
            } else {
                .unavailable
            }
        #else
            let authorization = FeedingReminderAuthorization.unavailable
        #endif
        return FeedingReminderService(defaults: defaults, scheduler: IsolatedFeedingReminderScheduler(
            authorization: authorization, liveActivitiesEnabled: authorization == .denied
        ))
    }

    #if DEBUG
        private static func configureWidgetTesting(arguments: [String], testing: Bool) -> Bool {
            // App intents can cold-launch without the UI runner's arguments. Retain only the isolated test session.
            let key = "debug.widgetTestingSession"
            if arguments.contains("--end-widget-testing") || (testing && !arguments.contains("--widget-testing")) {
                UserDefaults.standard.removeObject(forKey: key)
            } else if testing, arguments.contains("--widget-testing") {
                UserDefaults.standard.set(true, forKey: key)
            }
            let enabled = UserDefaults.standard.bool(forKey: key)
            UserDefaults(suiteName: WidgetSnapshotStore.appGroupIdentifier)?.set(enabled, forKey: key)
            return enabled
        }
    #endif

    private static func savedInvitation() -> Result<PendingFamilyInvitation, Error>? {
        guard let data = UserDefaults.standard.data(forKey: PendingFamilyInvitation.preferenceKey) else { return nil }
        return Result { try PendingFamilyInvitation(data: data) }
    }

    private func restoreLaunchPreferences(_ savedInvitation: Result<PendingFamilyInvitation, Error>?) {
        switch savedInvitation {
        case let .success(value): invitation = value
        case .failure: invitationFailure = Self.invalidInvitationMessage
        case nil: break
        }
        inviteSuggestionID = UserDefaults.standard.string(forKey: "onboarding.inviteSuggestion")
            .flatMap(UUID.init(uuidString:))
    }

    private func observeCalendarChanges() {
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange))
            .merge(with: NotificationCenter.default.publisher(for: .NSCalendarDayChanged))
            // Foundation can post midnight/time-zone notifications off the main
            // thread. Hop before entering this MainActor-inferred sink closure.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, ready else { return }
                    refreshWidgetSnapshot()
                    if !diaryRemovalInProgress {
                        feedingReminders.update(babyID: selectedID, events: events, babyName: baby?.name)
                    }
                }
            }.store(in: &widgetRefreshObservers)
    }

    private func refreshWidgetSnapshot() {
        guard widgetSnapshotBatchDepth == 0 else {
            widgetSnapshotRefreshPending = true
            return
        }
        // A failed cache write must never fail a successful diary save.
        do {
            if try widgetSnapshotStore.write(WidgetSnapshot(baby: baby, events: events)) {
                #if DEBUG
                    WidgetCommandTiming.current?.mark("snapshotPublished")
                #endif
                if reloadsWidgetTimelines {
                    WidgetCenter.shared.reloadAllTimelines()
                    ControlCenter.shared.reloadAllControls()
                }
            }
        } catch {
            // Keep the last complete atomic snapshot until the next reload retries.
        }
    }

    private func finishWidgetSnapshotBatch() {
        widgetSnapshotBatchDepth -= 1
        guard widgetSnapshotBatchDepth == 0, widgetSnapshotRefreshPending else { return }
        widgetSnapshotRefreshPending = false
        refreshWidgetSnapshot()
    }

    func load(checkCloudAccount: Bool = true) async {
        guard !ready, !loading else { return }
        loading = true
        defer { loading = false }
        if loadFailed {
            errorMessage = nil
        }
        loadFailed = false
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--initialize-cloudkit-schema") {
                // Maintenance mode must never open or mirror the user's diary stores.
                do {
                    try await persistence.prepareDevelopmentSchema()
                    exit(0)
                } catch {
                    let detail = error as NSError
                    print("SCHEMA_INITIALIZATION_FAILED: \(detail.domain) \(detail.code)")
                    exit(1)
                }
            }
        #endif
        do {
            try await persistence.load()
            #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                if arguments.contains("--ui-testing"), !arguments.contains("--test-onboarding") {
                    if arguments.contains("--reset-data"), try persistence.babies().isEmpty {
                        try persistence.saveBaby(Baby(name: "Малыш"))
                    }
                    if arguments.contains("--family-fixture") {
                        try prepareFamilyFixture()
                    }
                }
            #endif
            babies = try persistence.babies()
            let saved = UserDefaults.standard.string(forKey: selectionPreferenceKey).flatMap(UUID.init(uuidString:))
            selectedID = babies.first(where: { $0.id == saved })?.id
            try reload()
            ready = true
            updateCloudStatus()
            if cloudRequested != persistence.cloudEnabled, persistence.cloudStartupError == nil {
                scheduleCloudSwitch()
            } else if persistence.cloudEnabled, checkCloudAccount {
                await checkAccount()
            }
        } catch {
            loadFailed = true
            errorMessage =
                "Не удалось открыть дневник: \(error.localizedDescription). Данные не удалены. Попробуйте снова."
        }
    }

    func reload() throws {
        guard !diaryRemovalInProgress else { return }
        // An unavailable store pair must not be mistaken for an empty diary.
        guard persistence.privateStore != nil, persistence.sharedStore != nil else {
            throw Persistence.Failure.missingStore
        }
        photoGallery.revision += 1
        Task { await photoGallery.saveReceivedIfEnabled() }
        babies = try persistence.babies()
        try updateVisibleBabiesAndSelection()
        let joinedID = try importedDiaryForInvitation()
        if let joinedID {
            selectedID = joinedID
        }
        events = try selectedID.map { try persistence.events(babyID: $0).sorted { $0.start > $1.start } } ?? []
        measurements = try selectedID.map { try persistence.measurements(babyID: $0) } ?? []
        family = selectedID.flatMap { try? persistence.familySnapshot(babyID: $0) }
        // Warm per-diary actor knowledge for cold background Live Activity actions.
        for baby in babies {
            _ = try? persistence.currentEventAuthor(babyID: baby.id)
        }
        #if DEBUG
            if let testingFamily {
                family = FamilySnapshot(isOwner: testingFamily.isOwner, members: testingFamily.members.map { member in
                    let profile = baby?.parentProfiles[member.id]
                    return FamilyMember(id: member.id, name: profile?.name ?? member.name,
                                        role: profile?.role.label ?? member.role, status: member.status,
                                        isCurrentUser: member.isCurrentUser, isOwner: member.isOwner,
                                        canEdit: member.canEdit)
                })
            }
        #endif
        if let activityCoordinator {
            let allEvents = try babies.flatMap { try persistence.events(babyID: $0.id) }
            activityCoordinator.reconcile(events: allEvents, babies: babies, allowStart: allowsActivityStart())
        }
        if let joinedID {
            UserDefaults.standard.set(joinedID.uuidString, forKey: selectionPreferenceKey)
            joinedDiaryID = joinedID
            cancelInvitation()
        }
        if selectedID != nil, invitation == nil {
            hasOpenedDiary = true
        }
        refreshWidgetSnapshot()
        feedingReminders.update(babyID: selectedID, events: events, babyName: baby?.name)
    }

    func createFirstDiary(name: String, birthDate: Date?) throws {
        guard launchState == .welcome, !diaryRemovalInProgress else { return }
        // Re-read the store before writing in case a CloudKit import just committed.
        guard try persistence.babies().isEmpty else {
            try reload()
            return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        if let birthDate, Calendar.current.startOfDay(for: birthDate) > now {
            throw ChildProfileError.futureBirthday
        }
        var diary = Baby(
            name: name.isEmpty ? "Малыш" : name,
            birthDate: birthDate.map { Calendar.current.startOfDay(for: $0) } ?? now,
            birthDateConfirmed: birthDate != nil
        )
        diary.explicitlyCreated = true
        try persistence.saveBaby(diary)
        inviteSuggestionID = diary.id
        if storesPreferences {
            UserDefaults.standard.set(diary.id.uuidString, forKey: "onboarding.inviteSuggestion")
        }
        perform { try reload() }
    }

    func dismissInviteSuggestion() {
        inviteSuggestionID = nil
        if storesPreferences {
            UserDefaults.standard.removeObject(forKey: "onboarding.inviteSuggestion")
        }
    }

    func requestCloud(_ enabled: Bool) {
        cloudRequested = enabled
        cloudSwitchFailure = nil
        failedCloudTarget = nil
        scheduleCloudSwitch()
    }

    private func scheduleCloudSwitch(reopen: Bool = false) {
        guard ready, cloudSwitchTask == nil else { return }
        if !reopen, cloudRequested == persistence.cloudEnabled, persistence.cloudStartupError == nil {
            saveCloudPreference()
            updateCloudStatus()
            return
        }
        guard canChangeCloudMode else { return }
        cloudSwitchFailure = nil
        failedCloudTarget = nil
        cloudSwitchInProgress = true
        cloudSwitchTask = Task {
            await photoGallery.withExclusiveAccess {
                // Onboarding can choose local mode while a photo operation is finishing.
                if reopen || cloudRequested != persistence.cloudEnabled || persistence.cloudStartupError != nil {
                    applyCloudMode(cloudRequested, reopen: reopen)
                } else {
                    saveCloudPreference()
                }
            }
            cloudSwitchInProgress = false
            cloudSwitchTask = nil
            updateCloudStatus()
            if ready, persistence.cloudEnabled {
                await checkAccount()
            }
        }
    }

    private func applyCloudMode(_ enabled: Bool, reopen: Bool) {
        let previousGeneration = persistence.generation
        do {
            try persistence.switchCloud(to: enabled, reopen: reopen)
            saveCloudPreference()
        } catch {
            failedCloudTarget = enabled
            cloudRequested = persistence.cloudEnabled
            let action = enabled ? "включить" : "отключить"
            cloudSwitchFailure = persistence.isLoaded
                ? "Не удалось \(action) iCloud. Повторите попытку."
                : error.localizedDescription
        }
        if persistence.generation != previousGeneration || !persistence.isLoaded {
            cloudSetup = CloudSetupState()
            cloudImport = CloudSetupState()
            cloudAccountCheckID = nil
            cloudAccountAvailable = false
            cloudAccountFailure = nil
        }
        if persistence.isLoaded {
            perform { try reload() }
        } else {
            ready = false
            loadFailed = true
            errorMessage = cloudSwitchFailure
        }
    }

    private func saveCloudPreference() {
        if !cloudRequested {
            cancelInvitation()
        }
        if storesPreferences {
            UserDefaults.standard.set(cloudRequested, forKey: "cloudEnabled")
        }
    }

    func updateChildProfile(
        babyID: UUID,
        name: String,
        birthDate: Date,
        birthDateConfirmed: Bool,
        birthTime: CivilTime? = nil,
        replacing original: Baby,
        birthMeasurements: [MeasurementType: Double] = [:],
        skipBirthMeasurements: Bool = false
    ) throws {
        guard var latest = try persistence.babies().first(where: { $0.id == babyID })
        else { throw Persistence.Failure.missingBaby }
        guard latest.id == original.id, latest.name == original.name, latest.birthDate == original.birthDate,
              latest.birthDateConfirmed == original.birthDateConfirmed, latest.birthDay == original.birthDay,
              latest.birthTime == original.birthTime, latest.birthTimeZoneIdentifier == original.birthTimeZoneIdentifier
        else { throw ChildProfileError.conflict }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ChildProfileError.emptyName }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let birthDay = CivilDay(date: birthDate, timeZone: calendar.timeZone)
        var birthday = birthDay.date(calendar: calendar).map { calendar.startOfDay(for: $0) }
        let birthTimeChanged = !latest.birthDateConfirmed || birthDay != latest.birthDay || birthTime != latest
            .birthTime
        var birthTimeZoneIdentifier = birthTimeChanged ? nil : latest.birthTimeZoneIdentifier
        if birthDateConfirmed, let birthTime, birthTimeChanged || !birthMeasurements.isEmpty {
            let timeZone = birthTimeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? calendar.timeZone
            guard let date = birthTime.date(on: birthDay, calendar: calendar, recordedTimeZone: timeZone.identifier)
            else {
                throw ChildProfileError.invalidBirthTime
            }
            birthday = date
            birthTimeZoneIdentifier = timeZone.identifier
        }
        guard !birthDateConfirmed || (birthday ?? birthDate) <= now else { throw ChildProfileError.futureBirthday }
        latest.name = trimmed
        // Never rewrite an automatically generated legacy date until the user confirms one.
        if birthDateConfirmed {
            latest.birthDate = birthDate
            latest.birthDay = birthDay
        }
        latest.birthDateConfirmed = birthDateConfirmed
        latest.birthTime = birthDateConfirmed ? birthTime : nil
        latest.birthTimeZoneIdentifier = latest.birthTime == nil ? nil : birthTimeZoneIdentifier
        var initialMeasurements: [ChildMeasurement]?
        if !birthMeasurements.isEmpty {
            guard birthDateConfirmed, let birthday else { throw ChildProfileError.missingConfirmedBirthday }
            initialMeasurements = MeasurementType.allCases.compactMap { type in
                birthMeasurements[type].map {
                    ChildMeasurement(babyID: babyID, type: type, measuredAt: birthday, value: $0,
                                     createdAt: now, modifiedAt: now)
                }
            }
        } else if skipBirthMeasurements {
            initialMeasurements = []
        }
        try persistence.saveChildProfile(latest, initialMeasurements: initialMeasurements)
        // The save is already durable. A refresh failure must not ask the editor to retry the write.
        perform { try reload() }
    }

    func saveMeasurement(_ measurement: ChildMeasurement, replacing original: ChildMeasurement? = nil) throws {
        var value = measurement
        let existing = try persistence.measurements(babyID: value.babyID).first { $0.id == value.id }
        guard existing == original else { throw ChildProfileError.conflict }
        value.createdAt = existing?.createdAt ?? Date()
        value.modifiedAt = Date()
        try persistence.saveMeasurement(value)
        try reload()
    }

    func deleteMeasurement(id: UUID) throws {
        try persistence.deleteMeasurement(id: id)
        try reload()
    }

    func saveFamilyProfile(babyID: UUID, memberID: String, name: String, role: ParentRole) throws {
        let canEditMember = family?.members.first { $0.id == memberID }?.canEdit == true
        guard selectedID == babyID, canEditMember || localParent?.id == memberID,
              var latest = try persistence.babies().first(where: { $0.id == babyID })
        else {
            throw ParentProfileError.memberUnavailable
        }
        let profile = ParentProfile(name: name, role: role)
        guard !profile.name.isEmpty else { throw ParentProfileError.emptyName }
        latest.parentProfiles[memberID] = profile
        try persistence.saveBaby(latest)
        try reload()
    }

    #if DEBUG
        /// Uses only the isolated UI-testing store; no iCloud connection or real identities.
        private func prepareFamilyFixture() throws {
            guard let sharedStore = persistence.sharedStore else { throw Persistence.Failure.missingStore }
            let existing = try persistence.babies().contains { baby in
                try persistence.babyObject(id: baby.id)?.objectID.persistentStore == sharedStore
            }
            if !existing {
                let baby = Baby(name: "Семейный малыш")
                let context = persistence.container.viewContext
                let object = NSEntityDescription.insertNewObject(forEntityName: "BabyRecord", into: context)
                context.assign(object, to: sharedStore)
                object.setValue(baby.id, forKey: "id")
                object.setValue(baby.name, forKey: "name")
                object.setValue(baby.birthDate, forKey: "birthDate")
                try object.setValue(JSONEncoder().encode(baby), forKey: "payload")
                try context.save()
            }
            if ProcessInfo.processInfo.arguments.contains("--redundant-fixture"),
               let starter = try persistence.babies().first(where: { $0.name == "Малыш" }),
               try persistence.events(babyID: starter.id).isEmpty
            {
                let date = Date().addingTimeInterval(-3600)
                try persistence.saveEvent(CareEvent(babyID: starter.id, kind: .diaper, start: date,
                                                    end: date, note: "Запись до семьи"))
            }
            if ProcessInfo.processInfo.arguments.contains("--redundant-fixture"),
               let shared = try persistence.babies().first(where: { baby in
                   try persistence.babyObject(id: baby.id)?.objectID.persistentStore == sharedStore
               }), try persistence.events(babyID: shared.id).isEmpty
            {
                let date = Date().addingTimeInterval(-1800)
                try persistence.saveEvent(CareEvent(babyID: shared.id, kind: .bottle, start: date,
                                                    end: date, note: "Семейная запись"))
            }
            testingFamily = FamilySnapshot(isOwner: false, members: [
                FamilyMember(id: "owner", name: "Алексей", role: "Папа",
                             status: "В семье", isCurrentUser: false, isOwner: true),
                FamilyMember(id: "participant-1", name: "Анна", role: "Мама", status: "В семье", isCurrentUser: true),
            ])
        }
    #endif

    private func updateVisibleBabiesAndSelection() throws {
        let sharedStore = persistence.sharedStore
        let sharedIDs = try Set(babies.compactMap { baby -> UUID? in
            guard let sharedStore, let object = try persistence.babyObject(id: baby.id),
                  object.objectID.persistentStore == sharedStore else { return nil }
            return baby.id
        })
        var visible: [Baby] = []
        var redundant: [Baby] = []
        for baby in babies {
            let hasMeasurements = try !persistence.measurements(babyID: baby.id).isEmpty
            let hasPhotos = try !persistence.photos(babyID: baby.id).isEmpty
            let isDefaultCandidate = !sharedIDs.isEmpty && !sharedIDs.contains(baby.id) && baby
                .name == "Малыш" && !hasMeasurements && !hasPhotos
            let family: FamilySnapshot?
            do {
                family = isDefaultCandidate ? try persistence.familySnapshot(babyID: baby.id) : nil
            } catch {
                // Unavailable sharing metadata must never authorize deletion.
                visible.append(baby)
                continue
            }
            if !hasMeasurements, !hasPhotos, Self.isPreSharedDefault(baby, isShared: sharedIDs.contains(baby.id),
                                                                     hasSharedDiary: !sharedIDs.isEmpty, family: family)
            {
                redundant.append(baby)
            } else {
                visible.append(baby)
            }
        }
        visibleBabies = visible
        redundantBabies = redundant
        if !visibleBabies.contains(where: { $0.id == selectedID }) {
            selectedID = visibleBabies.first(where: { sharedIDs.contains($0.id) })?.id ?? visibleBabies.first?.id
        }
        if let selectedID {
            UserDefaults.standard.set(selectedID.uuidString, forKey: selectionPreferenceKey)
        }
    }

    var redundantEventCount: Int {
        get throws {
            try redundantBabies.reduce(0) { try $0 + persistence.events(babyID: $1.id).count }
        }
    }

    func removeRedundantDiaries() throws {
        // Re-read profiles, sharing metadata and records after the confirmation.
        // If the shared diary vanished or another parent accepted, nothing is removed.
        try reload()
        let ids = Set(redundantBabies.map(\.id))
        guard !ids.isEmpty else { return }
        try persistence.deleteBabyAndEvents(ids: ids)
        try reload()
    }

    enum DiaryRemoval {
        case one(UUID, invited: Bool)
        case all
    }

    func removeDiaries(_ removal: DiaryRemoval) async throws {
        guard canChangeCloudMode,
              persistence.cloudStartupError == nil, !persistence.cloudEnabled || cloudSharingReady
        else {
            throw Persistence.Failure.diaryChanged
        }
        diaryRemovalInProgress = true
        defer {
            diaryRemovalInProgress = false
            perform { try reload() }
            if cloudRequested != persistence.cloudEnabled {
                scheduleCloudSwitch()
            }
        }
        switch removal {
        case let .one(id, invited):
            try await persistence.removeDiary(id: id, invited: invited)
        case .all:
            try await persistence.resetDiaries()
            cancelInvitation()
        }
    }

    static func isPreSharedDefault(_ baby: Baby, isShared: Bool, hasSharedDiary: Bool,
                                   family: FamilySnapshot?) -> Bool
    {
        guard hasSharedDiary, !isShared, baby.name == "Малыш", !baby.birthDateConfirmed,
              !baby.birthMeasurementsCompleted, baby.explicitlyCreated != true,
              baby.parentProfiles.isEmpty else { return false }
        let hasAcceptedOtherParent = family?.members.contains {
            !$0.isOwner && !$0.isCurrentUser && $0.status == "В семье"
        } ?? false
        return !hasAcceptedOtherParent
    }

    private func importedDiaryForInvitation() throws -> UUID? {
        guard persistence.cloudEnabled, let invitation, let sharedStore = persistence.sharedStore else { return nil }
        let acceptedShareID = invitation.metadata.share.recordID
        var candidates: [NSManagedObjectID: UUID] = [:]
        for baby in babies {
            if let object = try persistence.babyObject(id: baby.id), object.objectID.persistentStore == sharedStore {
                candidates[object.objectID] = baby.id
            }
        }
        guard !candidates.isEmpty,
              let shares = try? persistence.container.fetchShares(matching: Array(candidates.keys)),
              let objectID = shares.first(where: { $0.value.recordID == acceptedShareID })?.key,
              let babyID = candidates[objectID] else { return nil }
        return babyID
    }

    func select(_ id: UUID) {
        perform { try selectAndReload(id) }
    }

    func selectAndReload(_ id: UUID) throws {
        guard !diaryRemovalInProgress else { throw ActivityActionFailure.unavailable }
        let previousID = selectedID
        let previousPreference = UserDefaults.standard.object(forKey: selectionPreferenceKey)
        let previousBabies = babies
        let previousVisibleBabies = visibleBabies
        let previousRedundantBabies = redundantBabies
        let previousEvents = events
        let previousMeasurements = measurements
        let previousFamily = family
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: selectionPreferenceKey)
        do {
            try reload()
        } catch {
            selectedID = previousID
            UserDefaults.standard.set(previousPreference, forKey: selectionPreferenceKey)
            babies = previousBabies
            visibleBabies = previousVisibleBabies
            redundantBabies = previousRedundantBabies
            events = previousEvents
            measurements = previousMeasurements
            family = previousFamily
            throw error
        }
    }

    func save(_ event: CareEvent) throws {
        var normalized = event
        if normalized.kind == .bottle || normalized.kind == .diaper {
            normalized.end = normalized.start
        }
        try normalized.validate()
        let existing = try persistence.events(babyID: normalized.babyID).first { $0.id == normalized.id }
        let author = try? persistence.currentEventAuthor(babyID: normalized.babyID)
        let now = Date()
        if let existing {
            normalized.createdAt = existing.createdAt
            normalized.createdBy = existing.createdBy
            normalized.lastEditedBy = author
        } else {
            normalized.createdAt = now
            normalized.createdBy = author
            normalized.lastEditedBy = nil
        }
        normalized.modifiedAt = now
        try persistence.saveEvent(normalized)
        try reload()
    }

    func authorLabel(for author: EventAuthor?, babyID: UUID) -> String {
        guard let author else { return "Автор не указан" }
        let profile = babies.first { $0.id == babyID }?.parentProfiles[author.id]
        let name = (profile?.name ?? author.nameSnapshot ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let role = profile?.role ?? author.role
        if !name.isEmpty, let role {
            return "\(name) · \(role.label)"
        }
        if !name.isEmpty {
            return name
        }
        return role?.label ?? "Родитель"
    }

    func eventAuthorLabel(for event: CareEvent) -> String? {
        event.createdBy.map { authorLabel(for: $0, babyID: event.babyID) }
    }

    func delete(_ event: CareEvent) throws {
        try persistence.deleteEvent(id: event.id)
        try reload()
    }

    func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    func start(_ kind: EventKind, side: BreastSide = .left) {
        guard let baby else { return }
        guard !active.contains(where: { $0.kind == kind }) else {
            errorMessage = "Этот таймер уже запущен. Завершите его на карточке выше."
            return
        }
        perform { try save(CareEvent(babyID: baby.id, kind: kind, side: side)) }
    }

    func diaper(_ type: DiaperType) {
        guard let baby else { return }
        let now = Date()
        perform { try save(CareEvent(babyID: baby.id, kind: .diaper, start: now, end: now, diaperType: type)) }
    }

    func finish(_ event: CareEvent) {
        perform { try finish(eventID: event.id, babyID: event.babyID) }
    }

    func switchSide(_ event: CareEvent) {
        let desiredSide: BreastSide = event.side == .left ? .right : .left
        perform { try switchSide(eventID: event.id, babyID: event.babyID, to: desiredSide) }
    }

    enum ActivityActionFailure: LocalizedError {
        case unavailable, wrongKind

        var errorDescription: String? {
            switch self {
            case .unavailable: "Запись больше недоступна. Откройте дневник и проверьте синхронизацию."
            case .wrongKind: "Это действие недоступно для выбранной записи."
            }
        }
    }

    private func latestActivityEvent(eventID: UUID, babyID: UUID) throws -> CareEvent {
        guard ready, !diaryRemovalInProgress else { throw ActivityActionFailure.unavailable }
        // Reconcile removals and remote edits before acting on a potentially stale card.
        try reload()
        guard try persistence.babyObject(id: babyID) != nil,
              let event = try persistence.events(babyID: babyID).first(where: { $0.id == eventID })
        else { throw ActivityActionFailure.unavailable }
        guard event.kind == .breast || event.kind == .sleep else { throw ActivityActionFailure.wrongKind }
        return event
    }

    /// Read the requested diary again: widget selection and cached event state are not authority.
    func recordWidgetAction(_ action: WidgetCareAction, babyID: UUID, commandID: UUID,
                            at date: Date = Date(), reminderToken: String? = nil) throws
    {
        widgetSnapshotBatchDepth += 1
        defer { finishWidgetSnapshotBatch() }
        guard ready, !diaryRemovalInProgress else { throw ActivityActionFailure.unavailable }
        try reload()
        guard try persistence.babyObject(id: babyID) != nil else { throw ActivityActionFailure.unavailable }
        if let reminderToken {
            guard selectedID == babyID, feedingReminders.deliveryChannel == .liveActivity,
                  feedingReminders.canOpen(token: reminderToken, babyID: babyID) else { return }
        }
        let latest = try persistence.events(babyID: babyID)
        let receiptKey = "widgetCommands.\(babyID.uuidString)"
        let receipts = UserDefaults.standard.stringArray(forKey: receiptKey) ?? []
        guard !receipts.contains(commandID.uuidString),
              !latest.contains(where: { $0.id == commandID }) else { return }
        let kind: EventKind = switch action {
        case .startBreastLeft, .startBreastRight: .breast
        case .startSleep: .sleep
        case .wetDiaper, .dirtyDiaper: .diaper
        }
        // A stale start cannot create a second timer or switch a newer timer's side.
        if kind != .diaper, latest.contains(where: { $0.kind == kind && $0.end == nil }) {
            UserDefaults.standard.set(Array(([commandID.uuidString] + receipts).prefix(512)), forKey: receiptKey)
            return
        }
        let event = CareEvent(id: commandID, babyID: babyID, kind: kind, start: date,
                              end: kind == .diaper ? date : nil,
                              side: action == .startBreastRight ? .right : .left,
                              diaperType: action == .dirtyDiaper ? .dirty : .wet)
        try save(event)
        // Record success only after Core Data save; projection publication follows at batch exit.
        UserDefaults.standard.set(Array(([commandID.uuidString] + receipts).prefix(512)), forKey: receiptKey)
    }

    func finish(eventID: UUID, babyID: UUID, at date: Date = Date()) throws {
        widgetSnapshotBatchDepth += 1
        defer { finishWidgetSnapshotBatch() }
        var event = try latestActivityEvent(eventID: eventID, babyID: babyID)
        guard event.end == nil else {
            try reload()
            return
        }
        event.finish(at: date)
        try save(event)
    }

    func switchSide(eventID: UUID, babyID: UUID, to side: BreastSide, at date: Date = Date()) throws {
        widgetSnapshotBatchDepth += 1
        defer { finishWidgetSnapshotBatch() }
        var event = try latestActivityEvent(eventID: eventID, babyID: babyID)
        guard event.kind == .breast else { throw ActivityActionFailure.wrongKind }
        guard event.end == nil, event.side != side else {
            try reload()
            return
        }
        event.switchSide(at: date)
        try save(event)
    }

    func checkAccount() async {
        guard persistence.isLoaded, persistence.cloudEnabled, !cloudSwitchInProgress,
              cloudAccountCheckID == nil else { return }
        let id = UUID()
        cloudAccountCheckID = id
        let result: Result<CKAccountStatus, Error>
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                result = .success(.noAccount)
            } else {
                result = await fetchCloudAccountStatus()
            }
        #else
            result = await fetchCloudAccountStatus()
        #endif
        guard cloudAccountCheckID == id else { return }
        cloudAccountCheckID = nil
        switch result {
        case let .success(status):
            cloudAccountAvailable = status == .available
            cloudAccountFailure = cloudAccountAvailable ? nil : "Войдите в iCloud в настройках iPhone."
        case let .failure(error):
            cloudAccountAvailable = false
            cloudAccountFailure = CloudFailure.message(for: error)
        }
        updateCloudStatus()
        await resumeInvitation()
    }

    private func fetchCloudAccountStatus() async -> Result<CKAccountStatus, Error> {
        do {
            let status = try await CKContainer(identifier: Persistence.containerIdentifier).accountStatus()
            return .success(status)
        } catch {
            return .failure(error)
        }
    }

    func retryRestoration() async {
        if let failedCloudTarget {
            cloudRequested = failedCloudTarget
            scheduleCloudSwitch(reopen: true)
        } else if !persistence.cloudEnabled || cloudSetup.failure(expected: expectedCloudStores) != nil
            || cloudImport.failure(expected: expectedCloudStores) != nil
        {
            cloudRequested = true
            scheduleCloudSwitch(reopen: true)
        } else {
            await checkAccount()
            perform { try reload() }
        }
    }

    func invite() async {
        guard canChangeCloudMode else { return }
        guard cloudSharingReady else {
            errorMessage = syncStatus
            return
        }
        guard let baby else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        do {
            pendingShare = try await persistence.share(babyID: baby.id)
            if inviteSuggestionID == baby.id {
                dismissInviteSuggestion()
            }
        } catch {
            errorMessage = CloudFailure.message(for: error)
        }
    }

    private static let invalidInvitationMessage = "Не удалось открыть приглашение. Попросите другого родителя отправить его ещё раз."

    func receiveInvitation(_ metadata: CKShare.Metadata) {
        if acceptingInvitation, invitation?.metadata.share.recordID == metadata.share.recordID {
            return
        }
        guard !diaryRemovalInProgress, !acceptingInvitation else {
            errorMessage = "Дождитесь завершения операции и откройте приглашение ещё раз."
            return
        }
        guard metadata.containerIdentifier == Persistence.containerIdentifier else {
            invitationFailure = Self.invalidInvitationMessage
            return
        }
        do {
            if invitation?.metadata.share.recordID != metadata.share.recordID {
                try saveInvitation(PendingFamilyInvitation(metadata: metadata))
            }
            invitationFailure = nil
            requestCloud(true)
        } catch {
            invitationFailure = Self.invalidInvitationMessage
        }
    }

    func resumeInvitation() async {
        guard ready, !diaryRemovalInProgress, !acceptingInvitation, let invitation,
              cloudSharingReady else { return }
        acceptingInvitation = true
        invitationFailure = nil
        defer { acceptingInvitation = false }
        do {
            try reload()
            guard self.invitation != nil, !invitation.accepted else { return }
            if !persistence.containsShare(invitation.metadata.share.recordID) {
                try await persistence.accept(metadata: invitation.metadata)
            }
            guard self.invitation?.metadata.share.recordID == invitation.metadata.share.recordID else { return }
            var accepted = invitation
            accepted.accepted = true
            try saveInvitation(accepted)
            // Acceptance can finish before the share and its diary are visible locally.
            try reload()
        } catch {
            if self.invitation != nil {
                invitationFailure = CloudFailure.message(for: error)
            }
        }
    }

    func cancelInvitation() {
        invitation = nil
        invitationFailure = nil
        if storesPreferences {
            UserDefaults.standard.removeObject(forKey: PendingFamilyInvitation.preferenceKey)
        }
    }

    private func saveInvitation(_ value: PendingFamilyInvitation) throws {
        if storesPreferences {
            try UserDefaults.standard.set(
                value.archive(),
                forKey: PendingFamilyInvitation.preferenceKey
            )
        }
        invitation = value
    }
}

/// Keeps injected stores and UI fixtures independent of the app's notification center.
@MainActor
final class IsolatedFeedingReminderScheduler: FeedingReminderScheduling {
    private let permission: FeedingReminderAuthorization
    let liveActivitiesEnabled: Bool
    private(set) var pending: FeedingReminderRequest?
    private(set) var activityRequest: FeedingReminderRequest?
    private var activityShown = false

    init(authorization: FeedingReminderAuthorization, liveActivitiesEnabled: Bool = false) {
        permission = authorization
        self.liveActivitiesEnabled = liveActivitiesEnabled
    }

    func liveActivities() -> [FeedingReminderLiveActivity] {
        guard let request = activityRequest else { return [] }
        return [.init(id: request.token, token: request.token, state: activityShown ? .shown : .pending)]
    }

    func scheduleLiveActivity(_ request: FeedingReminderRequest) throws {
        activityRequest = request
        activityShown = false
    }

    func endLiveActivities(except activityID: String?) async {
        if activityRequest?.token != activityID {
            activityRequest = nil
            activityShown = false
        }
    }

    func showScheduledActivity() {
        activityShown = true
    }

    func authorization() async -> FeedingReminderAuthorization {
        permission
    }

    func requestAuthorization() async throws {}
    func notificationState() async -> FeedingReminderNotificationState {
        .init(pendingToken: pending?.token)
    }

    func schedule(_ request: FeedingReminderRequest) async throws {
        pending = request
    }

    func removePending() {
        pending = nil
    }

    func removeDelivered() {}
}
