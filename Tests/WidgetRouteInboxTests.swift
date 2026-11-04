import Foundation
@testable import Malysh
import XCTest

@MainActor
final class WidgetRouteInboxTests: XCTestCase {
    func testColdRouteSurvivesUntilConsumerAndIsConsumedOnce() {
        let inbox = WidgetRouteInbox()
        let route = WidgetRoute(.diaper, babyID: UUID())
        inbox.receive(route.url)
        XCTAssertEqual(inbox.pending, route)
        XCTAssertEqual(inbox.take(), route)
        XCTAssertNil(inbox.take())
    }

    func testLatestNavigationWinsWhileStartupIsPending() {
        let inbox = WidgetRouteInbox()
        inbox.receive(WidgetRoute(.breast).url)
        inbox.receive(WidgetRoute(.history).url)
        XCTAssertEqual(inbox.take(), WidgetRoute(.history))
    }

    func testMalformedURLDoesNotErasePendingValidNavigation() throws {
        let inbox = WidgetRouteInbox()
        inbox.receive(WidgetRoute(.sleep).url)
        try inbox.receive(XCTUnwrap(URL(string: "https://example.com")))
        XCTAssertEqual(inbox.take(), WidgetRoute(.sleep))
    }
}
