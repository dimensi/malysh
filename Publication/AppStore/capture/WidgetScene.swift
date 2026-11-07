
    func testStorefrontWidget() {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing", "--reset-data", "--widget-testing", "--storefront-fixture", "--light-mode",
            "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU",
        ]
        app.launch()
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        let springboard = home()
        XCUIDevice.shared.press(.home)
        let sleep = widgetHost("Сон", in: springboard)
        // WidgetKit may need time to replace its prior UI-test snapshot.
        let existing = widgetControl("widget.sleep.start", label: "Начать сон", in: sleep)
        if !existing.waitForExistence(timeout: 15) {
            installWidget("Сон", in: springboard, within: sleep)
        }
        waitForWidget("widget.sleep.start", label: "Начать сон", in: sleep)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "11-home-widget"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
