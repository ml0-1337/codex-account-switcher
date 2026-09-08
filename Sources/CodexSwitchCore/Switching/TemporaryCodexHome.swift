import Darwin
import Foundation

/// The identity captured for an owned temporary home. It is deliberately
/// independent of a path so a replacement at the same path cannot be removed.
internal struct TemporaryHomeIdentity: Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt32
    let owner: UInt32

    var isDirectory: Bool {
        mode & UInt32(S_IFMT) == UInt32(S_IFDIR)
    }

    var isPrivate: Bool {
        mode & 0o077 == 0
    }

    var belongsToCurrentUser: Bool {
        owner == UInt32(getuid())
    }
}

/// Small injectable filesystem seam for exercising replacement and deletion
/// races. Production uses the system implementation; no process enumeration
/// is part of temporary-home cleanup because the owning session has already
/// confirmed its process group is gone.
internal struct TemporaryHomeCleanupOperations: @unchecked Sendable {
    var inspect: (URL) throws -> TemporaryHomeIdentity?
    var rename: (URL, URL) throws -> Void
    var remove: (URL) throws -> Void

    static let system = TemporaryHomeCleanupOperations(
        inspect: { try temporaryHomeIdentity(at: $0) },
        rename: { try renameTemporaryHome(from: $0, to: $1) },
        remove: { try FileManager.default.removeItem(at: $0) }
    )
}

/// An isolated private CODEX_HOME used only while adding an account. It never
/// copies the user's config, history, MCP settings, or shared auth file.
public final class TemporaryCodexHome: @unchecked Sendable {
    public let url: URL
    public let authFile: URL
    public private(set) var cleanupFailureReason: String?

    /// Internal only so tests can model a filesystem race without replacing
    /// the production ownership checks.
    internal var cleanupOperations = TemporaryHomeCleanupOperations.system

    private let parentURL: URL
    private let directoryDevice: UInt64
    private let directoryInode: UInt64
    private var removalURL: URL?
    private var cleanedUp = false
    private var cleanupOnDeinit = true

    public init(paths: AppPaths) throws {
        try paths.ensureRuntimeDirectories()
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("Codex Account Switcher", isDirectory: true)
            .standardizedFileURL
        try AppPaths.ensurePrivateDirectory(parent, label: "一時認証ディレクトリ")

        let directory = parent.appendingPathComponent(
            UUID().uuidString.lowercased(),
            isDirectory: true
        )
        try AppPaths.ensurePrivateDirectory(
            directory,
            label: "一時CODEX_HOME",
            requireCreation: true
        )

        guard let information = try temporaryHomeIdentity(at: directory),
              information.isDirectory,
              information.belongsToCurrentUser,
              information.isPrivate
        else {
            throw CodexSwitchError.unsafeFile("一時CODEX_HOMEの状態を確認できません。")
        }

        self.parentURL = parent
        self.url = directory
        self.authFile = directory.appendingPathComponent("auth.json", isDirectory: false)
        self.directoryDevice = information.device
        self.directoryInode = information.inode

        do {
            // This is the only Codex setting in the temporary home. In
            // particular, no user config, history, or MCP directory is copied
            // here.
            try AtomicFileWriter.write(
                Data("cli_auth_credentials_store = \"file\"\n".utf8),
                to: directory.appendingPathComponent("config.toml", isDirectory: false)
            )
        } catch {
            // The object cannot receive a deinit until initialization returns,
            // so clean the newly-created directory explicitly on partial
            // initialization failure. A failed cleanup is deliberately ignored
            // because the directory is still known by its captured identity.
            try? Self.removeCreatedDirectory(
                directory,
                parent: parent,
                expectedDevice: information.device,
                expectedInode: information.inode
            )
            throw error
        }
    }

    deinit {
        if cleanupOnDeinit { try? cleanup() }
    }

    public func readAuth() throws -> AuthBlob {
        let data = try AtomicFileWriter.readSecureFile(
            authFile,
            maximumSize: AuthBlob.maximumSize
        )
        return try AuthBlob(validating: data)
    }

    /// Leave the exact generated path available for manual cleanup/reporting.
    public func preserveUntilSystemTemporaryCleanup() {
        cleanupOnDeinit = false
    }

    public var preservedPath: URL { removalURL ?? url }

