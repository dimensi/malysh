import Foundation
@testable import Malysh
import XCTest

final class BabyPhotoTests: XCTestCase {
    func testAvatarPinnedAndDeterministicNewestFallback() throws {
        let babyID = UUID()
        let old = BabyPhoto(
            babyID: babyID,
            capturedAt: Date(timeIntervalSince1970: 1),
            addedBy: "owner",
            pixelWidth: 80,
            pixelHeight: 90
        )
        let recent = BabyPhoto(
            babyID: babyID,
            capturedAt: Date(timeIntervalSince1970: 2),
            addedBy: "user-parent",
            pixelWidth: 80,
            pixelHeight: 90
        )
        XCTAssertEqual(BabyPhoto.avatar(in: [old, recent], pinnedID: old.id), old)
        XCTAssertEqual(BabyPhoto.avatar(in: [old, recent], pinnedID: UUID()), recent)
        XCTAssertNil(BabyPhoto.avatar(in: [], pinnedID: old.id))
        XCTAssertEqual(try JSONDecoder().decode(BabyPhoto.self, from: JSONEncoder().encode(recent)), recent)
    }

    func testLegacyBabyPayloadAndPinnedRoundTrip() throws {
        var baby = Baby(name: "Малыш")
        XCTAssertNil(try JSONDecoder().decode(Baby.self, from: JSONEncoder().encode(baby)).pinnedPhotoID)
        baby.pinnedPhotoID = UUID()
        XCTAssertEqual(try JSONDecoder().decode(Baby.self, from: JSONEncoder().encode(baby)), baby)
    }
}
