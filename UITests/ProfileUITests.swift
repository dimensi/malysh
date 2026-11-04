import XCTest

@MainActor
final class ProfileUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ appearance: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data"] + appearance
        app.launch()
        XCTAssertTrue(app.buttons["child.profile.open"].waitForExistence(timeout: 10))
        app.buttons["child.profile.open"].tap()
        XCTAssertTrue(app.navigationBars["Профиль ребёнка"].waitForExistence(timeout: 5))
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func replace(_ field: XCUIElement, with text: String) {
        field.tap()
        if let old = field.value as? String, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(text)
    }

    func testProfileNameAndConfirmedBirthDatePersist() {
        let app = launch(["--light-mode"])
        XCTAssertFalse(app.descendants(matching: .any)["child.profile.age"].exists)
        app.buttons["child.profile.edit"].tap()
        let name = app.textFields["child.editor.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        replace(name, with: "Маша")
        let confirmed = app.switches["child.editor.confirmed"]
        reveal(confirmed, in: app)
        confirmed.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(confirmed.value as? String, "1")
        XCTAssertTrue(app.datePickers["child.editor.birthDate"].exists)
        app.buttons["child.editor.save"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["child.profile.age"].waitForExistence(timeout: 5))
        app.buttons["child.profile.close"].tap()
        XCTAssertTrue(app.staticTexts["Маша"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--light-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["child.profile.open"].waitForExistence(timeout: 10))
        app.buttons["child.profile.open"].tap()
        XCTAssertTrue(app.staticTexts["Маша"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["child.profile.age"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Child profile light"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testMeasurementAddEditAndImmediateDelete() {
        let app = launch(["--light-mode"])
        app.buttons["measurement.history.weight"].tap()
        app.buttons["measurement.add"].tap()
        let value = app.textFields["measurement.editor.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap()
        value.typeText("4200")
        app.buttons["measurement.editor.save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurement.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("200"))
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        replace(value, with: "4300")
        app.buttons["measurement.editor.save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("300"))
        row.tap()
        let delete = app.buttons["measurement.editor.delete"]
        reveal(delete, in: app)
        delete.tap()
        let absent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["Пока нет измерений"].exists)
    }

    func testProfileDarkWithLargeText() {
        let app = launch(["--dark-mode", "--large-text"])
        let height = app.buttons["measurement.history.height"]
        reveal(height, in: app)
        height.tap()
        app.buttons["measurement.add"].tap()
        let value = app.textFields["measurement.editor.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap()
        value.typeText("52")
        app.buttons["measurement.editor.save"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurement.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("52"))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Рост — тёмная тема и крупный текст"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
