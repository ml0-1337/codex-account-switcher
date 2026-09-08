import Foundation

public enum SwitchProgress: Sendable, Equatable {
    case preparing(String)
    case waitingForLogin(verificationURL: URL, userCode: String)
    case savingCurrentAccount
    case materializingTarget
    case validatingTarget
    case cleanupFailed(temporaryHome: URL, reason: String)
    case completed(String)
}

public struct SwitchOutcome: Sendable, Equatable {
    public let profile: AccountProfile?
    public let changed: Bool
    public let message: String

    public init(
        profile: AccountProfile? = nil,
        changed: Bool,
        message: String
    ) {
        self.profile = profile
        self.changed = changed
        self.message = message
    }
}

public enum RecoveryOutcome: Sendable, Equatable {
    case repairedSwitch(AccountProfile)
    case repairedRegistration(AccountProfile)
    case discardedRegistration
    case repairedState(AccountProfile)
    case noPendingOperation
}

public protocol AppServerSession: AnyObject {
    func initialize() throws -> InitializeResponse
    func accountRead(refreshToken: Bool, timeout: TimeInterval?) throws -> AccountReadResult
    func accountLoginStartDeviceCode(timeout: TimeInterval?) throws -> DeviceCodeLoginResult
    func accountLoginCancel(loginID: String, timeout: TimeInterval?) throws
    func waitForLoginCompleted(
        loginID: String,
        timeout: TimeInterval?
    ) throws -> LoginCompletedNotification
    func configRead(includeLayers: Bool, timeout: TimeInterval?) throws -> ConfigReadResult
    func close() throws
}

extension AppServerClient: AppServerSession {}

public final class SwitchCoordinator {
    public typealias ProgressHandler = (SwitchProgress) -> Void
    public typealias SessionFactory = (URL) throws -> any AppServerSession
    public typealias InstallationProvider = () throws -> CodexInstallation

    private let paths: AppPaths
    private let vault: any CredentialVault
    private let stateStore: any StateStoreProtocol
    private let journalStore: any SwitchJournalStoreProtocol
    private let registrationStore: any RegistrationStoreProtocol
    private let sessionFactory: SessionFactory?
    private let installationProvider: InstallationProvider?
    private let cancellation: CancellationToken?
    private let progress: ProgressHandler

    public init(
        paths: AppPaths,
        vault: any CredentialVault,
        sessionFactory: SessionFactory? = nil,
        installationProvider: InstallationProvider? = nil,
        stateStore: (any StateStoreProtocol)? = nil,
        journalStore: (any SwitchJournalStoreProtocol)? = nil,
        registrationStore: (any RegistrationStoreProtocol)? = nil,
        cancellation: CancellationToken? = nil,
        progress: @escaping ProgressHandler = { _ in }
    ) {
        self.paths = paths
        self.vault = vault
        self.stateStore = stateStore ?? StateStore(paths: paths)
        self.journalStore = journalStore ?? JournalStore(paths: paths)
        self.registrationStore = registrationStore ?? RegistrationStore(paths: paths)
        self.sessionFactory = sessionFactory
        self.installationProvider = installationProvider
        self.cancellation = cancellation
        self.progress = progress
    }

