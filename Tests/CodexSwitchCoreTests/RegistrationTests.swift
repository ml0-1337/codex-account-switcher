import Foundation
import XCTest
@testable import CodexSwitchCore

final class RegistrationTests: XCTestCase {
    func testAddPersistsPrivateLoginCredentialsWithoutChangingSharedAuthOrSelection() throws {
        let fixture = try Fixture()
        let sourceAuth = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let addedAuth = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        fixture.session = FixtureSession(
            auth: addedAuth,
            account: AccountInfo(type: "chatgpt", email: "person@example.com", planType: "plus")
        )

        let profile = try fixture.coordinator().add()

        XCTAssertEqual(profile.displayName, "person@example.com")
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
        XCTAssertEqual(
            try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID,
            fixture.source.id
        )
        XCTAssertEqual(fixture.session?.accountReadRefreshTokens, [false])
        XCTAssertTrue(fixture.session?.privateFiles.contains("config.toml") == true)
        XCTAssertFalse(fixture.session?.privateFiles.contains("history.json") == true)
        XCTAssertFalse(fixture.session?.privateFiles.contains("mcp.json") == true)
        XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
    }

    func testAddRejectsDuplicateAccountIDBeforePersistingNewProfile() throws {
        let fixture = try Fixture()
        let sourceAuth = try AuthBlob(validating: makeAuthData(accountID: "source"))
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        fixture.session = FixtureSession(
            auth: sourceAuth,
            account: AccountInfo(type: "chatgpt", email: "other@example.com")
        )

        XCTAssertThrowsError(try fixture.coordinator().add())
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().profiles.count, 1)
        XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
    }

    func testCancellationAfterLoginCleansPrivateHomeAndDoesNotSelectAddedAccount() throws {
        let fixture = try Fixture()
        let sourceAuth = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let addedAuth = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        let token = CancellationToken()
        fixture.session = FixtureSession(
            auth: addedAuth,
            account: AccountInfo(type: "chatgpt", email: "added@example.com"),
            onWait: { token.cancel() }
        )

        XCTAssertThrowsError(try fixture.coordinator(cancellation: token).add())
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
        XCTAssertEqual(fixture.vault.records.count, 1)
        XCTAssertTrue(fixture.session?.cancelCalls.contains("fixture-login") == true)
    }

    func testInitializeAndCloseFailuresPreservePrivateHomeAndReportItsPath() throws {
        let fixture = try Fixture()
        let sourceAuth = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let addedAuth = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        fixture.session = FixtureSession(
            auth: addedAuth,
            account: AccountInfo(type: "chatgpt", email: "added@example.com"),
            initializeError: CodexSwitchError.appServer("fixture initialize failure"),
            closeError: CodexSwitchError.appServer("fixture close failure")
        )
        var progress: [SwitchProgress] = []

        XCTAssertThrowsError(
            try fixture.coordinator(progress: { progress.append($0) }).add()
        ) { error in
            XCTAssertTrue(String(describing: error).contains("削除"))
        }

        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
        XCTAssertEqual(fixture.vault.records.count, 1)
        XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
        XCTAssertTrue(fixture.session?.closeCalls == 1)
        let cleanupEvent = progress.compactMap { progress -> (URL, String)? in
            guard case let .cleanupFailed(temporaryHome, reason) = progress else { return nil }
            return (temporaryHome, reason)
        }.first
        XCTAssertNotNil(cleanupEvent)
        XCTAssertTrue(cleanupEvent?.0.path.contains("Codex Account Switcher") == true)
        XCTAssertFalse(cleanupEvent?.1.isEmpty == true)
        if let temporaryHome = cleanupEvent?.0 {
            XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryHome.path))
            try FileManager.default.removeItem(at: temporaryHome)
        }
    }

    func testRejectedDeviceCodeCompletionIsAnAuthenticationFailureNotUserCancellation() throws {
        let fixture = try Fixture()
        let sourceAuth = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let addedAuth = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        fixture.session = FixtureSession(
            auth: addedAuth,
            account: AccountInfo(type: "chatgpt", email: "added@example.com"),
            completionSuccess: false
        )

        XCTAssertThrowsError(try fixture.coordinator().add()) { error in
            guard let switchError = error as? CodexSwitchError,
                  case .appServer = switchError
            else {
                return XCTFail("expected an app-server authentication failure")
            }
        }
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
        XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
    }

    func testPostWriteStateFailureRetainsRegistrationJournalAndPropagatesWriteError() throws {
        let fixture = try Fixture()
        let sourceAuth = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let addedAuth = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        fixture.session = FixtureSession(
            auth: addedAuth,
            account: AccountInfo(type: "chatgpt", email: "added@example.com")
        )
        let stateStore = WriteThenThrowStateStore(paths: fixture.paths)

        XCTAssertThrowsError(try fixture.coordinator(stateStore: stateStore).add()) { error in
            XCTAssertTrue(String(describing: error).contains("fixture state write after write"))
        }
        XCTAssertEqual(stateStore.loadCount, 1)
        XCTAssertNotNil(try RegistrationStore(paths: fixture.paths).load())
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
    }

    private final class Fixture {
        let root: URL
        let paths: AppPaths
        let source: AccountProfile
        let vault = MemoryVault()
        var session: FixtureSession?

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
            source = try AccountProfile(
                id: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
                displayName: "source@example.com"
            )
            try StateStore(paths: paths).save(
                SwitcherState(sharedCodexHome: codexHome.path, profiles: [source], activeProfileID: source.id)
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func writeShared(_ auth: AuthBlob) throws {
            try AtomicFileWriter.write(auth.data, to: paths.authFile)
        }

        func readShared() throws -> AuthBlob {
            try AuthBlob(validating: AtomicFileWriter.readSecureFile(paths.authFile, maximumSize: AuthBlob.maximumSize))
        }

        func coordinator(
            cancellation: CancellationToken? = nil,
            progress: @escaping SwitchCoordinator.ProgressHandler = { _ in },
            stateStore: (any StateStoreProtocol)? = nil
        ) -> SwitchCoordinator {
            SwitchCoordinator(
                paths: paths,
                vault: vault,
                sessionFactory: { [weak self] home in
                    guard let session = self?.session else {
                        throw CodexSwitchError.appServer("fixture session missing")
                    }
                    session.home = home
                    return session
                },
                stateStore: stateStore,
                cancellation: cancellation,
                progress: progress
            )
        }
    }

    private final class MemoryVault: CredentialVault, @unchecked Sendable {
        var records: [UUID: VaultRecord] = [:]

        func save(_ record: VaultRecord, displayName: String) throws {
            _ = displayName
            _ = try record.validatedAuth()
            records[record.profileID] = record
        }

        func load(profileID: UUID) throws -> VaultRecord {
            guard let record = records[profileID] else {
                throw CodexSwitchError.keychain("credential missing")
            }
            return record
        }

        func contains(profileID: UUID) throws -> Bool { records[profileID] != nil }
        func delete(profileID: UUID) throws { records.removeValue(forKey: profileID) }
    }

    private final class WriteThenThrowStateStore: StateStoreProtocol {
        private let backing: StateStore
        private(set) var loadCount = 0

        init(paths: AppPaths) {
            backing = StateStore(paths: paths)
        }

        func loadOrCreate() throws -> SwitcherState {
            loadCount += 1
            return try backing.loadOrCreate()
        }

        func save(_ state: SwitcherState) throws {
            try backing.save(state)
            throw CodexSwitchError.state("fixture state write after write")
        }
    }

    private final class FixtureSession: AppServerSession {
        let auth: AuthBlob
        let account: AccountInfo
        let onWait: (() -> Void)?
        let completionSuccess: Bool
        let initializeError: Error?
        let closeError: Error?
        var accountReadRefreshTokens: [Bool] = []
        var privateFiles: Set<String> = []
        var cancelCalls: [String] = []
        var closeCalls = 0
        var home: URL?

        init(
            auth: AuthBlob,
            account: AccountInfo,
            onWait: (() -> Void)? = nil,
            completionSuccess: Bool = true,
            initializeError: Error? = nil,
            closeError: Error? = nil
        ) {
            self.auth = auth
            self.account = account
            self.onWait = onWait
            self.completionSuccess = completionSuccess
            self.initializeError = initializeError
            self.closeError = closeError
        }

        func initialize() throws -> InitializeResponse {
            if let initializeError { throw initializeError }
            return try JSONDecoder().decode(InitializeResponse.self, from: Data("{}".utf8))
        }

        func accountLoginStartDeviceCode(timeout: TimeInterval?) throws -> DeviceCodeLoginResult {
            _ = timeout
            guard let home else { throw CodexSwitchError.appServer("fixture home missing") }
            try AtomicFileWriter.write(auth.data, to: home.appendingPathComponent("auth.json"))
            let entries = try FileManager.default.contentsOfDirectory(atPath: home.path)
            privateFiles = Set(entries)
            return DeviceCodeLoginResult(
                type: "chatgptDeviceCode",
                loginID: "fixture-login",
                verificationURL: "https://auth.openai.com/codex/device",
                userCode: "ABCD-1234"
            )
        }

        func waitForLoginCompleted(loginID: String, timeout: TimeInterval?) throws -> LoginCompletedNotification {
            _ = loginID
            _ = timeout
            onWait?()
            return LoginCompletedNotification(
                loginID: "fixture-login",
                success: completionSuccess,
                error: nil
            )
        }

        func accountRead(refreshToken: Bool, timeout: TimeInterval?) throws -> AccountReadResult {
            _ = timeout
            accountReadRefreshTokens.append(refreshToken)
            return AccountReadResult(account: account, requiresOpenaiAuth: true)
        }

        func accountLoginCancel(loginID: String, timeout: TimeInterval?) throws {
            _ = timeout
            cancelCalls.append(loginID)
        }

        func configRead(includeLayers: Bool, timeout: TimeInterval?) throws -> ConfigReadResult {
            _ = includeLayers
            _ = timeout
            return ConfigReadResult(config: .object(["cli_auth_credentials_store": .string("file")]))
        }

        func close() throws {
            closeCalls += 1
            if let closeError { throw closeError }
        }
    }
}
