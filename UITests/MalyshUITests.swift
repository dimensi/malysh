import XCTest

@MainActor
final class MalyshUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(reset: Bool = true, appearance: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-data"] : []) + appearance
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        return app
    }

    private func tap(_ app: XCUIApplication, id: String, label: String? = nil) {
        if id.hasPrefix("feed.") || id.hasPrefix("diaper.") {
            let action = app.descendants(matching: .any).matching(identifier: id).firstMatch
            if action.waitForExistence(timeout: 2) {
                action.tap()
                return
            }
            guard let label else { XCTFail("Не найдена кнопка \(id)"); return }
            let sheetAction = app.sheets.buttons[label].firstMatch
            if sheetAction.waitForExistence(timeout: 2) {
                sheetAction.tap()
                return
            }
            let fallback = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label))
                .firstMatch
            XCTAssertTrue(fallback.waitForExistence(timeout: 5))
            fallback.tap()
            return
        }
        let identified = app.buttons[id]
        if identified.waitForExistence(timeout: 2) {
            reveal(identified, in: app); identified.tap(); return
        }
        guard let label else { XCTFail("Не найдена кнопка \(id)"); return }
        let fallback = app.buttons[label]
        XCTAssertTrue(fallback.waitForExistence(timeout: 5))
        fallback.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 {
            if element.isHittable {
                return
            }
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeUp()
            } else if app.collectionViews.firstMatch.exists {
                app.collectionViews.firstMatch.swipeUp()
            } else {
                app.swipeUp()
            }
        }
    }

    private func button(_ app: XCUIApplication, prefix: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDiaperPersistsCanBeEditedAndDeleted() {
        let app = launch()
        tap(app, id: "action.diaper")
        tap(app, id: "diaper.wet", label: "Мокрый")
        XCTAssertTrue(button(app, prefix: "event.").waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let row = button(app, prefix: "event.")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        reveal(row, in: app)
        row.tap()
        let note = app.textFields["Заметка о событии"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        reveal(note, in: app)
        note.tap()
        note.typeText("Проверено")
        tap(app, id: "editor.save")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Проверено"].waitForExistence(timeout: 5))
        reveal(row, in: app)
        row.tap()
        let delete = app.buttons["editor.delete"]
        for _ in 0 ..< 5 where !delete.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.descendants(matching: .any).matching(identifier: "editor.confirm-delete").firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let absent = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: button(app, prefix: "event.")
        )
        XCTAssertEqual(XCTWaiter.wait(for: [absent], timeout: 5), .completed)
    }

    func testBreastAndSleepTimersSurviveRestart() {
        let app = launch()
        tap(app, id: "action.feed")
        tap(app, id: "feed.left", label: "Левая грудь")
        let switchSide = button(app, prefix: "timer.switch.")
        XCTAssertTrue(switchSide.waitForExistence(timeout: 5))
        reveal(switchSide, in: app)
        switchSide.tap()
        let finishBreast = button(app, prefix: "timer.finish.")
        XCTAssertTrue(finishBreast.waitForExistence(timeout: 5))
        reveal(finishBreast, in: app)
        finishBreast.tap()
        tap(app, id: "action.sleep")
        XCTAssertTrue(button(app, prefix: "timer.finish.").waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        let finishSleep = button(app, prefix: "timer.finish.")
        XCTAssertTrue(finishSleep.waitForExistence(timeout: 10))
        reveal(finishSleep, in: app)
        finishSleep.tap()
        app.tabBars.buttons["История"].tap()
        XCTAssertTrue(button(app, prefix: "event.").waitForExistence(timeout: 5))
        capture(app, name: "История кормления и сна")
        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.navigationBars["Статистика"].waitForExistence(timeout: 5))
        capture(app, name: "Статистика кормления и сна")
    }

    func testBottleAndAccessibleAppearances() {
        let app = launch(appearance: ["--large-text", "--dark-mode"])
        tap(app, id: "action.feed")
        tap(app, id: "feed.bottle", label: "Бутылочка")
        let volume = app.steppers["editor.volume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        reveal(volume, in: app)
        let adjustmentButtons = volume.buttons.allElementsBoundByIndex
        XCTAssertFalse(adjustmentButtons.isEmpty)
        adjustmentButtons.last?.tap()
        tap(app, id: "editor.save")
        XCTAssertTrue(button(app, prefix: "event.").waitForExistence(timeout: 5))
        reveal(button(app, prefix: "event."), in: app)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "61 мл")).firstMatch
            .waitForExistence(timeout: 5))
        capture(app, name: "Сегодня — тёмная тема и крупный текст")
        app.tabBars.buttons["Статистика"].tap()
        XCTAssertTrue(app.navigationBars["Статистика"].waitForExistence(timeout: 5))
        capture(app, name: "Статистика — тёмная тема и крупный текст")
        app.terminate()
        app.launchArguments = ["--ui-testing", "--light-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        capture(app, name: "Сегодня — светлая тема")
    }

    func testFamilySettingsLightWithLargeText() {
        assertFamilySettings(appearance: "--light-mode", screenshot: "Семья — светлая тема и крупный текст")
    }

    func testFamilySettingsDarkWithLargeText() {
        assertFamilySettings(appearance: "--dark-mode", screenshot: "Семья — тёмная тема и крупный текст")
    }

    /// A local rendering fixture: these checks do not exercise CloudKit delivery or acceptance.
    private func assertFamilySettings(appearance: String, screenshot: String) {
        let app = launch(appearance: ["--family-fixture", "--large-text", appearance])
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "family.header").firstMatch.exists)
        tap(app, id: "settings.open")
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["baby-name"].value as? String, "Семейный малыш")
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "diary-picker").firstMatch.exists)

        let status = app.staticTexts.matching(identifier: "family.status").firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        reveal(status, in: app)
        XCTAssertTrue(status.label.contains("Общий дневник"))

        let owner = app.descendants(matching: .any).matching(identifier: "family.member.owner").firstMatch
        XCTAssertTrue(owner.waitForExistence(timeout: 5))
        reveal(owner, in: app)
        XCTAssertTrue(owner.isHittable)
        XCTAssertTrue(owner.label.contains("Другой родитель"))
        XCTAssertTrue(owner.label.contains("Владелец дневника"))
        XCTAssertTrue(owner.label.contains("В семье"))

        let participant = app.descendants(matching: .any).matching(identifier: "family.member.participant-1").firstMatch
        XCTAssertTrue(participant.waitForExistence(timeout: 5))
        reveal(participant, in: app)
        XCTAssertTrue(participant.isHittable)
        XCTAssertTrue(participant.label.contains("Вы"))
        XCTAssertTrue(participant.label.contains("Родитель"))
        XCTAssertTrue(participant.label.contains("В семье"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "family.loading").firstMatch.exists)
        capture(app, name: screenshot)

        let access = app.buttons["invite-family"]
        reveal(access, in: app)
        XCTAssertTrue(access.label.contains("Управлять доступом"))
    }

    func testManualSleepAppearsInHistory() {
        let app = launch()
        tap(app, id: "manual.add")
        tap(app, id: "manual.sleep", label: "Сон вручную")
        tap(app, id: "editor.save")
        app.tabBars.buttons["История"].tap()
        let row = button(app, prefix: "event.")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.textFields["Заметка о событии"].waitForExistence(timeout: 5))
    }
}
