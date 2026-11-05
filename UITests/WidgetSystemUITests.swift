import XCTest

/// Exercises the real SpringBoard host. Attachments are system evidence, not view renders.
@MainActor
final class WidgetSystemUITests: XCTestCase {
    private var keyboardRecoveryNeeded = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "System keyboard introduction") { [weak self] alert in
            let tutorial = alert.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Speed up your typing'"))
            let next = alert.buttons["Continue"].firstMatch
            guard tutorial.firstMatch.exists, next.exists else { return false }
            next.tap()
            self?.keyboardRecoveryNeeded = true
            return true
        }
    }

    private func attach(_ app: XCUIApplication, stage: String) {
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = stage
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = stage + " — accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        print("WIDGET_SYSTEM_STAGE: " + stage)
    }

    private func dialogAction(_ identifier: String, label: String, app: XCUIApplication) -> XCUIElement {
        let identified = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if identified.waitForExistence(timeout: 5) {
            return identified
        }
        // Sheet dismissal and route presentation are asynchronous. A static text
        // with this label can belong to an existing event, not the chooser.
        return app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testInstalledMediumWidgetShowsDiaryDataAndOpensShortcuts() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data", "--widget-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        seedDiary(app)
        attach(app, stage: "Ordinary widget — seeded diary")
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 5))

        let springboard = home()
        installMedium(in: springboard)
        let bottle = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'Бутылочка'")
        ).firstMatch
        let populated = bottle.waitForExistence(timeout: 30)
        attach(springboard, stage: "Ordinary widget — installed medium with real diary data")
        guard populated else {
            XCTFail("Installed widget must show the seeded bottle feeding, not a placeholder")
            return
        }
        openShortcut("Подгузник", springboard: springboard, app: app)
        let wet = dialogAction("diaper.wet", label: "Мокрый", app: app)
        XCTAssertTrue(wet.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Настройки"].exists)
        attach(app, stage: "Ordinary widget — diaper chooser after Settings dismissal")
        wet.tap()
        app.buttons["child.profile.open"].tap()
        XCTAssertTrue(app.navigationBars["Профиль ребёнка"].waitForExistence(timeout: 5))
        app.buttons["child.profile.edit"].tap()
        XCTAssertTrue(app.navigationBars["Изменить профиль"].waitForExistence(timeout: 5))

        _ = home()
        openShortcut("Грудь", springboard: springboard, app: app)
        let left = dialogAction("feed.left", label: "Левая грудь", app: app)
        XCTAssertTrue(left.waitForExistence(timeout: 5))
        XCTAssertFalse(app.navigationBars["Профиль ребёнка"].exists)
        XCTAssertFalse(app.navigationBars["Изменить профиль"].exists)
        XCTAssertEqual(timers(app).count, 0)
        attach(app, stage: "Ordinary widget — breast chooser after profile dismissal")
        left.tap()
        let finish = timers(app).firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        for _ in 0 ..< 4 where !finish.isHittable {
            app.swipeDown()
        }
        finish.tap()

        _ = home()
        openShortcut("Сон", springboard: springboard, app: app)
        let start = dialogAction("widget.sleep.start", label: "Начать сон", app: app)
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertEqual(timers(app).count, 0)
        attach(app, stage: "Ordinary widget — sleep chooser requires confirmation")
        start.tap()
        XCTAssertTrue(timers(app).firstMatch.waitForExistence(timeout: 5))
        let timerID = timers(app).firstMatch.identifier
        _ = home()
        attach(springboard, stage: "Ordinary widget — Home widget while sleep timer is active")
        openShortcut("Сон", springboard: springboard, app: app)
        XCTAssertTrue(timers(app).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(timers(app).count, 1)
        XCTAssertEqual(timers(app).firstMatch.identifier, timerID)
    }

    private func seedDiary(_ app: XCUIApplication) {
        app.buttons["action.feed"].tap()
        let bottle = dialogAction("feed.bottle", label: "Бутылочка", app: app)
        XCTAssertTrue(bottle.waitForExistence(timeout: 5))
        bottle.tap()
        let save = app.buttons["editor.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        app.buttons["action.diaper"].tap()
        let wet = dialogAction("diaper.wet", label: "Мокрый", app: app)
        XCTAssertTrue(wet.waitForExistence(timeout: 5))
        wet.tap()
    }

    private func home() -> XCUIApplication {
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        _ = recoverKeyboardIfNeeded(in: springboard)
        return springboard
    }

    private func dismissKeyboardTutorial(in springboard: XCUIApplication) {
        let tutorial = springboard.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Speed up your typing'")
        ).firstMatch
        let next = springboard.buttons["Continue"].firstMatch
        if tutorial.exists, next.exists, next.isHittable {
            next.tap()
            keyboardRecoveryNeeded = true
        }
    }

    @discardableResult
    private func recoverKeyboardIfNeeded(in springboard: XCUIApplication) -> Bool {
        dismissKeyboardTutorial(in: springboard)
        guard keyboardRecoveryNeeded || springboard.keyboards.firstMatch.exists else { return false }
        keyboardRecoveryNeeded = false
        // Continue removes the tutorial but can leave its remote keyboard over Home.
        // Native Home dismisses that keyboard and the affected context menu together.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
        return true
    }

    private func installMedium(in springboard: XCUIApplication) {
        let icon = springboard.icons["Малыш"].firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 5))
        if icon.value as? String == "Widget" {
            return
        }
        // A fresh simulator queues all system widget catalogs. The first context
        // menu can precede our descriptor; its contents do not update in place.
        for attempt in 0 ..< 2 {
            icon.press(forDuration: 1.5)
            if recoverKeyboardIfNeeded(in: springboard) {
                // Reopen the interrupted menu within this same catalog attempt.
                icon.press(forDuration: 1.5)
            }
            let medium = springboard.buttons["Medium-sized widget"].firstMatch
            if medium.waitForExistence(timeout: 5) {
                medium.tap()
                return
            }
            attach(springboard, stage: "Ordinary widget — catalog menu attempt \(attempt + 1)")
            if attempt == 0 {
                _ = home()
            }
        }
        XCTFail("SpringBoard did not offer medium size after reopening its initial catalog menu once")
    }

    private func openShortcut(_ label: String, springboard: XCUIApplication, app: XCUIApplication) {
        let shortcut = springboard.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Открыть: " + label)
        ).firstMatch
        guard shortcut.waitForExistence(timeout: 5) else {
            attach(springboard, stage: "Ordinary widget — missing installed shortcut " + label)
            XCTFail("Installed medium widget has no accessible " + label + " shortcut")
            return
        }
        // Tap the observed title outside the 26-point glyph to prove the whole row links.
        let title = springboard.staticTexts[label].firstMatch
        guard title.waitForExistence(timeout: 5) else {
            attach(springboard, stage: "Ordinary widget — missing tappable title " + label)
            XCTFail("Installed shortcut must expose its visible title outside the glyph")
            return
        }
        title.tap()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
    }

    private func timers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timer.finish."))
    }
}
