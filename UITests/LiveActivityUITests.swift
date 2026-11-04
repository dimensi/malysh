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
        waitForRemoval(springboard.buttons["Завершить кормление"])
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
        waitForRemoval(finish)
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
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'"))
            .firstMatch.waitForExistence(timeout: 5))
        if breast {
            XCUIDevice.shared.press(.home)
        } else {
            // The system keeps rendering the start-based timer with no application process running.
            app.terminate()
        }
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let finish = springboard.buttons[breast ? "Завершить кормление" : "Завершить сон"]
        for _ in 0 ..< 3 {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.005))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)
                ))
            if finish.waitForExistence(timeout: 3) {
                break
            }
        }
        XCTAssertTrue(finish.waitForExistence(timeout: 5), springboard.debugDescription)
        // Resolve this app's first-activity system prompt before checking its normal appearance.
        let allow = springboard.buttons["Allow"].firstMatch
        if allow.exists {
            allow.tap()
        }
        if breast {
            XCTAssertTrue(springboard.staticTexts["Левая грудь"].exists)
            XCTAssertTrue(springboard.buttons["Переключить на правую грудь"].exists)
            capture("Кормление — экран блокировки, светлая тема")
            finish.tap()
            waitForRemoval(finish)
        } else {
            XCTAssertEqual(app.state, .notRunning)
            capture("Сон после закрытия приложения — экран блокировки, тёмная тема")
        }
        // Relaunch without reset and finish the isolated diary's sleep after checking its closed-process display.
        app.launchArguments = ["--ui-testing"]
        app.activate()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        if !breast {
            let timer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch
            XCTAssertTrue(timer.waitForExistence(timeout: 5))
            timer.tap()
        }
        waitForRemoval(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'timer.finish.'")).firstMatch)
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
            if springboard.buttons[button].waitForExistence(timeout: 3) {
                return springboard
            }
        }
        // iPhones without Dynamic Island expose the same intents on the Lock Screen.
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.005))
            .press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)
            ))
        return springboard
    }

    private func waitForRemoval(_ element: XCUIElement) {
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
