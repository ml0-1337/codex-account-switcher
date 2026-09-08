import Darwin
import Foundation

enum SecurePath {
    static func openDirectory(_ url: URL) throws -> Int32 {
        let standardized = url.standardizedFileURL
        guard standardized.isFileURL, standardized.path.hasPrefix("/") else {
            throw CodexSwitchError.unsafeFile("ディレクトリの絶対パスを確認できません。")
        }

        let resolvedSystemAlias = resolveSupportedSystemAlias(standardized.path)
        let components = resolvedSystemAlias.split(separator: "/").map(String.init)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CodexSwitchError.unsafeFile("ルートディレクトリを安全に開けません。")
        }

        do {
            for component in components {
                guard !component.isEmpty,
                      component != ".",
                      component != "..",
                      !component.contains("/")
                else {
                    throw CodexSwitchError.unsafeFile("ディレクトリの構成要素が不正です。")
                }
                let nextDescriptor = component.withCString { pointer in
                    Darwin.openat(
                        descriptor,
                        pointer,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard nextDescriptor >= 0 else {
                    throw CodexSwitchError.unsafeFile(
                        "ディレクトリ経路にシンボリックリンクまたは安全でない要素があります。"
                    )
                }
                var information = stat()
                let modeIsWritableByOthers: Bool
                let isTrustedStickySystemDirectory: Bool
                if Darwin.fstat(nextDescriptor, &information) == 0 {
                    modeIsWritableByOthers = information.st_mode & mode_t(0o022) != 0
                    isTrustedStickySystemDirectory = information.st_uid == 0
                        && information.st_mode & mode_t(S_ISVTX) != 0
                } else {
                    modeIsWritableByOthers = true
                    isTrustedStickySystemDirectory = false
                }
                guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                      information.st_uid == 0 || information.st_uid == getuid(),
                      !modeIsWritableByOthers || isTrustedStickySystemDirectory
                else {
                    _ = Darwin.close(nextDescriptor)
                    throw CodexSwitchError.unsafeFile(
                        "ディレクトリ経路の所有者または権限が安全ではありません。"
                    )
                }
                _ = Darwin.close(descriptor)
                descriptor = nextDescriptor
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func resolveSupportedSystemAlias(_ path: String) -> String {
        if path == "/var" { return "/private/var" }
        if path.hasPrefix("/var/") {
            return "/private" + path
        }
        if path == "/tmp" { return "/private/tmp" }
        if path.hasPrefix("/tmp/") {
            return "/private/tmp/" + path.dropFirst(5)
        }
        return path
    }
}
