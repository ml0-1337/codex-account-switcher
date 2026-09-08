import Darwin
import Foundation
import XCTest
@testable import CodexSwitchCore

final class NativeProcessTests: XCTestCase {
    func testNativeCommandSetsOwnedWorkingDirectoryAndEnvironment() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try NativeCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n%s\\n' \"$PWD\" \"$CODEX_HOME\""],
            environment: ["CODEX_HOME": directory.path],
            workingDirectory: directory
        )

        XCTAssertEqual(result.status, 0)
        // macOS exposes /var through a stable /private/var alias to child
        // processes, even when the caller supplied the public /var spelling.
        let resolvedPath = directory.path.hasPrefix("/var/")
            ? "/private\(directory.path)"
            : directory.path.hasPrefix("/tmp/")
                ? "/private\(directory.path)"
                : directory.path
        XCTAssertEqual(
            result.output,
            "\(resolvedPath)\n\(directory.standardizedFileURL.path)\n"
        )
    }

    func testOwnedGroupStopsLeaderAndGrandchildWithoutTouchingUnrelatedGroup() throws {
        let shell = try NativeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & printf ready; wait"]
        )
        let unrelated = try NativeProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )
        defer { try? unrelated.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        let ownedGroup = shell.processGroupID
        let unrelatedGroup = unrelated.processGroupID
        XCTAssertTrue(waitForOutput(shell.standardOutput, matching: "ready"))
        try shell.stop(gracefulTimeout: 0.05, terminateTimeout: 0.5)

        XCTAssertEqual(Darwin.kill(-ownedGroup, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(Darwin.kill(-unrelatedGroup, 0), 0)
    }

    func testTermIgnoringOwnedGroupRequiresKillAndLeavesUnrelatedGroupAlive() throws {
        let shell = try NativeProcess(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sh -c 'trap \"\" TERM; sleep 30 & printf ready; wait' & wait"]
        )
        let unrelated = try NativeProcess(
            executable: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"]
        )
        defer { try? unrelated.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        let ownedGroup = shell.processGroupID
        let unrelatedGroup = unrelated.processGroupID
        XCTAssertTrue(waitForOutput(shell.standardOutput, matching: "ready"))
        try shell.stop(gracefulTimeout: 0.05, terminateTimeout: 0.05)

        XCTAssertEqual(Darwin.kill(-ownedGroup, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(Darwin.kill(-unrelatedGroup, 0), 0)
    }

    func testInheritedIgnoredSIGTERMIsResetForOwnedChild() throws {
        let previousHandler = signal(SIGTERM, SIG_IGN)
        defer { _ = signal(SIGTERM, previousHandler) }

        let result = try NativeCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$"]
        )

        XCTAssertEqual(result.status, 143)
    }

    func testCancellationStopsOwnedNativeCommandAndReturnsInterruption() throws {
        let token = CancellationToken()
        let resultBox = ResultBox()
        let finished = expectation(description: "native command stops after cancellation")

        DispatchQueue.global().async {
            resultBox.store(Result {
                try NativeCommand.run(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "while :; do printf x >&2; done"],
                    cancellation: token
                )
            })
            finished.fulfill()
        }

        usleep(100_000)
        token.cancel(signal: SIGTERM)
        wait(for: [finished], timeout: 2)

        guard case let .failure(error) = resultBox.value else {
            return XCTFail("NativeCommand should stop with the cancellation error")
        }
        XCTAssertTrue(error is OperationInterrupted)
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<NativeCommandResult, Error>?

        var value: Result<NativeCommandResult, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }

        func store(_ result: Result<NativeCommandResult, Error>) {
            lock.lock()
            self.result = result
            lock.unlock()
        }
    }

    private func waitForOutput(
        _ descriptor: Int32,
        matching expected: String,
        timeout: TimeInterval = 1
    ) -> Bool {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            return false
        }

        let expectedData = Data(expected.utf8)
        var output = Data()
        let deadline = Date().addingTimeInterval(timeout)
        var buffer = [UInt8](repeating: 0, count: 256)
        while Date() < deadline {
            var descriptorState = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            let pollResult = Darwin.poll(&descriptorState, 1, 20)
            if pollResult < 0, errno == EINTR { continue }
            if pollResult < 0 { return false }
            if pollResult == 0 { continue }

            let readCount = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(descriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount > 0 {
                output.append(contentsOf: buffer.prefix(readCount))
                if output.range(of: expectedData) != nil { return true }
            } else if readCount == 0 {
                return output.range(of: expectedData) != nil
            } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
                return false
            }
        }
        return output.range(of: expectedData) != nil
    }
}
