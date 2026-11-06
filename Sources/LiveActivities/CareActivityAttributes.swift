import ActivityKit
import Foundation

struct CareActivityAttributes: ActivityAttributes, Sendable {
    struct ContentState: Codable, Hashable, Sendable {
        var kind: EventKind
        var start: Date
        var side: BreastSide?
        var babyName: String
        var end: Date?
    }

    let eventID: UUID
    let babyID: UUID
}
