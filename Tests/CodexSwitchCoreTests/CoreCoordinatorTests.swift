import Foundation
import XCTest
@testable import CodexSwitchCore

final class CoreCoordinatorTests: XCTestCase {
    func testSwitchUsesFreshSourceAndCommitsTargetWithoutOpeningAppServer() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")

        let result = try fixture.coordinator().switchAccount(targetProfileID: fixture.target.id)

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.profile, fixture.target)
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: target))
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.target.id)
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: source)
        )
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
    }

    func testSameSourceSelectionIsAnHonestNoOp() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")

        let result = try fixture.coordinator().switchAccount(targetProfileID: fixture.source.id)

        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.message.contains("既に"))
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
    }

    func testSameSourceSelectionChecksSharedAccountBeforeReturningNoOp() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let actual = try AuthBlob(validating: makeAuthData(accountID: "target"))
        try fixture.writeShared(actual)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )

        XCTAssertThrowsError(try fixture.coordinator().switchAccount(targetProfileID: fixture.source.id)) { error in
            XCTAssertTrue(String(describing: error).contains("recover"))
        }
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: actual))
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
    }

    func testSameSourceSelectionDoesNotOverwriteVaultWithFreshSharedBytes() throws {
        let fixture = try Fixture()
        let stored = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let fresh = try AuthBlob(validating: Data(
            String(decoding: stored.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-token")
                .utf8
        ))
        try fixture.writeShared(fresh)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: stored),
            displayName: fixture.source.displayName
        )

        let result = try fixture.coordinator().switchAccount(targetProfileID: fixture.source.id)

        XCTAssertFalse(result.changed)
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: fresh))
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: stored)
        )
    }

    func testSourceConflictBeforeWriteLeavesSharedFileAndJournalCleared() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let changed = try AuthBlob(validating: makeAuthData(accountID: "source-changed"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")
        fixture.vault.onSave = { record in
            guard record.profileID == fixture.source.id else { return }
            try fixture.writeShared(changed)
        }

        XCTAssertThrowsError(try fixture.coordinator().switchAccount(targetProfileID: fixture.target.id))
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: changed))
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
    }

    func testSourceVaultSaveFailurePreventsSharedWriteAndJournalCreation() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")
        fixture.vault.onSave = { record in
            if record.profileID == fixture.source.id {
                throw CodexSwitchError.keychain("fixture save failure")
            }
        }

        XCTAssertThrowsError(try fixture.coordinator().switchAccount(targetProfileID: fixture.target.id))
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: source))
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
    }

    func testPostWriteStateFailureRetainsJournalAndNeverRollsBackAuth() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")

        let state = try StateStore(paths: fixture.paths).loadOrCreate()
        let failingState = FailingStateStore(state: state, failingProfileID: fixture.target.id)
        let coordinator = fixture.coordinator(stateStore: failingState)

        XCTAssertThrowsError(try coordinator.switchAccount(targetProfileID: fixture.target.id))
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: target))
        let journal = try XCTUnwrap(try JournalStore(paths: fixture.paths).load())
        XCTAssertEqual(journal.schemaVersion, 3)
        XCTAssertEqual(journal.targetAccountID, "target")
    }

    func testStateWriteErrorStopsBeforeReadbackEvenWhenWriteAlreadyPersisted() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")

        let stateStore = WriteThenThrowStateStore(paths: fixture.paths)
        XCTAssertThrowsError(
            try fixture.coordinator(stateStore: stateStore).switchAccount(targetProfileID: fixture.target.id)
        )
        XCTAssertEqual(stateStore.loadCount, 1)
        XCTAssertNotNil(try JournalStore(paths: fixture.paths).load())
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: target))
    }

    func testSharedAuthRaceBeforeStateCommitRetainsJournalAndLeavesStateUnchanged() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        let changedTarget = try AuthBlob(validating: Data(
            String(decoding: target.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "changed-target-token")
                .utf8
        ))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")
        let stateBefore = try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576)
        XCTAssertThrowsError(
            try fixture.coordinator(progress: { progress in
                guard case .validatingTarget = progress else { return }
                try? fixture.writeShared(changedTarget)
            }).switchAccount(targetProfileID: fixture.target.id)
        )
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576),
            stateBefore
        )
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: changedTarget))
        XCTAssertNotNil(try JournalStore(paths: fixture.paths).load())
    }

    func testSharedAuthRaceAfterStateCommitRetainsJournal() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        let changedTarget = try AuthBlob(validating: Data(
            String(decoding: target.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "changed-target-token")
                .utf8
        ))
        try fixture.writeShared(source)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")
        let journalStore = MutatingJournalStore(paths: fixture.paths) {
            try fixture.writeShared(changedTarget)
        }

        XCTAssertThrowsError(
            try fixture.coordinator(journalStore: journalStore).switchAccount(targetProfileID: fixture.target.id)
        )
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: changedTarget))
        XCTAssertNotNil(try JournalStore(paths: fixture.paths).load())
    }

    func testRecoverReadsTargetAndRepairsVaultAndStateWithoutWritingSharedFile() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        let fresherTargetData = Data(
            String(decoding: target.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-target-access-token")
                .utf8
        )
        let fresherTarget = try AuthBlob(validating: fresherTargetData)
        try fixture.writeShared(fresherTarget)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")
        let journal = SwitchJournal(
            operationID: UUID(),
            sourceProfileID: fixture.source.id,
            targetProfileID: fixture.target.id,
            sourceAccountID: source.accountID,
            targetAccountID: target.accountID,
            sourceAuthHash: source.contentHash,
            targetAuthHash: target.contentHash
        )
        try JournalStore(paths: fixture.paths).save(journal)

        let outcome = try fixture.coordinator().recover()

        guard case let .repairedSwitch(profile) = outcome else {
            return XCTFail("expected repaired switch")
        }
        XCTAssertEqual(profile, fixture.target)
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: fresherTarget))
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.target.id).validatedAuth().hasSameBytes(as: fresherTarget)
        )
        XCTAssertNil(try JournalStore(paths: fixture.paths).load())
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.target.id)
    }

    func testRecoverRejectsSharedAuthRaceBeforeCommittingStateOrClearingJournal() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        let changedTarget = try AuthBlob(validating: Data(
            String(decoding: target.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "changed-target-token")
                .utf8
        ))
        try fixture.writeShared(target)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: target),
            displayName: fixture.target.displayName
        )
        let journal = SwitchJournal(
            operationID: UUID(),
            sourceProfileID: fixture.source.id,
            targetProfileID: fixture.target.id,
            sourceAccountID: source.accountID,
            targetAccountID: target.accountID,
            sourceAuthHash: source.contentHash,
            targetAuthHash: target.contentHash
        )
        try JournalStore(paths: fixture.paths).save(journal)
        let stateBefore = try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576)
        fixture.vault.onSave = { record in
            guard record.profileID == fixture.target.id else { return }
            try fixture.writeShared(changedTarget)
        }

        XCTAssertThrowsError(try fixture.coordinator().recover()) { error in
            XCTAssertTrue(String(describing: error).contains("変更"))
        }

        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: changedTarget))
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576),
            stateBefore
        )
        XCTAssertNotNil(try JournalStore(paths: fixture.paths).load())
    }

    func testRecoverStateRaceDuringStateSaveDoesNotReportSuccess() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        let changedTarget = try AuthBlob(validating: Data(
            String(decoding: target.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "changed-target-token")
                .utf8
        ))
        try fixture.writeShared(target)
        try fixture.vault.save(VaultRecord(profileID: fixture.source.id, auth: source), displayName: "source")
        try fixture.vault.save(VaultRecord(profileID: fixture.target.id, auth: target), displayName: "target")
        let stateStore = MutatingStateStore(paths: fixture.paths) {
            try fixture.writeShared(changedTarget)
        }

        XCTAssertThrowsError(try fixture.coordinator(stateStore: stateStore).recover())
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: changedTarget))
        XCTAssertEqual(
            try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID,
            fixture.target.id
        )
    }

    func testSetupOnlyReadsConfigAndAccountAndUsesAuthBlobAccountID() throws {
        let fixture = try Fixture()
        let auth = try AuthBlob(validating: makeAuthData(accountID: "auth-account"))
        try fixture.writeShared(auth)
        try StateStore(paths: fixture.paths).save(
            SwitcherState(sharedCodexHome: fixture.paths.codexHome.path)
        )
        let session = FixtureSession(
            account: AccountInfo(type: "chatgpt", email: "person@example.com", planType: "team"),
            config: .object(["cli_auth_credentials_store": .string("file")])
        )
        let coordinator = fixture.coordinator(sessionFactory: { _ in session })

        let profile = try coordinator.setup()

        XCTAssertEqual(profile.displayName, "person@example.com")
        XCTAssertEqual(try fixture.vault.load(profileID: profile.id).accountID, "auth-account")
        XCTAssertEqual(session.methods, ["initialize", "config/read", "account/read"])
        XCTAssertEqual(session.accountReadRefreshTokens, [false])
    }

    func testSetupFileStoreFailureProvidesActionableConfigurationGuidance() throws {
        let fixture = try Fixture()
        let auth = try AuthBlob(validating: makeAuthData(accountID: "auth-account"))
        try fixture.writeShared(auth)
        try StateStore(paths: fixture.paths).save(
            SwitcherState(sharedCodexHome: fixture.paths.codexHome.path)
        )
        let session = FixtureSession(
            account: AccountInfo(type: "chatgpt", email: "person@example.com"),
            config: .object(["cli_auth_credentials_store": .string("keychain")])
        )

        XCTAssertThrowsError(
            try fixture.coordinator(sessionFactory: { _ in session }).setup()
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("~/.codex/config.toml"))
            XCTAssertTrue(message.contains("cli_auth_credentials_store = \"file\""))
        }
    }

    func testRegistrationRecoveryWithNoVaultDoesNotSelectProfileOrDeleteCredentials() throws {
        let fixture = try Fixture()
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account"
        )
        try RegistrationStore(paths: fixture.paths).save(pending)
        let before = fixture.vault.deleteCount

        XCTAssertNoThrow(try fixture.coordinator().list())
        XCTAssertEqual(fixture.vault.deleteCount, before)
        let state = try StateStore(paths: fixture.paths).loadOrCreate()
        XCTAssertEqual(state.profiles.map(\.id), [fixture.source.id, fixture.target.id])
    }

    func testListReturnsOneReadOnlySnapshotAndLeavesPendingRegistrationUntouched() throws {
        let fixture = try Fixture()
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account"
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)
        let stateBefore = try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576)

        let snapshot = try fixture.coordinator().list()

        XCTAssertEqual(snapshot.profiles, [fixture.source, fixture.target])
        XCTAssertEqual(snapshot.activeProfileID, fixture.source.id)
        XCTAssertNotNil(try registrationStore.load())
        let state = try StateStore(paths: fixture.paths).loadOrCreate()
        XCTAssertEqual(state.profiles, [fixture.source, fixture.target])
        XCTAssertEqual(state.activeProfileID, fixture.source.id)
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576),
            stateBefore
        )
    }

    func testListOnUnconfiguredHomeDoesNotCreateStateDirectoryOrLock() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home", isDirectory: true)
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexHome.path)
        let paths = AppPaths(
            homeDirectory: home,
            codexHome: codexHome,
            stateRoot: root.appendingPathComponent("state", isDirectory: true)
        )

        let snapshot = try SwitchCoordinator(
            paths: paths,
            vault: MemoryVault(),
            sessionFactory: { _ in
                throw CodexSwitchError.appServer("unexpected app-server request in list fixture")
            }
        ).list()

        XCTAssertTrue(snapshot.profiles.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.lockFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.stateFile.path))
    }

    func testMutationsStopForPendingRegistrationWithoutFinishingIt() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let target = try AuthBlob(validating: makeAuthData(accountID: "target"))
        try fixture.writeShared(source)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: target),
            displayName: fixture.target.displayName
        )
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account"
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)
        let stateBefore = try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576)

        XCTAssertThrowsError(
            try fixture.coordinator().switchAccount(targetProfileID: fixture.target.id)
        ) { error in
            XCTAssertTrue(String(describing: error).contains("recover"))
        }

        XCTAssertEqual(try registrationStore.load(), pending)
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576),
            stateBefore
        )
        XCTAssertEqual(
            Set(fixture.vault.records.keys),
            Set([fixture.source.id, fixture.target.id])
        )
    }

    func testRecoverValidatesPendingSwitchBeforeFinishingRegistration() throws {
        let fixture = try Fixture()
        let addedProfileID = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
        let addedAuth = try AuthBlob(validating: makeAuthData(accountID: "added"))
        let registration = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: addedProfileID,
            kind: .add,
            displayName: "added@example.com",
            accountID: addedAuth.accountID
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(registration)
        try fixture.vault.save(
            VaultRecord(profileID: addedProfileID, auth: addedAuth),
            displayName: registration.displayName
        )
        let stateBefore = try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576)
        try AtomicFileWriter.write(
            Data("{\"schemaVersion\":2,\"operationID\":\"00000000-0000-0000-0000-000000000000\"}".utf8),
            to: fixture.paths.journalFile
        )
        let journalBefore = try AtomicFileWriter.readSecureFile(fixture.paths.journalFile, maximumSize: 65_536)

        XCTAssertThrowsError(try fixture.coordinator().recover())

        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576),
            stateBefore
        )
        XCTAssertEqual(try registrationStore.load(), registration)
        XCTAssertTrue(
            try fixture.vault.load(profileID: addedProfileID).validatedAuth().hasSameBytes(as: addedAuth)
        )
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.journalFile, maximumSize: 65_536),
            journalBefore
        )
    }

    func testRecoverKeepsRegistrationJournalWhenSharedAuthIsMissing() throws {
        let fixture = try Fixture()
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account"
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        XCTAssertThrowsError(try fixture.coordinator().recover())
        XCTAssertEqual(try registrationStore.load(), pending)
    }

    func testRecoverRejectsRegistrationWhenSharedAuthIsNotTheExistingAccount() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let added = try AuthBlob(validating: makeAuthData(accountID: "added"))
        let unrelated = try AuthBlob(validating: makeAuthData(accountID: "unrelated"))
        try fixture.writeShared(unrelated)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        let profileID = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: profileID,
            kind: .add,
            displayName: "added@example.com",
            accountID: added.accountID
        )
        try fixture.vault.save(VaultRecord(profileID: profileID, auth: added), displayName: pending.displayName)
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        XCTAssertThrowsError(try fixture.coordinator().recover())
        XCTAssertEqual(try registrationStore.load(), pending)
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().profiles.count, 2)
    }

    func testRecoverSetupWithoutVaultUsesMatchingSharedAuthAndFinishesRegistration() throws {
        let fixture = try Fixture()
        let auth = try AuthBlob(validating: makeAuthData(accountID: "setup-account"))
        try fixture.writeShared(auth)
        try StateStore(paths: fixture.paths).save(
            SwitcherState(sharedCodexHome: fixture.paths.codexHome.path)
        )
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(uuidString: "33333333-4444-4555-8666-777777777777")!,
            kind: .setup,
            displayName: "setup@example.com",
            accountID: auth.accountID
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        let outcome = try fixture.coordinator().recover()

        guard case let .repairedRegistration(profile) = outcome else {
            return XCTFail("expected repaired registration")
        }
        XCTAssertEqual(profile.id, pending.profileID)
        XCTAssertTrue(try fixture.vault.load(profileID: pending.profileID).validatedAuth().hasSameBytes(as: auth))
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, pending.profileID)
        XCTAssertNil(try registrationStore.load())
    }

    func testRecoverSetupSharedAuthRaceDuringVaultSaveRetainsJournal() throws {
        let fixture = try Fixture()
        let auth = try AuthBlob(validating: makeAuthData(accountID: "setup-account"))
        let changed = try AuthBlob(validating: Data(
            String(decoding: auth.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "changed-setup-token")
                .utf8
        ))
        try fixture.writeShared(auth)
        try StateStore(paths: fixture.paths).save(
            SwitcherState(sharedCodexHome: fixture.paths.codexHome.path)
        )
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .setup,
            displayName: "setup@example.com",
            accountID: auth.accountID
        )
        fixture.vault.onSave = { _ in try fixture.writeShared(changed) }
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)
        let stateBefore = try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576)

        XCTAssertThrowsError(try fixture.coordinator().recover())
        XCTAssertEqual(try registrationStore.load(), pending)
        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(fixture.paths.stateFile, maximumSize: 1_048_576),
            stateBefore
        )
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: changed))
        XCTAssertTrue(try fixture.vault.contains(profileID: pending.profileID))
    }

    func testRecoverSetupWithoutVaultButPersistedFlagKeepsJournal() throws {
        let fixture = try Fixture()
        let auth = try AuthBlob(validating: makeAuthData(accountID: "setup-account"))
        try fixture.writeShared(auth)
        try StateStore(paths: fixture.paths).save(
            SwitcherState(sharedCodexHome: fixture.paths.codexHome.path)
        )
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .setup,
            displayName: "setup@example.com",
            accountID: auth.accountID,
            vaultPersisted: true
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        XCTAssertThrowsError(try fixture.coordinator().recover())
        XCTAssertEqual(try registrationStore.load(), pending)
        XCTAssertFalse(try fixture.vault.contains(profileID: pending.profileID))
    }

    func testRecoverAddWithoutVaultDiscardsOnlyUnrecoverableMetadata() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let freshSource = try AuthBlob(validating: Data(
            String(decoding: source.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-source-access-token")
                .utf8
        ))
        try fixture.writeShared(freshSource)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        var state = try StateStore(paths: fixture.paths).loadOrCreate()
        state.activeProfileID = fixture.target.id
        try StateStore(paths: fixture.paths).save(state)
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account"
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        let outcome = try fixture.coordinator().recover()

        guard case .discardedRegistration = outcome else {
            return XCTFail("expected discarded registration")
        }
        XCTAssertNil(try registrationStore.load())
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().profiles.count, 2)
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: freshSource))
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: freshSource)
        )
        XCTAssertEqual(fixture.vault.deleteCount, 0)
    }

    func testRecoverExistingPendingAddKeepsJournalWhenExistingAccountVaultSaveFails() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let freshSource = try AuthBlob(validating: Data(
            String(decoding: source.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-source-access-token")
                .utf8
        ))
        let added = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(freshSource)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: added),
            displayName: fixture.target.displayName
        )
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: fixture.target.id,
            kind: .add,
            displayName: fixture.target.displayName,
            accountID: added.accountID
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)
        fixture.vault.onSave = { record in
            if record.profileID == fixture.source.id {
                throw CodexSwitchError.keychain("fixture existing-account vault save failure")
            }
        }

        XCTAssertThrowsError(try fixture.coordinator().recover())
        XCTAssertEqual(try registrationStore.load(), pending)
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: freshSource))
    }

    func testRecoverExistingPendingAddKeepsJournalWhenStateAlignmentFails() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let freshSource = try AuthBlob(validating: Data(
            String(decoding: source.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-source-access-token")
                .utf8
        ))
        let added = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(freshSource)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: added),
            displayName: fixture.target.displayName
        )
        var state = try StateStore(paths: fixture.paths).loadOrCreate()
        state.activeProfileID = fixture.target.id
        try StateStore(paths: fixture.paths).save(state)
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: fixture.target.id,
            kind: .add,
            displayName: fixture.target.displayName,
            accountID: added.accountID
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)
        let stateStore = FailingStateStore(
            state: state,
            failingProfileID: fixture.source.id
        )

        XCTAssertThrowsError(
            try fixture.coordinator(stateStore: stateStore).recover()
        )
        XCTAssertEqual(try registrationStore.load(), pending)
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: freshSource)
        )
    }

    func testRecoverExistingPendingAddRepairsCurrentSelectionWithoutChangingAddedVault() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let freshSource = try AuthBlob(validating: Data(
            String(decoding: source.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-source-access-token")
                .utf8
        ))
        let added = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(freshSource)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        try fixture.vault.save(
            VaultRecord(profileID: fixture.target.id, auth: added),
            displayName: fixture.target.displayName
        )
        var state = try StateStore(paths: fixture.paths).loadOrCreate()
        state.activeProfileID = fixture.target.id
        try StateStore(paths: fixture.paths).save(state)
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: fixture.target.id,
            kind: .add,
            displayName: fixture.target.displayName,
            accountID: added.accountID
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        let outcome = try fixture.coordinator().recover()

        guard case let .repairedRegistration(profile) = outcome else {
            return XCTFail("expected repaired registration")
        }
        XCTAssertEqual(profile, fixture.target)
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: freshSource)
        )
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.target.id).validatedAuth().hasSameBytes(as: added)
        )
        XCTAssertNil(try registrationStore.load())
    }

    func testRecoverDiscardedAddKeepsJournalWhenExistingAccountVaultSaveFails() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        try fixture.writeShared(source)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account"
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)
        fixture.vault.onSave = { record in
            if record.profileID == fixture.source.id {
                throw CodexSwitchError.keychain("fixture existing-account vault save failure")
            }
        }

        XCTAssertThrowsError(try fixture.coordinator().recover())
        XCTAssertEqual(try registrationStore.load(), pending)
    }

    func testRecoverDiscardedAddKeepsJournalWhenStateAlignmentFails() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        try fixture.writeShared(source)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        var state = try StateStore(paths: fixture.paths).loadOrCreate()
        state.activeProfileID = fixture.target.id
        try StateStore(paths: fixture.paths).save(state)
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account"
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)
        let stateStore = FailingStateStore(
            state: state,
            failingProfileID: fixture.source.id
        )

        XCTAssertThrowsError(
            try fixture.coordinator(stateStore: stateStore).recover()
        )
        XCTAssertEqual(try registrationStore.load(), pending)
    }

    func testRecoverExistingPendingSetupRefreshesVaultAndReturnsRegistration() throws {
        let fixture = try Fixture()
        let stored = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let fresh = try AuthBlob(validating: Data(
            String(decoding: stored.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-source-access-token")
                .utf8
        ))
        try fixture.writeShared(fresh)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: stored),
            displayName: fixture.source.displayName
        )
        var state = try StateStore(paths: fixture.paths).loadOrCreate()
        state.profiles = [fixture.source]
        state.activeProfileID = fixture.source.id
        try StateStore(paths: fixture.paths).save(state)
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: fixture.source.id,
            kind: .setup,
            displayName: fixture.source.displayName,
            accountID: stored.accountID
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        let outcome = try fixture.coordinator().recover()

        guard case let .repairedRegistration(profile) = outcome else {
            return XCTFail("expected repaired registration")
        }
        XCTAssertEqual(profile, fixture.source)
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: fresh)
        )
        XCTAssertEqual(try StateStore(paths: fixture.paths).loadOrCreate().activeProfileID, fixture.source.id)
        XCTAssertNil(try registrationStore.load())
    }

    func testRecoverPendingAddWithVaultRefreshesCurrentAndPreservesAddedVault() throws {
        let fixture = try Fixture()
        let storedSource = try AuthBlob(validating: makeAuthData(accountID: "source"))
        let freshSource = try AuthBlob(validating: Data(
            String(decoding: storedSource.data, as: UTF8.self)
                .replacingOccurrences(of: "fixture-access-token", with: "fresh-source-access-token")
                .utf8
        ))
        let added = try AuthBlob(validating: makeAuthData(accountID: "added"))
        try fixture.writeShared(freshSource)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: storedSource),
            displayName: fixture.source.displayName
        )
        let addedProfileID = UUID(uuidString: "33333333-4444-4555-8666-777777777777")!
        try fixture.vault.save(
            VaultRecord(profileID: addedProfileID, auth: added),
            displayName: "added@example.com"
        )
        var state = try StateStore(paths: fixture.paths).loadOrCreate()
        state.activeProfileID = fixture.target.id
        try StateStore(paths: fixture.paths).save(state)
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: addedProfileID,
            kind: .add,
            displayName: "added@example.com",
            accountID: added.accountID
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        let outcome = try fixture.coordinator().recover()

        guard case let .repairedRegistration(profile) = outcome else {
            return XCTFail("expected repaired registration")
        }
        XCTAssertEqual(profile.id, addedProfileID)
        let recoveredState = try StateStore(paths: fixture.paths).loadOrCreate()
        XCTAssertEqual(recoveredState.activeProfileID, fixture.source.id)
        XCTAssertTrue(recoveredState.profiles.contains(where: { $0.id == addedProfileID }))
        XCTAssertTrue(
            try fixture.vault.load(profileID: fixture.source.id).validatedAuth().hasSameBytes(as: freshSource)
        )
        XCTAssertTrue(
            try fixture.vault.load(profileID: addedProfileID).validatedAuth().hasSameBytes(as: added)
        )
        XCTAssertNil(try registrationStore.load())
    }

    func testRecoverAddWithoutVaultButPersistedFlagKeepsJournal() throws {
        let fixture = try Fixture()
        let source = try AuthBlob(validating: makeAuthData(accountID: "source"))
        try fixture.writeShared(source)
        try fixture.vault.save(
            VaultRecord(profileID: fixture.source.id, auth: source),
            displayName: fixture.source.displayName
        )
        let pending = try PendingCredentialRegistration(
            operationID: UUID(),
            profileID: UUID(),
            kind: .add,
            displayName: "added@example.com",
            accountID: "added-account",
            vaultPersisted: true
        )
        let registrationStore = RegistrationStore(paths: fixture.paths)
        try registrationStore.save(pending)

        XCTAssertThrowsError(try fixture.coordinator().recover())
        XCTAssertEqual(try registrationStore.load(), pending)
        XCTAssertTrue(try fixture.readShared().hasSameBytes(as: source))
    }

    func testLegacyPendingJournalsAreRejectedWithoutRemovingTheirBytes() throws {
        let fixture = try Fixture()
        try fixture.paths.ensureRuntimeDirectories()
        let legacy = Data("{\"schemaVersion\":1,\"operationID\":\"00000000-0000-0000-0000-000000000000\"}".utf8)
        try AtomicFileWriter.write(legacy, to: fixture.paths.journalFile)

        XCTAssertThrowsError(try JournalStore(paths: fixture.paths).load()) { error in
            XCTAssertTrue(String(describing: error).contains("旧版"))
        }
        let after = try AtomicFileWriter.readSecureFile(fixture.paths.journalFile, maximumSize: 65_536)
        XCTAssertEqual(after, legacy)

        let future = Data("{\"schemaVersion\":99}".utf8)
        try AtomicFileWriter.write(future, to: fixture.paths.journalFile)
        XCTAssertThrowsError(try JournalStore(paths: fixture.paths).load()) { error in
            XCTAssertFalse(String(describing: error).contains("旧版"))
        }
    }

    func testLegacyAndFutureRegistrationJournalVersionsGiveDifferentGuidance() throws {
        let fixture = try Fixture()
        try fixture.paths.ensureRuntimeDirectories()
        let legacy = Data("{\"schemaVersion\":1}".utf8)
        try AtomicFileWriter.write(legacy, to: fixture.paths.registrationJournalFile)

        XCTAssertThrowsError(try RegistrationStore(paths: fixture.paths).load()) { error in
            XCTAssertTrue(String(describing: error).contains("旧版"))
        }

        let future = Data("{\"schemaVersion\":99}".utf8)
        try AtomicFileWriter.write(future, to: fixture.paths.registrationJournalFile)
        XCTAssertThrowsError(try RegistrationStore(paths: fixture.paths).load()) { error in
            XCTAssertFalse(String(describing: error).contains("旧版"))
        }
    }

    private final class Fixture {
        let root: URL
        let paths: AppPaths
        let source: AccountProfile
        let target: AccountProfile
        let vault = MemoryVault()

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
            target = try AccountProfile(
                id: UUID(uuidString: "22222222-3333-4444-8555-666666666666")!,
                displayName: "target@example.com"
            )
            let state = SwitcherState(sharedCodexHome: codexHome.path, profiles: [source, target], activeProfileID: source.id)
            try StateStore(paths: paths).save(state)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func writeShared(_ auth: AuthBlob) throws {
            if !FileManager.default.fileExists(atPath: paths.authFile.path) {
                try AtomicFileWriter.write(auth.data, to: paths.authFile)
            } else {
                try AtomicFileWriter.write(auth.data, to: paths.authFile, requireExistingRegularFile: true)
            }
        }

        func readShared() throws -> AuthBlob {
            try AuthBlob(validating: AtomicFileWriter.readSecureFile(paths.authFile, maximumSize: AuthBlob.maximumSize))
        }

        func coordinator(
            stateStore: (any StateStoreProtocol)? = nil,
            journalStore: (any SwitchJournalStoreProtocol)? = nil,
            sessionFactory: SwitchCoordinator.SessionFactory? = nil,
            progress: @escaping SwitchCoordinator.ProgressHandler = { _ in }
        ) -> SwitchCoordinator {
            SwitchCoordinator(
                paths: paths,
                vault: vault,
                sessionFactory: sessionFactory ?? { _ in
                    throw CodexSwitchError.appServer("unexpected app-server request in core fixture")
                },
                stateStore: stateStore,
                journalStore: journalStore,
                progress: progress
            )
        }
    }

    private final class MemoryVault: CredentialVault, @unchecked Sendable {
        var records: [UUID: VaultRecord] = [:]
        var onSave: ((VaultRecord) throws -> Void)?
        var deleteCount = 0

        func save(_ record: VaultRecord, displayName: String) throws {
            _ = displayName
            _ = try record.validatedAuth()
            try onSave?(record)
            records[record.profileID] = record
        }

        func load(profileID: UUID) throws -> VaultRecord {
            guard let record = records[profileID] else {
                throw CodexSwitchError.keychain("credential missing")
            }
            return record
        }

        func contains(profileID: UUID) throws -> Bool { records[profileID] != nil }

        func delete(profileID: UUID) throws {
            deleteCount += 1
            records.removeValue(forKey: profileID)
        }
    }

    private final class FailingStateStore: StateStoreProtocol {
        var state: SwitcherState
        let failingProfileID: UUID

        init(state: SwitcherState, failingProfileID: UUID) {
            self.state = state
            self.failingProfileID = failingProfileID
        }

        func loadOrCreate() throws -> SwitcherState { state }

        func save(_ state: SwitcherState) throws {
            if state.activeProfileID == failingProfileID {
                throw CodexSwitchError.state("fixture state write failure")
            }
            self.state = state
        }
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

    private final class MutatingStateStore: StateStoreProtocol {
        private let backing: StateStore
        private let onSave: () throws -> Void

        init(paths: AppPaths, onSave: @escaping () throws -> Void) {
            backing = StateStore(paths: paths)
            self.onSave = onSave
        }

        func loadOrCreate() throws -> SwitcherState { try backing.loadOrCreate() }

        func save(_ state: SwitcherState) throws {
            try backing.save(state)
            try onSave()
        }
    }

    private final class MutatingJournalStore: SwitchJournalStoreProtocol {
        private let backing: JournalStore
        private let onSave: () throws -> Void
        private var saveCount = 0

        init(paths: AppPaths, onSave: @escaping () throws -> Void) {
            backing = JournalStore(paths: paths)
            self.onSave = onSave
        }

        func load() throws -> SwitchJournal? { try backing.load() }

        func save(_ journal: SwitchJournal) throws {
            try backing.save(journal)
            saveCount += 1
            if saveCount == 3 { try onSave() }
        }

        func remove() throws { try backing.remove() }
    }

    private final class FixtureSession: AppServerSession {
        let account: AccountInfo
        let config: JSONValue
        var methods: [String] = []
        var accountReadRefreshTokens: [Bool] = []

        init(account: AccountInfo, config: JSONValue) {
            self.account = account
            self.config = config
        }

        func initialize() throws -> InitializeResponse {
            methods.append("initialize")
            return try JSONDecoder().decode(InitializeResponse.self, from: Data("{}".utf8))
        }

        func accountRead(refreshToken: Bool, timeout: TimeInterval?) throws -> AccountReadResult {
            _ = timeout
            methods.append("account/read")
            accountReadRefreshTokens.append(refreshToken)
            return AccountReadResult(account: account, requiresOpenaiAuth: true)
        }

        func accountLoginStartDeviceCode(timeout: TimeInterval?) throws -> DeviceCodeLoginResult {
            _ = timeout
            throw CodexSwitchError.appServer("not used")
        }

        func waitForLoginCompleted(loginID: String, timeout: TimeInterval?) throws -> LoginCompletedNotification {
            _ = loginID
            _ = timeout
            throw CodexSwitchError.appServer("not used")
        }

        func accountLoginCancel(loginID: String, timeout: TimeInterval?) throws {
            _ = loginID
            _ = timeout
        }

        func configRead(includeLayers: Bool, timeout: TimeInterval?) throws -> ConfigReadResult {
            _ = includeLayers
            _ = timeout
            methods.append("config/read")
            return ConfigReadResult(config: config)
        }

        func close() throws {}
    }
}
