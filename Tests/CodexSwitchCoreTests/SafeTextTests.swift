import XCTest
@testable import CodexSwitchCore

final class SafeTextTests: XCTestCase {
    func testRedactsQuotedCredentialFieldsAndBearerValues() {
        let input = #"failure {"refresh_token":"opaque-secret-value","email":"person@example.com"} Authorization: Bearer bearer-secret-value"#
        let result = SafeText.bounded(input)
        XCTAssertFalse(result.contains("opaque-secret-value"))
        XCTAssertFalse(result.contains("person@example.com"))
        XCTAssertFalse(result.contains("bearer-secret-value"))
    }

    func testRedactsUnlabelledLongOpaqueValuesAndFlattensLines() {
        let secret = String(repeating: "a", count: 48)
        let result = SafeText.bounded("first\n\(secret)\rsecond\t\u{001B}[31m")
        XCTAssertFalse(result.contains(secret))
        XCTAssertFalse(result.contains("\n"))
        XCTAssertFalse(result.contains("\r"))
        XCTAssertFalse(result.contains("\t"))
        XCTAssertFalse(result.contains("\u{001B}"))
    }

    func testRedactsShortCamelCaseCredentialFields() {
        let input = "accessToken=short-a refreshToken=short-b accountId=acct deviceCode=ABCD-1234 userCode=WXYZ"
        let result = SafeText.bounded(input)

        XCTAssertFalse(result.contains("short-a"))
        XCTAssertFalse(result.contains("short-b"))
        XCTAssertFalse(result.contains("acct"))
        XCTAssertFalse(result.contains("ABCD-1234"))
        XCTAssertFalse(result.contains("WXYZ"))
    }
}
