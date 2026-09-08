import Foundation
import XCTest
@testable import CodexSwitchCore

final class CoreAcceptanceTests: XCTestCase {
    func testSwitchPersistsFreshSharedSourceBytesWhenVaultHasStaleRecord() throws {
        let fixture = try Fixture(initialState: .standard)
        let staleSource = try makeFixtureAuth(
            accountID: "source",
            accessToken: "stale-source-access-token"
        )
        let freshSource = try makeFixtureAuth(
            accountID: "source",
            accessToken: "fresh-source-access-token"
        )
        let targetAuth = try makeFixtureAuth(
            accountID: "target",
            accessToken: "target-access-token"
        )
        try fixture.writeShared(freshSource)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: staleSource),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: targetAuth),
            displayName: fixture.target.displayName
        )

        let result = try fixture.coordinator().switchAccount(targetProfileID: fixture.target.id)

        XCTAssertTrue(result.changed)
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: targetAuth))
        let savedSource = try fixture.vault.load(profileID: fixture.source.id).validatedAuth()
        XCTAssertTrue(savedSource.hasSameBytes(as: freshSource))
        XCTAssertFalse(savedSource.hasSameBytes(as: staleSource))
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
    }

    func testSwitchTargetVaultRefusalLeavesSharedAuthAndJournalUntouched() throws {
        let fixture = try Fixture(initialState: .standard)
        let sourceAuth = try makeFixtureAuth(
            accountID: "source",
            accessToken: "source-access-token"
        )
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )

        XCTAssertThrowsError(
            try fixture.coordinator().switchAccount(targetProfileID: fixture.target.id)
        ) { error in
            XCTAssertFalse(String(describing: error).contains("unexpected real runtime"))
        }

        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalFile.path))
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
    }

    func testSwitchSourceVaultReadbackMismatchStopsBeforeSharedAuthMutationOrJournal() throws {
        let fixture = try Fixture(initialState: .standard)
        let sourceAuth = try makeFixtureAuth(
            accountID: "source",
            accessToken: "source-access-token"
        )
        let targetAuth = try makeFixtureAuth(
            accountID: "target",
            accessToken: "target-access-token"
        )
        let mismatchedSource = try makeFixtureAuth(
            accountID: "source",
            accessToken: "mismatched-source-access-token"
        )
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: targetAuth),
            displayName: fixture.target.displayName
        )
        fixture.vault.readbackOverrideAfterSave[fixture.source.id] = VaultRecord(
            profileID: fixture.source.id,
            auth: mismatchedSource
        )

        XCTAssertThrowsError(
            try fixture.coordinator().switchAccount(targetProfileID: fixture.target.id)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("照合"))
        }

        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.journalFile.path))
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
    }

    func testSetupRejectsKeyringAutoAndMissingCredentialStoresWithoutSuccess() throws {
        let cases: [(String, JSONValue)] = [
            ("keyring", .object(["cli_auth_credentials_store": .string("keyring")])),
            ("auto", .object(["cli_auth_credentials_store": .string("auto")])),
            ("missing", .object([:])),
        ]

        for (label, config) in cases {
            let fixture = try Fixture(initialState: .empty)
            let auth = try makeFixtureAuth(
                accountID: "setup-account",
                accessToken: "setup-access-token"
            )
            try fixture.writeShared(auth)
            let session = AcceptanceSession(
                account: AccountInfo(type: "chatgpt", email: "setup@example.com"),
                config: config
            )
            fixture.session = session
            let stateBefore = try fixture.stateBytes()

            XCTAssertThrowsError(try fixture.coordinator().setup(), label) { error in
                XCTAssertFalse(String(describing: error).contains("unexpected account/read"))
            }

            XCTAssertEqual(session.methods, ["initialize", "config/read", "close"])
            XCTAssertEqual(session.accountReadCount, 0)
            XCTAssertEqual(session.closeCalls, 1)
            XCTAssertEqual(session.home?.standardizedFileURL, fixture.paths.codexHome.standardizedFileURL)
            XCTAssertEqual(try fixture.stateBytes(), stateBefore)
            let state = try StateStore(paths: fixture.paths).loadOrCreate()
            XCTAssertTrue(state.profiles.isEmpty)
            XCTAssertNil(state.activeProfileID)
            XCTAssertTrue(fixture.vault.records.isEmpty)
            XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
        }
    }

    func testSetupRejectsSharedAuthMutationDuringAccountReadWithoutRegistrationOrStateSuccess() throws {
        let fixture = try Fixture(initialState: .empty)
        let originalAuth = try makeFixtureAuth(
            accountID: "setup-account",
            accessToken: "setup-before-read"
        )
        let changedAuth = try makeFixtureAuth(
            accountID: "setup-account",
            accessToken: "setup-during-read"
        )
        try fixture.writeShared(originalAuth)
        let session = AcceptanceSession(
            account: AccountInfo(type: "chatgpt", email: "setup@example.com"),
            config: .object(["cli_auth_credentials_store": .string("file")])
        )
        session.onAccountRead = { [weak fixture] in
            guard let fixture else {
                throw CodexSwitchError.appServer("fixture released before account/read")
            }
            try fixture.writeShared(changedAuth)
        }
        fixture.session = session
        let stateBefore = try fixture.stateBytes()

        XCTAssertThrowsError(try fixture.coordinator().setup()) { error in
            XCTAssertTrue(String(describing: error).contains("変更されました"))
        }

        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: changedAuth))
        XCTAssertEqual(session.methods, ["initialize", "config/read", "account/read", "close"])
        XCTAssertEqual(session.closeCalls, 1)
        XCTAssertEqual(try fixture.stateBytes(), stateBefore)
        let state = try StateStore(paths: fixture.paths).loadOrCreate()
        XCTAssertTrue(state.profiles.isEmpty)
        XCTAssertNil(state.activeProfileID)
        XCTAssertTrue(fixture.vault.records.isEmpty)
        XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
    }

    func testAddSameEmailDifferentAccountIDUsesFingerprintAndLeavesActiveSelection() throws {
        let fixture = try Fixture(initialState: .sourceOnly)
        let sourceAuth = try makeFixtureAuth(
            accountID: "source",
            accessToken: "source-access-token"
        )
        let addedAuth = try makeFixtureAuth(
            accountID: "added",
            accessToken: "added-access-token"
        )
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        let session = AcceptanceSession(
            account: AccountInfo(type: "chatgpt", email: fixture.source.displayName, planType: "plus"),
            auth: addedAuth,
            config: .object(["cli_auth_credentials_store": .string("file")])
        )
        fixture.session = session

        let profile = try fixture.coordinator().add()

        XCTAssertEqual(profile.displayName, "\(fixture.source.displayName) · \(addedAuth.accountFingerprint)")
        XCTAssertTrue(profile.displayName.hasSuffix("· \(addedAuth.accountFingerprint)"))
        XCTAssertNotEqual(profile.id, fixture.source.id)
        let state = try StateStore(paths: fixture.paths).loadOrCreate()
        XCTAssertEqual(state.profiles.map(\.id), [fixture.source.id, profile.id])
        XCTAssertEqual(state.activeProfileID, fixture.source.id)
        XCTAssertTrue(
            try fixture.vault.load(profileID: profile.id).validatedAuth().hasSameBytes(as: addedAuth)
        )
        XCTAssertNil(try RegistrationStore(paths: fixture.paths).load())
        XCTAssertEqual(session.closeCalls, 1)
        let temporaryHome = try XCTUnwrap(session.home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryHome.path))
    }

    func testAddPreservesSharedConfigHistoryAndSessionFixtures() throws {
        let fixture = try Fixture(initialState: .sourceOnly)
        let sourceAuth = try makeFixtureAuth(
            accountID: "source",
            accessToken: "source-access-token"
        )
        let addedAuth = try makeFixtureAuth(
            accountID: "added",
            accessToken: "added-access-token"
        )
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )

        let sharedConfig = Data(
            "cli_auth_credentials_store = \"file\"\n[mcp_servers.fixture]\ncommand = \"/usr/bin/true\"\n".utf8
        )
        let sharedHistory = Data("shared-history-sentinel\n".utf8)
        let sharedSession = Data("shared-session-sentinel\n".utf8)
        let configURL = fixture.paths.codexHome.appendingPathComponent("config.toml")
        let historyURL = fixture.paths.codexHome.appendingPathComponent("history.jsonl")
        let sessionsURL = fixture.paths.codexHome.appendingPathComponent("sessions", isDirectory: true)
        let sessionFixtureURL = sessionsURL.appendingPathComponent("fixture.jsonl")
        try AtomicFileWriter.write(sharedConfig, to: configURL)
        try AtomicFileWriter.write(sharedHistory, to: historyURL)
        try AppPaths.ensurePrivateDirectory(sessionsURL, label: "fixture sessions")
        try AtomicFileWriter.write(sharedSession, to: sessionFixtureURL)
        let sharedConfigBefore = try AtomicFileWriter.readSecureFile(configURL, maximumSize: 65_536)
        let sharedHistoryBefore = try AtomicFileWriter.readSecureFile(historyURL, maximumSize: 65_536)
        let sharedSessionBefore = try AtomicFileWriter.readSecureFile(sessionFixtureURL, maximumSize: 65_536)

        let session = AcceptanceSession(
            account: AccountInfo(type: "chatgpt", email: "added@example.com", planType: "plus"),
            auth: addedAuth,
            config: .object(["cli_auth_credentials_store": .string("file")])
        )
        fixture.session = session

        _ = try fixture.coordinator().add()

        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(configURL, maximumSize: 65_536),
            sharedConfigBefore
        )
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(historyURL, maximumSize: 65_536),
            sharedHistoryBefore
        )
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(sessionFixtureURL, maximumSize: 65_536),
            sharedSessionBefore
        )
        XCTAssertEqual(session.privateConfigContents, "cli_auth_credentials_store = \"file\"\n")
        XCTAssertFalse(session.privateConfigContents?.contains("mcp_servers") == true)
        XCTAssertFalse(session.privateFiles.contains("history.jsonl"))
        XCTAssertFalse(session.privateFiles.contains("sessions"))
        XCTAssertTrue(session.privateFiles.contains("config.toml"))
        XCTAssertTrue(session.privateFiles.contains("auth.json"))
        XCTAssertEqual(session.closeCalls, 1)
        let temporaryHome = try XCTUnwrap(session.home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryHome.path))
    }

    func testRecoverCompletesVaultOnlyAddRegistrationWithoutDeletingCredentialOrSelectingIt() throws {
        let fixture = try Fixture(initialState: .sourceOnly)
        let sourceAuth = try makeFixtureAuth(
            accountID: "source",
            accessToken: "source-access-token"
        )
        let addedAuth = try makeFixtureAuth(
            accountID: "added",
            accessToken: "added-access-token"
        )
        try fixture.writeShared(sourceAuth)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
            displayName: fixture.source.displayName
        )
        let addedProfileID = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
        let registration = try PendingCredentialRegistration(
            operationID: UUID(uuidString: "44444444-5555-4666-8777-888888888888")!,
            profileID: addedProfileID,
            kind: .add,
            displayName: "added@example.com",
            accountID: addedAuth.accountID,
            email: "added@example.com",
            planType: "plus",
            profileCreatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            vaultPersisted: true
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(registration)
        try fixture.vault.save(
            VaultRecord(profileID: addedProfileID, auth: addedAuth),
            displayName: registration.displayName
        )
        let savedCredentialBefore = try fixture.vault.load(profileID: addedProfileID)
        let deleteCountBefore = fixture.vault.deleteCount

        let outcome = try fixture.coordinator().recover()

        guard case let .repairedRegistration(profile) = outcome else {
            return XCTFail("expected the vault-only add registration to be repaired")
        }
        XCTAssertEqual(profile.id, addedProfileID)
        XCTAssertEqual(profile.displayName, registration.displayName)
        let state = try StateStore(paths: fixture.paths).loadOrCreate()
        XCTAssertEqual(state.profiles.map(\.id), [fixture.source.id, addedProfileID])
        XCTAssertEqual(state.activeProfileID, fixture.source.id)
        XCTAssertEqual(fixture.vault.deleteCount, deleteCountBefore)
        XCTAssertEqual(try fixture.vault.load(profileID: addedProfileID), savedCredentialBefore)
        XCTAssertNil(try registrationStore.load())
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: sourceAuth))
    }

    func testSwitchRecoveryPreservesMissingCorruptAndUnrelatedSharedAuth() throws {
        enum SharedAuthCase {
            case missing
            case corrupt
            case unrelated
        }

        for scenario in [SharedAuthCase.missing, .corrupt, .unrelated] {
            let fixture = try Fixture(initialState: .standard)
            let sourceAuth = try makeFixtureAuth(
                accountID: "source",
                accessToken: "source-access-token"
            )
            let targetAuth = try makeFixtureAuth(
                accountID: "target",
                accessToken: "target-access-token"
            )
            try fixture.vault.save(
                VaultRecord(profileID: fixture.source.id, auth: sourceAuth),
                displayName: fixture.source.displayName
            )
            try fixture.vault.save(
                VaultRecord(profileID: fixture.target.id, auth: targetAuth),
                displayName: fixture.target.displayName
            )
            let journal = SwitchJournal(
                operationID: UUID(uuidString: "55555555-6666-4777-8888-999999999999")!,
                sourceProfileID: fixture.source.id,
                targetProfileID: fixture.target.id,
                sourceAccountID: sourceAuth.accountID,
                targetAccountID: targetAuth.accountID,
                sourceAuthHash: sourceAuth.contentHash,
                targetAuthHash: targetAuth.contentHash
            )
            let journalStore = JournalStore(paths: fixture.paths)
            try journalStore.save(journal)
            let journalBefore = try fixture.journalBytes()
            let stateBefore = try fixture.stateBytes()
            let sourceRecordBefore = try fixture.vault.load(profileID: fixture.source.id)
            let targetRecordBefore = try fixture.vault.load(profileID: fixture.target.id)
            let vaultSaveCountBefore = fixture.vault.saveCount

            switch scenario {
            case .missing:
                break
            case .corrupt:
                try fixture.writeShared(Data("{\"not_auth\":true}".utf8))
            case .unrelated:
                let unrelated = try makeFixtureAuth(
                    accountID: "unrelated",
                    accessToken: "unrelated-access-token"
                )
                try fixture.writeShared(unrelated)
            }
            let sharedAuthBefore = try fixture.paths.authFileExists()
                ? fixture.readSharedData()
                : nil

            XCTAssertThrowsError(try fixture.coordinator().recover()) { error in
                XCTAssertFalse(String(describing: error).contains("unexpected real runtime"))
            }

            XCTAssertEqual(try fixture.journalBytes(), journalBefore)
            XCTAssertEqual(try fixture.stateBytes(), stateBefore)
            XCTAssertEqual(try fixture.vault.load(profileID: fixture.source.id), sourceRecordBefore)
            XCTAssertEqual(try fixture.vault.load(profileID: fixture.target.id), targetRecordBefore)
            XCTAssertEqual(fixture.vault.saveCount, vaultSaveCountBefore)
            XCTAssertEqual(try journalStore.load(), journal)
            if let sharedAuthBefore {
                XCTAssertTrue(try fixture.readSharedData() == sharedAuthBefore)
            } else {
                XCTAssertFalse(fixture.paths.authFileExists())
            }
        }
    }

    func testSwitchRecoveryStoresFreshSourceAuthWithoutWritingSharedFile() throws {
        let fixture = try Fixture(initialState: .standard)
        let staleSource = try makeFixtureAuth(
            accountID: "source",
            accessToken: "stale-source-access-token"
        )
        let freshSource = try makeFixtureAuth(
            accountID: "source",
            accessToken: "fresh-source-access-token"
        )
        let targetAuth = try makeFixtureAuth(
            accountID: "target",
            accessToken: "target-access-token"
        )
        try fixture.writeShared(freshSource)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: staleSource),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: targetAuth),
            displayName: fixture.target.displayName
        )
        let journal = SwitchJournal(
            operationID: UUID(uuidString: "66666666-7777-4888-9999-aaaaaaaaaaaa")!,
            sourceProfileID: fixture.source.id,
            targetProfileID: fixture.target.id,
            sourceAccountID: staleSource.accountID,
            targetAccountID: targetAuth.accountID,
            sourceAuthHash: staleSource.contentHash,
            targetAuthHash: targetAuth.contentHash
        )
        try JournalStore(paths: fixture.paths).save(journal)
        let sharedBefore = try fixture.readSharedData()

        let outcome = try fixture.coordinator().recover()

        guard case let .repairedSwitch(profile) = outcome else {
            return XCTFail("expected the source-side switch recovery to be repaired")
        }
        XCTAssertEqual(profile, fixture.source)
        XCTAssertEqual(try fixture.readSharedData(), sharedBefore)
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: freshSource)
        )
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
    }

    private func makeFixtureAuth(accountID: String, accessToken: String) throws -> AuthBlob {
        let base = try makeAuthData(accountID: accountID)
        let text = String(decoding: base, as: UTF8.self)
            .replacingOccurrences(of: "fixture-access-token", with: accessToken)
        return try AuthBlob(validating: Data(text.utf8))
    }

    private final class Fixture {
        enum InitialState {
            case standard
            case sourceOnly
            case empty
        }

        let root: URL
        let paths: AppPaths
        let source: AccountProfile
        let target: AccountProfile
        let vault = MemoryCredentialVault()
        var session: AcceptanceSession?

        init(initialState: InitialState) throws {
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
            target = try AccountProfile(
                id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
                displayName: "target@example.com"
            )

            let profiles: [AccountProfile]
            let activeProfileID: UUID?
            switch initialState {
            case .standard:
                profiles = [source, target]
                activeProfileID = source.id
            case .sourceOnly:
                profiles = [source]
                activeProfileID = source.id
            case .empty:
                profiles = []
                activeProfileID = nil
            }
            try StateStore(paths: paths).save(
                SwitcherState(
                    sharedCodexHome: paths.codexHome.path,
                    profiles: profiles,
                    activeProfileID: activeProfileID
                )
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func coordinator(
            stateStore: (any StateStoreProtocol)? = nil,
            journalStore: (any SwitchJournalStoreProtocol)? = nil,
            registrationStore: (any RegistrationStoreProtocol)? = nil
        ) -> SwitchCoordinator {
            SwitchCoordinator(
                paths: paths,
                vault: vault,
                sessionFactory: { [weak self] home in
                    guard let self else {
                        throw CodexSwitchError.appServer("fixture coordinator was released")
                    }
                    guard let session = self.session else {
                        throw CodexSwitchError.appServer(
                            "unexpected real runtime requested by core acceptance fixture"
                        )
                    }
                    session.home = home
                    return session
                },
                stateStore: stateStore,
                journalStore: journalStore,
                registrationStore: registrationStore
            )
        }

        func writeShared(_ auth: AuthBlob) throws {
            try writeShared(auth.data)
        }

        func writeShared(_ data: Data) throws {
            try AtomicFileWriter.write(
                data,
                to: paths.authFile,
                requireExistingRegularFile: paths.authFileExists()
            )
        }

        func readShared() throws -> AuthBlob {
            try AuthBlob(validating: readSharedData())
        }

        func readSharedData() throws -> Data {
            try AtomicFileWriter.readSecureFile(
                paths.authFile,
                maximumSize: AuthBlob.maximumSize
            )
        }

        func stateBytes() throws -> Data {
            try AtomicFileWriter.readSecureFile(paths.stateFile, maximumSize: 1_048_576)
        }

        func journalBytes() throws -> Data {
            try AtomicFileWriter.readSecureFile(paths.journalFile, maximumSize: 65_536)
        }
    }

    private final class MemoryCredentialVault: CredentialVault, @unchecked Sendable {
        var records: [UUID: VaultRecord] = [:]
        var deleteCount = 0
        var saveCount = 0
        var readbackOverrideAfterSave: [UUID: VaultRecord] = [:]
        private var pendingReadback: [UUID: VaultRecord] = [:]

        func save(_ record: VaultRecord, displayName: String) throws {
            _ = displayName
            _ = try record.validatedAuth()
            saveCount += 1
            records[record.profileID] = record
            if let override = readbackOverrideAfterSave[record.profileID] {
                pendingReadback[record.profileID] = override
            }
        }

        func load(profileID: UUID) throws -> VaultRecord {
            if let override = pendingReadback.removeValue(forKey: profileID) {
                return override
            }
            guard let record = records[profileID] else {
                throw CodexSwitchError.keychain("fixture credential missing")
            }
            return record
        }

        func contains(profileID: UUID) throws -> Bool {
            records[profileID] != nil
        }

        func delete(profileID: UUID) throws {
            deleteCount += 1
            records.removeValue(forKey: profileID)
        }
    }

    private final class AcceptanceSession: AppServerSession {
        let account: AccountInfo
        let auth: AuthBlob?
        let config: JSONValue
        var methods: [String] = []
        var accountReadCount = 0
        var onAccountRead: (() throws -> Void)?
        var home: URL?
        var privateConfigContents: String?
        var privateFiles: Set<String> = []
        var closeCalls = 0

        init(
            account: AccountInfo,
            auth: AuthBlob? = nil,
            config: JSONValue
        ) {
            self.account = account
            self.auth = auth
            self.config = config
        }

        func initialize() throws -> InitializeResponse {
            methods.append("initialize")
            return try JSONDecoder().decode(InitializeResponse.self, from: Data("{}".utf8))
        }

        func accountRead(refreshToken: Bool, timeout: TimeInterval?) throws -> AccountReadResult {
            _ = refreshToken
            _ = timeout
            methods.append("account/read")
            accountReadCount += 1
            try onAccountRead?()
            return AccountReadResult(account: account, requiresOpenaiAuth: true)
        }

        func accountLoginStartDeviceCode(timeout: TimeInterval?) throws -> DeviceCodeLoginResult {
            _ = timeout
            methods.append("account/login/start")
            guard let home else {
                throw CodexSwitchError.appServer("fixture temporary home missing")
            }
            guard let auth else {
                throw CodexSwitchError.appServer("fixture login auth missing")
            }
            try AtomicFileWriter.write(auth.data, to: home.appendingPathComponent("auth.json"))
            let privateConfig = try AtomicFileWriter.readSecureFile(
                home.appendingPathComponent("config.toml"),
                maximumSize: 65_536
            )
            privateConfigContents = String(decoding: privateConfig, as: UTF8.self)
            privateFiles = Set(try FileManager.default.contentsOfDirectory(atPath: home.path))
            return DeviceCodeLoginResult(
                type: "chatgptDeviceCode",
                loginID: "fixture-login",
                verificationURL: "https://auth.openai.com/codex/device",
                userCode: "ABCD-1234"
            )
        }

        func waitForLoginCompleted(
            loginID: String,
            timeout: TimeInterval?
        ) throws -> LoginCompletedNotification {
            _ = timeout
            methods.append("account/login/completed")
            return LoginCompletedNotification(loginID: loginID, success: true, error: nil)
        }

        func accountLoginCancel(loginID: String, timeout: TimeInterval?) throws {
            _ = loginID
            _ = timeout
            methods.append("account/login/cancel")
        }

        func configRead(includeLayers: Bool, timeout: TimeInterval?) throws -> ConfigReadResult {
            _ = includeLayers
            _ = timeout
            methods.append("config/read")
            return ConfigReadResult(config: config)
        }

        func close() throws {
            closeCalls += 1
            methods.append("close")
        }
    }
}

private extension AppPaths {
    func authFileExists() -> Bool {
        FileManager.default.fileExists(atPath: authFile.path)
    }
}
