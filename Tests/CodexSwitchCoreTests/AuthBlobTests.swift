import XCTest
@testable import CodexSwitchCore

final class AuthBlobTests: XCTestCase {
    func testAcceptsChatGPTAuthAndPreservesOriginalBytes() throws {
        let data = try makeAuthData(accountID: "account-a")
        let auth = try AuthBlob(validating: data)

        XCTAssertEqual(auth.accountID, "account-a")
        XCTAssertEqual(auth.data, data)
        XCTAssertEqual(auth.contentHash.count, 64)
        XCTAssertEqual(auth.accountFingerprint.count, 16)
    }

    func testRejectsMissingTokenWithoutIncludingValuesInError() throws {
        let sensitiveValue = "must-not-appear-in-errors"
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "tokens": [
                "id_token": sensitiveValue,
                "access_token": "fixture",
                "account_id": "account-a",
            ],
        ])

        XCTAssertThrowsError(try AuthBlob(validating: data)) { error in
            XCTAssertFalse(error.localizedDescription.contains(sensitiveValue))
        }
    }

    func testRejectsNonChatGPTAuth() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "apikey",
            "tokens": [:],
        ])
        XCTAssertThrowsError(try AuthBlob(validating: data))
    }

    func testRejectsOversizedInput() {
        let data = Data(repeating: 0x61, count: AuthBlob.maximumSize + 1)
        XCTAssertThrowsError(try AuthBlob(validating: data))
    }

    func testConstantTimeComparisonReportsEqualBytes() throws {
        let first = try AuthBlob(validating: makeAuthData(accountID: "account-a"))
        let second = try AuthBlob(validating: first.data)
        let third = try AuthBlob(validating: makeAuthData(accountID: "account-b"))

        XCTAssertTrue(first.hasSameBytes(as: second))
        XCTAssertFalse(first.hasSameBytes(as: third))
    }
}