    @discardableResult
    public func setup() throws -> AccountProfile {
        try withLock {
            try prepareMutation()
            var state = try stateStore.loadOrCreate()
            if let existing = configuredProfile(in: state) {
                progress(.completed("\(existing.displayName) は既に登録されています。"))
                return existing
            }
            guard state.profiles.isEmpty, state.activeProfileID == nil else {
                throw CodexSwitchError.state("初期設定の状態を確認できません。")
            }

            progress(.preparing("現在のアカウントを登録します。"))
            let beforeAuth = try readSharedAuth()
            let session = try makeSession(codexHome: paths.codexHome)
            do {
                _ = try session.initialize()
                let config = try session.configRead(includeLayers: true, timeout: nil)
                try requireFileCredentialStore(config)
                let account = try session.accountRead(refreshToken: false, timeout: nil)
                let afterAuth = try readSharedAuth()
                guard beforeAuth.hasSameBytes(as: afterAuth) else {
                    throw CodexSwitchError.state(
                        "アカウント情報の確認中に共有認証ファイルが変更されました。"
                    )
                }
                try cancellation?.check()
                try validateAccount(account)
                let profile = try makeProfile(
                    id: UUID(),
                    account: account.account,
                    auth: afterAuth,
                    existingProfiles: []
                )
                try session.close()
                try cancellation?.check()

                let registration = try PendingCredentialRegistration(
                    operationID: UUID(),
                    profileID: profile.id,
                    kind: .setup,
                    displayName: profile.displayName,
                    accountID: afterAuth.accountID,
                    email: normalizedEmail(account.account?.email),
                    planType: account.account?.planType,
                    profileCreatedAt: profile.createdAt
                )
                try registrationStore.save(registration)
                try saveAndVerifyVault(
                    VaultRecord(profileID: profile.id, auth: afterAuth),
                    displayName: profile.displayName
                )
                try cancellation?.check()
                try registrationStore.save(registration.markingVaultPersisted())

                state.profiles = [profile]
                state.activeProfileID = profile.id
                try cancellation?.check()
                try saveAndVerifyState(state)
                try cancellation?.check()
                try registrationStore.remove()
                progress(.completed("\(profile.displayName) を登録しました。"))
                return profile
            } catch {
                do {
                    try session.close()
                } catch {
                    throw CodexSwitchError.appServer("app-serverを停止できません。")
                }
                throw error
            }
        }
    }

