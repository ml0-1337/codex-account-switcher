import Foundation
import XCTest
@testable import CodexSwitchCore

final class VaultCompatibilityTests: XCTestCase {
    func testLegacyBinaryRecordLoadsWithoutChangingCredentialBytes() throws {
        let profileID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let authData = try makeAuthData()
        let fixture: [String: Any] = [
            "schemaVersion": 1,
            "profileID": profileID.uuidString,
            "accountID": "account-fixture",
            "authData": authData,
            "savedAt": Date(timeIntervalSince1970: 1_767_225_600),
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: fixture, format: .binary, options: 0
        )
        let record = try PropertyListDecoder().decode(VaultRecord.self, from: data)
        XCTAssertEqual(record.profileID, profileID)
        XCTAssertEqual(try record.validatedAuth().data, authData)
    }

    func testMismatchedStoredAccountIsRejected() throws {
        let record = VaultRecord(profileID: UUID(), auth: try AuthBlob(validating: makeAuthData()))
        let data = try PropertyListEncoder().encode(record)
        var fixture = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        fixture["accountID"] = "different-fixture-account"
        let mismatched = try PropertyListDecoder().decode(
            VaultRecord.self,
            from: PropertyListSerialization.data(fromPropertyList: fixture, format: .binary, options: 0)
        )
        XCTAssertThrowsError(try mismatched.validatedAuth())
    }

    func testExistingServiceAndEmailLabelRemainCompatible() throws {
        XCTAssertEqual(KeychainVault.defaultService, "app.codex-account-switcher.credentials.v1")
        XCTAssertEqual(
            try KeychainVault.itemLabel(displayName: "person@example.com"),
            "Codex Account Switcher — person@example.com"
        )
        XCTAssertEqual(
            try KeychainVault.itemLabel(displayName: "person@example.com · 0123456789abcdef"),
            "Codex Account Switcher — person@example.com · 0123456789abcdef"
        )
    }
}
