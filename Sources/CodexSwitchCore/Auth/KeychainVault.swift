import Foundation
import Security

public protocol CredentialVault: Sendable {
    func save(_ record: VaultRecord, displayName: String) throws
    func load(profileID: UUID) throws -> VaultRecord
    func contains(profileID: UUID) throws -> Bool
    func delete(profileID: UUID) throws
}

public final class KeychainVault: CredentialVault {
    public static let defaultService = "app.codex-account-switcher.credentials.v1"

    private let service: String

    public init(service: String = KeychainVault.defaultService) {
        self.service = service
    }

    public func save(_ record: VaultRecord, displayName: String) throws {
        _ = try record.validatedAuth()
        let itemLabel = try Self.itemLabel(displayName: displayName)

        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw CodexSwitchError.keychain("認証情報をキーチェーン用に変換できません。")
        }

        let match = baseQuery(profileID: record.profileID)
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: itemLabel,
        ]

        let updateStatus = SecItemUpdate(
            match as CFDictionary,
            updates as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus, operation: "認証情報を更新")
        }

        var item = match
        item[kSecValueData as String] = data
        item[kSecAttrLabel as String] = itemLabel

        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(
                match as CFDictionary,
                updates as CFDictionary
            )
            guard retryStatus == errSecSuccess else {
                throw keychainError(retryStatus, operation: "認証情報を更新")
            }
            return
        }
        throw keychainError(addStatus, operation: "認証情報を保存")
    }

    static func itemLabel(displayName: String) throws -> String {
        let profile = try AccountProfile(displayName: displayName)
        return "Codex Account Switcher — \(profile.displayName)"
    }

    public func load(profileID: UUID) throws -> VaultRecord {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = kCFBooleanTrue as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound {
                throw CodexSwitchError.keychain("選択したアカウントの認証情報がキーチェーンにありません。")
            }
            throw keychainError(status, operation: "認証情報を取得")
        }

        guard data.count <= AuthBlob.maximumSize + 65_536 else {
            throw CodexSwitchError.keychain("キーチェーン内の認証情報が大きすぎます。")
        }

        let record: VaultRecord
        do {
            record = try PropertyListDecoder().decode(VaultRecord.self, from: data)
        } catch {
            throw CodexSwitchError.keychain("キーチェーン内の認証情報を読み取れません。")
        }
        guard record.profileID == profileID else {
            throw CodexSwitchError.keychain("キーチェーン内のプロファイルが一致しません。")
        }
        _ = try record.validatedAuth()
        return record
    }

    public func contains(profileID: UUID) throws -> Bool {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = kCFBooleanFalse as Any
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound { return false }
        throw keychainError(status, operation: "認証情報の存在を確認")
    }

    public func delete(profileID: UUID) throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, operation: "認証情報を削除")
        }
    }

    private func baseQuery(profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString.lowercased(),
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private func keychainError(
        _ status: OSStatus,
        operation: String
    ) -> CodexSwitchError {
        let reason: String
        switch status {
        case errSecItemNotFound:
            reason = "対象の認証情報がありません。"
        case errSecDuplicateItem:
            reason = "対象の認証情報が既に存在します。"
        case errSecInteractionNotAllowed:
            reason = "キーチェーンがロック中か、ユーザー操作を必要としています。"
        case errSecAuthFailed:
            reason = "キーチェーンの認証に失敗しました。"
        case errSecMissingEntitlement:
            reason = "アプリのキーチェーン権限が不足しています。"
        case errSecParam:
            reason = "キーチェーンのパラメータが不正です。"
        case errSecDecode:
            reason = "キーチェーンのデータを解釈できません。"
        default:
            reason = "キーチェーン操作に失敗しました。OSStatus \(status)。"
        }
        return .keychain("\(operation)できません。\(reason)")
    }
}