    @discardableResult
    public func add() throws -> AccountProfile {
        try withLock {
            try prepareMutation()
            var state = try stateStore.loadOrCreate()
            guard !state.profiles.isEmpty, state.activeProfileID != nil else {
                throw CodexSwitchError.state("先にsetupを実行してください。")
            }

            let temporaryHome = try TemporaryCodexHome(paths: paths)
            var session: (any AppServerSession)?
            var loginID: String?
            var loginCancellationSent = false
            do {
                session = try makeSession(codexHome: temporaryHome.url)
                guard let activeSession = session else {
                    throw CodexSwitchError.appServer("ログイン用app-serverを作成できません。")
                }
                _ = try activeSession.initialize()
                let login = try activeSession.accountLoginStartDeviceCode(timeout: nil)
                guard login.type == "chatgptDeviceCode",
                      !login.loginID.isEmpty,
                      login.loginID.count <= 512,
                      login.loginID.unicodeScalars.allSatisfy({
                          !CharacterSet.controlCharacters.contains($0)
                      })
                else {
                    throw CodexSwitchError.appServer("Device Codeログインの応答が不正です。")
                }
                loginID = login.loginID
                try cancellation?.check()
                let validated = try ValidatedDeviceCodeLogin(
                    verificationURL: login.verificationURL,
                    userCode: login.userCode
                )
                progress(.waitingForLogin(
                    verificationURL: validated.verificationURL,
                    userCode: validated.userCode
                ))

                let completed: LoginCompletedNotification
                do {
                    completed = try activeSession.waitForLoginCompleted(
                        loginID: login.loginID,
                        timeout: nil
                    )
                } catch {
                    // The cancellation request intentionally remains possible
                    // after CancellationToken has been set.
                    try? activeSession.accountLoginCancel(loginID: login.loginID, timeout: 1)
                    loginCancellationSent = true
                    throw error
                }
                try cancellation?.check()
                guard completed.loginID == login.loginID else {
                    throw CodexSwitchError.appServer("ログイン完了通知の識別子が一致しません。")
                }
                guard completed.success else {
                    throw CodexSwitchError.appServer("アカウントのログインに失敗しました。")
                }

                let account = try activeSession.accountRead(refreshToken: false, timeout: nil)
                let auth = try temporaryHome.readAuth()
                try cancellation?.check()
                try validateAccount(account)
                for existing in state.profiles {
                    let existingRecord = try vault.load(profileID: existing.id)
                    guard existingRecord.accountID != auth.accountID else {
                        throw CodexSwitchError.invalidInput("このアカウントはすでに登録されています。")
                    }
                }
                let profile = try makeProfile(
                    id: UUID(),
                    account: account.account,
                    auth: auth,
                    existingProfiles: state.profiles
                )

                try activeSession.close()
                session = nil
                try temporaryHome.cleanup()
                try cancellation?.check()

                let registration = try PendingCredentialRegistration(
                    operationID: UUID(),
                    profileID: profile.id,
                    kind: .add,
                    displayName: profile.displayName,
                    accountID: auth.accountID,
                    email: normalizedEmail(account.account?.email),
                    planType: account.account?.planType,
                    profileCreatedAt: profile.createdAt
                )
                try registrationStore.save(registration)
                try saveAndVerifyVault(
                    VaultRecord(profileID: profile.id, auth: auth),
                    displayName: profile.displayName
                )
                try cancellation?.check()
                try registrationStore.save(registration.markingVaultPersisted())
                state.profiles.append(profile)
                try cancellation?.check()
                try saveAndVerifyState(state)
                try cancellation?.check()
                try registrationStore.remove()
                progress(.completed("\(profile.displayName) を追加しました。"))
                return profile
            } catch {
                let operationError = error
                if let loginID, let session, !loginCancellationSent {
                    try? session.accountLoginCancel(loginID: loginID, timeout: 1)
                }
                var cleanupError: Error?
                if let session {
                    do {
                        try session.close()
                    } catch {
                        cleanupError = error
                        temporaryHome.preserveUntilSystemTemporaryCleanup()
                    }
                }
                if cleanupError == nil {
                    do {
                        try temporaryHome.cleanup()
                    } catch {
                        cleanupError = error
                        temporaryHome.preserveUntilSystemTemporaryCleanup()
                    }
                }
                if let cleanupError {
                    // This diagnostic bypasses cancellation-aware ordinary
                    // progress output. It contains only the exact owned path
                    // and a bounded, redacted cleanup reason.
                    progress(.cleanupFailed(
                        temporaryHome: temporaryHome.preservedPath,
                        reason: SafeText.bounded(String(describing: cleanupError))
                    ))
                    throw CodexSwitchError.state(
                        "アカウント追加に失敗し、一時CODEX_HOMEを安全に削除できませんでした。"
                    )
                }
                throw operationError
            }
        }
    }

    public func list() throws -> SwitcherState {
        try cancellation?.check()
        return try stateStore.loadOrCreate()
    }

