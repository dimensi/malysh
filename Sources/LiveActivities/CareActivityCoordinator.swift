@preconcurrency import ActivityKit
import Foundation

@MainActor
protocol CareActivityCoordinating: AnyObject {
    func reconcile(events: [CareEvent], babies: [Baby], allowStart: Bool)
    func flush() async
}

struct CareActivityInstance {
    enum Status { case active, ended, dismissed }
    let id: String
    let attributes: CareActivityAttributes
    let content: CareActivityAttributes.ContentState
    let status: Status
}

@MainActor
protocol CareActivityBackend: AnyObject {
    var enabled: Bool { get }
    var dismissedEventIDs: Set<UUID> { get }
    func instances() -> [CareActivityInstance]
    func request(attributes: CareActivityAttributes, content: CareActivityAttributes.ContentState) async throws
    func update(id: String, content: CareActivityAttributes.ContentState) async
    func end(id: String) async
    func finish(id: String, content: CareActivityAttributes.ContentState, dismissalDate: Date) async
}

/// Reconciles only committed persistence snapshots. A single worker rechecks the latest snapshot
/// after every suspension, so an obsolete request/update is corrected before flush returns.
@MainActor
final class CareActivityCoordinator: CareActivityCoordinating {
    private struct Desired {
        let attributes: CareActivityAttributes
        let content: CareActivityAttributes.ContentState
    }

    private let backend: any CareActivityBackend
    private var desired: [UUID: Desired] = [:]
    private var pendingFinalContent: [String: CareActivityAttributes.ContentState] = [:]
    private var allowStart = false
    private var revision = 0
    private var worker: Task<Void, Never>?

    init(backend: any CareActivityBackend = SystemCareActivityBackend()) {
        self.backend = backend
    }

    func reconcile(events: [CareEvent], babies: [Baby], allowStart: Bool) {
        let names = Dictionary(babies.map { ($0.id, $0.name) }, uniquingKeysWith: { _, latest in latest })
        desired = [:]
        for event in events where event.kind == .breast || event.kind == .sleep {
            guard let name = names[event.babyID] else { continue }
            desired[event.id] = Desired(
                attributes: CareActivityAttributes(eventID: event.id, babyID: event.babyID),
                content: .init(kind: event.kind, start: event.start,
                               side: event.kind == .breast ? event.side : nil,
                               babyName: String(String.UnicodeScalarView(name.unicodeScalars.prefix(120))),
                               end: event.end)
            )
        }
        self.allowStart = allowStart
        revision += 1
        if worker == nil {
            worker = Task { await self.drain() }
        }
    }

    func flush() async {
        while let worker {
            await worker.value
        }
    }

    private func drain() async {
        var attemptedRevision = -1
        var attemptedRequests = Set<UUID>()
        var attemptedUpdates = Set<String>()
        var attemptedFinishes = Set<String>()
        while true {
            if attemptedRevision != revision {
                attemptedRevision = revision
                attemptedRequests = []
                attemptedUpdates = []
                attemptedFinishes = []
            }
            let instances = backend.instances().sorted { $0.id < $1.id }
            let instanceIDs = Set(instances.map(\.id))
            pendingFinalContent = pendingFinalContent.filter { instanceIDs.contains($0.key) }
            if let obsolete = obsoleteInstance(in: instances) {
                await backend.end(id: obsolete.id)
                continue
            }
            if let finished = instances.first(where: {
                $0.status == .active && !attemptedFinishes.contains($0.id)
                    && pendingFinalContent[$0.id] == nil
                    && desired[$0.attributes.eventID]?.content.end != nil
            }), let target = desired[finished.attributes.eventID], let end = target.content.end {
                attemptedFinishes.insert(finished.id)
                let dismissalDate = end.addingTimeInterval(15 * 60)
                if dismissalDate > Date() {
                    pendingFinalContent[finished.id] = target.content
                    await backend.finish(id: finished.id, content: target.content, dismissalDate: dismissalDate)
                } else {
                    await backend.end(id: finished.id)
                }
                continue
            }
            if let changed = instances.first(where: {
                $0.status == .active && !attemptedUpdates.contains($0.id)
                    && desired[$0.attributes.eventID]?.content.end == nil
                    && desired[$0.attributes.eventID]?.content != $0.content
            }), let target = desired[changed.attributes.eventID] {
                // ActivityKit can ignore updates or expose their content with a delay. Bound
                // attempts to one per snapshot and retry at the next reconciliation.
                attemptedUpdates.insert(changed.id)
                await backend.update(id: changed.id, content: target.content)
                continue
            }
            let active = Set(instances.filter { $0.status == .active }.map(\.attributes.eventID))
            if allowStart, backend.enabled,
               let eventID = desired.keys.sorted(by: { $0.uuidString < $1.uuidString }).first(where: {
                   desired[$0]?.content.end == nil && !active.contains($0)
                       && !backend.dismissedEventIDs.contains($0) && !attemptedRequests.contains($0)
               }), let target = desired[eventID]
            {
                attemptedRequests.insert(eventID)
                // A failed request is retried on the next snapshot (for example foreground entry).
                try? await backend.request(attributes: target.attributes, content: target.content)
                continue
            }
            worker = nil
            return
        }
    }

