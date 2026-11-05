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

    func testOlderPinnedAvatarPersistsAndDeletionFallsBackToNewestThenBrand() {
        let app = launch(["--photo-fixtures", "--light-mode"])
        let oldID = "00000000-0000-0000-0000-000000000001"
        let newID = "00000000-0000-0000-0000-000000000002"
        let avatar = app.buttons["photo.gallery.open"]
        let profileAvatar = app.buttons["child.profile.avatar"]
        func checkProfileAvatar(_ expected: String?) {
            app.tabBars.buttons["Малыш"].tap()
            XCTAssertTrue(profileAvatar.waitForExistence(timeout: 5))
            XCTAssertEqual(profileAvatar.value as? String, expected)
            app.tabBars.buttons["Сегодня"].tap()
        }
        let newestValue = avatar.value as? String
        XCTAssertNotNil(newestValue)
        XCTAssertTrue(newestValue?.hasPrefix("Главное фото от ") == true)
        let headerLight = XCTAttachment(screenshot: app.screenshot())
        headerLight.name = "Child photo header light"
        headerLight.lifetime = .keepAlways
        add(headerLight)
        checkProfileAvatar(newestValue)
        avatar.tap()
        app.buttons["photo.grid.\(oldID)"].tap()
        action("photo.pin", app: app)
        app.buttons["photo.viewer.close"].tap()
        app.buttons["photo.gallery.close"].tap()
        let olderPinnedValue = avatar.value as? String
        XCTAssertNotNil(olderPinnedValue)
        XCTAssertTrue(olderPinnedValue?.hasPrefix("Главное фото от ") == true)
        XCTAssertNotEqual(olderPinnedValue, newestValue)
        checkProfileAvatar(olderPinnedValue)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--light-mode"]
        app.launch()
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertEqual(avatar.value as? String, olderPinnedValue)
        checkProfileAvatar(olderPinnedValue)
        avatar.tap()
        app.buttons["photo.grid.\(oldID)"].tap()
        action("photo.delete", app: app)
        app.buttons["photo.viewer.close"].tap()
        app.buttons["photo.gallery.close"].tap()
        XCTAssertEqual(avatar.value as? String, newestValue)
        checkProfileAvatar(newestValue)
        avatar.tap()
        app.buttons["photo.grid.\(newID)"].tap()
        action("photo.delete", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["photo.empty"].waitForExistence(timeout: 5))
        app.buttons["photo.gallery.close"].tap()
        XCTAssertEqual(avatar.value as? String, "Фотографий пока нет")
        checkProfileAvatar("Фотографий пока нет")
    }

    func testFullscreenPagingSystemShareAndWidgetRoute() throws {
        let app = launch(["--photo-fixtures"])
        app.tabBars.buttons["Малыш"].tap()
        let album = app.buttons["child.profile.photos"]
        for _ in 0 ..< 6 where !album.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(album.isHittable)
        XCTAssertTrue(album.label.contains("Количество фото: 2"))
        album.tap()
        XCTAssertTrue(app.navigationBars["Фотографии малыша"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["photo.gallery.close"].exists)
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
        try app.open(XCTUnwrap(URL(string: "malysh://widget/diaper")))
        XCTAssertTrue(app.navigationBars["Сегодня"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["photo.viewer.close"].exists)
        XCTAssertTrue(app.sheets["Подгузник"].buttons["Мокрый"].waitForExistence(timeout: 5))
    }

    func testUndatedImportRequiresChoiceAndSkipDoesNotCreatePhoto() throws {
        let app = launch(["--photo-import-date-fixture", "--light-mode"])
        func startImport() {
            app.buttons["photo.add"].tap()
            let source = app.buttons.matching(identifier: "photo.source.library").firstMatch
            XCTAssertTrue(source.waitForExistence(timeout: 5))
            source.tap()
            XCTAssertTrue(app.navigationBars["Указать дату съёмки"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.datePickers["photo.import.date"].exists)
        }
        startImport()
        app.buttons["photo.import.skip"].tap()
        app.buttons["photo.gallery.open"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["photo.empty"].waitForExistence(timeout: 5))
        app.buttons["photo.gallery.close"].tap()
        startImport()
        app.buttons["photo.import.today"].tap()
        let avatar = app.buttons["photo.gallery.open"]
        let saved = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value BEGINSWITH %@", "Главное фото от "), object: avatar
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 8), .completed)
        avatar.tap()
        XCTAssertTrue(firstPhoto(app).waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "photo.date.group").count, 1)
        let group = app.staticTexts.matching(identifier: "photo.date.group").firstMatch
        let numbers = group.label.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let today = Calendar.current.dateComponents([.day, .year], from: Date())
        XCTAssertTrue(try numbers.contains(XCTUnwrap(today.day)))
        XCTAssertTrue(try numbers.contains(XCTUnwrap(today.year)))
    }

    func testWidgetRouteCancelsUndatedBatchWithoutReopeningNextPrompt() throws {
        let fixtures = ["--photo-import-date-fixture", "--photo-import-date-batch-fixture"]
        let url = try XCTUnwrap(URL(string: "malysh://widget/today"))
        enum Entry: String, CaseIterable {
            case today = "Сегодня"
            case child = "Малыш"
            case album = "Фотоальбом"
        }
        for entry in Entry.allCases {
            try XCTContext.runActivity(named: "Импорт из «\(entry.rawValue)»") { _ in
                let app = launch(fixtures)
                if entry != .today {
                    app.tabBars.buttons["Малыш"].tap()
                }
                if entry == .album {
                    let album = app.buttons["child.profile.photos"]
                    for _ in 0 ..< 6 where !album.isHittable {
                        app.swipeUp()
                    }
                    XCTAssertTrue(album.isHittable)
                    album.tap()
                    XCTAssertTrue(app.navigationBars["Фотографии малыша"].waitForExistence(timeout: 5))
                }
                let addPhoto = app.buttons["photo.add"]
                if entry == .child {
                    for _ in 0 ..< 6 where !addPhoto.isHittable {
                        app.swipeUp()
                    }
                }
                XCTAssertTrue(addPhoto.isHittable)
                addPhoto.tap()
                let source = app.buttons.matching(identifier: "photo.source.library").firstMatch
                XCTAssertTrue(source.waitForExistence(timeout: 5))
                source.tap()
                let dateSheet = app.navigationBars["Указать дату съёмки"]
                XCTAssertTrue(dateSheet.waitForExistence(timeout: 5))
                app.launchArguments = ["--ui-testing"] + fixtures
                try app.open(url)
                let dismissed = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == false"),
                    object: dateSheet
                )
                XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
                let avatar = app.buttons["photo.gallery.open"]
                XCTAssertTrue(avatar.waitForExistence(timeout: 5))
                XCTAssertTrue(avatar.isHittable)
                avatar.tap()
                XCTAssertTrue(app.descendants(matching: .any)["photo.empty"].waitForExistence(timeout: 5))
                XCTAssertFalse(dateSheet.exists)
            }
        }
    }
}
