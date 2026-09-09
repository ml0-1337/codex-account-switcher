import Darwin
import Foundation

/// The filesystem locations owned by Codex Account Switcher.
///
/// `AppPaths.current()` deliberately resolves only the supported shared home.
/// A caller may construct an instance with fixture URLs, but the production
/// environment still has one canonical `~/.codex` location.
public struct AppPaths: Sendable, Equatable {
    public let homeDirectory: URL
    public let codexHome: URL
    public let stateRoot: URL
    public let stateFile: URL
    public let journalFile: URL
    public let registrationJournalFile: URL
    public let lockFile: URL

    public init(homeDirectory: URL, codexHome: URL, stateRoot: URL? = nil) {
        let normalizedHome = homeDirectory.standardizedFileURL
        let normalizedCodexHome = codexHome.standardizedFileURL
        self.homeDirectory = normalizedHome
        self.codexHome = normalizedCodexHome
        self.stateRoot = (stateRoot ?? normalizedHome
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Codex Account Switcher", isDirectory: true))
            .standardizedFileURL
        self.stateFile = self.stateRoot.appendingPathComponent("state.json", isDirectory: false)
        self.journalFile = self.stateRoot.appendingPathComponent("switch-journal.json", isDirectory: false)
        self.registrationJournalFile = self.stateRoot.appendingPathComponent(
            "credential-registration.json",
            isDirectory: false
        )
        self.lockFile = self.stateRoot.appendingPathComponent("switch.lock", isDirectory: false)
    }

    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> AppPaths {
        guard getuid() != 0, getuid() == geteuid() else {
            throw CodexSwitchError.process(
                "アカウント切替は通常のログインユーザーとして実行してください。"
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let defaultCodexHome = home.appendingPathComponent(".codex", isDirectory: true)
            .standardizedFileURL

        if let configured = environment["CODEX_HOME"], !configured.isEmpty {
            guard configured.hasPrefix("/") else {
                throw CodexSwitchError.invalidInput("CODEX_HOMEには絶対パスを指定してください。")
            }
            let requested = URL(fileURLWithPath: configured, isDirectory: true).standardizedFileURL
            guard requested == defaultCodexHome else {
                throw CodexSwitchError.invalidInput(
                    "カスタムCODEX_HOMEには対応していません。既定の~/.codexを使うタスクで実行してください。"
                )
            }
        }

        return AppPaths(homeDirectory: home, codexHome: defaultCodexHome)
    }

    public var authFile: URL {
        codexHome.appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Creates and validates the private state directory.
    ///
    /// State persistence is the only runtime directory needed by the
    /// synchronous core. Login homes are created by `TemporaryCodexHome`.
    public func ensureRuntimeDirectories() throws {
        try Self.ensureDirectoryHierarchy(stateRoot, label: "切替ツールの状態ディレクトリ")
    }

    /// Ensures one private directory using the same path checks as state
    /// persistence and temporary-home creation.
    public static func ensurePrivateDirectory(
        _ url: URL,
        label: String,
        requireCreation: Bool = false
    ) throws {
        let normalized = url.standardizedFileURL
        guard normalized.isFileURL,
              normalized.path.hasPrefix("/"),
              normalized.lastPathComponent.count > 0,
              normalized.lastPathComponent != ".",
              normalized.lastPathComponent != "..",
              !normalized.lastPathComponent.contains("/")
        else {
            throw CodexSwitchError.unsafeFile("\(label)のパスが不正です。")
        }

        let parent = normalized.deletingLastPathComponent()
        try ensureDirectoryHierarchy(parent, label: "\(label)の親ディレクトリ")
        let existed = FileManager.default.fileExists(atPath: normalized.path)
        if requireCreation, existed {
            throw CodexSwitchError.io("\(label)は既に存在します。")
        }
        if !existed {
            do {
                try FileManager.default.createDirectory(
                    at: normalized,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CodexSwitchError.io("\(label)を作成できません。")
            }
        }
        try validatePrivateDirectory(normalized, label: label, applyPermissions: !existed)
    }

    private static func ensureDirectoryHierarchy(_ url: URL, label: String) throws {
        let normalized = url.standardizedFileURL
        guard normalized.isFileURL, normalized.path.hasPrefix("/") else {
            throw CodexSwitchError.unsafeFile("\(label)の絶対パスを確認できません。")
        }

        // Create one component at a time after an lstat check. FileManager's
        // intermediate-directory convenience follows an existing symlink and
        // could otherwise create a child below an attacker-replaced path.
        let resolved = SecurePath.resolveSupportedSystemAlias(normalized.path)
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in resolved.split(separator: "/") {
            current.appendPathComponent(String(component), isDirectory: true)
            var information = stat()
            if Darwin.lstat(current.path, &information) == 0 {
                guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                    throw CodexSwitchError.unsafeFile("\(label)の経路にディレクトリ以外の要素があります。")
                }
                continue
            }
            guard errno == ENOENT else {
                throw CodexSwitchError.unsafeFile("\(label)の経路を確認できません。")
            }
            do {
                try FileManager.default.createDirectory(
                    at: current,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw CodexSwitchError.io("\(label)を作成できません。")
            }
        }
        try validatePrivateDirectory(normalized, label: label, applyPermissions: false)
    }

    private static func validatePrivateDirectory(
        _ url: URL,
        label: String,
        applyPermissions: Bool
    ) throws {
        let descriptor = try SecurePath.openDirectory(url)
        defer { _ = Darwin.close(descriptor) }

        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              information.st_uid == getuid(),
              information.st_mode & mode_t(0o022) == 0
        else {
            throw CodexSwitchError.unsafeFile(
                "\(label)の所有者または権限が安全ではありません。"
            )
        }
        guard !applyPermissions || Darwin.fchmod(descriptor, mode_t(0o700)) == 0 else {
            throw CodexSwitchError.io("\(label)の権限を設定できません。")
        }
    }
}
