import Foundation
import Observation
import WatchConnectivity
import WatchKit
import WidgetKit

@MainActor
@Observable
final class WatchStore: NSObject, WCSessionDelegate {
    static let shared = WatchStore()

    private var state = WatchLocalState()
    private var storageMessage: String?
    private var actionRejection: WatchRejection?
    private(set) var isReachable = false
    private(set) var isCompanionInstalled: Bool?

    @ObservationIgnored private let fileURL = WatchLocalState.fileURL
    @ObservationIgnored private let session = WCSession.default
    @ObservationIgnored private var needsRead = true
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var sendingLive = false
    @ObservationIgnored private var backgroundTasks: [WKWatchConnectivityRefreshBackgroundTask] = []
    @ObservationIgnored private var contentObservation: NSKeyValueObservation?

    var selectedDiary: WatchDiary? {
        state.selectedDiary
    }

    var diaries: [WatchDiary] {
        state.diaries
    }

    var selectedID: UUID? {
        state.selectedID
    }

    var pendingCount: Int {
        state.pending.count
    }

    var hasSnapshot: Bool {
        state.snapshot != nil
    }

    var snapshotDate: Date? {
        state.snapshot?.generatedAt
    }

    var statusMessage: String? {
        storageMessage ?? (actionRejection ?? state.rejection)?.errorDescription
    }

    override init() {
        super.init()
        loadState()
        session.delegate = self
        contentObservation = session.observe(\.hasContentPending) { [weak self] _, _ in
            DispatchQueue.main.async { self?.completeBackgroundTasksIfReady() }
        }
        session.activate()
    }

    func select(_ id: UUID) {
        guard loadState() else { return }
        var updated = state
        updated.select(id)
        if persist(updated) {
            actionRejection = nil
        }
    }

    @discardableResult
    func record(_ action: WatchAction, eventID: UUID? = nil) -> Bool {
        guard loadState(), let diary = selectedDiary else { return false }
        let operationID = (action.createsEvent ? eventID : nil) ?? UUID()
        let operation = WatchOperation(id: operationID, babyID: diary.id, eventID: eventID, action: action)
        if state.pending.contains(where: { $0.id == operationID }) {
            return true
        }
        var updated = state
        do {
            try updated.enqueue(operation)
        } catch let rejection as WatchRejection {
            actionRejection = rejection
            return false
        } catch {
            actionRejection = .invalidOperation
            return false
        }
        guard persist(updated) else { return false }
        actionRejection = nil
        pump()
        return true
    }

    func refresh() {
        loadState()
        guard session.activationState == .activated else {
            session.activate()
            return
        }
        updateConnection()
        receive(WatchPayload(session.receivedApplicationContext))
        requestSnapshot()
        restartRetriesIfExhausted()
        pump()
    }

    @discardableResult
    private func loadState() -> Bool {
        guard needsRead else { return true }
        do {
            guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
            state = try WatchLocalState.read(from: fileURL)
            needsRead = false
            storageMessage = nil
            return true
        } catch {
            storageMessage = "Не удалось прочитать данные на часах."
            return false
        }
    }

    @discardableResult
    private func persist(_ updated: WatchLocalState) -> Bool {
        if updated == state {
            return true
        }
        do {
            guard let fileURL else { throw CocoaError(.fileNoSuchFile) }
            try updated.write(to: fileURL)
            let previous = state.selectedDiary
            let next = updated.selectedDiary
            let now = Date()
            let wasStale = state.snapshot.map { $0.staleAt <= now }
            let isStale = updated.snapshot.map { $0.staleAt <= now }
            let active = next?.active(.breast) ?? next?.active(.sleep)
            let timerWasLocal = state.pending.contains { $0.action.createsEvent && $0.eventID == active?.id }
            let timerIsLocal = updated.pending.contains { $0.action.createsEvent && $0.eventID == active?.id }
            state = updated
            storageMessage = nil
            if wasStale != isStale || timerWasLocal != timerIsLocal
                || previous?.id != next?.id || previous?.name != next?.name
                || previous?.latestCompletedFeeding != next?.latestCompletedFeeding
                || previous?.active(.breast) != next?.active(.breast)
                || previous?.active(.sleep) != next?.active(.sleep)
            {
                WidgetCenter.shared.reloadTimelines(ofKind: "WatchDiaryWidget")
            }
            return true
        } catch {
            storageMessage = "Не удалось сохранить данные на часах."
            return false
        }
    }

    private func receive(_ payload: WatchPayload) {
        guard loadState() else { return }
        let head = state.pending.first?.id
        let previousSnapshot = state.snapshot
        var updated = state
        if let data = payload.receipt, let receipt = try? JSONDecoder().decode(WatchReceipt.self, from: data) {
            updated.receive(receipt)
        }
        if let data = payload.snapshot, let snapshot = try? JSONDecoder().decode(WatchSnapshot.self, from: data) {
            updated.receive(snapshot)
        }
        guard persist(updated) else { return }
        if head == state.pending.first?.id {
            if previousSnapshot != state.snapshot, attempt >= 4 {
                restartRetriesIfExhausted()
                pump()
            }
            return
        }
        if let head {
            for transfer in session.outstandingUserInfoTransfers
                where WatchPayload.operationID(in: transfer.userInfo) == head
            {
                transfer.cancel()
            }
        }
        cancelRetry()
        attempt = 0
        sendingLive = false
        actionRejection = nil
        pump()
    }

