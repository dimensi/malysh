import ActivityKit
import Foundation

struct FeedingReminderActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        let babyName: String
        let elapsedLabel: String
    }

    let token: String
    let babyID: UUID
}
