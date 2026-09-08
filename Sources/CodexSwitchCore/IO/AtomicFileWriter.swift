import Darwin
import Foundation

public enum AtomicFileWriter {
    private static let ownerOnlyMode = mode_t(0o600)

    public static func write(
        _ data: Data,
        to destination: URL,
        mode: mode_t = 0o600,
        requireExistingRegularFile: Bool = false
    ) throws {
        try requireSameRealAndEffectiveUser()
        guard mode == ownerOnlyMode else {
            throw CodexSwitchError.unsafeFile("保存するファイルの権限が安全な設定ではありません。")
        }

        let normalizedDestination = destination.standardizedFileURL
        let parent = normalizedDestination.deletingLastPathComponent()
        let fileName = normalizedDestination.lastPathComponent
        try validateComponent(fileName)

        let directoryDescriptor = try openSecureDirectory(parent)
        defer { _ = Darwin.close(directoryDescriptor) }

        if let existingDescriptor = try openExistingFile(
            directoryDescriptor: directoryDescriptor,
            fileName: fileName
        ) {
            defer { _ = Darwin.close(existingDescriptor) }
            try validateRegularDescriptor(
                existingDescriptor,
                requiredMode: nil,
                requireSingleLink: true
            )
        } else if requireExistingRegularFile {
            throw CodexSwitchError.unsafeFile("更新対象のファイルがありません。")
        }

        let temporaryName = ".\(fileName).\(UUID().uuidString.lowercased()).tmp"
        let temporaryDescriptor = temporaryName.withCString { pointer in
            Darwin.openat(
                directoryDescriptor,
                pointer,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode
            )
        }
        guard temporaryDescriptor >= 0 else {
            throw CodexSwitchError.io("一時ファイルを安全に作成できません。")
        }

        var didRename = false
        defer {
            _ = Darwin.close(temporaryDescriptor)
            if !didRename {
                temporaryName.withCString { pointer in
                    _ = Darwin.unlinkat(directoryDescriptor, pointer, 0)
                }
            }
        }

        guard Darwin.fchmod(temporaryDescriptor, mode) == 0 else {
            throw CodexSwitchError.io("一時ファイルの権限を設定できません。")
        }

        try writeAll(data, to: temporaryDescriptor)
        try synchronizeFile(temporaryDescriptor)

        let renameResult = temporaryName.withCString { temporaryPointer in
            fileName.withCString { destinationPointer in
                Darwin.renameatx_np(
                    directoryDescriptor,
                    temporaryPointer,
                    directoryDescriptor,
                    destinationPointer,
                    UInt32(RENAME_NOFOLLOW_ANY)
                )
            }
        }
        guard renameResult == 0 else {
            throw CodexSwitchError.io("ファイルを原子的に置き換えられません。")
        }
        didRename = true

        try synchronizeDirectory(directoryDescriptor)

        let persisted = try readSecureFile(
            normalizedDestination,
            maximumSize: max(data.count, 1)
        )
        guard persisted == data else {
            throw CodexSwitchError.io("保存したファイルの照合に失敗しました。")
        }
    }

    public static func validateRegularFile(
        _ url: URL,
        requiredMode: mode_t? = 0o600
    ) throws {
        try requireSameRealAndEffectiveUser()
        let normalizedURL = url.standardizedFileURL
        let parent = normalizedURL.deletingLastPathComponent()
        let fileName = normalizedURL.lastPathComponent
        try validateComponent(fileName)

        let directoryDescriptor = try openSecureDirectory(parent)
        defer { _ = Darwin.close(directoryDescriptor) }

        guard let descriptor = try openExistingFile(
            directoryDescriptor: directoryDescriptor,
            fileName: fileName
        ) else {
            throw CodexSwitchError.unsafeFile("対象ファイルを確認できません。")
        }
        defer { _ = Darwin.close(descriptor) }

        try validateRegularDescriptor(
            descriptor,
            requiredMode: requiredMode,
            requireSingleLink: true
        )
    }

    public static func readSecureFile(
        _ url: URL,
        maximumSize: Int
    ) throws -> Data {
        try requireSameRealAndEffectiveUser()
        guard maximumSize > 0 else {
            throw CodexSwitchError.invalidInput("読み取りサイズの上限が不正です。")
        }

        let normalizedURL = url.standardizedFileURL
        let parent = normalizedURL.deletingLastPathComponent()
        let fileName = normalizedURL.lastPathComponent
        try validateComponent(fileName)

        let directoryDescriptor = try openSecureDirectory(parent)
        defer { _ = Darwin.close(directoryDescriptor) }

        guard let descriptor = try openExistingFile(
            directoryDescriptor: directoryDescriptor,
            fileName: fileName
        ) else {
            throw CodexSwitchError.unsafeFile("対象ファイルを確認できません。")
        }
        defer { _ = Darwin.close(descriptor) }

        let initialInformation = try validateRegularDescriptor(
            descriptor,
            requiredMode: ownerOnlyMode,
            requireSingleLink: true
        )
        guard initialInformation.st_size >= 0,
              initialInformation.st_size <= off_t(maximumSize)
        else {
            throw CodexSwitchError.unsafeFile("対象ファイルのサイズが許容範囲外です。")
        }

        var result = Data()
        result.reserveCapacity(Int(initialInformation.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(
                    descriptor,
                    rawBuffer.baseAddress,
                    rawBuffer.count
                )
            }

            if count < 0 {
                if errno == EINTR { continue }
                throw CodexSwitchError.io("対象ファイルを安全に読み取れません。")
            }
            if count == 0 { break }

            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumSize else {
                throw CodexSwitchError.unsafeFile("対象ファイルのサイズが許容範囲外です。")
            }
        }

        var finalInformation = stat()
        guard Darwin.fstat(descriptor, &finalInformation) == 0 else {
            throw CodexSwitchError.io("対象ファイルの状態を再確認できません。")
        }
        guard finalInformation.st_dev == initialInformation.st_dev,
              finalInformation.st_ino == initialInformation.st_ino,
              finalInformation.st_size == off_t(result.count)
        else {
            throw CodexSwitchError.unsafeFile("読み取り中に対象ファイルが変更されました。")
        }

        return result
    }