    private func requestSnapshot() {
        guard isReachable else { return }
        session.sendMessage([WatchWire.refresh: true], replyHandler: { [weak self] message in
            let payload = WatchPayload(message)
            DispatchQueue.main.async { self?.receive(payload) }
        }, errorHandler: nil)
    }

    private func pump() {
        guard session.activationState == .activated, session.isCompanionAppInstalled,
              let operation = state.pending.first, attempt < 4, retry == nil, !sendingLive,
              let data = try? JSONEncoder().encode(operation)
        else { return }
        let id = operation.id
        let alreadyQueued = session.outstandingUserInfoTransfers.contains { transfer in
            WatchPayload.operationID(in: transfer.userInfo) == id
        }
        guard !alreadyQueued || isReachable else { return }
        attempt += 1
        let message = [WatchWire.operation: data]
        // Queue before the live attempt so delivery can continue if watchOS suspends this process.
        if !alreadyQueued {
            session.transferUserInfo(message)
        }
        if isReachable {
            sendingLive = true
            session.sendMessage(message, replyHandler: { [weak self] reply in
                let payload = WatchPayload(reply)
                DispatchQueue.main.async { self?.finishLive(id, payload: payload) }
            }, errorHandler: { [weak self] _ in
                DispatchQueue.main.async { self?.finishLive(id, payload: nil) }
            })
        }
    }

    private func finishLive(_ id: UUID, payload: WatchPayload?) {
        if let payload {
            receive(payload)
        }
        if state.pending.first?.id == id {
            sendingLive = false
        }
    }

    private func scheduleRetry(for id: UUID, delay: Duration) {
        cancelRetry()
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, state.pending.first?.id == id else { return }
            retry = nil
            sendingLive = false
            pump()
        }
    }

    private func cancelRetry() {
        retry?.cancel()
        retry = nil
    }

    private func restartRetriesIfExhausted() {
        if attempt >= 4 {
            attempt = 0
        }
    }

    private func updateConnection() {
        let active = session.activationState == .activated
        isReachable = active && session.isReachable
        isCompanionInstalled = active ? session.isCompanionAppInstalled : nil
    }

    func handle(_ tasks: Set<WKRefreshBackgroundTask>) {
        for task in tasks {
            if let task = task as? WKWatchConnectivityRefreshBackgroundTask {
                backgroundTasks.append(task)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
        if session.activationState == .activated {
            completeBackgroundTasksIfReady()
        } else {
            session.activate()
        }
    }

    private func completeBackgroundTasksIfReady(activationFailed: Bool = false) {
        guard activationFailed || (session.activationState == .activated && !session.hasContentPending) else {
            return
        }
        let tasks = backgroundTasks
        backgroundTasks.removeAll()
        for task in tasks {
            task.setTaskCompletedWithSnapshot(false)
        }
    }

    nonisolated func session(
        _: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error _: (any Error)?
    ) {
        let succeeded = activationState == .activated
        DispatchQueue.main.async {
            if succeeded {
                self.refresh()
            } else {
                self.updateConnection()
            }
            self.completeBackgroundTasksIfReady(activationFailed: !succeeded)
        }
    }

    nonisolated func sessionCompanionAppInstalledDidChange(_: WCSession) {
        DispatchQueue.main.async { self.refresh() }
    }

    nonisolated func sessionReachabilityDidChange(_: WCSession) {
        DispatchQueue.main.async {
            self.updateConnection()
            if self.isReachable {
                self.requestSnapshot()
                self.restartRetriesIfExhausted()
                self.pump()
            }
        }
    }

    nonisolated func session(_: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let payload = WatchPayload(applicationContext)
        DispatchQueue.main.async {
            self.receive(payload)
            self.completeBackgroundTasksIfReady()
        }
    }

    nonisolated func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let payload = WatchPayload(userInfo)
        DispatchQueue.main.async {
            self.receive(payload)
            self.completeBackgroundTasksIfReady()
        }
    }

    nonisolated func session(
        _: WCSession,
        didFinish userInfoTransfer: WCSessionUserInfoTransfer,
        error: (any Error)?
    ) {
        guard let id = WatchPayload.operationID(in: userInfoTransfer.userInfo) else { return }
        let succeeded = error == nil
        DispatchQueue.main.async {
            guard self.state.pending.first?.id == id, self.attempt < 4 else { return }
            self.scheduleRetry(for: id, delay: .seconds(succeeded ? 20 : 5 * max(1, self.attempt)))
        }
    }
}

private struct WatchPayload: Sendable {
    let snapshot: Data?
    let receipt: Data?

    init(_ message: [String: Any]) {
        snapshot = message[WatchWire.snapshot] as? Data
        receipt = message[WatchWire.receipt] as? Data
    }

    static func operationID(in message: [String: Any]) -> UUID? {
        guard let data = message[WatchWire.operation] as? Data else { return nil }
        return (try? JSONDecoder().decode(WatchOperation.self, from: data))?.id
    }
}

final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        WatchStore.shared.handle(backgroundTasks)
    }
}
