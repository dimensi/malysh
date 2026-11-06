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
        app.tabBars.buttons["Малыш"].tap()
        let addMeasurement = app.buttons["child.measurement.add"]
        reveal(addMeasurement, in: app)
        addMeasurement.tap()
        let type = app.buttons["Вес"].firstMatch
        XCTAssertTrue(type.waitForExistence(timeout: 5))
        type.tap()
        let value = app.textFields["measurement.editor.value"]
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap()
        value.typeText("4200")
        app.buttons["measurement.editor.save"].tap()
        let weight = app.buttons["measurement.history.weight"]
        app.swipeDown()
        XCTAssertTrue(weight.isHittable)
        XCTAssertTrue(weight.label.contains("200"))
        weight.tap()
        XCTAssertTrue(app.navigationBars["Вес"].waitForExistence(timeout: 5))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurement.row.")).firstMatch
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("200"))
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

    func testProfileTabAndPrivateParentSettings() {
        let app = launch()
        let tabs = app.tabBars.buttons
        XCTAssertEqual(tabs.count, 4)
        for title in ["История", "Статистика", "Малыш", "Сегодня"] {
            tabs[title].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        }
        app.buttons["child.profile.open"].tap()
        XCTAssertTrue(tabs["Малыш"].isSelected)
        app.buttons["child.profile.edit"].tap()
        XCTAssertTrue(app.navigationBars["Изменить профиль"].waitForExistence(timeout: 5))
        XCTAssertTrue(tabs["Малыш"].exists)
        tabs["Сегодня"].tap()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["settings.child.open"].exists)
        XCTAssertFalse(app.textFields["baby-name"].exists)
        let parent = app.buttons["family.member.owner"]
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        parent.tap()
        let name = app.textFields["family.profile.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Nikita")
        let role = app.descendants(matching: .any).matching(identifier: "family.profile.role").firstMatch
        role.tap()
        app.buttons["Папа"].firstMatch.tap()
        app.buttons["family.profile.save"].tap()
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        XCTAssertTrue(parent.label.contains("Nikita"))
        XCTAssertTrue(parent.label.contains("Папа"))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 10))
        app.buttons["settings.open"].tap()
        XCTAssertTrue(parent.waitForExistence(timeout: 5))
        XCTAssertTrue(parent.label.contains("Nikita"))
        XCTAssertTrue(parent.label.contains("Папа"))
    }

    func testBirthMeasurementRequiresBirthdayAndCanBeEditedInHistory() {
        let app = launch()
        app.tabBars.buttons["Малыш"].tap()
        app.buttons["child.profile.edit"].tap()
        let birthWeight = app.textFields["child.editor.birth.weight"]
        reveal(birthWeight, in: app)
        birthWeight.tap()
        birthWeight.typeText("3200")
        app.buttons["child.editor.save"].tap()
        let error = app.alerts["Не удалось изменить профиль"]
        XCTAssertTrue(error.staticTexts.containing(NSPredicate(
            format: "label BEGINSWITH %@",
            "Укажите дату рождения"
        ))
        .firstMatch.waitForExistence(timeout: 5))
        error.buttons["Понятно"].tap()
        let setBirthDate = app.buttons["child.editor.setBirthDate"]
        XCTAssertTrue(setBirthDate.exists)
        setBirthDate.tap()
        app.buttons["child.editor.save"].tap()
        XCTAssertTrue(app.navigationBars["Малыш"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["child.profile.age"].exists)
        app.buttons["child.profile.edit"].tap()
        XCTAssertTrue(app.navigationBars["Изменить профиль"].waitForExistence(timeout: 5))
        XCTAssertFalse(birthWeight.exists)
        app.navigationBars["Изменить профиль"].buttons.firstMatch.tap()
        let weight = app.buttons["measurement.history.weight"]
        reveal(weight, in: app)
        weight.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "measurement.row.")).firstMatch
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("200"))
        row.tap()
        replace(app.textFields["measurement.editor.value"], with: "3300")
        app.buttons["measurement.editor.save"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("300"))
    }

    func testOptionalBirthTimePersistsAcrossLaunchAndCanBeRemoved() {
        let app = launch()
        app.tabBars.buttons["Малыш"].tap()
        let edit = app.buttons["child.profile.edit"]
        edit.tap()
        let addTime = app.buttons["child.editor.setBirthTime"]
        let removeTime = app.buttons["child.editor.removeBirthTime"]
        let save = app.buttons["child.editor.save"]
        XCTAssertFalse(addTime.exists)
        app.buttons["child.editor.setBirthDate"].tap()
        XCTAssertTrue(addTime.exists)
        XCTAssertFalse(removeTime.exists)
        addTime.tap()
        XCTAssertTrue(removeTime.exists)
        save.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.tabBars.buttons["Малыш"].tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(removeTime.waitForExistence(timeout: 5))
        removeTime.tap()
        save.tap()
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        XCTAssertTrue(addTime.waitForExistence(timeout: 5))
        XCTAssertFalse(removeTime.exists)
    }
}
