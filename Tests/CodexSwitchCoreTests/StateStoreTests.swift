import Foundation
import XCTest
@testable import CodexSwitchCore

final class StateStoreTests: XCTestCase {
    func testUnrepresentableJournalTimestampIsRejectedWithoutChangingItsBytes() throws {
        let fixture = try Fixture()
        let store = JournalStore(paths: fixture.paths)
        try store.save(SwitchJournal(
            operationID: UUID(),
            sourceProfileID: UUID(),
            targetProfileID: UUID(),
            sourceAccountID: "source-fixture",
            targetAccountID: "target-fixture",
            sourceAuthHash: String(repeating: "a", count: 64),
            targetAuthHash: String(repeating: "b", count: 64)
        ))
        let original = try AtomicFileWriter.readSecureFile(fixture.paths.journalFile, maximumSize: 65_536)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["createdAt"] = Int64.max
        let invalid = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try AtomicFileWriter.write(invalid, to: fixture.paths.journalFile)

        XCTAssertThrowsError(try store.load())
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.journalFile, maximumSize: 65_536),
            invalid
        )
    }

    func testMissingStateDirectoryIsReadWithoutCreatingFiles() throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.paths.stateRoot)

        XCTAssertEqual(
            try StateStore(paths: fixture.paths).loadOrCreate(),
            SwitcherState(sharedCodexHome: fixture.paths.codexHome.path)
        )
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
        XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.stateRoot.path))
    }

    func testDanglingStateAndJournalSymlinksAreRejected() throws {
        let fixture = try Fixture()
        let missing = fixture.root.appendingPathComponent("missing")
        let files = [
            fixture.paths.stateFile,
            fixture.paths.journalFile,
            fixture.paths.registrationJournalFile,
        ]
        for file in files {
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: missing)
        }

        XCTAssertThrowsError(try StateStore(paths: fixture.paths).loadOrCreate())
        XCTAssertThrowsError(try JournalStore(paths: fixture.paths).load())
        XCTAssertThrowsError(try RegistrationStore(paths: fixture.paths).load())
        for file in files {
            XCTAssertEqual(
                try FileManager.default.destinationOfSymbolicLink(atPath: file.path),
                missing.path
            )
        }
    }

    func testDanglingStateDirectorySymlinkIsRejected() throws {
        let fixture = try Fixture()
        try FileManager.default.removeItem(at: fixture.paths.stateRoot)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.stateRoot,
            withDestinationURL: fixture.root.appendingPathComponent("missing")
        )

        XCTAssertThrowsError(try StateStore(paths: fixture.paths).loadOrCreate())
        XCTAssertThrowsError(try JournalStore(paths: fixture.paths).load())
        XCTAssertThrowsError(try RegistrationStore(paths: fixture.paths).load())
    }

    func testStateV1IsRejectedWithoutChangingItsBytes() throws {
        let fixture = try Fixture()
        let profile = try AccountProfile(
            id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            displayName: "person@example.com",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let legacy: [String: Any] = [
            "schemaVersion": 1,
            "sharedCodexHome": fixture.paths.codexHome.path,
            "profiles": [[
                "id": profile.id.uuidString,
                "displayName": profile.displayName,
                "createdAt": Int64((profile.createdAt.timeIntervalSince1970 * 1_000_000).rounded()),
            ]],
            "activeProfileID": profile.id.uuidString,
            "previousCredentialStore": "file",
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.sortedKeys])
        try AtomicFileWriter.write(legacyData, to: fixture.paths.stateFile)

        XCTAssertThrowsError(try StateStore(paths: fixture.paths).loadOrCreate())
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576),
            legacyData
        )
    }

    func testLegacyRegistrationJournalIsRejectedAndBytesRemainUntouched() throws {
        let fixture = try Fixture()
        let legacy = Data(
            "{\"schemaVersion\":1,\"operationID\":\"00000000-0000-0000-0000-000000000000\"}".utf8
        )
        try AtomicFileWriter.write(legacy, to: fixture.paths.registrationJournalFile)

        XCTAssertThrowsError(try RegistrationStore(paths: fixture.paths).load())
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(
                fixture.paths.registrationJournalFile,
                maximumSize: 32_768
            ),
            legacy
        )
    }

    func testRegistrationV2RoundTripsProfileMetadataWithoutAuthBytes() throws {
        let fixture = try Fixture()
        let registration = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
            kind: .add,
            displayName: "person@example.com · a1b2c3d4",
            accountID: "account-fixture",
            email: "person@example.com",
            planType: "team",
            profileCreatedAt: Date(timeIntervalSince1970: 1_700_000_001)
        )

        try RegistrationStore(paths: fixture.paths).save(registration)
        let loaded = try XCTUnwrap(try RegistrationStore(paths: fixture.paths).load())

        XCTAssertEqual(loaded, registration)
        let bytes = try AtomicFileWriter.readSecureFile(
            fixture.paths.registrationJournalFile,
            maximumSize: 32_768
        )
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("refresh_token"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("access_token"))
    }

    func testRegistrationV2DoesNotDecodeProfileMetadataAlternativeKeys() throws {
        let fixture = try Fixture()
        let legacyShape: [String: Any] = [
            "schemaVersion": 2,
            "operationID": UUID().uuidString,
            "profile": [
                "id": UUID().uuidString,
                "displayName": "legacy@example.com",
                "createdAt": 1_700_000_000_000_000,
            ],
            "kind": "add",
            "accountID": "legacy-account",
            "createdAt": 1_700_000_000_000_000,
            "vaultPersisted": false,
        ]
        let bytes = try JSONSerialization.data(withJSONObject: legacyShape, options: [.sortedKeys])
        try AtomicFileWriter.write(bytes, to: fixture.paths.registrationJournalFile)

        XCTAssertThrowsError(try RegistrationStore(paths: fixture.paths).load())
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.registrationJournalFile, maximumSize: 32_768),
            bytes
        )
    }

    func testRegistrationV2RequiresVaultPersistedKey() throws {
        let fixture = try Fixture()
        let registration = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "person@example.com",
            accountID: "account-fixture"
        )
        try RegistrationStore(paths: fixture.paths).save(registration)
        var bytes = try AtomicFileWriter.readSecureFile(
            fixture.paths.registrationJournalFile,
            maximumSize: 32_768
        )
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object.removeValue(forKey: "vaultPersisted")
        bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try AtomicFileWriter.write(bytes, to: fixture.paths.registrationJournalFile)

        XCTAssertThrowsError(try RegistrationStore(paths: fixture.paths).load())
    }

    private final class Fixture {
        let root: URL
        let paths: AppPaths

        init() throws {
            root = try makeTemporaryDirectory()
            let home = root.appendingPathComponent("home", isDirectory: true)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexHome.path)
            paths = AppPaths(
                homeDirectory: home,
                codexHome: codexHome,
                stateRoot: root.appendingPathComponent("state", isDirectory: true)
            )
            try paths.ensureRuntimeDirectories()
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
