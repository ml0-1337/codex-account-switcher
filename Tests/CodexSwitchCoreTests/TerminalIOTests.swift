import Darwin
import XCTest
@testable import CodexSwitchCore

final class TerminalIOTests: XCTestCase {
    func testStandardTerminalIOPollsAndPreservesMultipleLines() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            _ = Darwin.close(descriptors[0])
            if descriptors[1] >= 0 {
                _ = Darwin.close(descriptors[1])
            }
        }

        let token = CancellationToken()
        let io = StandardTerminalIO(
            cancellation: token,
            inputDescriptor: descriptors[0],
            interactive: false,
            pollIntervalMilliseconds: 5
        )
        let bytes = Data("alice\r\nbob\n".utf8)
        XCTAssertEqual(bytes.withUnsafeBytes { rawBuffer in
            Darwin.write(descriptors[1], rawBuffer.baseAddress, rawBuffer.count)
        }, bytes.count)
        _ = Darwin.close(descriptors[1])
        descriptors[1] = -1

        XCTAssertEqual(try io.readLine(cancellation: token), "alice")
        XCTAssertEqual(try io.readLine(cancellation: token), "bob")
        XCTAssertNil(try io.readLine(cancellation: token))
    }

    func testStandardTerminalIOStopsBlockedReadWhenTokenIsCancelled() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            _ = Darwin.close(descriptors[0])
            if descriptors[1] >= 0 {
                _ = Darwin.close(descriptors[1])
            }
        }

        let inputDescriptor = descriptors[0]
        let token = CancellationToken()
        let outcome = ExitCodeOutcome()
        let finished = expectation(description: "blocked terminal input exits")
        DispatchQueue.global().async {
            let io = StandardTerminalIO(
                cancellation: token,
                inputDescriptor: inputDescriptor,
                interactive: true,
                pollIntervalMilliseconds: 5
            )
            do {
                _ = try io.readLine(cancellation: token)
            } catch let interrupted as OperationInterrupted {
                outcome.exitCode = interrupted.exitCode
            } catch {
                outcome.exitCode = -1
            }
            finished.fulfill()
        }

        usleep(20_000)
        token.cancel()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(outcome.exitCode, 130)
    }

    func testStandardTerminalIOStopsBlockedOutputWhenTokenIsCancelled() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            _ = Darwin.close(descriptors[0])
            if descriptors[1] >= 0 {
                _ = Darwin.close(descriptors[1])
            }
        }

        let outputDescriptor = descriptors[1]
        let originalFlags = fcntl(outputDescriptor, F_GETFL)
        guard originalFlags >= 0 else {
            XCTFail("could not inspect pipe flags")
            return
        }
        guard fcntl(outputDescriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            XCTFail("could not make fixture pipe nonblocking")
            return
        }

        let fill = [UInt8](repeating: 0x66, count: 4096)
        while true {
            let writeCount = fill.withUnsafeBytes { rawBuffer in
                Darwin.write(outputDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if writeCount >= 0 { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                XCTFail("fixture pipe did not report EAGAIN")
                return
            }
            break
        }
        guard fcntl(outputDescriptor, F_SETFL, originalFlags) == 0 else {
            XCTFail("could not restore fixture pipe flags")
            return
        }

        let token = CancellationToken()
        let outcome = ExitCodeOutcome()
        let finished = expectation(description: "blocked terminal output exits")
        DispatchQueue.global().async {
            let io = StandardTerminalIO(
                cancellation: token,
                inputDescriptor: STDIN_FILENO,
                outputDescriptor: outputDescriptor,
                interactive: false,
                pollIntervalMilliseconds: 5
            )
            do {
                try io.write("output waits for space", to: .standardOutput)
                outcome.exitCode = -2
            } catch let interrupted as OperationInterrupted {
                outcome.exitCode = interrupted.exitCode
            } catch {
                outcome.exitCode = -1
            }
            finished.fulfill()
        }

        usleep(20_000)
        token.cancel()
        wait(for: [finished], timeout: 1)
        XCTAssertEqual(outcome.exitCode, 130)
    }

    func testStandardTerminalIODiagnosticWritesToStderrAfterTokenCancellation() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            _ = Darwin.close(descriptors[0])
            if descriptors[1] >= 0 {
                _ = Darwin.close(descriptors[1])
            }
        }

        let token = CancellationToken()
        let io = StandardTerminalIO(
            cancellation: token,
            inputDescriptor: STDIN_FILENO,
            errorDescriptor: descriptors[1],
            interactive: false,
            pollIntervalMilliseconds: 5
        )
        token.cancel(signal: SIGTERM)

        let expected = "ログイン用一時ホームを保持しています: /private/tmp/diagnostic-fixture\n"
        try io.write(expected, to: .standardError)
        _ = Darwin.close(descriptors[1])
        descriptors[1] = -1

        var bytes = [UInt8](repeating: 0, count: 256)
        let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(descriptors[0], rawBuffer.baseAddress, rawBuffer.count)
        }
        XCTAssertEqual(
            String(decoding: bytes.prefix(max(readCount, 0)), as: UTF8.self),
            expected
        )
    }

    func testStandardTerminalIODiagnosticStopsPollWaitAtDeadlineWhenStderrPipeIsFull() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        XCTAssertEqual(pipe(&descriptors), 0)
        defer {
            _ = Darwin.close(descriptors[0])
            if descriptors[1] >= 0 {
                _ = Darwin.close(descriptors[1])
            }
        }

        let outputDescriptor = descriptors[1]
        let originalFlags = fcntl(outputDescriptor, F_GETFL)
        guard originalFlags >= 0 else {
            XCTFail("could not inspect pipe flags")
            return
        }
        guard fcntl(outputDescriptor, F_SETFL, originalFlags | O_NONBLOCK) == 0 else {
            XCTFail("could not make fixture pipe nonblocking")
            return
        }

        let fill = [UInt8](repeating: 0x66, count: 4096)
        while true {
            let writeCount = fill.withUnsafeBytes { rawBuffer in
                Darwin.write(outputDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if writeCount >= 0 { continue }
            guard errno == EAGAIN || errno == EWOULDBLOCK else {
                XCTFail("fixture pipe did not report EAGAIN")
                return
            }
            break
        }
        guard fcntl(outputDescriptor, F_SETFL, originalFlags) == 0 else {
            XCTFail("could not restore fixture pipe flags")
            return
        }

        let token = CancellationToken()
        token.cancel(signal: SIGTERM)
        let io = StandardTerminalIO(
            cancellation: token,
            inputDescriptor: STDIN_FILENO,
            errorDescriptor: outputDescriptor,
            interactive: false,
            pollIntervalMilliseconds: 5
        )

        let start = Date()
        // This bounds the poll wait for a full pipe; it does not claim an
        // absolute deadline for an externally stalled inherited descriptor.
        XCTAssertThrowsError(try io.write("diagnostic waits for space", to: .standardError))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testStandardTerminalIORejectsInvalidOutputDescriptor() {
        let token = CancellationToken()
        let io = StandardTerminalIO(
            cancellation: token,
            inputDescriptor: STDIN_FILENO,
            outputDescriptor: -1,
            interactive: false,
            pollIntervalMilliseconds: 5
        )

        XCTAssertThrowsError(try io.write("invalid descriptor", to: .standardOutput))
    }
}

private final class ExitCodeOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?

    var exitCode: Int32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
        set {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }
}
