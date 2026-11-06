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
    private var acceptingShares = 0
    private(set) var diaryRemovalInProgress = false
    private var cloudSetup = CloudSetupState()
    private var cloudAccountAvailable = false
    var pendingShare: CKShare?
    private var pendingAcceptedShareID: CKRecord.ID?
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

    private var expectedCloudStores: Set<String> {
        Set(persistence.container.persistentStoreCoordinator.persistentStores.map(\.identifier))
    }

    var cloudSharingReady: Bool {
        persistence.cloudEnabled && cloudAccountAvailable && cloudSetup.isReady(expected: expectedCloudStores)
    }

    private func updateCloudStatus() {
        if let error = persistence.cloudStartupError {
            syncStatus = CloudFailure.message(for: error)
        } else if !persistence.cloudEnabled {
            syncStatus = "Записи сохраняются на этом iPhone"
        } else if let failure = cloudSetup.failure(expected: expectedCloudStores) {
            syncStatus = failure
        } else if !cloudAccountAvailable {
            syncStatus = "Проверяем доступ к iCloud · записи доступны локально"
        } else if !cloudSharingReady {
            syncStatus = "Подготавливаем iCloud · записи доступны локально"
        } else {
            syncStatus = "iCloud готов · доставка изменений может занять время"
        }
    }

    func recordCloudSetup(identifier: String, error: Error?) {
        cloudSetup.record(identifier: identifier, error: error)
        updateCloudStatus()
    }

    func handleCloudEvent(_ event: NSPersistentCloudKitContainer.Event) {
        guard persistence.cloudEnabled else { return }
        if event.type == .setup {
            if let error = event.error {
                recordCloudSetup(identifier: event.storeIdentifier, error: error)
            } else if event.endDate != nil, event.succeeded {
                recordCloudSetup(identifier: event.storeIdentifier, error: nil)
            } else if event.endDate == nil {
                cloudSetup.begin(identifier: event.storeIdentifier)
                updateCloudStatus()
            } else {
                recordCloudSetup(
                    identifier: event.storeIdentifier,
                    error: NSError(domain: CKErrorDomain, code: CKError.internalError.rawValue)
                )
            }
        } else if let error = event.error {
            syncStatus = CloudFailure.message(for: error)
        } else if event.endDate != nil, event.succeeded {
            if cloudSharingReady {
                syncStatus = "Последняя синхронизация: \((event.endDate ?? Date()).formatted(date: .omitted, time: .shortened))"
            }
            if ready {
                perform { try reload() }
            }
        }
    }

    init(persistence injectedPersistence: Persistence? = nil,
         activityCoordinator: (any CareActivityCoordinating)? = nil,
         widgetSnapshotStore: WidgetSnapshotStore? = nil)
    {
        self.activityCoordinator = activityCoordinator
        let arguments = ProcessInfo.processInfo.arguments
        var testing = arguments.contains("--ui-testing")
        var widgetTesting = false
        #if DEBUG
            // App intents can cold-launch without the UI runner's launch arguments.
            // Retain only the explicit isolated widget-test session, never real data.
            let widgetTestingKey = "debug.widgetTestingSession"
            if injectedPersistence == nil {
                if arguments.contains("--end-widget-testing") || (testing && !arguments.contains("--widget-testing")) {
                    UserDefaults.standard.removeObject(forKey: widgetTestingKey)
                } else if testing && arguments.contains("--widget-testing") {
                    UserDefaults.standard.set(true, forKey: widgetTestingKey)
                }
                widgetTesting = UserDefaults.standard.bool(forKey: widgetTestingKey)
                UserDefaults(suiteName: WidgetSnapshotStore.appGroupIdentifier)?.set(
                    widgetTesting,
                    forKey: widgetTestingKey
                )
                testing = testing || widgetTesting
            }
        #endif
        selectionPreferenceKey = testing ? "debug.selectedBabyUITesting" : "selectedBaby"
        let publishesWidgets = injectedPersistence == nil && (!testing || widgetTesting)
        reloadsWidgetTimelines = publishesWidgets
        self.widgetSnapshotStore = widgetSnapshotStore ?? (publishesWidgets
            ? WidgetSnapshotStore() : WidgetSnapshotStore(directory: nil))
        if let injectedPersistence {
            persistence = injectedPersistence
            storedPhotoGallery = PhotoGalleryStore(
                persistence: injectedPersistence,
                directory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("PhotoWorkflowTests-" + UUID().uuidString)
            )
            observeWidgetCalendarChanges()
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
        persistence = Persistence(
            directory: directory,
            cloudEnabled: !testing && UserDefaults.standard.bool(forKey: "cloudEnabled")
        )
        observeWidgetCalendarChanges()
    }

    private func observeWidgetCalendarChanges() {
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
            babies = try persistence.babies()
            if babies.isEmpty {
                let baby = Baby(name: "Малыш")
                try persistence.saveBaby(baby)
                babies = [baby]
            }
            #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                   ProcessInfo.processInfo.arguments.contains("--family-fixture")
                {
                    try prepareFamilyFixture()
                }
            #endif
            let saved = UserDefaults.standard.string(forKey: selectionPreferenceKey).flatMap(UUID.init(uuidString:))
            selectedID = babies.first(where: { $0.id == saved })?.id
            try reload()
            ready = true
            if let cloudError = persistence.cloudStartupError {
                syncStatus = CloudFailure.message(for: cloudError)
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
        photoGallery.revision += 1
        Task { await photoGallery.saveReceivedIfEnabled() }
        babies = try persistence.babies()
        if babies.isEmpty {
            let starter = Baby(name: "Малыш")
            try persistence.saveBaby(starter)
            babies = [starter]
        }
        try updateVisibleBabiesAndSelection()
        let emptyRedundantIDs = try Set(redundantBabies
            .filter {
                try persistence.events(babyID: $0.id).isEmpty && persistence.measurements(babyID: $0.id)
                    .isEmpty && persistence.photos(babyID: $0.id).isEmpty
            }
            .map(\.id))
        if !emptyRedundantIDs.isEmpty {
            try persistence.deleteBabyAndEvents(ids: emptyRedundantIDs)
            babies = try persistence.babies()
            try updateVisibleBabiesAndSelection()
        }
        try selectAcceptedSharedBabyIfAvailable()
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
        refreshWidgetSnapshot()
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
                // Include empty starters so reload can remove them automatically.
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
        guard ready, !diaryRemovalInProgress, !cloudBusy, acceptingShares == 0,
              persistence.cloudStartupError == nil, !persistence.cloudEnabled || cloudSharingReady
        else {
            throw Persistence.Failure.diaryChanged
        }
        diaryRemovalInProgress = true
        defer {
            diaryRemovalInProgress = false
            perform { try reload() }
        }
        switch removal {
        case let .one(id, invited):
            try await persistence.removeDiary(id: id, invited: invited)
        case .all:
            try await persistence.resetDiaries()
            pendingAcceptedShareID = nil
        }
    }

    static func isPreSharedDefault(_ baby: Baby, isShared: Bool, hasSharedDiary: Bool,
                                   family: FamilySnapshot?) -> Bool
    {
        guard hasSharedDiary, !isShared, baby.name == "Малыш", !baby.birthDateConfirmed,
              !baby.birthMeasurementsCompleted, baby.parentProfiles.isEmpty else { return false }
        let hasAcceptedOtherParent = family?.members.contains {
            !$0.isOwner && !$0.isCurrentUser && $0.status == "В семье"
        } ?? false
        return !hasAcceptedOtherParent
    }

    private func selectAcceptedSharedBabyIfAvailable() throws {
        guard let acceptedShareID = pendingAcceptedShareID, let sharedStore = persistence.sharedStore else { return }
        var candidates: [NSManagedObjectID: UUID] = [:]
        for baby in babies {
            if let object = try persistence.babyObject(id: baby.id), object.objectID.persistentStore == sharedStore {
                candidates[object.objectID] = baby.id
            }
        }
        guard !candidates.isEmpty else { return }
        let shares = try persistence.container.fetchShares(matching: Array(candidates.keys))
        guard let objectID = shares.first(where: { $0.value.recordID == acceptedShareID })?.key,
              let babyID = candidates[objectID] else { return }
        selectedID = babyID
        UserDefaults.standard.set(babyID.uuidString, forKey: selectionPreferenceKey)
        pendingAcceptedShareID = nil
    }

    func select(_ id: UUID) {
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: selectionPreferenceKey)
        perform { try reload() }
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
                            at date: Date = Date()) throws
    {
        widgetSnapshotBatchDepth += 1
        defer { finishWidgetSnapshotBatch() }
        guard ready, !diaryRemovalInProgress else { throw ActivityActionFailure.unavailable }
        try reload()
        guard try persistence.babyObject(id: babyID) != nil else { throw ActivityActionFailure.unavailable }
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
        do {
            let status = try await CKContainer(identifier: Persistence.containerIdentifier).accountStatus()
            cloudAccountAvailable = status == .available
            if cloudAccountAvailable {
                updateCloudStatus()
            } else {
                syncStatus = "Войдите в iCloud в настройках iPhone. Записи доступны локально."
            }
        } catch {
            cloudAccountAvailable = false
            syncStatus = CloudFailure.message(for: error)
        }
    }

    func invite() async {
        guard !cloudBusy, !diaryRemovalInProgress else { return }
        guard cloudSharingReady else {
            errorMessage = syncStatus
            return
        }
        guard let baby else { return }
        cloudBusy = true
        defer { cloudBusy = false }
        do {
            pendingShare = try await persistence.share(babyID: baby.id)
        } catch {
            errorMessage = CloudFailure.message(for: error)
        }
    }

    func accept(_ metadata: CKShare.Metadata) async {
        guard !diaryRemovalInProgress else {
            errorMessage = "Дождитесь завершения операции и откройте приглашение ещё раз."
            return
        }
        acceptingShares += 1
        defer { acceptingShares -= 1 }
        do {
            if !ready {
                await load()
            }
            try await persistence.accept(metadata: metadata)
        } catch {
            pendingAcceptedShareID = nil
            errorMessage = CloudFailure.message(for: error)
            return
        }
        pendingAcceptedShareID = metadata.share.recordID
        // Acceptance can complete before Core Data imports the shared objects.
        // Keep the target through delayed imports and transient metadata lookup errors.
        perform { try reload() }
    }
}