    public static func removeSecureFileIfPresent(_ url: URL) throws {
        try requireSameRealAndEffectiveUser()
        let normalizedURL = url.standardizedFileURL
        let parent = normalizedURL.deletingLastPathComponent()
        let fileName = normalizedURL.lastPathComponent
        try validateComponent(fileName)

        let directoryDescriptor = try openSecureDirectory(parent)
        defer { _ = Darwin.close(directoryDescriptor) }

        guard let descriptor = try openExistingFile(
            directoryDescriptor: directoryDescriptor,
            fileName: fileName
        ) else {
            return
        }
        defer { _ = Darwin.close(descriptor) }

        try validateRegularDescriptor(
            descriptor,
            requiredMode: nil,
            requireSingleLink: true
        )
        guard Darwin.unlinkat(directoryDescriptor, fileName, 0) == 0 else {
            if errno == ENOENT { return }
            throw CodexSwitchError.io("対象ファイルを削除できません。")
        }
    }

    private static func openSecureDirectory(_ url: URL) throws -> Int32 {
        let descriptor = try SecurePath.openDirectory(url)

        do {
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0,
                  (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
                  information.st_uid == getuid(),
                  information.st_mode & mode_t(0o022) == 0
            else {
                throw CodexSwitchError.unsafeFile("保存先ディレクトリの所有者または権限が安全ではありません。")
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    private static func openExistingFile(
        directoryDescriptor: Int32,
        fileName: String
    ) throws -> Int32? {
        let descriptor = fileName.withCString { pointer in
            Darwin.openat(
                directoryDescriptor,
                pointer,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        if descriptor >= 0 { return descriptor }
        if errno == ENOENT { return nil }
        if errno == ELOOP {
            throw CodexSwitchError.unsafeFile("対象ファイルがシンボリックリンクです。")
        }
        throw CodexSwitchError.io("対象ファイルを安全に開けません。")
    }

    @discardableResult
    private static func validateRegularDescriptor(
        _ descriptor: Int32,
        requiredMode: mode_t?,
        requireSingleLink: Bool
    ) throws -> stat {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw CodexSwitchError.unsafeFile("対象ファイルの状態を確認できません。")
        }
        guard (information.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw CodexSwitchError.unsafeFile("対象は通常ファイルではありません。")
        }
        guard information.st_uid == getuid() else {
            throw CodexSwitchError.unsafeFile("対象ファイルの所有者が現在のユーザーではありません。")
        }
        guard information.st_mode & mode_t(0o077) == 0 else {
            throw CodexSwitchError.unsafeFile("対象ファイルの権限が安全な設定ではありません。")
        }
        if requireSingleLink {
            guard information.st_nlink == 1 else {
                throw CodexSwitchError.unsafeFile("対象ファイルに複数のハードリンクがあります。")
            }
        }
        if let requiredMode {
            guard information.st_mode & mode_t(0o777) == requiredMode else {
                throw CodexSwitchError.unsafeFile("対象ファイルの権限が安全な設定ではありません。")
            }
        }
        return information
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < rawBuffer.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    rawBuffer.count - written
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw CodexSwitchError.io("一時ファイルへの書き込みに失敗しました。")
                }
                guard result > 0 else {
                    throw CodexSwitchError.io("一時ファイルへの書き込みが完了しませんでした。")
                }
                written += result
            }
        }
    }

    private static func synchronizeFile(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) == -1 {
            if errno == EINTR { continue }
            throw CodexSwitchError.io("一時ファイルを永続化できません。")
        }

        #if os(macOS)
        while true {
            let result = Darwin.fcntl(descriptor, F_FULLFSYNC)
            if result == 0 { break }
            if errno == EINTR { continue }
            if errno == EINVAL || errno == ENOTSUP { break }
            throw CodexSwitchError.io("一時ファイルを完全に永続化できません。")
        }
        #endif
    }

    private static func synchronizeDirectory(_ descriptor: Int32) throws {
        while Darwin.fsync(descriptor) == -1 {
            if errno == EINTR { continue }
            throw CodexSwitchError.io("保存先ディレクトリを永続化できません。")
        }
    }

    private static func requireSameRealAndEffectiveUser() throws {
        guard getuid() == geteuid() else {
            throw CodexSwitchError.unsafeFile("実ユーザーと実効ユーザーが一致しないため処理できません。")
        }
    }

    private static func validateComponent(_ component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/")
        else {
            throw CodexSwitchError.unsafeFile("対象ファイル名が不正です。")
        }
    }
}
