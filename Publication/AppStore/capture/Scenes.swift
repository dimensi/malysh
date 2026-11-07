
/// Screenshot driver included only in a temporary source checkout.
@MainActor
final class StorefrontScenes: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDiaryScreens() {
        let app = launch()
        let tabs = app.tabBars.buttons
        tap(app.buttons["child.profile.open"], open: false)
        shot("01-today")

        tap(tabs["История"])
        tap(app.navigationBars["История"], open: false)
        shot("04-history")
        shot("01-family-parent")

        tap(tabs["Статистика"])
        tap(app.navigationBars["Статистика"], open: false)
        shot("05-statistics")

        tap(tabs["Малыш"])
        tap(app.staticTexts["child.profile.name"], open: false)
        shot("06-profile")
        tap(app.buttons["measurement.history.weight"])
        tap(app.navigationBars["Вес"], open: false)
        shot("06a-weight")

        tap(tabs["Сегодня"])
        tap(app.buttons["photo.gallery.open"])
        tap(app.navigationBars["Фотографии малыша"], open: false)
        shot("08-gallery")
        tap(app.buttons["photo.gallery.close"])

        tap(app.buttons["settings.open"])
        tap(app.staticTexts["Общий дневник"], open: false)
        shot("07-family")
    }

    func testSupportLinksAtAccessibilitySize() {
        let app = launch(appearance: ["--dark-mode", "--large-text"])
        tap(app.buttons["settings.open"])
        verifySupportLinks(in: app)
    }

    private func verifySupportLinks(in app: XCUIApplication) {
        let support = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Поддержка"))
            .firstMatch
        let privacy = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Политика конфиденциальности")
        ).firstMatch
        for _ in 0 ..< 8 where !privacy.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(support.isHittable)
        XCTAssertTrue(privacy.isHittable)
    }

    func testFeedingAndIsland() {
        let app = launch(appearance: ["--light-mode", "--widget-testing"])
        tap(app.buttons["action.feed"])
        tap(app.buttons.matching(identifier: "feed.left").firstMatch)
        tap(timer(in: app), open: false)
        shot("02-feeding")

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        allowActivities(in: springboard)
        // A second Home press returns to the first Home page.
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.031)).press(forDuration: 1.2)
        let finish = springboard.buttons["Завершить кормление"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 5) && finish.isHittable)
        shot("12a-dynamic-island-expanded")
    }

    func testSleepAndLockScreen() {
        let app = launch()
        tap(app.buttons["action.sleep"])
        tap(timer(in: app), open: false)
        shot("03-sleep")

        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        allowActivities(in: springboard)
        let cover = springboard.windows["SBCoverSheetWindow"]
        for _ in 0 ..< 3 where !cover.isHittable {
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.005))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.12, dy: 0.71)
                ))
        }
        XCTAssertTrue(cover.isHittable)
        let finish = cover.buttons["Завершить сон"]
        for _ in 0 ..< 3 {
            allowActivities(in: springboard)
            if finish.waitForExistence(timeout: 9), finish.isHittable {
                Thread.sleep(forTimeInterval: 1)
                allowActivities(in: springboard)
                let prompt = springboard.buttons["Разрешать всегда"].firstMatch
                XCTAssertFalse(prompt.exists && prompt.isHittable)
                shot("10-lock-screen")
                return
            }
            cover.scrollViews.firstMatch.swipeUp()
        }
        XCTFail("Карточка сна не появилась на экране блокировки")
    }

    func testPDFReport() {
        let app = launch()
        tap(app.tabBars.buttons["Малыш"])
        let pdf = app.buttons["child.profile.report"]
        for _ in 0 ..< 5 where !pdf.isHittable { app.swipeUp() }
        tap(pdf)
        tap(app.buttons["diary.pdf.share"], open: false)
        shot("15-pediatrician-pdf")
    }

    func testDuoScreens() {
        let app = launch()
        tap(app.buttons["child.profile.open"], open: false)
        shot("01-today")
        Thread.sleep(forTimeInterval: 5) // Host captures the active Duo display explicitly.
        tap(app.buttons["История"].firstMatch)
        shot("04-history")
        Thread.sleep(forTimeInterval: 5)
        tap(app.buttons["Статистика"].firstMatch)
        shot("05-statistics")
        Thread.sleep(forTimeInterval: 5)
    }

    func testToday() {
        let app = launch()
        tap(app.buttons["child.profile.open"], open: false)
        shot("01-today")
    }

    func testWelcome() {
        let app = launch(onboarding: true)
        tap(app.buttons["onboarding.create"], open: false)
        shot("09-onboarding")
    }

    private func launch(onboarding: Bool = false, appearance: [String] = ["--light-mode"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-data",
            onboarding ? "--test-onboarding" : "--storefront-fixture",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
        ] + appearance
        app.launch()
        return app
    }

    private func timer(in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "timer.finish.")).firstMatch
    }

    private func allowActivities(in springboard: XCUIApplication) {
        for title in ["Always Allow", "Allow", "Разрешать всегда", "Всегда разрешать", "Разрешить"] {
            let button = springboard.buttons[title].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
    }

    private func tap(_ element: XCUIElement, open: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element)", file: file, line: line)
        if open {
            XCTAssertTrue(element.isHittable, "\(element)", file: file, line: line)
            element.tap()
        }
    }

    private func shot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
