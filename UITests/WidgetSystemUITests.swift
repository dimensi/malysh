import XCTest

/// Exercises the real SpringBoard host. Attachments are system evidence, not view renders.
@MainActor
final class WidgetSystemUITests: XCTestCase {
    private var keyboardRecoveryNeeded = false

    override func setUp() async throws {
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

    override func tearDown() async throws {
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["--ui-testing", "--end-widget-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        app.terminate()
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
        if identified.exists {
            return identified
        }
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    func testInstalledMediumWidgetShowsInteractiveControls() {
        _ = launchIsolatedDiary()
        let springboard = home()
        installMedium(in: springboard)
        for (identifier, label) in [
            ("widget.breast.left", "Начать кормление левой грудью"),
            ("widget.diaper.wet", "Мокрый подгузник"),
            ("widget.diaper.dirty", "Стул"),
            ("widget.sleep.start", "Начать сон"),
        ] {
            waitForWidget(identifier, label: label, in: springboard)
        }
        attach(springboard, stage: "Native widget gallery — installed interactive medium")
    }

    func testColdBreastControlsSwitchAndFinishTheSamePersistedEvent() {
        let app = launchIsolatedDiary()
        let springboard = home()
        installMedium(in: springboard)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        tapWidget("widget.breast.left", label: "Начать кормление левой грудью", in: springboard, app: app,
                  repeated: true)
        waitForWidget("widget.breast.finish", label: "Завершить кормление", in: springboard)
        tapWidget("widget.breast.switch", label: "Сменить грудь", in: springboard, app: app)
        attach(springboard, stage: "Interactive breast — cold start and side switch")
        relaunch(app)
        XCTAssertEqual(timers(app).count, 1)
        XCTAssertTrue(app.staticTexts["Кормление · правая грудь"].waitForExistence(timeout: 10))
        let eventID = String(timers(app).firstMatch.identifier.dropFirst("timer.finish.".count))
        _ = home()
        app.terminate()
        tapWidget("widget.breast.finish", label: "Завершить кормление", in: springboard, app: app)
        waitForWidget("widget.breast.left", label: "Начать кормление левой грудью", in: springboard)
        XCTAssertNotEqual(app.state, .runningForeground)
        app.terminate()
        relaunch(app)
        XCTAssertEqual(timers(app).count, 0)
        assertSavedEvent(eventID, in: app)
        XCTAssertEqual(events(app).count, 1, "Starting, switching and finishing must update one Core Data event")
        attach(app, stage: "Interactive breast — one completed event after relaunch")
    }

    func testColdDiaperControlsPersistWetAndStoolWithoutOpeningApp() {
        let app = launchIsolatedDiary()
        let springboard = home()
        installMedium(in: springboard)
        app.terminate()
        tapWidget("widget.diaper.wet", label: "Мокрый подгузник", in: springboard, app: app, repeated: true)
        // Observe the first committed save before sending another independent action.
        relaunch(app)
        XCTAssertTrue(events(app).firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(events(app).count, 1)
        let firstID = events(app).firstMatch.identifier
        XCTAssertTrue(events(app).firstMatch.label.contains("Мокрый"))
        _ = home()
        app.terminate()
        tapWidget("widget.diaper.dirty", label: "Стул", in: springboard, app: app)
        relaunch(app)
        let committed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 2"), object: events(app))
        XCTAssertEqual(XCTWaiter.wait(for: [committed], timeout: 10), .completed)
        XCTAssertTrue(app.buttons[firstID].exists)
        XCTAssertTrue(events(app).allElementsBoundByIndex.contains { $0.label.contains("Стул") })
        XCTAssertEqual(timers(app).count, 0)
        app.terminate()
        relaunch(app)
        XCTAssertEqual(events(app).count, 2, "Both diaper records must survive a full application restart")
        attach(app, stage: "Interactive diapers — wet and stool persisted after cold dispatch")
    }

    func testColdSleepControlsPersistOneTimerAndAgreeWithLiveActivity() {
        let app = launchIsolatedDiary()
        let springboard = home()
        installMedium(in: springboard)
        app.terminate()
        tapWidget("widget.sleep.start", label: "Начать сон", in: springboard, app: app, repeated: true)
        waitForWidget("widget.sleep.finish", label: "Завершить сон", in: springboard)
        relaunch(app)
        XCTAssertEqual(timers(app).count, 1)
        let eventID = String(timers(app).firstMatch.identifier.dropFirst("timer.finish.".count))
        _ = home()
        let cover = notificationCenter(in: springboard)
        let activityFinish = cover.buttons["Завершить сон"].firstMatch
        XCTAssertTrue(activityFinish.waitForExistence(timeout: 20), cover.debugDescription)
        attach(springboard, stage: "Interactive sleep — same active timer in Live Activity")
        _ = home()
        app.terminate()
        tapWidget("widget.sleep.finish", label: "Завершить сон", in: springboard, app: app)
        waitForWidget("widget.sleep.start", label: "Начать сон", in: springboard)
        let endedCover = notificationCenter(in: springboard)
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false OR hittable == false"),
            object: endedCover.buttons["Завершить сон"].firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 30), .completed)
        XCTAssertNotEqual(app.state, .runningForeground)
        app.terminate()
        relaunch(app)
        XCTAssertEqual(timers(app).count, 0)
        assertSavedEvent(eventID, in: app)
        XCTAssertEqual(events(app).count, 1)
        attach(app, stage: "Interactive sleep — completed event and no duplicate timer")
    }

    private func launchIsolatedDiary() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data", "--widget-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        return app
    }

    private func relaunch(_ app: XCUIApplication) {
        app.launchArguments = ["--ui-testing", "--widget-testing"]
        if app.state == .notRunning {
            app.launch()
        } else {
            app.activate()
        }
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
    }

    private func widgetControl(_ identifier: String, label: String, in springboard: XCUIApplication) -> XCUIElement {
        let identified = springboard.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if identified.exists {
            return identified
        }
        return springboard.buttons[label].firstMatch
    }

    private func waitForWidget(_ identifier: String, label: String, in springboard: XCUIApplication) {
        logTiming("wait.begin", control: identifier)
        let control = widgetControl(identifier, label: label, in: springboard)
        XCTAssertTrue(control.waitForExistence(timeout: 30), springboard.debugDescription)
        logTiming("wait.observed", control: identifier)
    }

    private func logTiming(_ stage: String, control: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        print(
            "WIDGET_UI_TIMING stage=\(stage) control=\(control) utc=\(formatter.string(from: Date())) uptime=\(ProcessInfo.processInfo.systemUptime)"
        )
    }

    private func tapWidget(_ identifier: String, label: String, in springboard: XCUIApplication,
                           app: XCUIApplication, repeated: Bool = false)
    {
        let control = widgetControl(identifier, label: label, in: springboard)
        XCTAssertTrue(control.waitForExistence(timeout: 30), springboard.debugDescription)
        XCTAssertTrue(control.isHittable)
        logTiming("tap.begin", control: identifier)
        if repeated {
            control.doubleTap()
        } else {
            control.tap()
        }
        logTiming("tap.end", control: identifier)
        XCTAssertNotEqual(app.state, .runningForeground, "An interactive widget action must stay on Home")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 5))
    }

    private func events(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "event."))
    }

    private func assertSavedEvent(_ id: String, in app: XCUIApplication) {
        let row = app.buttons["event." + id]
        if !row.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10))
    }

    private func notificationCenter(in springboard: XCUIApplication) -> XCUIElement {
        let cover = springboard.windows["SBCoverSheetWindow"]
        for _ in 0 ..< 3 {
            if cover.exists, cover.isHittable {
                return cover
            }
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.005))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.1, dy: 0.65)
                ))
            if cover.waitForExistence(timeout: 5), cover.isHittable {
                for label in ["Always Allow", "Allow", "Всегда разрешать", "Разрешить"] {
                    let button = springboard.buttons[label].firstMatch
                    if button.exists, button.isHittable {
                        button.tap()
                    }
                }
                cover.scrollViews.firstMatch.swipeUp()
                return cover
            }
        }
        XCTFail("Notification Center did not open")
        return cover
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
        let installed = widgetControl("widget.sleep.start", label: "Начать сон", in: springboard)
        if installed.exists, installed.isHittable {
            return
        }
        // A second Home press returns from Today/App Library to the first Home page.
        XCUIDevice.shared.press(.home)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.79)).press(forDuration: 2)
        attach(springboard, stage: "Native widget gallery — Home edit entry")
        let edit = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Edit", "Изменить", "Править"]))
            .firstMatch
        guard edit.waitForExistence(timeout: 5) else {
            XCTFail("Home editing did not expose its native Edit button; inspect attachment")
            return
        }
        edit.tap()
        attach(springboard, stage: "Native widget gallery — Edit menu")
        let add = springboard.buttons.matching(NSPredicate(format: "label IN %@", [
            "Add Widget", "Add Widgets", "Добавить виджет", "Добавить виджеты",
        ])).firstMatch
        guard add.waitForExistence(timeout: 5) else {
            XCTFail("Native Edit menu did not expose Add Widget; inspect attachment")
            return
        }
        add.tap()
        attach(springboard, stage: "Native widget gallery — opened catalog")
        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 5) else {
            attach(springboard, stage: "Native widget gallery — missing catalog search")
            XCTFail("Widget catalog has no search field")
            return
        }
        search.tap()
        search.typeText("Малыш")
        attach(springboard, stage: "Native widget gallery — Малыш search results")
        let provider = springboard.cells.matching(NSPredicate(format: "label == %@", "Малыш")).firstMatch
        guard provider.waitForExistence(timeout: 10), provider.isHittable else {
            attach(springboard, stage: "Native widget gallery — missing Малыш provider")
            XCTFail("Widget catalog did not offer the Малыш provider row")
            return
        }
        provider.tap()
        attach(springboard, stage: "Native widget gallery — Малыш descriptor picker")
        let quickActions = springboard.staticTexts["Быстрые действия"].firstMatch
        for _ in 0 ..< 14 {
            if quickActions.exists, quickActions.isHittable {
                break
            }
            springboard.swipeLeft()
        }
        guard quickActions.exists, quickActions.isHittable else {
            attach(springboard, stage: "Native widget gallery — missing quick actions descriptor")
            XCTFail("Widget picker did not expose Быстрые действия")
            return
        }
        attach(springboard, stage: "Native widget gallery — selected Быстрые действия medium")
        let addWidget = springboard.buttons.matching(NSPredicate(format: "label IN %@", [
            "Add Widget", "Add Widgets", "Добавить виджет", "Добавить виджеты",
        ])).firstMatch
        guard addWidget.waitForExistence(timeout: 5) else {
            attach(springboard, stage: "Native widget gallery — missing Add Widget confirmation")
            XCTFail("Selected descriptor did not expose Add Widget")
            return
        }
        addWidget.tap()
        let done = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "Готово"])).firstMatch
        guard done.waitForExistence(timeout: 5) else {
            attach(springboard, stage: "Native widget gallery — missing Home Done")
            XCTFail("Adding widget did not return to Home editing")
            return
        }
        done.tap()
        waitForWidget("widget.sleep.start", label: "Начать сон", in: springboard)
        attach(springboard, stage: "Native widget gallery — installed on Home")
    }

    private func timers(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timer.finish."))
    }
}
