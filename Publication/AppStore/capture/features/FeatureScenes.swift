
/// App Store capture code compiled only into a disposable UI-test build.
@MainActor
final class StorefrontFeatureScenes: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    func testPediatricianPDF() {
        let app = launch()
        let childTab = app.tabBars.buttons["Малыш"]
        XCTAssertTrue(childTab.waitForExistence(timeout: 10))
        childTab.tap()
        let report = app.buttons["child.profile.report"]
        reveal(report, in: app)
        report.tap()
        XCTAssertTrue(app.buttons["diary.pdf.share"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["diary.pdf.settings"].label.contains("Краткий отчёт"))
        shot("15-pediatrician-pdf")
    }

    func testReminder() {
        let app = launch(extra: ["--storefront-reminder-system"])
        let settings = app.buttons["settings.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()
        let toggle = app.switches["feeding-reminder.enabled"]
        reveal(toggle, in: app)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let permission = system.alerts.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "Разрешить"]))
            .firstMatch
        if permission.waitForExistence(timeout: 3), permission.isHittable { permission.tap() }

        let status = app.staticTexts["feeding-reminder.status"]
        reveal(status, in: app)
        let scheduled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Следующее напоминание"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [scheduled], timeout: 10), .completed)
        shot("13-feeding-reminder")

        XCUIDevice.shared.press(.home)
        let cover = system.windows["SBCoverSheetWindow"]
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.005))
            .press(forDuration: 0.05, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.71)))
        let reminder = cover.buttons["Напомнить через 15 минут"].firstMatch
        let alternate = cover.staticTexts["Кормление"].firstMatch
        if reminder.waitForExistence(timeout: 49), reminder.isHittable {
            allowLiveActivity(in: system)
            shot("14-reminder-live")
        } else if alternate.exists, alternate.isHittable {
            allowLiveActivity(in: system)
            shot("14-reminder-notification")
        } else {
            XCTFail("Настоящее системное напоминание не появилось")
        }
        // Stop the reminder through its real switch before another capture scene.
        app.activate()
        reveal(toggle, in: app)
        if toggle.value as? String == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 7 where !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.81))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.50, dy: 0.55)))
        }
        XCTAssertTrue(element.isHittable, "\(element)")
    }

    private func launch(extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-data", "--light-mode", "--storefront-fixture",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
        ] + extra
        app.launch()
        return app
    }

    private func allowLiveActivity(in system: XCUIApplication) {
        for label in ["Разрешать всегда", "Разрешить", "Always Allow", "Allow"] {
            let button = system.buttons[label].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
