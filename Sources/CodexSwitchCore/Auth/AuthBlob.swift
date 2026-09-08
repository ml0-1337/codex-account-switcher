import CryptoKit
import Foundation

public struct AuthBlob: Sendable, Equatable {
    public static let maximumSize = 1_048_576

    public let data: Data
    public let accountID: String

    public init(validating data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumSize else {
            throw CodexSwitchError.invalidInput("認証ファイルのサイズが許容範囲外です。")
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodexSwitchError.invalidInput("認証ファイルは有効なJSONではありません。")
        }

        guard let root = object as? [String: Any],
              root["auth_mode"] as? String == "chatgpt",
              let tokens = root["tokens"] as? [String: Any]
        else {
            throw CodexSwitchError.invalidInput("ChatGPT管理認証のファイルではありません。")
        }

        for key in ["id_token", "access_token", "refresh_token"] {
            guard let value = tokens[key] as? String, !value.isEmpty else {
                throw CodexSwitchError.invalidInput("認証ファイルに必要な項目がありません。")
            }
        }

        guard let accountID = tokens["account_id"] as? String,
              !accountID.isEmpty,
              accountID.count <= 512
        else {
            throw CodexSwitchError.invalidInput("認証ファイルからアカウントを識別できません。")
        }

        self.data = data
        self.accountID = accountID
    }

    public var accountFingerprint: String {
        let digest = SHA256.hash(data: Data(accountID.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public var contentHash: String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public func hasSameBytes(as other: AuthBlob) -> Bool {
        guard data.count == other.data.count else { return false }
        return data.withUnsafeBytes { (leftBuffer: UnsafeRawBufferPointer) in
            other.data.withUnsafeBytes { (rightBuffer: UnsafeRawBufferPointer) in
                var difference: UInt8 = 0
                for index in 0..<leftBuffer.count {
                    difference |= leftBuffer[index] ^ rightBuffer[index]
                }
                return difference == 0
            }
        }
    }
}