    private func obsoleteInstance(in instances: [CareActivityInstance]) -> CareActivityInstance? {
        var kept = Set<UUID>()
        // Preserve one deliberately finished card, but never confuse a system timeout
        // (whose state has no end date) with the committed end of a care event.
        for instance in instances where instance.status == .ended {
            let eventID = instance.attributes.eventID
            guard let target = desired[eventID],
                  target.attributes.babyID == instance.attributes.babyID,
                  let end = target.content.end,
                  end.addingTimeInterval(15 * 60) > Date(),
                  !backend.dismissedEventIDs.contains(eventID),
                  kept.insert(eventID).inserted
            else { return instance }
            if instance.content == target.content {
                pendingFinalContent.removeValue(forKey: instance.id)
            } else if pendingFinalContent[instance.id] != target.content {
                return instance
            }
        }
        for instance in instances where instance.status == .active {
            let eventID = instance.attributes.eventID
            guard let target = desired[eventID],
                  target.attributes.babyID == instance.attributes.babyID,
                  pendingFinalContent[instance.id].map({ $0 == target.content }) ?? true,
                  !backend.dismissedEventIDs.contains(eventID),
                  kept.insert(eventID).inserted
            else { return instance }
        }
        return nil
    }
}

/// ActivityKit owns the lifetime (at most eight hours). An ended activity can be restored on
/// foreground entry while its persisted care event is still running. Explicit dismissals observed
/// by this process are retained across launches as a presentation preference.
@MainActor
final class SystemCareActivityBackend: CareActivityBackend {
    private let defaults: UserDefaults
    private let dismissalKey = "careActivity.dismissedEventIDs"
    private var observations: [String: Task<Void, Never>] = [:]
    private var observedActivities: [String: Activity<CareActivityAttributes>] = [:]
    private var endedIDs = Set<String>()

    var enabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var dismissedEventIDs: Set<UUID> {
        Set((defaults.stringArray(forKey: dismissalKey) ?? []).compactMap(UUID.init(uuidString:)))
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for activity in Activity<CareActivityAttributes>.activities {
            observe(activity)
        }
    }

    func instances() -> [CareActivityInstance] {
        for activity in Activity<CareActivityAttributes>.activities {
            observe(activity)
        }
        return Array(observedActivities.values).compactMap { activity in
            if activity.activityState == .ended {
                endedIDs.insert(activity.id)
            }
            if activity.activityState == .dismissed, !endedIDs.contains(activity.id) {
                rememberDismissal(activity.attributes.eventID)
            }
            if activity.activityState == .dismissed {
                observations.removeValue(forKey: activity.id)?.cancel()
                observedActivities.removeValue(forKey: activity.id)
                return nil
            }
            let status: CareActivityInstance.Status = switch activity.activityState {
            case .active, .stale: .active
            case .ended: .ended
            case .dismissed: .dismissed
            // Newer systems can return .pending; keep it rather than starting a duplicate.
            default: .active
            }
            return CareActivityInstance(id: activity.id, attributes: activity.attributes,
                                        content: activity.content.state, status: status)
        }
    }

    func request(attributes: CareActivityAttributes, content: CareActivityAttributes.ContentState) async throws {
        let activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: content, staleDate: nil), pushType: nil)
        observe(activity)
    }

    func update(id: String, content: CareActivityAttributes.ContentState) async {
        await observedActivities[id]?.update(ActivityContent(state: content, staleDate: nil))
    }

    func end(id: String) async {
        // Stop observing before ending: the app's own immediate dismissal is not a user dismissal.
        observations.removeValue(forKey: id)?.cancel()
        endedIDs.insert(id)
        guard let activity = observedActivities.removeValue(forKey: id) else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
    }

    func finish(id: String, content: CareActivityAttributes.ContentState, dismissalDate: Date) async {
        guard let activity = observedActivities[id] else { return }
        // Keep tracking the ended activity so a later deletion or access loss can remove it.
        endedIDs.insert(id)
        await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .after(dismissalDate))
    }

    private func observe(_ activity: Activity<CareActivityAttributes>) {
        guard activity.activityState != .dismissed,
              observedActivities[activity.id] == nil, !endedIDs.contains(activity.id) else { return }
        observedActivities[activity.id] = activity
        observations[activity.id] = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled else { return }
                if state == .ended {
                    self?.endedIDs.insert(activity.id)
                }
                if state == .dismissed {
                    if self?.endedIDs.contains(activity.id) == false {
                        self?.rememberDismissal(activity.attributes.eventID)
                    }
                    self?.observations.removeValue(forKey: activity.id)
                    self?.observedActivities.removeValue(forKey: activity.id)
                    return
                }
            }
        }
    }

    private func rememberDismissal(_ eventID: UUID) {
        var ids = dismissedEventIDs
        guard ids.insert(eventID).inserted else { return }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: dismissalKey)
    }
}
