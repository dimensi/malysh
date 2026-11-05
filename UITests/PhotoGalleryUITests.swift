import XCTest

@MainActor
final class PhotoGalleryUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-data"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["photo.gallery.open"].waitForExistence(timeout: 10))
        return app
    }

    private func firstPhoto(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo.grid.")).firstMatch
    }

    private func action(_ identifier: String, app: XCUIApplication) {
        app.buttons["photo.actions"].tap()
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        button.tap()
    }

    func testBrandFallbackAndProfileGalleryAccess() {
        let app = launch(["--light-mode"])
        app.buttons["photo.gallery.open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["photo.empty"].waitForExistence(timeout: 5))
        app.buttons["photo.gallery.close"].tap()
        app.buttons["child.profile.open"].tap()
        app.buttons["child.profile.photos"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["photo.empty"].waitForExistence(timeout: 5))
    }

    func testCameraSourceDialogIsOnHomeButton() {
        let app = launch()
        let source = app.buttons["photo.add"]
        XCTAssertTrue(source.isHittable)
        source.tap()
        XCTAssertTrue(app.buttons["Сфотографировать"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Выбрать из Фото"].exists)
        // Both options remain system controls; outside dismissal keeps the home header intact.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)).tap()
        XCTAssertTrue(app.buttons["child.profile.open"].exists)
    }

    func testDateGroupsFavoritePinAndImmediateDelete() {
        let app = launch(["--photo-fixtures", "--light-mode"])
        app.buttons["photo.gallery.open"].tap()
        XCTAssertTrue(firstPhoto(app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "photo.date.group").count, 2)
        let galleryLight = XCTAttachment(screenshot: app.screenshot())
        galleryLight.name = "Photo gallery light"
        galleryLight.lifetime = .keepAlways
        add(galleryLight)
        firstPhoto(app).tap()
        action("photo.favorite", app: app)
        action("photo.pin", app: app)
        action("photo.delete", app: app)
        XCTAssertFalse(app.alerts.firstMatch.exists)
        app.buttons["photo.viewer.close"].tap()
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo.grid.")).count, 1)
    }

    func testOlderPinnedAvatarPersistsAndDeletionFallsBackToNewestThenBrand() {
        let app = launch(["--photo-fixtures", "--light-mode"])
        let oldID = "00000000-0000-0000-0000-000000000001"
        let newID = "00000000-0000-0000-0000-000000000002"
        let avatar = app.buttons["photo.gallery.open"]
        XCTAssertEqual(avatar.value as? String, newID)
        let headerLight = XCTAttachment(screenshot: app.screenshot())
        headerLight.name = "Child photo header light"
        headerLight.lifetime = .keepAlways
        add(headerLight)
        avatar.tap()
        app.buttons["photo.grid.\(oldID)"].tap()
        action("photo.pin", app: app)
        app.buttons["photo.viewer.close"].tap()
        app.buttons["photo.gallery.close"].tap()
        XCTAssertEqual(avatar.value as? String, oldID)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--light-mode"]
        app.launch()
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertEqual(avatar.value as? String, oldID)
        avatar.tap()
        app.buttons["photo.grid.\(oldID)"].tap()
        action("photo.delete", app: app)
        app.buttons["photo.viewer.close"].tap()
        app.buttons["photo.gallery.close"].tap()
        XCTAssertEqual(avatar.value as? String, newID)
        avatar.tap()
        app.buttons["photo.grid.\(newID)"].tap()
        action("photo.delete", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["photo.empty"].waitForExistence(timeout: 5))
        app.buttons["photo.gallery.close"].tap()
        XCTAssertEqual(avatar.value as? String, "brand")
    }

    func testFullscreenPagingAndSystemShare() {
        let app = launch(["--photo-fixtures"])
        app.buttons["photo.gallery.open"].tap()
        let newID = "00000000-0000-0000-0000-000000000002"
        let oldID = "00000000-0000-0000-0000-000000000001"
        app.buttons["photo.grid.\(newID)"].tap()
        XCTAssertTrue(app.images["photo.full.\(newID)"].waitForExistence(timeout: 5))
        app.swipeLeft()
        let olderImage = app.images["photo.full.\(oldID)"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: olderImage)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        action("photo.share", app: app)
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 5)
            || app.buttons["Copy"].exists || app.buttons["Скопировать"].exists)
        app.swipeDown()
        XCTAssertTrue(app.buttons["photo.actions"].waitForExistence(timeout: 5))
        app.buttons["photo.viewer.close"].tap()
        XCTAssertTrue(firstPhoto(app).waitForExistence(timeout: 5))
    }

    func testDeniedCameraSaveShowsHomeErrorAndRetainsOriginalForRetry() {
        let app = launch(["--photo-camera-fixture", "--photo-permission-denied"])
        app.buttons["photo.add"].tap()
        let cameraSource = app.buttons.matching(identifier: "photo.source.camera").firstMatch
        XCTAssertTrue(cameraSource.waitForExistence(timeout: 5))
        cameraSource.tap()
        let shutter = app.buttons["photo.camera.shutter"]
        XCTAssertTrue(shutter.waitForExistence(timeout: 5))
        shutter.tap()
        XCTAssertTrue(app.alerts["Не удалось добавить фотографию"].waitForExistence(timeout: 8))
        app.alerts.buttons["Понятно"].tap()
        app.buttons["photo.gallery.open"].tap()
        let retry = app.buttons["photo.pending.retry"]
        for _ in 0 ..< 6 where !retry.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(retry.isHittable)
        retry.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Понятно"].tap()
        XCTAssertTrue(retry.exists)
    }

    func testInterruptedSaveRetainsRecoveryAndDoesNotDuplicate() {
        let app = launch(["--photo-fixtures", "--photo-save-pending"])
        app.buttons["photo.gallery.open"].tap()
        XCTAssertTrue(firstPhoto(app).waitForExistence(timeout: 5))
        let recovery = app.buttons["photo.pending.reconcile"]
        for _ in 0 ..< 6 where !recovery.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(recovery.isHittable)
        app.buttons["photo.pending.retry"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Понятно"].tap()
        XCTAssertTrue(recovery.exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "photo.grid.")).count, 2)
    }

    func testDarkLargeTypeAndDeniedAutomaticSave() {
        let app = launch(["--photo-fixtures", "--dark-mode", "--large-text", "--photo-permission-denied"])
        app.buttons["photo.gallery.open"].tap()
        XCTAssertTrue(firstPhoto(app).waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Photo gallery dark large text"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["photo.gallery.close"].tap()
        app.buttons["settings.open"].tap()
        let toggle = app.switches["photo.autoSave"]
        for _ in 0 ..< 6 where !toggle.isHittable {
            app.swipeUp()
        }
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Понятно"].tap()
        XCTAssertEqual(toggle.value as? String, "0")
    }
}