    public func cleanup() throws {
        guard !cleanedUp else { return }
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent() == parentURL,
              UUID(uuidString: standardized.lastPathComponent) != nil,
              standardized.lastPathComponent.count == 36
        else {
            cleanupFailureReason = "削除対象のパスを確認できません。"
            throw CodexSwitchError.unsafeFile(cleanupFailureReason!)
        }

        let targetWasRenamed = removalURL != nil
        var target = removalURL ?? standardized
        let identity: TemporaryHomeIdentity?
        do {
            identity = try cleanupOperations.inspect(target)
        } catch {
            cleanupFailureReason = "一時CODEX_HOMEの削除対象を確認できません。"
            throw CodexSwitchError.unsafeFile(cleanupFailureReason!)
        }
        guard let identity else {
            if !targetWasRenamed {
                cleanedUp = true
                return
            }
            cleanupFailureReason = "保存した一時CODEX_HOMEの削除対象を確認できません。"
            throw CodexSwitchError.unsafeFile(cleanupFailureReason!)
        }
        guard identityMatches(identity) else {
            cleanupFailureReason = targetWasRenamed
                ? "保存した一時CODEX_HOMEが作成時と一致しません。"
                : "一時CODEX_HOMEが作成時と一致しません。"
            throw CodexSwitchError.unsafeFile(cleanupFailureReason!)
        }

        if !targetWasRenamed {
            let tombstone = parentURL.appendingPathComponent(
                ".deleting-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
            do {
                try cleanupOperations.rename(standardized, tombstone)
            } catch {
                cleanupFailureReason = "一時CODEX_HOMEを安全に削除準備できません。"
                throw CodexSwitchError.io(cleanupFailureReason!)
            }
            // The original inode is not enough: inspect the renamed path before
            // allowing recursive removal. A replacement at the tombstone path
            // remains preserved and is never followed.
            removalURL = tombstone
            target = tombstone
            let movedIdentity: TemporaryHomeIdentity?
            do {
                movedIdentity = try cleanupOperations.inspect(tombstone)
            } catch {
                cleanupFailureReason = "移動後の一時CODEX_HOMEを確認できません。"
                throw CodexSwitchError.unsafeFile(cleanupFailureReason!)
            }
            guard let movedIdentity, identityMatches(movedIdentity) else {
                cleanupFailureReason = "移動後の一時CODEX_HOMEが作成時と一致しません。"
                throw CodexSwitchError.unsafeFile(cleanupFailureReason!)
            }
        }

        do {
            try cleanupOperations.remove(target)
        } catch {
            // Keep removalURL so the next cleanup starts from the existing
            // tombstone. It must not attempt to rename the now-missing original
            // path again.
            cleanupFailureReason = "一時CODEX_HOMEを削除できません。"
            throw CodexSwitchError.io(cleanupFailureReason!)
        }
        removalURL = nil
        cleanupFailureReason = nil
        cleanedUp = true
    }

    private func identityMatches(_ identity: TemporaryHomeIdentity) -> Bool {
        identity.isDirectory
            && identity.belongsToCurrentUser
            && identity.isPrivate
            && identity.device == directoryDevice
            && identity.inode == directoryInode
    }

    private static func removeCreatedDirectory(
        _ directory: URL,
        parent: URL,
        expectedDevice: UInt64,
        expectedInode: UInt64
    ) throws {
        let tombstone = parent.appendingPathComponent(
            ".deleting-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        guard let identity = try temporaryHomeIdentity(at: directory),
              identity.isDirectory,
              identity.belongsToCurrentUser,
              identity.isPrivate,
              identity.device == expectedDevice,
              identity.inode == expectedInode
        else {
            throw CodexSwitchError.unsafeFile("一時CODEX_HOMEが削除直前の照合に失敗しました。")
        }
        try renameTemporaryHome(from: directory, to: tombstone)
        guard let moved = try temporaryHomeIdentity(at: tombstone),
              moved.isDirectory,
              moved.belongsToCurrentUser,
              moved.isPrivate,
              moved.device == expectedDevice,
              moved.inode == expectedInode
        else {
            throw CodexSwitchError.unsafeFile("移動後の一時CODEX_HOMEが作成時と一致しません。")
        }
        try FileManager.default.removeItem(at: tombstone)
    }
}

private func temporaryHomeIdentity(at url: URL) throws -> TemporaryHomeIdentity? {
    var information = stat()
    guard Darwin.lstat(url.standardizedFileURL.path, &information) == 0 else {
        if errno == ENOENT { return nil }
        throw CodexSwitchError.io("一時CODEX_HOMEの状態を確認できません。")
    }
    return TemporaryHomeIdentity(
        device: UInt64(information.st_dev),
        inode: UInt64(information.st_ino),
        mode: UInt32(information.st_mode),
        owner: UInt32(information.st_uid)
    )
}

private func renameTemporaryHome(from source: URL, to destination: URL) throws {
    let normalizedSource = source.standardizedFileURL
    let normalizedDestination = destination.standardizedFileURL
    guard normalizedSource.deletingLastPathComponent()
        == normalizedDestination.deletingLastPathComponent()
    else {
        throw CodexSwitchError.unsafeFile("一時CODEX_HOMEの削除先が同じ親ディレクトリではありません。")
    }
    let descriptor = try SecurePath.openDirectory(normalizedSource.deletingLastPathComponent())
    defer { _ = Darwin.close(descriptor) }
    let result = Darwin.renameatx_np(
        descriptor,
        normalizedSource.lastPathComponent,
        descriptor,
        normalizedDestination.lastPathComponent,
        UInt32(RENAME_EXCL)
    )
    guard result == 0 else {
        throw CodexSwitchError.io("一時CODEX_HOMEを安全に移動できません。")
    }
}
