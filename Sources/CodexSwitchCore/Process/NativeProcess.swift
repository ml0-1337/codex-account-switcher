import Darwin
import Foundation

/// A small direct `posix_spawn` owner used by app-server sessions and native
/// inspection commands. It never delegates launch or termination to
/// Foundation's process launcher, and it only signals the process group it
/// created.
public final class NativeProcess: @unchecked Sendable {
    public let processID: Int32
    public let processGroupID: Int32
    public let standardInput: Int32
    public let standardOutput: Int32
    public let standardError: Int32

    private var inputClosed = false
    private var descriptorsClosed = false
    private var leaderReaped = false
    private var stopped = false

    public private(set) var cleanupFailureReason: String?
    public private(set) var terminationStatus: Int32?

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil
    ) throws {
        guard executable.isFileURL,
              executable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw CodexSwitchError.process("実行ファイルを確認できません。")
        }

        if let workingDirectory {
            guard workingDirectory.isFileURL,
                  workingDirectory.path.hasPrefix("/")
            else {
                throw CodexSwitchError.invalidInput("子プロセスの作業ディレクトリが不正です。")
            }
            let descriptor = try SecurePath.openDirectory(workingDirectory)
            _ = Darwin.close(descriptor)
        }

        var inputPipe = [Int32](repeating: -1, count: 2)
        var outputPipe = [Int32](repeating: -1, count: 2)
        var errorPipe = [Int32](repeating: -1, count: 2)
        guard pipe(&inputPipe) == 0,
              pipe(&outputPipe) == 0,
              pipe(&errorPipe) == 0
        else {
            closeNativePipes(inputPipe, outputPipe, errorPipe)
            throw CodexSwitchError.process("子プロセスの入出力を作成できません。")
        }

        // Mark every pipe endpoint close-on-exec before spawning. The file
        // actions duplicate only the three standard streams; this prevents
        // the child's original endpoints from leaking into grandchildren.
        for descriptor in inputPipe + outputPipe + errorPipe {
            guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) >= 0 else {
                closeNativePipes(inputPipe, outputPipe, errorPipe)
                throw CodexSwitchError.process("子プロセスの入出力を安全に設定できません。")
            }
        }

        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        var actionsInitialized = false
        var attributesInitialized = false
        defer {
            if attributesInitialized { posix_spawnattr_destroy(&attributes) }
            if actionsInitialized { posix_spawn_file_actions_destroy(&actions) }
        }
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            closeNativePipes(inputPipe, outputPipe, errorPipe)
            throw CodexSwitchError.process("子プロセスの入出力を設定できません。")
        }
        actionsInitialized = true
        guard posix_spawn_file_actions_adddup2(&actions, inputPipe[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addclose(&actions, inputPipe[1]) == 0,
              posix_spawn_file_actions_addclose(&actions, outputPipe[0]) == 0,
              posix_spawn_file_actions_addclose(&actions, errorPipe[0]) == 0
        else {
            closeNativePipes(inputPipe, outputPipe, errorPipe)
            throw CodexSwitchError.process("子プロセスの入出力を設定できません。")
        }

        if let workingDirectory {
            let result = workingDirectory.standardizedFileURL.path.withCString { pointer in
                posix_spawn_file_actions_addchdir_np(&actions, pointer)
            }
            guard result == 0 else {
                closeNativePipes(inputPipe, outputPipe, errorPipe)
                throw CodexSwitchError.process("子プロセスの作業ディレクトリを設定できません。")
            }
        }

        guard posix_spawnattr_init(&attributes) == 0 else {
            closeNativePipes(inputPipe, outputPipe, errorPipe)
            throw CodexSwitchError.process("子プロセスの属性を設定できません。")
        }
        attributesInitialized = true
        var defaultSignals = sigset_t()
        var emptyMask = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGTERM)
        sigemptyset(&emptyMask)

        let setGroupResult = posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP)
                | Int16(POSIX_SPAWN_SETSIGDEF)
                | Int16(POSIX_SPAWN_SETSIGMASK)
        )
        let setGroupIDResult = posix_spawnattr_setpgroup(&attributes, 0)
        let setDefaultSignalsResult = posix_spawnattr_setsigdefault(
            &attributes,
            &defaultSignals
        )
        let setSignalMaskResult = posix_spawnattr_setsigmask(&attributes, &emptyMask)
        guard setGroupResult == 0,
              setGroupIDResult == 0,
              setDefaultSignalsResult == 0,
              setSignalMaskResult == 0
        else {
            closeNativePipes(inputPipe, outputPipe, errorPipe)
            throw CodexSwitchError.process("子プロセスグループを設定できません。")
        }

        let commandArguments = [executable.path] + arguments
        let environmentArguments = environment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var childPID: pid_t = 0
        let spawnResult: Int32 = withCStringArray(commandArguments) { argv in
            withCStringArray(environmentArguments) { envp in
                executable.path.withCString { executablePointer in
                    posix_spawn(
                        &childPID,
                        executablePointer,
                        &actions,
                        &attributes,
                        argv,
                        envp
                    )
                }
            }
        }
        guard spawnResult == 0, childPID > 0 else {
            closeNativePipes(inputPipe, outputPipe, errorPipe)
            throw CodexSwitchError.process("子プロセスを起動できません。")
        }

        // The child now owns the opposite side of each pipe. Parent
        // descriptors were marked close-on-exec before the spawn call.
        Darwin.close(inputPipe[0])
        Darwin.close(outputPipe[1])
        Darwin.close(errorPipe[1])

        self.processID = Int32(childPID)
        self.processGroupID = Int32(childPID)
        self.standardInput = inputPipe[1]
        self.standardOutput = outputPipe[0]
        self.standardError = errorPipe[0]
    }

    deinit {
        if !stopped {
            try? stop(gracefulTimeout: 0, terminateTimeout: 0.25)
        }
        closeDescriptors()
    }

    public var isStopped: Bool { stopped }

    public func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        Darwin.close(standardInput)
    }

    /// Closes the input, then waits for the owned group. If the group does not
    /// exit, TERM and KILL are sent only to that group. The leader is reaped
    /// only after the group is confirmed gone, preventing PID/PGID reuse while
    /// descendant cleanup is still uncertain.
    public func stop(
        gracefulTimeout: TimeInterval,
        terminateTimeout: TimeInterval
    ) throws {
        guard !stopped else { return }
        closeInput()

        if waitForOwnedProcesses(timeout: gracefulTimeout) {
            finishStop()
            return
        }
        sendSignal(SIGTERM)
        if waitForOwnedProcesses(timeout: terminateTimeout) {
            finishStop()
            return
        }
        sendSignal(SIGKILL)
        if waitForOwnedProcesses(timeout: max(terminateTimeout, 1.0)) {
            finishStop()
            return
        }

        cleanupFailureReason = "所有プロセスグループの終了を確認できません。"
        // Keep the process descriptors available for a caller that needs to
        // retain the exact temporary-home path and report this failure.
        throw CodexSwitchError.process(cleanupFailureReason!)
    }

    private func waitForOwnedProcesses(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while ownedProcessesExist() {
            if Date() >= deadline { return false }
            usleep(20_000)
        }
        // Only now may the leader be reaped. A zombie leader keeps the group
        // observable until this point, so a new process cannot reuse its PID.
        reapLeaderIfNeeded()
        return true
    }

    private func ownedProcessesExist() -> Bool {
        if let groupHasLiveProcesses = groupHasLiveProcesses(processGroupID) {
            return groupHasLiveProcesses
        }
        let result = Darwin.kill(-processGroupID, 0)
        if result == 0 || errno == EPERM { return true }
        if errno == ESRCH { return false }
        // If the group query itself failed for an unexpected reason, retain
        // the conservative process-level check rather than claiming cleanup.
        if result < 0, errno != ESRCH {
            let leaderResult = Darwin.kill(processID, 0)
            return leaderResult == 0 || errno == EPERM
        }
        return false
    }

    /// `kill(-pgid, 0)` also reports a retained zombie leader. Query only this
    /// process group so a zombie can be reaped after every live descendant is
    /// gone without enumerating or touching unrelated processes.
    private func groupHasLiveProcesses(_ processGroupID: Int32) -> Bool? {
        let requiredBytes = proc_listpids(
            UInt32(PROC_PGRP_ONLY),
            UInt32(processGroupID),
            nil,
            0
        )
        guard requiredBytes >= 0 else { return nil }
        guard requiredBytes > 0 else { return false }

        let pidSize = MemoryLayout<pid_t>.size
        let requiredCount = Int(requiredBytes) / pidSize
        let maximumCapacity = 1 << 16
        var capacity = min(max(requiredCount + 1, 64), maximumCapacity)
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let returnedBytes = pids.withUnsafeMutableBytes { rawBuffer in
                proc_listpids(
                    UInt32(PROC_PGRP_ONLY),
                    UInt32(processGroupID),
                    rawBuffer.baseAddress,
                    Int32(rawBuffer.count)
                )
            }
            guard returnedBytes >= 0 else { return nil }
            // A full result may be truncated while descendants fork between
            // the sizing and enumeration calls. Grow and retry instead of
            // treating the visible prefix as a complete process group.
            if returnedBytes >= Int32(pids.count * pidSize) {
                guard capacity < maximumCapacity else { return nil }
                capacity = min(capacity * 2, maximumCapacity)
                continue
            }

            let count = Int(returnedBytes) / pidSize
            for pid in pids.prefix(count) where pid > 0 {
                var information = proc_bsdinfo()
                let result = withUnsafeMutablePointer(to: &information) { pointer in
                    proc_pidinfo(
                        pid,
                        Int32(PROC_PIDTBSDINFO),
                        0,
                        UnsafeMutableRawPointer(pointer),
                        Int32(MemoryLayout<proc_bsdinfo>.size)
                    )
                }
                // Darwin returns zero for a zombie whose BSD information has
                // already been torn down. Treat that entry as exited only for
                // our retained leader; an uninspectable descendant keeps
                // cleanup conservative rather than being mistaken for a live
                // process.
                if result == 0, pid == processID { continue }
                guard result == Int32(MemoryLayout<proc_bsdinfo>.size) else { return nil }
                if information.pbi_status != UInt32(SZOMB) {
                    return true
                }
            }
            return false
        }
    }

    private func sendSignal(_ signal: Int32) {
        _ = Darwin.kill(-processGroupID, signal)
    }

    private func reapLeaderIfNeeded() {
        guard !leaderReaped else { return }
        var status: Int32 = 0
        while true {
            let result = waitpid(processID, &status, 0)
            if result == processID {
                leaderReaped = true
                terminationStatus = decodeWaitStatus(status)
                return
            }
            if result < 0, errno == EINTR { continue }
            if result < 0, errno == ECHILD {
                leaderReaped = true
                terminationStatus = 0
            }
            return
        }
    }

    private func finishStop() {
        stopped = true
        closeDescriptors()
    }

    private func closeDescriptors() {
        guard !descriptorsClosed else { return }
        descriptorsClosed = true
        closeInput()
        Darwin.close(standardOutput)
        Darwin.close(standardError)
    }

}

