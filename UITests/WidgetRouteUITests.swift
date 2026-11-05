import XCTest

/// Real external URL launch coverage. Warm delivery belongs to installed-widget tests.
@MainActor
final class WidgetRouteUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        // XCUIApplication.open launches with these arguments; preserve the same diary.
        app.launchArguments = ["--ui-testing"]
        return app
    }

    private func open(_ route: String, app: XCUIApplication) {
        app.terminate()
        app.open(URL(string: "malysh://widget/" + route)!)
    }

    private func action(_ identifier: String, label: String, app: XCUIApplication) -> XCUIElement {
        let identified = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if identified.exists {
            return identified
        }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func rows(_ prefix: String, app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testColdBreastLinkRequiresSelectionBeforeStartingTimer() {
        let app = launch()
        open("breast", app: app)
        let left = action("feed.left", label: "Левая грудь", app: app)
        XCTAssertTrue(left.waitForExistence(timeout: 10))
        XCTAssertEqual(rows("timer.finish.", app: app).count, 0)
        capture(app, "Внешняя ссылка — выбор груди после холодного запуска")
        left.tap()
        XCTAssertTrue(rows("timer.finish.", app: app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows("timer.finish.", app: app).count, 1)
    }

    func testColdDiaperLinkSavesChosenTypeAndHistoryLinkOpensDiary() {
        let app = launch()
        open("diaper", app: app)
        let wet = action("diaper.wet", label: "Мокрый", app: app)
        XCTAssertTrue(wet.waitForExistence(timeout: 10))
        XCTAssertEqual(rows("event.", app: app).count, 0)
        capture(app, "Внешняя ссылка — выбор подгузника после холодного запуска")
        wet.tap()
        XCTAssertTrue(rows("event.", app: app).firstMatch.waitForExistence(timeout: 5))
        open("history", app: app)
        XCTAssertTrue(app.navigationBars["История"].waitForExistence(timeout: 10))
        XCTAssertEqual(rows("event.", app: app).count, 1)
        capture(app, "Внешняя ссылка — сохранённая запись в истории")
        open("today", app: app)
        XCTAssertTrue(app.navigationBars["Сегодня"].waitForExistence(timeout: 10))
    }

    func testColdSleepLinkRequiresConfirmationAndKeepsExistingTimerAfterRelaunch() {
        let app = launch()
        open("sleep", app: app)
        let start = action("widget.sleep.start", label: "Начать сон", app: app)
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertEqual(rows("timer.finish.", app: app).count, 0)
        XCTAssertEqual(rows("event.", app: app).count, 0)
        start.tap()
        let timer = rows("timer.finish.", app: app).firstMatch
        XCTAssertTrue(timer.waitForExistence(timeout: 5))
        let identifier = timer.identifier
        open("sleep", app: app)
        XCTAssertTrue(rows("timer.finish.", app: app).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows("timer.finish.", app: app).count, 1)
        XCTAssertEqual(rows("timer.finish.", app: app).firstMatch.identifier, identifier)
        XCTAssertFalse(action("widget.sleep.start", label: "Начать сон", app: app).exists)
        capture(app, "Внешняя ссылка — существующий сон после перезапуска")
    }

    func testWrongDiaryAndUnknownLinksDoNotCreateEvents() {
        let app = launch()
        for route in ["sleep?baby=" + UUID().uuidString, "delete"] {
            open(route, app: app)
            XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
            XCTAssertEqual(rows("timer.finish.", app: app).count, 0)
            XCTAssertEqual(rows("event.", app: app).count, 0)
            XCTAssertFalse(action("widget.sleep.start", label: "Начать сон", app: app).exists)
        }
    }
}
