import Darwin
import Foundation

public final class FileLock: @unchecked Sendable {
    private let descriptor: Int32
    private var locked = false

    public init(url: URL) throws {
        guard getuid() == geteuid() else {
            throw CodexSwitchError.process("実ユーザーと実効ユーザーが一致しないため切替ロックを取得できません。")
        }

        let normalizedURL = url.standardizedFileURL
        let parent = normalizedURL.deletingLastPathComponent()
        let fileName = normalizedURL.lastPathComponent
        guard !fileName.isEmpty,
              fileName != ".",
              fileName != "..",
              !fileName.contains("/")
        else {
            throw CodexSwitchError.unsafeFile("切替ロックのファイル名が不正です。")
        }

        let parentDescriptor = try SecurePath.openDirectory(parent)
        defer { _ = Darwin.close(parentDescriptor) }

        try Self.validateDirectory(parentDescriptor)

        let lockDescriptor = fileName.withCString { pointer in
            Darwin.openat(
                parentDescriptor,
                pointer,
                O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW,
                mode_t(0o600)
            )
        }
        guard lockDescriptor >= 0 else {
            if errno == ELOOP {
                throw CodexSwitchError.unsafeFile("切替ロックがシンボリックリンクです。")
            }
            throw CodexSwitchError.io("切替ロックを安全に作成できません。")
        }

        do {
            try Self.validateLockFile(lockDescriptor)
            guard Darwin.fchmod(lockDescriptor, mode_t(0o600)) == 0 else {
                throw CodexSwitchError.io("切替ロックの権限を設定できません。")
            }

            var fileLock = flock(
                l_start: 0,
                l_len: 0,
                l_pid: 0,
                l_type: Int16(F_WRLCK),
                l_whence: Int16(SEEK_SET)
            )
            while Darwin.fcntl(lockDescriptor, F_SETLK, &fileLock) == -1 {
                if errno == EINTR { continue }
                if errno == EACCES || errno == EAGAIN {
                    throw CodexSwitchError.process("別のアカウント切替が実行中です。")
                }
                throw CodexSwitchError.io("切替ロックを取得できません。")
            }

            self.descriptor = lockDescriptor
            self.locked = true
        } catch {
            _ = Darwin.close(lockDescriptor)
            throw error
        }
    }

    deinit {
        if locked {
            var fileLock = flock(
                l_start: 0,
                l_len: 0,
                l_pid: 0,
                l_type: Int16(F_UNLCK),
                l_whence: Int16(SEEK_SET)
            )
            _ = Darwin.fcntl(descriptor, F_SETLK, &fileLock)
        }
        _ = Darwin.close(descriptor)
    }

    private static func validateDirectory(_ descriptor: Int32) throws {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw CodexSwitchError.unsafeFile("切替ロックの保存先を確認できません。")
        }
        guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              information.st_uid == getuid(),
              information.st_mode & mode_t(0o022) == 0
        else {
            throw CodexSwitchError.unsafeFile("切替ロックの保存先の所有者または権限が安全ではありません。")
        }
    }

    private static func validateLockFile(_ descriptor: Int32) throws {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw CodexSwitchError.unsafeFile("切替ロックの状態を確認できません。")
        }
        guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              information.st_uid == getuid(),
              information.st_mode & mode_t(0o077) == 0,
              information.st_nlink == 1
        else {
            throw CodexSwitchError.unsafeFile("切替ロックの所有者、権限、またはリンク数が安全ではありません。")
        }
    }
}
