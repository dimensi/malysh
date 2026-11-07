import XCTest

/// Exercises WidgetKit and the app-process intents through SpringBoard, using only test diary data.
@MainActor
final class LiveActivityUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
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
        assertSystemActivityFinished(button: "Завершить сон", status: "Сон завершён", app: app)
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

    func testFeedingLockScreenKeepsControlsBesideTitleAndShowsCompletedCard() {
        let app = launch()
        app.buttons["action.feed"].tap()
        let left = app.buttons.matching(identifier: "feed.left").firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        left.tap()
        let timer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        let eventID = String(timer.identifier.dropFirst("timer.finish.".count))

        let title = "Малыш · Кормление"
        let finishLabel = "Завершить кормление"
        let switchLabel = "Переключить на правую грудь"
        XCUIDevice.shared.press(.home)
        let activeCard = showActivity(button: finishLabel)
        let activeTitle = activeCard.staticTexts[title]
        let switchSide = activeCard.buttons[switchLabel]
        let finish = activeCard.buttons[finishLabel]
        XCTAssertTrue(activeTitle.exists)
        XCTAssertTrue(switchSide.isHittable)
        XCTAssertGreaterThanOrEqual(switchSide.frame.minX, activeTitle.frame.maxX)
        XCTAssertGreaterThan(finish.frame.minX, switchSide.frame.minX)
        XCTAssertEqual(switchSide.frame.midY, finish.frame.midY, accuracy: 2)

        finish.tap()
        let completedCard = assertSystemActivityFinished(button: finishLabel, status: "Кормление завершено", app: app)
        XCTAssertTrue(completedCard.staticTexts[title].exists)
        waitForSystemDismissal(completedCard.buttons[switchLabel])
        app.activate()
        waitForRemoval(timer)
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
        for scrollCount in 0 ... 3 {
            allowActivityIfNeeded(springboard)
            if control.waitForExistence(timeout: 10) {
                allowActivityIfNeeded(springboard)
                let ready = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND hittable == true"), object: control
                )
                if XCTWaiter.wait(for: [ready], timeout: 2) == .completed {
                    return cover
                }
            }
            guard scrollCount < 3 else { break }
            // Notification Center lazily exposes cards below the clock's initial viewport.
            let list = cover.scrollViews.firstMatch
            XCTAssertTrue(list.exists)
            list.swipeUp()
        }
        XCTFail("Live Activity control is not hittable: \(cover.debugDescription)")
        return cover
    }

    @discardableResult
    private func assertSystemActivityFinished(button: String, status: String, app: XCUIApplication) -> XCUIElement {
        XCTAssertNotEqual(app.state, .runningForeground)
        // Refresh iOS 26's stale AX snapshot before querying the removed card.
        XCUIDevice.shared.press(.home)
        let cover = openNotificationCenter(XCUIApplication(bundleIdentifier: "com.apple.springboard"))
        waitForSystemDismissal(cover.buttons[button])
        XCTAssertTrue(cover.staticTexts[status].waitForExistence(timeout: 15))
        capture("\(status) — итог")
        XCTAssertTrue(cover.isHittable)
        XCTAssertNotEqual(app.state, .runningForeground)
        return cover
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
