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

    func testRedundantProfileCleanupRequiresConfirmationAndPreservesFamily() {
        let app = launch(appearance: ["--family-fixture", "--redundant-fixture", "--light-mode"])
        let familyEvents = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "event."))
            .allElementsBoundByIndex.map(\.label)
        XCTAssertTrue(familyEvents.contains { $0.contains("Семейная запись") })
        let familyStatus = app.descendants(matching: .any).matching(identifier: "family.status").firstMatch
        let sharedDiaryLabel = app.staticTexts.matching(NSPredicate(format: "label == %@", "Общий дневник")).firstMatch
        tap(app, id: "settings.open")
        XCTAssertTrue(familyStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(sharedDiaryLabel.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "diary-picker").firstMatch.exists)
        let cleanup = app.buttons["family.cleanup"]
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        reveal(cleanup, in: app)
        cleanup.tap()
        let dialog = app.alerts["Удалить лишний «Малыш»?"].firstMatch
        XCTAssertTrue(dialog.waitForExistence(timeout: 5))
        XCTAssertTrue(dialog.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Записей для удаления: 1"))
            .firstMatch.waitForExistence(timeout: 5))
        capture(app, name: "Подтверждение удаления лишнего дневника")
        let cancel = dialog.buttons["Отмена"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: dialog)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertTrue(cleanup.exists)
        reveal(cleanup, in: app)
        cleanup.tap()
        XCTAssertTrue(dialog.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Записей для удаления: 1"))
            .firstMatch.waitForExistence(timeout: 5))
        let confirm = dialog.buttons["Удалить лишний «Малыш»"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: cleanup)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertTrue(familyStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(sharedDiaryLabel.waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--family-fixture", "--light-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 10))
        let restoredEvents = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "event."))
            .allElementsBoundByIndex.map(\.label)
        XCTAssertEqual(restoredEvents, familyEvents)
        tap(app, id: "settings.open")
        XCTAssertTrue(familyStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(sharedDiaryLabel.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["family.cleanup"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "diary-picker").firstMatch.exists)
        capture(app, name: "Семья после удаления лишнего профиля")
    }

    func testDiaryResetRequiresConfirmationAndStaysEmptyAfterRelaunch() {
        let app = launch(appearance: ["--dark-mode", "--large-text"])
        tap(app, id: "action.diaper")
        tap(app, id: "diaper.wet", label: "Мокрый")
        let event = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "event.")).firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5))
        tap(app, id: "settings.open")
        tap(app, id: "diary.manage")
        tap(app, id: "diary.reset")
        let alert = app.alerts["Начать заново?"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Отмена"].firstMatch.tap()
        app.terminate()
        _ = launch(reset: false, appearance: ["--dark-mode", "--large-text"])
        XCTAssertTrue(event.waitForExistence(timeout: 5))

        tap(app, id: "settings.open")
        tap(app, id: "diary.manage")
        tap(app, id: "diary.reset")
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["diary.reset.confirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 10))
        XCTAssertFalse(event.exists)
    }

    func testFeedingReminderSettingsPersistAndShowNextReminder() {
        let fixture = ["--feeding-reminders-authorized", "--light-mode"]
        let app = launch(appearance: fixture)
        tap(app, id: "settings.open")

        let toggle = app.switches["feeding-reminder.enabled"]
        revealReminderRow(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        let control = toggle.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "1")
        let status = app.staticTexts["feeding-reminder.status"]
        revealReminderRow(status, in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        let firstFeeding = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Напоминание появится после первого кормления."),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [firstFeeding], timeout: 5), .completed)

        let interval = app.descendants(matching: .any).matching(identifier: "feeding-reminder.interval").firstMatch
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        interval.tap()
        let custom = app.buttons["Свой интервал"].firstMatch
        XCTAssertTrue(custom.waitForExistence(timeout: 5))
        custom.tap()
        let minutes = app.descendants(matching: .any).matching(identifier: "feeding-reminder.minutes").firstMatch
        revealReminderRow(minutes, in: app)
        XCTAssertTrue(minutes.waitForExistence(timeout: 5))
        minutes.tap()
        let five = app.buttons["5"].firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 5))
        five.tap()
        XCTAssertEqual(minutes.value as? String, "5")
        capture(app, name: "Напоминания — свой интервал")

        app.terminate()
        let restored = launch(reset: false, appearance: fixture)
        tap(restored, id: "action.feed")
        tap(restored, id: "feed.bottle", label: "Бутылочка")
        tap(restored, id: "editor.save")
        XCTAssertTrue(button(restored, prefix: "event.").waitForExistence(timeout: 5))
        tap(restored, id: "settings.open")
        revealReminderRow(toggle, in: restored)

        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(interval.waitForExistence(timeout: 5))
        revealReminderRow(minutes, in: restored)
        XCTAssertEqual(minutes.value as? String, "5")
        interval.tap()
        let preset = restored.buttons["4 часа"].firstMatch
        XCTAssertTrue(preset.waitForExistence(timeout: 5))
        preset.tap()
        XCTAssertEqual(interval.value as? String, "4 часа")
        XCTAssertFalse(minutes.exists)
        revealReminderRow(status, in: restored)
        let scheduled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label BEGINSWITH %@", "Следующее напоминание"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [scheduled], timeout: 5), .completed)
        capture(restored, name: "Напоминания — запланировано")
    }

    func testFeedingReminderSettingsOfferSystemSettingsWhenDenied() {
        let app = launch(appearance: ["--feeding-reminders-denied", "--dark-mode", "--large-text"])
        tap(app, id: "action.feed")
        tap(app, id: "feed.bottle", label: "Бутылочка")
        tap(app, id: "editor.save")
        XCTAssertTrue(button(app, prefix: "event.").waitForExistence(timeout: 5))
        tap(app, id: "settings.open")

        let toggle = app.switches["feeding-reminder.enabled"]
        revealReminderRow(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let control = toggle.switches.firstMatch
        if control.exists {
            control.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        }

        let settings = app.buttons["feeding-reminder.notification-settings"]
        revealReminderRow(settings, in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let channel = app.staticTexts["feeding-reminder.channel"]
        revealReminderRow(channel, in: app)
        let liveActivity = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "Напоминание появится на экране блокировки."),
            object: channel
        )
        XCTAssertEqual(XCTWaiter.wait(for: [liveActivity], timeout: 5), .completed)
        let permission = app.staticTexts["feeding-reminder.notification-status"]
        revealReminderRow(permission, in: app)
        XCTAssertTrue(permission.waitForExistence(timeout: 5))
        XCTAssertEqual(permission.label, "Резервные уведомления выключены в настройках iPhone.")
        capture(app, name: "Напоминания — уведомления запрещены")
    }

    private func revealReminderRow(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0 ..< 6 where !element.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.56))
            )
        }
    }

    func testCloudModeChangesInSettingsWithoutClosingDiary() {
        let app = launch(appearance: ["--dark-mode", "--large-text"])
        tap(app, id: "action.diaper")
        tap(app, id: "diaper.wet", label: "Мокрый")
        let savedEvent = button(app, prefix: "event.")
        XCTAssertTrue(savedEvent.waitForExistence(timeout: 5))
        let eventID = savedEvent.identifier
        tap(app, id: "action.sleep")
        let activeTimer = button(app, prefix: "timer.finish.")
        XCTAssertTrue(activeTimer.waitForExistence(timeout: 5))
        let timerID = activeTimer.identifier

        tap(app, id: "settings.open")
        let toggle = app.switches["cloud-toggle"]
        reveal(toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let localStatus = app.staticTexts["Записи сохраняются на этом iPhone"]
        let cloudStatus = app.staticTexts["Войдите в iCloud в настройках iPhone."]
        for enabled in [true, false, true] {
            reveal(toggle, in: app)
            XCTAssertTrue(toggle.isEnabled)
            let control = toggle.switches.firstMatch
            if control.exists {
                control.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            }
            XCTAssertEqual(toggle.value as? String, enabled ? "1" : "0")
            XCTAssertTrue((enabled ? cloudStatus : localStatus).waitForExistence(timeout: 5))
            XCTAssertTrue(app.navigationBars["Настройки"].exists)
        }

        let settings = app.navigationBars["Настройки"]
        settings.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(
            forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        )
        XCTAssertTrue(app.buttons[timerID].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[eventID].exists)
    }

    func testFirstLaunchCanReturnFromFamilyAndCreateBeforeBirthOffline() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--test-onboarding", "--reset-data", "--light-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 10))
        capture(app, name: "onboarding-welcome")
        tap(app, id: "onboarding.join")
        capture(app, name: "onboarding-family")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Ожидаем приглашение"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--test-onboarding", "--light-mode", "--large-text"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 10))
        capture(app, name: "onboarding-welcome-large-text")
        tap(app, id: "onboarding.restore")
        XCTAssertTrue(app.staticTexts["Войдите в iCloud в настройках iPhone."].waitForExistence(timeout: 5))
        tap(app, id: "onboarding.restore.local")
        tap(app, id: "onboarding.join")
        tap(app, id: "onboarding.join.create")
        XCTAssertFalse(app.datePickers["onboarding.birthday"].exists)
        capture(app, name: "onboarding-create-before-birth")
        tap(app, id: "onboarding.save")
        XCTAssertTrue(app.buttons["action.feed"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ведите дневник вместе"].exists)
        tap(app, id: "onboarding.invite.later")
        XCTAssertFalse(app.staticTexts["Ведите дневник вместе"].exists)
        app.terminate()
        _ = launch(reset: false)
        XCTAssertFalse(app.buttons["onboarding.create"].exists)
    }

    func testFirstLaunchSavesConfirmedBirthdayAndOffersExistingProfile() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--test-onboarding", "--reset-data", "--dark-mode"]
        app.launch()
        XCTAssertTrue(app.buttons["onboarding.create"].waitForExistence(timeout: 10))
        capture(app, name: "onboarding-welcome-dark")
        tap(app, id: "onboarding.create")
        let born = app.switches["onboarding.born"]
        XCTAssertTrue(born.waitForExistence(timeout: 5))
        born.tap()
        XCTAssertTrue(app.datePickers["onboarding.birthday"].waitForExistence(timeout: 5))
        capture(app, name: "onboarding-create-birthday-dark")
        let name = app.textFields["onboarding.name"]
        name.tap()
        capture(app, name: "onboarding-name-focused-dark")
        name.typeText("Nika\n")
        tap(app, id: "onboarding.save")
        XCTAssertTrue(app.buttons["child.profile.open"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Ведите дневник вместе"].exists)
        tap(app, id: "onboarding.invite.later")
        tap(app, id: "child.profile.open")
        XCTAssertTrue(app.staticTexts["child.profile.age"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["child.profile.name"].label, "Nika")
        tap(app, id: "child.profile.edit")
        XCTAssertTrue(app.textFields["child.editor.birth.weight"].waitForExistence(timeout: 5))
    }
}
