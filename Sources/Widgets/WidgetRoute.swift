import Foundation

/// Widget links only open an app surface; they never create or finish events.
struct WidgetRoute: Equatable, Sendable {
    enum Destination: String, CaseIterable, Sendable { case today, breast, diaper, sleep, history, activity }
    let destination: Destination
    let babyID: UUID?
    let eventID: UUID?

    init(_ destination: Destination, babyID: UUID? = nil, eventID: UUID? = nil) {
        self.destination = destination
        self.babyID = babyID
        self.eventID = eventID
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == AppConfiguration.widgetURLScheme, parts.host == "widget",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let destination = Destination(rawValue: String(parts.path.dropFirst())),
              parts.path == "/" + destination.rawValue else { return nil }
        let query = parts.queryItems ?? []
        guard query.allSatisfy({ $0.name == "baby" || $0.name == "event" }),
              query.filter({ $0.name == "baby" }).count <= 1,
              query.filter({ $0.name == "event" }).count <= 1 else { return nil }
        let babyItem = query.first { $0.name == "baby" }
        let eventItem = query.first { $0.name == "event" }
        if let babyItem {
            guard let value = babyItem.value, let id = UUID(uuidString: value) else { return nil }
            babyID = id
        } else {
            babyID = nil
        }
        if let eventItem {
            guard let value = eventItem.value, let id = UUID(uuidString: value) else { return nil }
            eventID = id
        } else {
            eventID = nil
        }
        guard destination == .activity ? babyID != nil && eventID != nil : eventID == nil else { return nil }
        self.destination = destination
    }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = AppConfiguration.widgetURLScheme
        parts.host = "widget"
        parts.path = "/" + destination.rawValue
        var query: [URLQueryItem] = []
        if let babyID {
            query.append(URLQueryItem(name: "baby", value: babyID.uuidString))
        }
        if let eventID {
            query.append(URLQueryItem(name: "event", value: eventID.uuidString))
        }
        if !query.isEmpty {
            parts.queryItems = query
        }
        return parts.url!
    }
}