    @discardableResult
    public func switchAccount(targetProfileID: UUID) throws -> SwitchOutcome {
        try withLock {
            try prepareMutation()
            var state = try stateStore.loadOrCreate()
            guard let sourceID = state.activeProfileID,
                  let sourceProfile = state.profiles.first(where: { $0.id == sourceID }),
                  let targetProfile = state.profiles.first(where: { $0.id == targetProfileID })
            else {
                throw CodexSwitchError.state("切替元または切替先を確認できません。")
            }

            try cancellation?.check()
            let sourceRecord = try vault.load(profileID: sourceID)
            let sourceRegistered = try sourceRecord.validatedAuth()
            let current = try readSharedAuth()
            try cancellation?.check()
            guard current.accountID == sourceRegistered.accountID else {
                throw CodexSwitchError.state(
                    "現在の認証と最後に切替指定したアカウントが一致しません。codex-switch recover を実行してください。"
                )
            }
            if sourceID == targetProfileID {
                let message = "\(targetProfile.displayName) は既に選択されています。"
                progress(.completed(message))
                return SwitchOutcome(profile: targetProfile, changed: false, message: message)
            }

            let targetRecord = try vault.load(profileID: targetProfileID)
            let targetAuth = try targetRecord.validatedAuth()
            guard sourceRegistered.accountID != targetAuth.accountID else {
                throw CodexSwitchError.state("切替元と切替先のアカウント識別子が重複しています。")
            }

            progress(.savingCurrentAccount)
            try saveAndVerifyVault(
                VaultRecord(profileID: sourceID, auth: current),
                displayName: sourceProfile.displayName
            )

            var journal = SwitchJournal(
                operationID: UUID(),
                sourceProfileID: sourceID,
                targetProfileID: targetProfileID,
                sourceAccountID: current.accountID,
                targetAccountID: targetAuth.accountID,
                sourceAuthHash: current.contentHash,
                targetAuthHash: targetAuth.contentHash
            )
            try journalStore.save(journal)
            var writeAttempted = false
            do {
                progress(.materializingTarget)
                try cancellation?.check()
                let beforeWrite = try readSharedAuth()
                guard beforeWrite.hasSameBytes(as: current) else {
                    throw CodexSwitchError.state(
                        "準備中に共有認証ファイルが変更されました。認証ファイルは変更していません。"
                    )
                }

                try cancellation?.check()
                writeAttempted = true
                try AtomicFileWriter.write(
                    targetAuth.data,
                    to: paths.authFile,
                    requireExistingRegularFile: true
                )
                try cancellation?.check()
                let persistedTarget = try readSharedAuth()
                guard persistedTarget.hasSameBytes(as: targetAuth) else {
                    throw CodexSwitchError.state("置き換えた認証ファイルを照合できません。")
                }
                journal.stage = .targetMaterialized
                try journalStore.save(journal)

                progress(.validatingTarget)
                try cancellation?.check()
                try verifySharedAuthUnchanged(targetAuth)
                state.activeProfileID = targetProfileID
                try saveAndVerifyState(state)
                try cancellation?.check()
                journal.stage = .stateCommitted
                try journalStore.save(journal)
                try verifySharedAuthUnchanged(targetAuth)
                try journalStore.remove()
                let message = "\(targetProfile.displayName) に切り替えました。"
                progress(.completed(message))
                return SwitchOutcome(profile: targetProfile, changed: true, message: message)
            } catch {
                if writeAttempted {
                    // The shared auth file is authoritative after a write
                    // attempt. Never roll it back; retain the v3 journal.
                    throw CodexSwitchError.state(
                        "共有認証ファイルへの書き込みを開始しましたが、切替処理を完了・確認できません。切替記録を保持しています。codex-switch recover を実行してください。"
                    )
                }
                do {
                    try journalStore.remove()
                } catch {
                    throw CodexSwitchError.state(
                        "認証ファイルを変更する前に切替記録を削除できません。切替記録を保持しています。"
                    )
                }
                throw error
            }
        }
    }

    @discardableResult
    public func recover() throws -> RecoveryOutcome {
        try withLock {
            try cancellation?.check()
            // Validate both pending stores before changing any management
            // record. In particular, an unsupported switch journal must not
            // be hidden by finishing a valid registration first.
            let pendingRegistration = try registrationStore.load()
            let pendingSwitch = try journalStore.load()
            if let journal = pendingSwitch {
                return try recoverSwitch(journal)
            }
            if let pendingRegistration {
                return try finishPendingRegistration(pendingRegistration)
            }

            let state = try stateStore.loadOrCreate()
            guard !state.profiles.isEmpty else {
                let message = "復旧する処理はありません。"
                progress(.completed(message))
                return .noPendingOperation
            }
            let actual = try readSharedAuth()
            var matches: [(AccountProfile, VaultRecord)] = []
            for profile in state.profiles {
                guard let record = try? vault.load(profileID: profile.id),
                      let validated = try? record.validatedAuth(),
                      validated.accountID == actual.accountID
                else { continue }
                matches.append((profile, record))
            }
            guard matches.count == 1 else {
                throw CodexSwitchError.state("共有認証に一致する登録済みアカウントを一意に確認できません。")
            }
            let (profile, _) = matches[0]
            try cancellation?.check()
            try saveAndVerifyVault(
                VaultRecord(profileID: profile.id, auth: actual),
                displayName: profile.displayName
            )
            try verifySharedAuthUnchanged(actual)
            try cancellation?.check()
            if state.activeProfileID != profile.id {
                var repaired = state
                repaired.activeProfileID = profile.id
                try saveAndVerifyState(repaired)
            }
            try verifySharedAuthUnchanged(actual)
            let outcome = RecoveryOutcome.repairedState(profile)
            progress(.completed("\(profile.displayName) の状態を復旧しました。"))
            return outcome
        }
    }

