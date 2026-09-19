import AppKit
import Darwin
import Foundation

/// A single row of `ps -axo pid=,ppid=,args=` output.
public struct ObservedProcess: Sendable, Equatable {
    public let pid: Int32
    public let parentPID: Int32
    public let command: String

    public init(pid: Int32, parentPID: Int32, command: String) {
        self.pid = pid
        self.parentPID = parentPID
        self.command = command
    }

    /// argv[0]: the first whitespace-separated token of the command line.
    public var executable: String {
        command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }

    var tokens: [String] {
        command.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

public enum AppServerReloadOutcome: Sendable, Equatable {
    /// No running backend belonged to the official application.
    case notRunning
    /// SIGTERM was delivered but no replacement was observed before the
    /// deadline; the application restarts the backend on its own schedule.
    case terminationRequested(previousPIDs: [Int32])
    /// The previous backend exited and a replacement is already running.
    case reloaded(previousPIDs: [Int32], currentPIDs: [Int32])
    /// The backend set could not be enumerated or signalled.
    case indeterminate
}

/// Reloads switched credentials by terminating only the official
/// application's own `app-server` sidecar. The application respawns the
/// backend, which reads the replaced auth file and broadcasts
/// `account/updated`; the app itself is never quit or signalled.
///
/// A backend qualifies only when argv[0] is the bundled
/// `Contents/Resources/codex`, its parent is the official application
/// process, and `app-server` appears as an argument token. Other Codex
/// processes on the machine are never matched.
public struct AppServerReloader: Sendable {
    public typealias ProcessLister = @Sendable () throws -> [ObservedProcess]
    public typealias SignalSender = @Sendable (Int32, Int32) -> Bool

    private let applicationExecutablePath: String
    private let serverExecutablePath: String
    private let listProcesses: ProcessLister
    private let sendSignal: SignalSender
    private let pollInterval: TimeInterval
    private let timeout: TimeInterval
    private let wait: @Sendable (TimeInterval) -> Void

    public init(
        applicationURL: URL = AppServerReloader.defaultApplicationURL(),
        pollInterval: TimeInterval = 0.25,
        timeout: TimeInterval = 15,
        listProcesses: @escaping ProcessLister = AppServerReloader.liveProcessList,
        sendSignal: @escaping SignalSender = { Darwin.kill($0, $1) == 0 },
        wait: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        applicationExecutablePath = applicationURL
            .appending(components: "Contents", "MacOS", "ChatGPT").path
        serverExecutablePath = applicationURL
            .appending(components: "Contents", "Resources", "codex").path
        self.listProcesses = listProcesses
        self.sendSignal = sendSignal
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.wait = wait
    }

    public func reload(cancellation: CancellationToken? = nil) -> AppServerReloadOutcome {
        guard let initial = try? listProcesses() else { return .indeterminate }
        let targets = serverPIDs(in: initial)
        guard !targets.isEmpty else { return .notRunning }

        let signalled = targets.filter { sendSignal($0, SIGTERM) }
        guard !signalled.isEmpty else { return .indeterminate }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // The signal is already delivered; a cancellation only shortens
            // the wait for the replacement, never the switch result.
            do { try cancellation?.check() } catch { break }
            wait(pollInterval)
            guard let current = try? listProcesses() else { continue }
            let currentServers = Set(serverPIDs(in: current))
            let survivors = currentServers.intersection(signalled)
            let replacements = currentServers.subtracting(signalled)
            if survivors.isEmpty && !replacements.isEmpty {
                return .reloaded(
                    previousPIDs: signalled,
                    currentPIDs: replacements.sorted()
                )
            }
        }
        return .terminationRequested(previousPIDs: signalled)
    }

    /// PIDs of `app-server` processes parented to the running official
    /// application. Empty when the application itself is not running.
    func serverPIDs(in processes: [ObservedProcess]) -> [Int32] {
        let appPIDs = Set(
            processes.lazy
                .filter { $0.executable == applicationExecutablePath }
                .map(\.pid)
        )
        guard !appPIDs.isEmpty else { return [] }
        return processes
            .filter {
                $0.executable == serverExecutablePath
                    && appPIDs.contains($0.parentPID)
                    && $0.tokens.contains("app-server")
            }
            .map(\.pid)
            .sorted()
    }

    public static func defaultApplicationURL() -> URL {
        let standard = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        if FileManager.default.fileExists(atPath: standard.path) {
            return standard
        }
        if let resolved = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: CodexInstallation.officialBundleIdentifier
        ) {
            return resolved.standardizedFileURL
        }
        return standard
    }

    /// Enumerates processes through libproc and sysctl only. No helper
    /// subprocess is spawned: a spawned lister can deadlock when its output
    /// outlives the draining loop, and a reloader must never depend on a
    /// child that can hang.
    public static func liveProcessList() throws -> [ObservedProcess] {
        let byteCount = proc_listallpids(nil, 0)
        guard byteCount > 0 else {
            throw CodexSwitchError.process("プロセス一覧を取得できませんでした。")
        }
        var pids = [pid_t](
            repeating: 0,
            count: Int(byteCount) / MemoryLayout<pid_t>.size + 64
        )
        let written = proc_listallpids(
            &pids,
            Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard written > 0 else {
            throw CodexSwitchError.process("プロセス一覧を取得できませんでした。")
        }
        let count = Int(written) / MemoryLayout<pid_t>.size
        return pids[0..<count].compactMap(observedProcess)
    }

    private static func observedProcess(for pid: pid_t) -> ObservedProcess? {
        var info = proc_bsdinfo()
        let infoSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, infoSize) == infoSize,
              info.pbi_status != SZOMB,
              let argv = arguments(for: pid),
              !argv.isEmpty
        else { return nil }
        return ObservedProcess(
            pid: Int32(pid),
            parentPID: Int32(info.pbi_ppid),
            command: argv.joined(separator: " ")
        )
    }

    /// KERN_PROCARGS2 layout: int32 argc, NUL-terminated executable path,
    /// NUL padding, then argc NUL-terminated argument strings.
    private static func arguments(for pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size
        else { return nil }
        let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = MemoryLayout<Int32>.size
        guard let execEnd = buffer[index...].firstIndex(of: 0) else { return nil }
        index = execEnd + 1
        while index < size, buffer[index] == 0 { index += 1 }
        var argv: [String] = []
        while argv.count < argc, index < size {
            guard let end = buffer[index...].firstIndex(of: 0) else { break }
            argv.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return argv.isEmpty ? nil : argv
    }
}
