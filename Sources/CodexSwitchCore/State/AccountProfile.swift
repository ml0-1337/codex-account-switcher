import Foundation

func normalizedPersistentDate(_ date: Date) -> Date {
    let rawSeconds = date.timeIntervalSince1970
    let seconds = rawSeconds.isFinite
        ? min(max(rawSeconds, -62_135_596_800), 253_402_300_799)
        : 0
    return Date(timeIntervalSince1970: Double(Int64((seconds * 1_000_000).rounded())) / 1_000_000)
}

public struct AccountProfile: Codable, Sendable, Equatable, Identifiable {
    public static let maximumDisplayNameLength = 320
    public let id: UUID
    public let displayName: String
    public let createdAt: Date

    public init(id: UUID = UUID(), displayName: String, createdAt: Date = Date()) throws {
        let normalized = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.count <= Self.maximumDisplayNameLength,
              normalized.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw CodexSwitchError.invalidInput("アカウント表示名が不正です。")
        }
        self.id = id
        self.displayName = normalized
        self.createdAt = normalizedPersistentDate(createdAt)
    }
}
