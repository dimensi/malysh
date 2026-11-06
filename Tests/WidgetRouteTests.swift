import Foundation
@testable import Malysh
import XCTest

final class WidgetRouteTests: XCTestCase {
    func testAllDestinationsRoundTripWithDiaryIdentity() {
        let id = UUID()
        for destination in WidgetRoute.Destination.allCases where destination != .activity {
            let route = WidgetRoute(destination, babyID: id)
            XCTAssertEqual(WidgetRoute(url: route.url), route)
        }
        XCTAssertEqual(WidgetRoute(url: WidgetRoute(.today).url), WidgetRoute(.today))
        let activity = WidgetRoute(.activity, babyID: id, eventID: UUID())
        XCTAssertEqual(WidgetRoute(url: activity.url), activity)
    }

    func testRejectsForeignAndMalformedLinks() throws {
        let scheme = AppConfiguration.widgetURLScheme
        let otherScheme = scheme == "malysh" ? "malysh-dev" : "malysh"
        for value in [
            "https://widget/today",
            "\(otherScheme)://widget/today",
            "\(scheme)://other/today",
            "\(scheme)://widget/delete",
            "\(scheme)://widget/today/",
            "\(scheme)://widget/today?baby=invalid",
            "\(scheme)://widget/today?unexpected=1",
            "\(scheme)://widget/today?baby=&baby=",
            "\(scheme)://widget/today#anything",
            "\(scheme)://user@widget/today",
            "\(scheme)://widget/activity",
            "\(scheme)://widget/activity?baby=invalid&event=invalid",
            "\(scheme)://widget/activity?baby=\(UUID())",
            "\(scheme)://widget/activity?event=\(UUID())",
            "\(scheme)://widget/activity?baby=\(UUID())&event=\(UUID())&event=\(UUID())",
            "\(scheme)://widget/activity?baby=\(UUID())&baby=\(UUID())&event=\(UUID())",
            "\(scheme)://widget/today?event=\(UUID())",
        ] {
            XCTAssertNil(try WidgetRoute(url: XCTUnwrap(URL(string: value))), value)
        }
    }
}
