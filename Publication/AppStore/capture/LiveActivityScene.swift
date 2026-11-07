
#if DEBUG && targetEnvironment(simulator)
import ActivityKit

/// A demonstration of native system presentations, not simultaneous product workflow.
/// This source exists only in the disposable capture checkout.
@MainActor
enum StorefrontActivityScene {
    private static var installed = false

    static func install(store: AppStore) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), arguments.contains("--storefront-live-states"),
              !installed, store.ready, let baby = store.baby else { return }
        precondition(!store.persistence.cloudEnabled)
        installed = true
        for _ in 0 ..< 30 where UIApplication.shared.applicationState != .active {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for activity in Activity<CareActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        for activity in Activity<FeedingReminderActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        let now = Date()
        var outcomes: [[String: String]] = []
        for (kind, seconds, side) in [(EventKind.breast, 12 * 60, BreastSide.left),
                                      (EventKind.sleep, 43 * 60, BreastSide.left)] {
            do {
                let attributes = CareActivityAttributes(eventID: UUID(), babyID: baby.id)
                let state = CareActivityAttributes.ContentState(
                    kind: kind, start: now.addingTimeInterval(-Double(seconds)),
                    side: kind == .breast ? side : nil, babyName: baby.name, end: nil
                )
                let activity = try Activity<CareActivityAttributes>.request(
                    attributes: attributes, content: ActivityContent(state: state, staleDate: nil), pushType: nil
                )
                outcomes.append(["kind": kind.rawValue, "status": "requested", "activityID": activity.id])
            } catch {
                outcomes.append(["kind": kind.rawValue, "status": "failed", "error": String(reflecting: error)])
            }
        }
        do {
            let activity = try Activity<FeedingReminderActivityAttributes>.request(
                attributes: .init(token: UUID().uuidString, babyID: baby.id),
                content: ActivityContent(state: .init(babyName: baby.name, elapsedLabel: "3 часа"), staleDate: nil),
                pushType: nil
            )
            outcomes.append(["kind": "reminder", "status": "requested", "activityID": activity.id])
        } catch {
            outcomes.append(["kind": "reminder", "status": "failed", "error": String(reflecting: error)])
        }
        let report: [String: Any] = [
            "capturedSession": ISO8601DateFormatter().string(from: now),
            "syntheticData": true,
            "mode": "native ActivityKit presentation demonstration",
            "productionCaveat": "Regular app cancels the reminder when breastfeeding starts. This DEBUG-only scene directly requests all presentations and bypasses normal reconciliation.",
            "babyName": baby.name,
            "feedingMinutes": 12, "sleepMinutes": 43, "reminderElapsed": "3 часа",
            "outcomes": outcomes,
            "careActivities": Activity<CareActivityAttributes>.activities.count,
            "reminderActivities": Activity<FeedingReminderActivityAttributes>.activities.count,
        ]
        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StorefrontLiveActivities.json")
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: path, options: .atomic)
        }
    }
}
#endif
