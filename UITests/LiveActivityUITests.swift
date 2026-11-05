import XCTest

/// Exercises WidgetKit and the app-process intents through SpringBoard, using only test diary data.
@MainActor
final class LiveActivityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testBreastSystemControlsSaveWhileAppStaysInBackground() {
        let app = launch()
        app.buttons["action.feed"].tap()
        let left = app.descendants(matching: .any).matching(identifier: "feed.left").firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        left.tap()
        let timer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        let eventID = String(timer.identifier.dropFirst("timer.finish.".count))
        XCUIDevice.shared.press(.home)
        let cover = showActivity(button: "Переключить на правую грудь")
        let switchSide = cover.buttons["Переключить на правую грудь"]
        capture("Кормление — системные кнопки")
        switchSide.tap()
        // Wait for the updated card before sending its next intent.
        let updatedCover = showActivity(button: "Переключить на левую грудь")
        XCTAssertTrue(updatedCover.staticTexts["Правая грудь"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
        updatedCover.buttons["Завершить кормление"].tap()
        assertSystemActivityRemoved(button: "Завершить кормление", app: app)
        XCTAssertNotEqual(app.state, .runningForeground)
        app.activate()
        waitForRemoval(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'"))
            .firstMatch.exists)
        assertSavedEvent(eventID, in: app)
    }

    func testSleepSystemControlsSaveWhileAppStaysInBackground() {
        let app = launch()
        app.buttons["action.sleep"].tap()
        let timer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        let eventID = String(timer.identifier.dropFirst("timer.finish.".count))
        XCUIDevice.shared.press(.home)
        let cover = showActivity(button: "Завершить сон")
        let finish = cover.buttons["Завершить сон"]
        capture("Сон — системные кнопки")
        finish.tap()
        assertSystemActivityRemoved(button: "Завершить сон", app: app)
        XCTAssertNotEqual(app.state, .runningForeground)
        app.activate()
        waitForRemoval(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch)
        assertSavedEvent(eventID, in: app)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'"))
            .firstMatch.exists)
        assertSavedEvent(eventID, in: app)
    }

    private func assertSavedEvent(_ id: String, in app: XCUIApplication) {
        let event = app.buttons["event.\(id)"]
        if !event.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(event.waitForExistence(timeout: 10))
    }

    private func openNotificationCenter(_ springboard: XCUIApplication) -> XCUIElement {
        let cover = springboard.windows["SBCoverSheetWindow"]
        // A synthesized edge gesture is not proof that Notification Center opened.
        for _ in 0 ..< 3 {
            if cover.exists, cover.isHittable {
                return cover
            }
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.005))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)
                ))
            if cover.waitForExistence(timeout: 5), cover.isHittable {
                return cover
            }
        }
        XCTFail("Notification Center did not open: \(springboard.debugDescription)")
        return cover
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        return app
    }

    private func showActivity(button: String) -> XCUIElement {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cover = openNotificationCenter(springboard)
        let control = cover.buttons[button]
        // Await the first WidgetKit render and its permission before interacting with the card.
        for _ in 0 ..< 3 {
            allowActivityIfNeeded(springboard)
            if control.waitForExistence(timeout: 10) {
                allowActivityIfNeeded(springboard)
                if control.isHittable {
                    return cover
                }
            }
            // Notification Center lazily exposes cards below the clock's initial viewport.
            let list = cover.scrollViews.firstMatch
            XCTAssertTrue(list.exists)
            list.swipeUp()
        }
        XCTFail("Live Activity control is not hittable: \(cover.debugDescription)")
        return cover
    }

    private func assertSystemActivityRemoved(button: String, app: XCUIApplication) {
        XCTAssertNotEqual(app.state, .runningForeground)
        // Refresh iOS 26's stale AX snapshot before querying the removed card.
        XCUIDevice.shared.press(.home)
        let cover = openNotificationCenter(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        waitForSystemDismissal(cover.buttons[button])
        XCTAssertTrue(cover.isHittable)
        XCTAssertNotEqual(app.state, .runningForeground)
    }

    private func allowActivityIfNeeded(_ springboard: XCUIApplication) {
        for label in ["Always Allow", "Allow", "Всегда разрешать", "Разрешить"] {
            let allow = springboard.buttons[label].firstMatch
            if allow.exists, allow.isHittable {
                allow.tap()
                return
            }
        }
    }

    private func waitForRemoval(_ element: XCUIElement) {
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
    }

    private func waitForSystemDismissal(_ element: XCUIElement) {
        // iOS 26 can retain an AX node after its system card has disappeared.
        // The first cold system intent took 19 seconds to dispatch in CI before ending successfully.
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 30), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
