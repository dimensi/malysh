
/// Uses the existing real widget extension and lets SpringBoard choose the layout.
@MainActor
final class StorefrontLiveActivityScenes: XCTestCase {
    func testNativeLockScreenStates() {
        continueAfterFailure = false
        // Previous manual capture may have physically locked this test-only device.
        XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cover = system.windows["SBCoverSheetWindow"]
        if cover.exists && cover.isHittable {
            system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
                .press(forDuration: 0.05, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
        }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data", "--storefront-fixture",
                               "--storefront-live-states", "--light-mode",
                               "-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launch()
        XCTAssertTrue(app.buttons["child.profile.open"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 3)
        XCUIDevice.shared.press(.home)
        for _ in 0 ..< 3 where !cover.isHittable {
            system.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.005))
                .press(forDuration: 0.05, thenDragTo: system.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.71)))
        }
        XCTAssertTrue(cover.isHittable)
        let controls = ["Завершить кормление", "Завершить сон", "Начать кормление левой грудью"]
        for _ in 0 ..< 6 {
            if controls.allSatisfy({ cover.buttons[$0].firstMatch.isHittable }) { break }
            // iOS initially groups an app's activities. Expand the real system group,
            // including a first-run permission that can be hidden inside that group.
            let less = cover.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Показать меньше")).firstMatch
            if !less.exists {
                // Simulator 27.2 exposes the collapsed ListCell with y=0 in XCTest,
                // although SpringBoard draws the group near the bottom of the screen.
                // Tap the visible group's body, away from the real action buttons.
                system.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.77)).tap()
            }
            for title in ["Always Allow", "Allow", "Разрешать всегда", "Всегда разрешать", "Разрешить"] {
                let button = system.buttons[title].firstMatch
                if button.exists && button.isHittable { button.tap() }
            }
            Thread.sleep(forTimeInterval: 1)
        }
        for title in controls {
            XCTAssertTrue(cover.buttons[title].firstMatch.isHittable,
                          "Native activity is not visibly expanded: \(title)")
        }
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "16-live-activities-lock-screen"
        screen.lifetime = .keepAlways
        add(screen)
        let hierarchy = XCTAttachment(string: system.debugDescription)
        hierarchy.name = "16-live-activities-system-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
