import CloudKit
@testable import Malysh
import XCTest

final class CloudFailureTests: XCTestCase {
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
