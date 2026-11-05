import Foundation
import Observation

/// Retains a validated scene URL until SwiftUI and the selected diary are ready.
/// The scene delegate is the sole URL ingress, so SwiftUI cannot deliver it twice.
@MainActor
@Observable
final class WidgetRouteInbox {
    static let shared = WidgetRouteInbox()
    private(set) var pending: WidgetRoute?

    func receive(_ url: URL) {
        guard let route = WidgetRoute(url: url) else { return }
        // Navigation follows the latest user request while startup is in flight.
        pending = route
    }

    func take() -> WidgetRoute? {
        let route = pending
        pending = nil
        return route
    }
}