    private func recoverSwitch(_ inputJournal: SwitchJournal) throws -> RecoveryOutcome {
        var journal = inputJournal
        var state = try stateStore.loadOrCreate()
        guard let sourceProfile = state.profiles.first(where: { $0.id == journal.sourceProfileID }),
              let targetProfile = state.profiles.first(where: { $0.id == journal.targetProfileID })
        else {
            throw CodexSwitchError.state("復旧対象のプロファイルが登録一覧にありません。")
        }
        let source = try vault.load(profileID: journal.sourceProfileID).validatedAuth()
        let target = try vault.load(profileID: journal.targetProfileID).validatedAuth()
        guard source.accountID == journal.sourceAccountID,
              target.accountID == journal.targetAccountID
        else {
            throw CodexSwitchError.state("切替記録と保存済みアカウント識別子が一致しません。")
        }

        // Recovery never writes paths.authFile. It reads the actual file and
        // uses that content as the freshest vault record.
        let actual: AuthBlob
        do {
            actual = try readSharedAuth()
        } catch {
            throw CodexSwitchError.state("処理中に共有認証ファイルを確認できません。切替記録を保持しています。")
        }
        let matchedProfile: AccountProfile
        if actual.accountID == source.accountID {
            matchedProfile = sourceProfile
            try cancellation?.check()
            try saveAndVerifyVault(
                VaultRecord(profileID: sourceProfile.id, auth: actual),
                displayName: sourceProfile.displayName
            )
            journal.targetAuthHash = target.contentHash
            journal.stage = .stateCommitted
        } else if actual.accountID == target.accountID {
            matchedProfile = targetProfile
            try cancellation?.check()
            try saveAndVerifyVault(
                VaultRecord(profileID: targetProfile.id, auth: actual),
                displayName: targetProfile.displayName
            )
            journal.targetAuthHash = actual.contentHash
            journal.stage = .targetValidated
        } else {
            throw CodexSwitchError.state("共有認証が切替記録の対象アカウントと一致しません。切替記録を保持しています。")
        }

        try verifySharedAuthUnchanged(actual)
        state.activeProfileID = matchedProfile.id
        try cancellation?.check()
        try saveAndVerifyState(state)
        try cancellation?.check()
        try journalStore.save(journal)
        try cancellation?.check()
        try verifySharedAuthUnchanged(actual)
        try journalStore.remove()
        progress(.completed("\(matchedProfile.displayName) の状態へ復旧しました。"))
        return .repairedSwitch(matchedProfile)
    }

