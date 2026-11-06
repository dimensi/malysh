import Foundation
import WatchConnectivity

@MainActor
final class WatchPhoneBridge: NSObject, WCSessionDelegate {
    private let runtime: CareActivityRuntime
    private let sync: WatchPhoneSync
    private let session: WCSession?
    private var publishedRevision: UInt64?
    private var publishing: Task<Void, Never>?

    init(runtime: CareActivityRuntime) {
        self.runtime = runtime
        sync = WatchPhoneSync(store: runtime.store)
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    func activate() {
        guard let session else { return }
        runtime.store.watchSnapshotDidChange = { [weak self] in self?.schedulePublish() }
        session.delegate = self
        session.activate()
    }

    private var activeSession: WCSession? {
        guard let session, session.activationState == .activated, session.isPaired,
              session.isWatchAppInstalled else { return nil }
        return session
    }

    private func schedulePublish() {
        guard activeSession != nil, publishing == nil else { return }
        publishing = Task { @MainActor [weak self] in
            guard let self else { return }
            await runtime.ensureReady(checkCloudAccount: false)
            publishing = nil
            if let snapshot = try? sync.snapshot() {
                publish(snapshot)
            }
        }
    }

    private func publish(_ snapshot: WatchSnapshot) {
        guard let session = activeSession, publishedRevision != snapshot.revision else { return }
        do {
            try session.updateApplicationContext([WatchWire.snapshot: JSONEncoder().encode(snapshot)])
            publishedRevision = snapshot.revision
        } catch {
            // The next activation, snapshot request or store reload retries.
        }
    }

    private func handle(operation data: Data?, refresh: Bool) async -> [String: Any] {
        await runtime.ensureReady(checkCloudAccount: false)
        do {
            if let data {
                let operation = try JSONDecoder().decode(WatchOperation.self, from: data)
                let receipt = try sync.receive(operation)
                publish(receipt.snapshot)
                return try [WatchWire.receipt: JSONEncoder().encode(receipt)]
            }
            if refresh {
                let snapshot = try sync.snapshot(refresh: true)
                publish(snapshot)
                return try [WatchWire.snapshot: JSONEncoder().encode(snapshot)]
            }
        } catch {
            // An empty reply asks the watch to retain and retry its durable head.
        }
        return [:]
    }

    private func queueReply(_ reply: [String: Any], operationData: Data?) {
        guard let session = activeSession, !reply.isEmpty else { return }
        if let operationData,
           let operation = try? JSONDecoder().decode(WatchOperation.self, from: operationData),
           session.outstandingUserInfoTransfers.contains(where: { transfer in
               guard let data = transfer.userInfo[WatchWire.receipt] as? Data,
                     let receipt = try? JSONDecoder().decode(WatchReceipt.self, from: data) else { return false }
               return receipt.operationID == operation.id
           })
        {
            return
        }
        session.transferUserInfo(reply)
    }

    nonisolated func session(
        _: WCSession,
        activationDidCompleteWith _: WCSessionActivationState,
        error _: (any Error)?
    ) {
        Task { @MainActor in
            publishedRevision = nil
            schedulePublish()
        }
    }

    nonisolated func sessionDidBecomeInactive(_: WCSession) {}

    nonisolated func sessionDidDeactivate(_: WCSession) {
        Task { @MainActor in
            publishedRevision = nil
            session?.activate()
        }
    }

    nonisolated func sessionWatchStateDidChange(_: WCSession) {
        Task { @MainActor in
            publishedRevision = nil
            schedulePublish()
        }
    }

    nonisolated func session(_: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void)
    {
        let data = message[WatchWire.operation] as? Data
        let refresh = message[WatchWire.refresh] as? Bool == true
        let reply = Reply(handler: replyHandler)
        Task { @MainActor in
            await reply.handler(handle(operation: data, refresh: refresh))
        }
    }

    nonisolated func session(_: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let data = userInfo[WatchWire.operation] as? Data
        let refresh = userInfo[WatchWire.refresh] as? Bool == true
        Task { @MainActor in
            let response = await handle(operation: data, refresh: refresh)
            if data != nil {
                queueReply(response, operationData: data)
            }
        }
    }

    /// Apple's reply closure is callable from any queue and invoked once.
    private struct Reply: @unchecked Sendable {
        let handler: ([String: Any]) -> Void
    }
}
