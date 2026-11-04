import Foundation

/// Widget links only open an app surface; they never create or finish events.
struct WidgetRoute: Equatable, Sendable {
    enum Destination: String, CaseIterable, Sendable { case today, breast, diaper, sleep, history }
    let destination: Destination
    let babyID: UUID?

    init(_ destination: Destination, babyID: UUID? = nil) {
        self.destination = destination
        self.babyID = babyID
    }

    init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "malysh", parts.host == "widget",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let destination = Destination(rawValue: String(parts.path.dropFirst())),
              parts.path == "/" + destination.rawValue else { return nil }
        let query = parts.queryItems ?? []
        guard query.allSatisfy({ $0.name == "baby" }), query.count <= 1 else { return nil }
        if let item = query.first {
            guard let value = item.value, let id = UUID(uuidString: value) else { return nil }
            babyID = id
        } else {
            babyID = nil
        }
        self.destination = destination
    }

    var url: URL {
        var parts = URLComponents()
        parts.scheme = "malysh"
        parts.host = "widget"
        parts.path = "/" + destination.rawValue
        if let babyID {
            parts.queryItems = [URLQueryItem(name: "baby", value: babyID.uuidString)]
        }
        return parts.url!
    }
}
