import Foundation
import XCTest
@testable import CodexSwitchCore

final class AppServerReloaderTests: XCTestCase {
    private static let appExecutable = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    private static let serverExecutable = "/Applications/ChatGPT.app/Contents/Resources/codex"
    private static let serverCommand = serverExecutable + " -c features.code_mode_host=true app-server"

    private func process(_ pid: Int32, _ parent: Int32, _ command: String) -> ObservedProcess {
        ObservedProcess(pid: pid, parentPID: parent, command: command)
    }

    private func liveTable(serverPID: Int32 = 200) -> [ObservedProcess] {[
        process(100, 1, Self.appExecutable),
        process(serverPID, 100, Self.serverCommand),
        // Same arguments, different installation: never a target.
        process(300, 1, "/usr/local/bin/codex app-server"),
        // Bundled binary without the app-server subcommand: not a backend.
        process(400, 100, Self.serverExecutable + " exec ls"),
        // Backend command line parented to an unrelated process: not ours.
        process(500, 999, Self.serverCommand),
    ]}

    private func makeReloader(
        lister: @escaping @Sendable () throws -> [ObservedProcess],
        signalBox: SignalBox,
        timeout: TimeInterval = 0
    ) -> AppServerReloader {
        AppServerReloader(
            applicationURL: URL(fileURLWithPath: "/Applications/ChatGPT.app"),
            pollInterval: 0.01,
            timeout: timeout,
            listProcesses: lister,
            sendSignal: { pid, signal in
                signalBox.record(pid: pid, signal: signal)
                return signalBox.result
            },
            wait: { _ in }
        )
    }

    func testReloadSignalsOnlyTheApplicationsOwnAppServer() throws {
        let table = liveTable()
        let box = SignalBox()
        let reloader = makeReloader(lister: { table }, signalBox: box)

        XCTAssertEqual(
            reloader.reload(),
            .terminationRequested(previousPIDs: [200])
        )
        XCTAssertEqual(box.calls, [SignalBox.Call(pid: 200, signal: SIGTERM)])
    }

    func testReloadReportsNotRunningWithoutApplicationProcess() throws {
        let table = [process(300, 1, "/usr/local/bin/codex app-server")]
        let box = SignalBox()
        let reloader = makeReloader(lister: { table }, signalBox: box)

        XCTAssertEqual(reloader.reload(), .notRunning)
        XCTAssertTrue(box.calls.isEmpty)
    }

    func testReloadReportsNotRunningWithoutBackendProcess() throws {
        let table = [process(100, 1, Self.appExecutable)]
        let box = SignalBox()
        let reloader = makeReloader(lister: { table }, signalBox: box)

        XCTAssertEqual(reloader.reload(), .notRunning)
        XCTAssertTrue(box.calls.isEmpty)
    }

    func testReloadReportsReloadedWhenReplacementAppears() throws {
        let snapshots = SnapshotBox(tables: [
            liveTable(serverPID: 200),
            liveTable(serverPID: 900),
        ])
        let box = SignalBox()
        let reloader = makeReloader(
            lister: { try snapshots.next() },
            signalBox: box,
            timeout: 60
        )

        XCTAssertEqual(
            reloader.reload(),
            .reloaded(previousPIDs: [200], currentPIDs: [900])
        )
        XCTAssertEqual(box.calls, [SignalBox.Call(pid: 200, signal: SIGTERM)])
    }

    func testReloadReportsTerminationRequestedWhenBackendStaysGone() throws {
        let snapshots = SnapshotBox(tables: [
            liveTable(serverPID: 200),
            [process(100, 1, Self.appExecutable)],
        ])
        let box = SignalBox()
        let reloader = makeReloader(
            lister: { try snapshots.next() },
            signalBox: box,
            timeout: 60
        )

        XCTAssertEqual(reloader.reload(), .terminationRequested(previousPIDs: [200]))
    }

    func testReloadReportsIndeterminateWhenEverySignalFails() throws {
        let table = liveTable()
        let box = SignalBox(result: false)
        let reloader = makeReloader(lister: { table }, signalBox: box)

        XCTAssertEqual(reloader.reload(), .indeterminate)
        XCTAssertEqual(box.calls, [SignalBox.Call(pid: 200, signal: SIGTERM)])
    }

    func testReloadReportsIndeterminateWhenListingFails() throws {
        struct ListingFailed: Error {}
        let box = SignalBox()
        let reloader = makeReloader(
            lister: { throw ListingFailed() },
            signalBox: box
        )

        XCTAssertEqual(reloader.reload(), .indeterminate)
        XCTAssertTrue(box.calls.isEmpty)
    }

    func testLiveProcessListFindsCurrentProcessWithoutSubprocess() throws {
        let list = try AppServerReloader.liveProcessList()
        let selfPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let own = list.first { $0.pid == selfPID }

        XCTAssertNotNil(own)
        XCTAssertEqual(own?.parentPID, getppid())
        XCTAssertFalse(list.isEmpty)
    }

    private final class SignalBox: @unchecked Sendable {
        struct Call: Equatable {
            let pid: Int32
            let signal: Int32
        }

        private let lock = NSLock()
        private var recorded: [Call] = []
        let result: Bool

        init(result: Bool = true) {
            self.result = result
        }

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func record(pid: Int32, signal: Int32) {
            lock.lock()
            recorded.append(Call(pid: pid, signal: signal))
            lock.unlock()
        }
    }

    /// Replays a fixed list of process tables, then repeats the last one.
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var tables: [[ObservedProcess]]

        init(tables: [[ObservedProcess]]) {
            self.tables = tables
        }

        func next() throws -> [ObservedProcess] {
            lock.lock()
            defer { lock.unlock() }
            guard tables.count > 1 else { return tables[0] }
            return tables.removeFirst()
        }
    }
}
