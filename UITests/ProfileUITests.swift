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

    func testMeasurementAddEditAndImmediateDelete() {
        let app = launch(["--dark-mode", "--large-text"])
        let weight = app.buttons["measurement.history.weight"]
        reveal(weight, in: app)
        weight.tap()
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
}
