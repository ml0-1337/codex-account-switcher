import Foundation

public struct SwitcherState: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var profiles: [AccountProfile]
    public var activeProfileID: UUID?
    public var sharedCodexHome: String
    /// Retained for compatibility with state v2 written by earlier builds.
    /// The current file-only core never writes a different credential store.
    public var previousCredentialStore: String?

    public init(
        sharedCodexHome: String,
        profiles: [AccountProfile] = [],
        activeProfileID: UUID? = nil,
        previousCredentialStore: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.profiles = profiles
        self.activeProfileID = activeProfileID
        self.sharedCodexHome = sharedCodexHome
        self.previousCredentialStore = previousCredentialStore
    }

    public func validated(expectedCodexHome: URL) throws -> SwitcherState {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CodexSwitchError.state("保存されている状態の形式に対応していません。")
        }
        guard URL(fileURLWithPath: sharedCodexHome).standardizedFileURL
            == expectedCodexHome.standardizedFileURL
        else {
            throw CodexSwitchError.state("設定済みのCODEX_HOMEが現在の環境と一致しません。")
        }

        let ids = profiles.map(\.id)
        guard Set(ids).count == ids.count else {
            throw CodexSwitchError.state("同じプロファイル識別子が重複しています。")
        }
        for profile in profiles {
            let normalized: AccountProfile
            do {
                normalized = try AccountProfile(
                    id: profile.id,
                    displayName: profile.displayName,
                    createdAt: profile.createdAt
                )
            } catch {
                throw CodexSwitchError.state("保存されているアカウント表示名が不正です。")
            }
            guard normalized == profile else {
                throw CodexSwitchError.state("保存されているアカウント表示名が正規化されていません。")
            }
        }

        let normalizedNames = profiles.map {
            $0.displayName.folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
        guard Set(normalizedNames).count == normalizedNames.count else {
            throw CodexSwitchError.state("同じ表示名のアカウントが重複しています。")
        }
        if let activeProfileID, !ids.contains(activeProfileID) {
            throw CodexSwitchError.state("現在のプロファイルが登録一覧にありません。")
        }
        return self
    }
}

/// Stages in the v3 offline switch journal. `targetMaterialized` means the
/// shared auth file was attempted and read back; all later failures retain the
/// journal and are repaired from the actual file during recovery.
public enum SwitchStage: String, Codable, Sendable, Equatable {
    case prepared
    case targetMaterialized
    case targetValidated
    case stateCommitted
}

public struct SwitchJournal: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 3

    public let schemaVersion: Int
    public let operationID: UUID
    public let sourceProfileID: UUID
    public let targetProfileID: UUID
    public let sourceAccountID: String
    public let targetAccountID: String
    public let sourceAuthHash: String
    public var targetAuthHash: String
    public var stage: SwitchStage
    public let createdAt: Date

    public init(
        operationID: UUID,
        sourceProfileID: UUID,
        targetProfileID: UUID,
        sourceAccountID: String,
        targetAccountID: String,
        stage: SwitchStage = .prepared,
        sourceAuthHash: String,
        targetAuthHash: String,
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.operationID = operationID
        self.sourceProfileID = sourceProfileID
        self.targetProfileID = targetProfileID
        self.sourceAccountID = sourceAccountID
        self.targetAccountID = targetAccountID
        self.stage = stage
        self.sourceAuthHash = sourceAuthHash
        self.targetAuthHash = targetAuthHash
        self.createdAt = normalizedPersistentDate(createdAt)
    }

    public func validated() throws -> SwitchJournal {
        guard schemaVersion == Self.currentSchemaVersion,
              sourceProfileID != targetProfileID,
              !sourceAccountID.isEmpty,
              !targetAccountID.isEmpty,
              sourceAccountID.count <= 512,
              targetAccountID.count <= 512,
              Self.isSafeText(sourceAccountID, maximumLength: 512),
              Self.isSafeText(targetAccountID, maximumLength: 512),
              Self.isHash(sourceAuthHash),
              Self.isHash(targetAuthHash)
        else {
            throw CodexSwitchError.state("未完了の切替記録の内容が不正です。")
        }
        return self
    }

    private static func isHash(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 97...102:
                true
            default:
                false
            }
        }
    }

    private static func isSafeText(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

public enum CredentialRegistrationKind: String, Codable, Sendable, Equatable {
    case setup
    case add
}

/// v2 stores enough non-secret metadata to finish a vault-only registration
/// after a process interruption. Authentication bytes remain solely in the
/// injected credential vault and never enter this JSON record.
public struct PendingCredentialRegistration: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let operationID: UUID
    public let profileID: UUID
    public let kind: CredentialRegistrationKind
    public let displayName: String
    public let accountID: String
    public let email: String?
    public let planType: String?
    public let profileCreatedAt: Date?
    public let createdAt: Date
    public var vaultPersisted: Bool

    public init(
        operationID: UUID,
        profileID: UUID,
        kind: CredentialRegistrationKind,
        displayName: String,
        accountID: String,
        email: String? = nil,
        planType: String? = nil,
        profileCreatedAt: Date? = nil,
        vaultPersisted: Bool = false,
        createdAt: Date = Date()
    ) throws {
        guard Self.isSafeText(accountID, maximumLength: 512),
              Self.isSafeOptionalText(email, maximumLength: 254),
              Self.isSafeOptionalText(planType, maximumLength: 128)
        else {
            throw CodexSwitchError.invalidInput("認証登録記録のメタデータが不正です。")
        }
        self.schemaVersion = Self.currentSchemaVersion
        self.operationID = operationID
        self.profileID = profileID
        self.kind = kind
        self.displayName = try AccountProfile(displayName: displayName).displayName
        self.accountID = accountID
        self.email = email
        self.planType = planType
        self.profileCreatedAt = profileCreatedAt.map(normalizedPersistentDate)
        self.vaultPersisted = vaultPersisted
        self.createdAt = normalizedPersistentDate(createdAt)
    }

    public func validated(now: Date = Date()) throws -> PendingCredentialRegistration {
        guard schemaVersion == Self.currentSchemaVersion,
              now.timeIntervalSince(createdAt) >= -5,
              accountID.count > 0,
              accountID.count <= 512,
              Self.isSafeText(accountID, maximumLength: 512),
              displayName.count > 0,
              displayName.count <= AccountProfile.maximumDisplayNameLength,
              displayName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              (try? AccountProfile(displayName: displayName))?.displayName == displayName,
              Self.isSafeOptionalText(email, maximumLength: 254),
              Self.isSafeOptionalText(planType, maximumLength: 128)
        else {
            throw CodexSwitchError.state("未完了の認証登録記録の内容が不正です。")
        }
        return self
    }

    public func markingVaultPersisted() -> PendingCredentialRegistration {
        var copy = self
        copy.vaultPersisted = true
        return copy
    }

    private static func isSafeText(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty
            && value.count <= maximumLength
            && value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }

    private static func isSafeOptionalText(_ value: String?, maximumLength: Int) -> Bool {
        guard let value else { return true }
        return isSafeText(value, maximumLength: maximumLength)
    }
}
