import CloudKit
@testable import Malysh
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
}
