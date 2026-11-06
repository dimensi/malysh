import Foundation
import Observation

/// Retains navigation from scene URLs and notifications until SwiftUI can handle it.
@MainActor
@Observable
final class WidgetRouteInbox {
    static let shared = WidgetRouteInbox()
    private(set) var pending: WidgetRoute?

    func receive(_ url: URL) {
        guard let route = WidgetRoute(url: url) else { return }
        receive(route)
    }

    func receive(_ route: WidgetRoute) {
        // Navigation follows the latest user request while startup is in flight.
        pending = route
    }

    func take() -> WidgetRoute? {
        let route = pending
        pending = nil
        return route
    }
}
