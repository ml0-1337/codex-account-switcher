import Foundation
@testable import CodexSwitchCore

func makeAuthData(accountID: String = "account-fixture") throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "auth_mode": "chatgpt",
        "OPENAI_API_KEY": NSNull(),
        "tokens": [
            "id_token": "fixture-id-token",
            "access_token": "fixture-access-token",
            "refresh_token": "fixture-refresh-token",
            "account_id": accountID,
            "future_field": ["preserved": true],
        ],
        "last_refresh": "2026-01-01T00:00:00Z",
        "future_top_level": "preserved",
    ], options: [.sortedKeys])
}

func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("codex-switch-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return directory
}
