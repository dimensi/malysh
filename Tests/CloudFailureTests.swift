import CloudKit
@testable import Malysh
import UIKit
import XCTest

final class CloudFailureTests: XCTestCase {
    func testNestedBadContainerExplainsConfigurationWithoutLeakingDiagnostics() {
        let cloud = NSError(domain: CKErrorDomain, code: CKError.badContainer.rawValue,
                            userInfo: [NSLocalizedDescriptionKey: "secret-record-id"])
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_060,
                              userInfo: [NSUnderlyingErrorKey: cloud])
        let message = CloudFailure.message(for: wrapped)
        XCTAssertTrue(message.contains("Контейнер iCloud недоступен"))
        XCTAssertTrue(message.contains("команду разработчика"))
        XCTAssertFalse(message.contains("secret-record-id"))
        XCTAssertFalse(message.contains("134060"))
    }

    func testPartialAndMultipleErrorsFindUnderlyingAuthenticationFailure() {
        let authentication = NSError(domain: CKErrorDomain, code: CKError.notAuthenticated.rawValue)
        let multiple = NSError(domain: NSCocoaErrorDomain, code: 134_060,
                               userInfo: [NSMultipleUnderlyingErrorsKey: [authentication]])
        let partial = NSError(domain: CKErrorDomain, code: CKError.partialFailure.rawValue,
                              userInfo: [CKPartialErrorsByItemIDKey: ["private-record-id": multiple]])
        let message = CloudFailure.message(for: partial)
        XCTAssertTrue(message.contains("Войдите в iCloud"))
        XCTAssertFalse(message.contains("private-record-id"))
    }

    func testNetworkAndUnknownErrorsKeepLocalDataMessage() {
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertTrue(CloudFailure.message(for: network).contains("Проверьте сеть"))
        let unknown = NSError(domain: "PrivateDiagnostic", code: 123,
                              userInfo: [NSLocalizedDescriptionKey: "sensitive diagnostic"])
        XCTAssertTrue(CloudFailure.message(for: unknown).contains("Записи доступны локально"))
        XCTAssertFalse(CloudFailure.message(for: unknown).contains("sensitive diagnostic"))
    }

    func testSharingRequiresEveryStoreAndRecoversOnlyAfterSuccessfulSetup() {
        let expected: Set = ["private", "shared"]
        var state = CloudSetupState()
        XCTAssertFalse(state.isReady(expected: []))
        XCTAssertFalse(state.isReady(expected: expected))
        state.record(identifier: "private", error: nil)
        XCTAssertFalse(state.isReady(expected: expected))
        state.record(identifier: "unrelated", error: nil)
        XCTAssertFalse(state.isReady(expected: expected))
        let error = NSError(domain: CKErrorDomain, code: CKError.badContainer.rawValue)
        state.record(identifier: "shared", error: error)
        XCTAssertFalse(state.isReady(expected: expected))
        XCTAssertNotNil(state.failure(expected: expected))
        state.begin(identifier: "shared")
        XCTAssertNotNil(state.failure(expected: expected))
        state.record(identifier: "shared", error: nil)
        XCTAssertTrue(state.isReady(expected: expected))
        XCTAssertNil(state.failure(expected: expected))
        state.begin(identifier: "private")
        XCTAssertFalse(state.isReady(expected: expected))
        state.record(identifier: "private", error: nil)
        XCTAssertTrue(state.isReady(expected: expected))
    }

    func testMissingProductionSchemaIsNotPresentedAsTemporaryNetworkFailure() {
        let schema = NSError(
            domain: CKErrorDomain,
            code: CKError.invalidArguments.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Cannot create new type PRIVATE_RECORD in production schema"]
        )
        let partial = NSError(domain: CKErrorDomain, code: CKError.partialFailure.rawValue,
                              userInfo: [CKPartialErrorsByItemIDKey: ["private-id": schema]])
        let message = CloudFailure.message(for: partial)
        XCTAssertTrue(message.contains("ещё не подготовлена"))
        XCTAssertFalse(message.contains("PRIVATE_RECORD"))
        XCTAssertFalse(message.contains("private-id"))
        XCTAssertFalse(message.contains("Повторите позже"))
    }

    @MainActor
    func testSystemSharingSaveRefreshesUI() async {
        let refresh = expectation(forNotification: .malyshSharingChanged, object: nil)
        var saveError: Error?
        let coordinator = ShareSheet.Coordinator { saveError = $0 }

        coordinator.cloudSharingControllerDidSaveShare(UICloudSharingController())

        await fulfillment(of: [refresh], timeout: 1)
        XCTAssertNil(saveError)
    }

    @MainActor
    func testSystemSharingFailureReportsErrorWithoutRefresh() async {
        let unexpectedRefresh = expectation(forNotification: .malyshSharingChanged, object: nil)
        unexpectedRefresh.isInverted = true
        var reportedError: NSError?
        let coordinator = ShareSheet.Coordinator { reportedError = $0 as NSError }
        let error = NSError(domain: CKErrorDomain, code: CKError.networkFailure.rawValue)

        coordinator.cloudSharingController(UICloudSharingController(), failedToSaveShareWithError: error)

        XCTAssertEqual(reportedError, error)
        await fulfillment(of: [unexpectedRefresh], timeout: 0.1)
    }

    func testFamilyMemberNamesAndRolesKeepIdentityPrivate() {
        var components = PersonNameComponents()
        components.givenName = "Анна"
        let owner = FamilyMember.make(id: "owner", nameComponents: components, isOwner: true,
                                      acceptanceStatus: .accepted, isCurrentUser: false)
        XCTAssertTrue(owner.name.contains("Анна"))
        XCTAssertEqual(owner.role, "Родитель")
        XCTAssertTrue(owner.isOwner)
        XCTAssertEqual(owner.status, "В семье")
        let current = FamilyMember.make(id: "current", nameComponents: components, isOwner: false,
                                        acceptanceStatus: .accepted, isCurrentUser: true)
        XCTAssertEqual(current.name, "Анна")
        XCTAssertEqual(current.role, "Родитель")
        XCTAssertTrue(current.isCurrentUser)
    }

    func testFamilyMemberWithoutNameUsesHonestInvitationStatus() {
        let pending = FamilyMember.make(id: "pending", nameComponents: nil, isOwner: false,
                                        acceptanceStatus: .pending, isCurrentUser: false)
        XCTAssertTrue(pending.name.isEmpty)
        XCTAssertEqual(pending.status, "Приглашение отправлено")
        let removed = FamilyMember.make(id: "removed", nameComponents: PersonNameComponents(), isOwner: false,
                                        acceptanceStatus: .removed, isCurrentUser: false)
        XCTAssertTrue(removed.name.isEmpty)
        XCTAssertEqual(removed.status, "Доступ прекращён")
        let unknown = FamilyMember.make(id: "unknown", nameComponents: nil, isOwner: false,
                                        acceptanceStatus: .unknown, isCurrentUser: false)
        XCTAssertEqual(unknown.status, "Статус пока неизвестен")
    }
}