    /// Finishes a registration journal only after validating the current shared
    /// auth file. Recovery never writes that file and never deletes a vault
    /// item. A missing add vault is recoverable only by discarding its metadata
    /// record; setup can instead recover the shared auth into its vault.
    private func finishPendingRegistration(_ pending: PendingCredentialRegistration) throws -> RecoveryOutcome {
        // Shared auth is the first management input validated. This prevents a
        // malformed, missing, or unrelated auth file from being paired with a
        // vault or state entry and then clearing the journal.
        let sharedAuth: AuthBlob
        do {
            sharedAuth = try readSharedAuth()
        } catch {
            throw CodexSwitchError.state("共有認証ファイルを確認できません。登録記録を保持しています。")
        }
        try cancellation?.check()

        var state = try stateStore.loadOrCreate()
        let existingPendingProfile = state.profiles.first(where: { $0.id == pending.profileID })
        let currentProfile: AccountProfile?
        if pending.kind == .setup {
            guard sharedAuth.accountID == pending.accountID else {
                throw CodexSwitchError.state(
                    "共有認証が登録記録のアカウントと一致しません。登録記録を保持します。"
                )
            }
            currentProfile = nil
        } else {
            // An add operation runs in an isolated home and leaves the shared
            // account untouched. Its recovery therefore requires one and only
            // one already-registered vault to identify that shared account.
            currentProfile = try existingRegisteredProfiles(
                matching: sharedAuth.accountID,
                excluding: pending.profileID,
                in: state
            ).first
        }

        if let existingPendingProfile {
            guard try vault.contains(profileID: existingPendingProfile.id) else {
                throw CodexSwitchError.state("登録済みプロファイルの認証情報がありません。登録記録を保持します。")
            }
            let record = try vault.load(profileID: existingPendingProfile.id)
            let auth = try record.validatedAuth()
            guard auth.accountID == pending.accountID else {
                throw CodexSwitchError.state("登録記録と保存済みアカウント識別子が一致しません。")
            }
            if pending.kind == .setup {
                // Setup's pending profile is the profile represented by the
                // shared file. Always refresh it with the latest bytes.
                try saveLatestSharedAuth(
                    sharedAuth,
                    to: existingPendingProfile
                )
                try alignRecoveredState(
                    &state,
                    activeProfileID: existingPendingProfile.id,
                    forceSave: false,
                    sharedAuth: sharedAuth
                )
            } else {
                guard let currentProfile else {
                    throw CodexSwitchError.state(
                        "共有認証に一致する登録済みアカウントを一意に確認できません。登録記録を保持します。"
                    )
                }
                guard auth.accountID != sharedAuth.accountID else {
                    throw CodexSwitchError.invalidInput("このアカウントはすでに登録されています。")
                }
                // The added vault is already present and must remain untouched;
                // only refresh the existing profile which owns the shared file.
                try saveLatestSharedAuth(sharedAuth, to: currentProfile)
                try alignRecoveredState(
                    &state,
                    activeProfileID: currentProfile.id,
                    forceSave: false,
                    sharedAuth: sharedAuth
                )
            }
            try cancellation?.check()
            try registrationStore.remove()
            return .repairedRegistration(existingPendingProfile)
        }

        if pending.kind == .setup {
            guard state.profiles.isEmpty, state.activeProfileID == nil else {
                throw CodexSwitchError.state("初期設定の状態を確認できません。登録記録を保持します。")
            }
            let profile = try AccountProfile(
                id: pending.profileID,
                displayName: pending.displayName,
                createdAt: pending.profileCreatedAt ?? pending.createdAt
            )
            let hasVault = try vault.contains(profileID: pending.profileID)
            if hasVault {
                let record = try vault.load(profileID: pending.profileID)
                let auth = try record.validatedAuth()
                guard auth.accountID == pending.accountID else {
                    throw CodexSwitchError.state("登録記録と保存済みアカウント識別子が一致しません。")
                }
            } else if pending.vaultPersisted {
                throw CodexSwitchError.state(
                    "登録記録は認証情報の保存済み状態ですが、認証情報がありません。登録記録を保持します。"
                )
            }
            try saveLatestSharedAuth(sharedAuth, to: profile)
            state.profiles.append(profile)
            state.activeProfileID = profile.id
            try alignRecoveredState(
                &state,
                activeProfileID: profile.id,
                forceSave: true,
                sharedAuth: sharedAuth
            )
            try cancellation?.check()
            try registrationStore.remove()
            return .repairedRegistration(profile)
        }

        guard let currentProfile else {
            throw CodexSwitchError.state(
                "共有認証に一致する登録済みアカウントを一意に確認できません。登録記録を保持します。"
            )
        }

        let hasVault = try vault.contains(profileID: pending.profileID)
        var addedProfile: AccountProfile?
        if hasVault {
            let record = try vault.load(profileID: pending.profileID)
            let auth = try record.validatedAuth()
            guard auth.accountID == pending.accountID else {
                throw CodexSwitchError.state("登録記録と保存済みアカウント識別子が一致しません。")
            }
            guard auth.accountID != sharedAuth.accountID else {
                throw CodexSwitchError.invalidInput("このアカウントはすでに登録されています。")
            }
            let profile = try AccountProfile(
                id: pending.profileID,
                displayName: pending.displayName,
                createdAt: pending.profileCreatedAt ?? pending.createdAt
            )
            guard !state.profiles.contains(where: { sameDisplayName($0.displayName, profile.displayName) }) else {
                throw CodexSwitchError.state("登録記録の表示名が現在の状態と重複しています。")
            }
            addedProfile = profile
        } else if pending.vaultPersisted {
            throw CodexSwitchError.state(
                "登録記録は認証情報の保存済み状態ですが、認証情報がありません。登録記録を保持します。"
            )
        }

        // The current shared account is the only recoverable credential for
        // this interrupted add. Refresh its existing vault and select that
        // profile; never select or synthesize the missing added profile.
        try saveLatestSharedAuth(sharedAuth, to: currentProfile)
        if let addedProfile {
            state.profiles.append(addedProfile)
            try alignRecoveredState(
                &state,
                activeProfileID: currentProfile.id,
                forceSave: true,
                sharedAuth: sharedAuth
            )
            try cancellation?.check()
            try registrationStore.remove()
            return .repairedRegistration(addedProfile)
        }

        try alignRecoveredState(
            &state,
            activeProfileID: currentProfile.id,
            forceSave: false,
            sharedAuth: sharedAuth
        )
        try cancellation?.check()
        try registrationStore.remove()
        return .discardedRegistration
    }