/// Runs a short-lived native command and bounds the captured output. This is
/// used only for inspection (for example `codesign` and `codex --version`).
public struct NativeCommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
}

public enum NativeCommand {
    private static let maximumDrainReads = 8
    private static let pollingSlice: TimeInterval = 0.05

    public static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maximumOutputBytes: Int = 64 * 1024,
        workingDirectory: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> NativeCommandResult {
        try cancellation?.check()
        let process = try NativeProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        process.closeInput()

        let outputDescriptor = process.standardOutput
        let errorDescriptor = process.standardError
        _ = fcntl(outputDescriptor, F_SETFL, fcntl(outputDescriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(errorDescriptor, F_SETFL, fcntl(errorDescriptor, F_GETFL) | O_NONBLOCK)

        var captured = Data()
        let deadline = Date().addingTimeInterval(30)
        do {
            while true {
                try cancellation?.check()
                guard Date() < deadline else {
                    throw CodexSwitchError.process("ネイティブコマンドがタイムアウトしました。")
                }

                try drain(
                    descriptor: outputDescriptor,
                    into: &captured,
                    maximum: maximumOutputBytes,
                    cancellation: cancellation
                )
                try drain(
                    descriptor: errorDescriptor,
                    into: &captured,
                    maximum: maximumOutputBytes,
                    cancellation: cancellation
                )
                if process.waitForExitWithoutStopping(timeout: pollingSlice) {
                    try cancellation?.check()
                    try drain(
                        descriptor: outputDescriptor,
                        into: &captured,
                        maximum: maximumOutputBytes,
                        cancellation: cancellation
                    )
                    try drain(
                        descriptor: errorDescriptor,
                        into: &captured,
                        maximum: maximumOutputBytes,
                        cancellation: cancellation
                    )
                    let status = process.terminationStatus ?? 0
                    return NativeCommandResult(
                        status: status,
                        output: String(decoding: captured, as: UTF8.self)
                    )
                }
            }
        } catch {
            guard !process.isStopped else { throw error }
            do {
                try process.stop(gracefulTimeout: 0, terminateTimeout: 0.2)
            } catch {
                // A cleanup failure is actionable: do not hide it behind the
                // original timeout, cancellation, or read error.
                throw error
            }
            throw error
        }
    }

    private static func drain(
        descriptor: Int32,
        into data: inout Data,
        maximum: Int,
        cancellation: CancellationToken?
    ) throws {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<maximumDrainReads {
            try cancellation?.check()
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                if data.count < maximum {
                    data.append(contentsOf: buffer.prefix(min(count, maximum - data.count)))
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
            if count < 0 {
                throw CodexSwitchError.process("ネイティブコマンドの出力を読み取れません。")
            }
            break
        }
    }
}

private extension NativeProcess {
    func waitForExitWithoutStopping(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while true {
            if !ownedProcessesExist() {
                reapLeaderIfNeeded()
                stopped = true
                return true
            }
            if Date() >= deadline { return false }
            usleep(10_000)
        }
    }
}

private func decodeWaitStatus(_ status: Int32) -> Int32 {
    // Darwin's wait-status macros are not imported by Swift. The POSIX layout
    // stores a normal exit code in bits 8...15 and a terminating signal in the
    // low seven bits.
    if status & 0x7f == 0 {
        return (status >> 8) & 0xff
    }
    return 128 + (status & 0x7f)
}

private func withCStringArray<T>(
    _ strings: [String],
    _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) throws -> T
) rethrows -> T {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers where pointer != nil {
            free(pointer)
        }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress)
    }
}

private func closeNativePipes(
    _ input: [Int32],
    _ output: [Int32],
    _ error: [Int32]
) {
    for descriptor in input + output + error where descriptor >= 0 {
        Darwin.close(descriptor)
    }
}
