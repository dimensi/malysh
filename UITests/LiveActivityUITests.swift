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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.switch.'"))
            .firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let springboard = showActivity(button: "Переключить на правую грудь")
        let switchSide = springboard.buttons["Переключить на правую грудь"]
        XCTAssertTrue(switchSide.waitForExistence(timeout: 10), springboard.debugDescription)
        capture("Кормление — системные кнопки")
        switchSide.tap()
        XCTAssertTrue(springboard.staticTexts["Правая грудь"].waitForExistence(timeout: 10))
        XCTAssertNotEqual(app.state, .runningForeground)
        springboard.buttons["Завершить кормление"].tap()
        waitForSystemDismissal(springboard.buttons["Завершить кормление"])
        XCTAssertNotEqual(app.state, .runningForeground)
        app.activate()
        waitForRemoval(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'"))
            .firstMatch.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'event.'"))
            .firstMatch.exists)
    }

    func testSleepSystemControlsSaveWhileAppStaysInBackground() {
        let app = launch()
        app.buttons["action.sleep"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'"))
            .firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        let springboard = showActivity(button: "Завершить сон")
        let finish = springboard.buttons["Завершить сон"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10), springboard.debugDescription)
        capture("Сон — системные кнопки")
        finish.tap()
        waitForSystemDismissal(finish)
        XCTAssertNotEqual(app.state, .runningForeground)
        app.activate()
        waitForRemoval(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'event.'"))
            .firstMatch.exists)
    }

    func testBreastLockScreenInLightAppearance() {
        assertLockScreen(breast: true, appearance: .light)
    }

    func testSleepLockScreenInDarkAppearanceAfterTermination() {
        assertLockScreen(breast: false, appearance: .dark)
    }

    private func assertLockScreen(breast: Bool, appearance: XCUIDevice.Appearance) {
        let previousAppearance = XCUIDevice.shared.appearance
        XCUIDevice.shared.appearance = appearance
        defer { XCUIDevice.shared.appearance = previousAppearance }
        let app = launch()
        if breast {
            app.buttons["action.feed"].tap()
            let left = app.descendants(matching: .any).matching(identifier: "feed.left").firstMatch
            XCTAssertTrue(left.waitForExistence(timeout: 5))
            left.tap()
        } else {
            app.buttons["action.sleep"].tap()
        }
        let activeTimer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch
        XCTAssertTrue(activeTimer.waitForExistence(timeout: 5))
        let eventID = String(activeTimer.identifier.dropFirst("timer.finish.".count))
        let finishLabel = breast ? "Завершить кормление" : "Завершить сон"
        XCUIDevice.shared.press(.home)
        let springboard = showActivity(button: finishLabel)
        // The first WidgetKit host launch on a clean simulator can take longer than an app transition.
        XCTAssertTrue(springboard.buttons[finishLabel].waitForExistence(timeout: 30), springboard.debugDescription)
        XCTAssertTrue(springboard.buttons[finishLabel].isHittable)
        XCUIDevice.shared.press(.home)
        let cover = openNotificationCenter(springboard)
        let finish = cover.buttons[finishLabel]
        for _ in 0 ..< 2 {
            allowActivityIfNeeded(springboard)
            if finish.waitForExistence(timeout: 3) {
                allowActivityIfNeeded(springboard)
                if finish.isHittable {
                    break
                }
            }
            let list = cover.scrollViews.firstMatch
            XCTAssertTrue(list.exists)
            list.swipeUp()
        }
        XCTAssertTrue(finish.waitForExistence(timeout: 5), springboard.debugDescription)
        allowActivityIfNeeded(springboard)
        XCTAssertTrue(cover.isHittable)
        if breast {
            XCTAssertTrue(springboard.staticTexts["Левая грудь"].exists)
            XCTAssertTrue(springboard.buttons["Переключить на правую грудь"].exists)
            capture("Кормление — экран блокировки, светлая тема")
            XCTAssertTrue(finish.isHittable)
            finish.tap()
            XCTAssertNotEqual(app.state, .runningForeground)
            // iOS 26 can keep the removed card hittable in its old AX snapshot.
            // Reopen the system surface before checking dismissal, without activating the app.
            XCUIDevice.shared.press(.home)
            let refreshedCover = openNotificationCenter(springboard)
            waitForSystemDismissal(refreshedCover.buttons[finishLabel])
            XCTAssertNotEqual(app.state, .runningForeground)
        } else {
            // Wait for WidgetKit to render before killing the process that requests the activity.
            XCTAssertTrue(finish.isHittable)
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            XCTAssertTrue(finish.waitForExistence(timeout: 5), springboard.debugDescription)
            XCTAssertTrue(finish.isHittable)
            capture("Сон после закрытия приложения — экран блокировки, тёмная тема")
        }
        // Relaunch without reset and finish the isolated diary's sleep after checking its closed-process display.
        app.launchArguments = ["--ui-testing"]
        if app.state == .notRunning {
            // activate() reuses the arguments of the previous launch, including --reset-data.
            app.launch()
        } else {
            app.activate()
        }
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        if !breast {
            let timer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch
            XCTAssertTrue(timer.waitForExistence(timeout: 5))
            timer.tap()
        }
        waitForRemoval(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch)
        assertSavedEvent(eventID, in: app)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch
            .exists)
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
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.005))
            .press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)
            ))
        let cover = springboard.windows["SBCoverSheetWindow"]
        XCTAssertTrue(cover.waitForExistence(timeout: 5))
        return cover
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        return app
    }

    private func showActivity(button: String) -> XCUIApplication {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The first WidgetKit render can finish after the Home transition.
        for _ in 0 ..< 3 {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).press(forDuration: 1.5)
            allowActivityIfNeeded(springboard)
            if springboard.buttons[button].waitForExistence(timeout: 3) {
                allowActivityIfNeeded(springboard)
                if springboard.buttons[button].isHittable {
                    return springboard
                }
            }
        }
        // iPhones without Dynamic Island expose the same intents on the Lock Screen.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.005))
            .press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)
            ))
        allowActivityIfNeeded(springboard)
        return springboard
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
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"), object: element
        )
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