    private func prepareMutation() throws {
        try cancellation?.check()
        // Pending records are recovery-owned. Loading both before throwing
        // keeps setup/add/switch from changing any state while either record
        // is present, including when the other record is unsupported.
        let pendingRegistration = try registrationStore.load()
        let pendingSwitch = try journalStore.load()
        guard pendingRegistration == nil, pendingSwitch == nil else {
            throw CodexSwitchError.state("未完了の処理があります。先にrecoverを実行してください。")
        }
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try paths.ensureRuntimeDirectories()
        let lock = try FileLock(url: paths.lockFile)
        return try withExtendedLifetime(lock) { try body() }
    }

    private func makeSession(codexHome: URL) throws -> any AppServerSession {
        if let sessionFactory { return try sessionFactory(codexHome) }
        let installation = try installationProvider?() ?? CodexInstallation.discover(cancellation: cancellation)
        return try AppServerClient(
            codexExecutable: installation.codexExecutableURL,
            codexHome: codexHome,
            cancellation: cancellation
        )
    }

    private func readSharedAuth() throws -> AuthBlob {
        let data = try AtomicFileWriter.readSecureFile(
            paths.authFile,
            maximumSize: AuthBlob.maximumSize
        )
        return try AuthBlob(validating: data)
    }

    private func saveAndVerifyVault(_ record: VaultRecord, displayName: String) throws {
        try vault.save(record, displayName: displayName)
        let persisted = try vault.load(profileID: record.profileID)
        let expected = try record.validatedAuth()
        let actual = try persisted.validatedAuth()
        guard persisted.accountID == record.accountID,
              expected.hasSameBytes(as: actual)
        else {
            throw CodexSwitchError.keychain("保存した認証情報の照合に失敗しました。")
        }
    }

    private func saveLatestSharedAuth(
        _ sharedAuth: AuthBlob,
        to profile: AccountProfile
    ) throws {
        try cancellation?.check()
        try saveAndVerifyVault(
            VaultRecord(profileID: profile.id, auth: sharedAuth),
            displayName: profile.displayName
        )
        try cancellation?.check()
        try verifySharedAuthUnchanged(sharedAuth)
    }

