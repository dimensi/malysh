import Foundation
@testable import Malysh
import XCTest

final class WidgetRouteTests: XCTestCase {
    func testAllDestinationsRoundTripWithDiaryIdentity() {
        let id = UUID()
        for destination in WidgetRoute.Destination.allCases {
            let route = WidgetRoute(destination, babyID: id)
            XCTAssertEqual(WidgetRoute(url: route.url), route)
        }
        XCTAssertEqual(WidgetRoute(url: WidgetRoute(.today).url), WidgetRoute(.today))
    }

    func testRejectsForeignAndMalformedLinks() throws {
        for value in ["https://widget/today", "malysh://other/today", "malysh://widget/delete",
                      "malysh://widget/today/", "malysh://widget/today?baby=invalid",
                      "malysh://widget/today?unexpected=1", "malysh://widget/today?baby=&baby=",
                      "malysh://widget/today#anything", "malysh://user@widget/today"]
        {
            XCTAssertNil(try WidgetRoute(url: XCTUnwrap(URL(string: value))), value)
        }
    }
}
