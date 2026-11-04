import XCTest

@MainActor
final class EventAuthorshipUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testNewEventKeepsCreatorAndRecordsEditorAfterRelaunch() {
        let app = launch()
        let diaper = app.buttons["action.diaper"]
        reveal(diaper, in: app)
        diaper.tap()
        let wet = app.buttons.matching(identifier: "diaper.wet").firstMatch
        XCTAssertTrue(wet.waitForExistence(timeout: 5))
        wet.tap()

        let row = eventRow(in: app, containing: "Подгузник")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        reveal(row, in: app)
        XCTAssertTrue(row.label.contains("Мокрый"))
        XCTAssertTrue(row.label.contains("Алексей · Папа"))
        row.tap()
        assertMetadata(in: app, id: "editor.created-by", contains: "Алексей · Папа")
        appendNote("Проверка автора", in: app)
        save(in: app)

        let edited = eventRow(in: app, containing: "Проверка автора")
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        reveal(edited, in: app)
        XCTAssertTrue(edited.label.contains("Подгузник"))
        XCTAssertTrue(edited.label.contains("Алексей · Папа"))
        edited.tap()
        assertMetadata(in: app, id: "editor.created-by", contains: "Алексей · Папа")
        assertMetadata(in: app, id: "editor.edited-by", contains: "Алексей · Папа")
        capture(app, name: "Автор и редактор новой записи")

        relaunch(app)
        let restored = eventRow(in: app, containing: "Проверка автора")
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        reveal(restored, in: app)
        XCTAssertTrue(restored.label.contains("Подгузник"))
        XCTAssertTrue(restored.label.contains("Мокрый"))
        XCTAssertTrue(restored.label.contains("Алексей · Папа"))
        restored.tap()
        assertMetadata(in: app, id: "editor.created-by", contains: "Алексей · Папа")
        assertMetadata(in: app, id: "editor.edited-by", contains: "Алексей · Папа")
    }

    func testLegacyEventKeepsUnknownCreatorWhenCurrentParentEditsIt() {
        let app = launch(legacy: true)
        let legacy = eventRow(in: app, containing: "Старая запись")
        XCTAssertTrue(legacy.waitForExistence(timeout: 5))
        reveal(legacy, in: app)
        XCTAssertTrue(legacy.label.contains("Бутылочка"))
        XCTAssertFalse(legacy.label.contains("Алексей · Папа"))
        legacy.tap()
        assertMetadata(in: app, id: "editor.created-by", contains: "Автор не указан")
        appendNote(" · Исправлено", in: app)
        save(in: app)

        let edited = eventRow(in: app, containing: "Старая запись")
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        reveal(edited, in: app)
        XCTAssertTrue(edited.label.contains("Бутылочка"))
        XCTAssertTrue(edited.label.contains("Исправлено"))
        edited.tap()
        assertMetadata(in: app, id: "editor.created-by", contains: "Автор не указан")
        assertMetadata(in: app, id: "editor.edited-by", contains: "Алексей · Папа")
        capture(app, name: "Неизвестный автор старой записи и известный редактор")

        relaunch(app, legacy: true)
        let restored = eventRow(in: app, containing: "Старая запись")
        XCTAssertTrue(restored.waitForExistence(timeout: 10))
        reveal(restored, in: app)
        XCTAssertTrue(restored.label.contains("Бутылочка"))
        XCTAssertTrue(restored.label.contains("Исправлено"))
        restored.tap()
        assertMetadata(in: app, id: "editor.created-by", contains: "Автор не указан")
        assertMetadata(in: app, id: "editor.edited-by", contains: "Алексей · Папа")
    }

    private func launch(legacy: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments(reset: true, legacy: legacy)
        app.launch()
        XCTAssertTrue(app.buttons["action.diaper"].waitForExistence(timeout: 10))
        return app
    }

    private func relaunch(_ app: XCUIApplication, legacy: Bool = false) {
        app.terminate()
        app.launchArguments = arguments(reset: false, legacy: legacy)
        app.launch()
        XCTAssertTrue(app.buttons["action.diaper"].waitForExistence(timeout: 10))
    }

    private func arguments(reset: Bool, legacy: Bool) -> [String] {
        ["--ui-testing", "--author-fixture", "--light-mode"]
            + (reset ? ["--reset-data"] : [])
            + (legacy ? ["--legacy-author-fixture"] : [])
    }

    private func eventRow(in app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "event.", text))
            .firstMatch
    }

    private func assertMetadata(in app: XCUIApplication, id: String, contains text: String) {
        let metadata = app.descendants(matching: .any).matching(identifier: id).firstMatch
        XCTAssertTrue(metadata.waitForExistence(timeout: 5))
        reveal(metadata, in: app)
        XCTAssertTrue(metadata.isHittable)
        XCTAssertTrue(metadata.label.contains(text))
        XCTAssertEqual(metadata.textFields.count, 0)
    }

    private func appendNote(_ text: String, in app: XCUIApplication) {
        let note = app.textFields["Заметка о событии"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        reveal(note, in: app)
        note.tap()
        note.typeText(text)
    }

    private func save(in app: XCUIApplication) {
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 {
            if element.isHittable {
                return
            }
            if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else if app.scrollViews.firstMatch.exists {
                app.scrollViews.firstMatch.swipeUp()
            } else {
                app.swipeUp()
            }
        }
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