    private func alignRecoveredState(
        _ state: inout SwitcherState,
        activeProfileID: UUID,
        forceSave: Bool,
        sharedAuth: AuthBlob
    ) throws {
        let needsSave = forceSave || state.activeProfileID != activeProfileID
        if needsSave {
            state.activeProfileID = activeProfileID
            try cancellation?.check()
            try saveAndVerifyState(state)
            try cancellation?.check()
        }
        try verifySharedAuthUnchanged(sharedAuth)
    }

    private func verifySharedAuthUnchanged(_ expected: AuthBlob) throws {
        let latest: AuthBlob
        do {
            latest = try readSharedAuth()
        } catch {
            throw CodexSwitchError.state("処理中に共有認証ファイルを確認できません。")
        }
        guard latest.hasSameBytes(as: expected) else {
            throw CodexSwitchError.state("処理中に共有認証ファイルが変更されました。")
        }
    }

    private func saveAndVerifyState(_ state: SwitcherState) throws {
        try stateStore.save(state)
        guard try stateStore.loadOrCreate() == state else {
            throw CodexSwitchError.state("状態を保存後に照合できません。")
        }
    }

    private func configuredProfile(in state: SwitcherState) -> AccountProfile? {
        if let active = state.activeProfileID {
            return state.profiles.first(where: { $0.id == active })
        }
        return state.profiles.first
    }

    private func requireFileCredentialStore(_ result: ConfigReadResult) throws {
        guard value(at: ["cli_auth_credentials_store"], in: result.config)?.stringValue == "file" else {
            throw CodexSwitchError.appServer(
                "~/.codex/config.toml に cli_auth_credentials_store = \"file\" を設定してからsetupを再実行してください。"
            )
        }
    }

    private func existingRegisteredProfiles(
        matching accountID: String,
        excluding excludedProfileID: UUID,
        in state: SwitcherState
    ) throws -> [AccountProfile] {
        let matches = state.profiles.compactMap { profile -> AccountProfile? in
            guard profile.id != excludedProfileID,
                  let record = try? vault.load(profileID: profile.id),
                  let auth = try? record.validatedAuth(),
                  auth.accountID == accountID
            else { return nil }
            return profile
        }
        guard matches.count == 1 else {
            throw CodexSwitchError.state(
                "共有認証に一致する登録済みアカウントを一意に確認できません。登録記録を保持します。"
            )
        }
        return matches
    }

    private func validateAccount(_ result: AccountReadResult) throws {
        guard result.requiresOpenaiAuth,
              let account = result.account,
              account.type == "chatgpt"
        else {
            throw CodexSwitchError.appServer("ChatGPT管理認証を確認できません。")
        }
    }

    private func makeProfile(
        id: UUID,
        account: AccountInfo?,
        auth: AuthBlob,
        existingProfiles: [AccountProfile]
    ) throws -> AccountProfile {
        let email = normalizedEmail(account?.email)
        var displayName = email ?? "ChatGPTアカウント · \(auth.accountFingerprint)"
        if existingProfiles.contains(where: { sameDisplayName($0.displayName, displayName) }) {
            displayName = "\(displayName) · \(auth.accountFingerprint)"
        }
        guard !existingProfiles.contains(where: { sameDisplayName($0.displayName, displayName) }) else {
            throw CodexSwitchError.state("アカウント表示名を一意に作成できません。")
        }
        return try AccountProfile(id: id, displayName: displayName)
    }

    private func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard !trimmed.isEmpty,
              trimmed.count <= 254,
              components.count == 2,
              !components[0].isEmpty,
              !components[1].isEmpty,
              trimmed.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
                      && !CharacterSet.whitespacesAndNewlines.contains($0)
              })
        else { return nil }
        return trimmed
    }

    private func sameDisplayName(_ left: String, _ right: String) -> Bool {
        left.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ) == right.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private func value(at keyPath: [String], in value: JSONValue) -> JSONValue? {
        var current = value
        for key in keyPath {
            guard case let .object(object) = current,
                  let next = object[key]
            else { return nil }
            current = next
        }
        return current
    }
}
