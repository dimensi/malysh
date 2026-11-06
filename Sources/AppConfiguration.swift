import Foundation

enum AppConfiguration {
    static let appGroup = requiredValue(for: "MalyshAppGroup")
    static let cloudKitContainer = requiredValue(for: "MalyshCloudKitContainer")
    static let widgetURLScheme = requiredValue(for: "MalyshWidgetURLScheme")

    private static func requiredValue(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.hasPrefix("$(")
        else {
            preconditionFailure("Missing build configuration value: \(key)")
        }
        return value
    }
}
