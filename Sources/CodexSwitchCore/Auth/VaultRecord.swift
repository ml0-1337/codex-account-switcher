import Foundation

public struct VaultRecord: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let profileID: UUID
    public let accountID: String
    public let authData: Data
    public let savedAt: Date

    public init(profileID: UUID, auth: AuthBlob, savedAt: Date = Date()) {
        self.schemaVersion = Self.currentSchemaVersion
        self.profileID = profileID
        self.accountID = auth.accountID
        self.authData = auth.data
        self.savedAt = savedAt
    }

    public func validatedAuth() throws -> AuthBlob {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw CodexSwitchError.keychain("キーチェーン内の認証形式に対応していません。")
        }
        guard profileID.uuidString.count == 36 else {
            throw CodexSwitchError.keychain("キーチェーン内のプロファイル識別子が不正です。")
        }
        let auth = try AuthBlob(validating: authData)
        guard auth.accountID == accountID else {
            throw CodexSwitchError.keychain("キーチェーン内のアカウント情報が一致しません。")
        }
        return auth
    }
}
