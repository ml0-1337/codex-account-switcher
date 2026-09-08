import Darwin
import Foundation
import XCTest

final class EntryPointTests: XCTestCase {
    func testHelpWorksWithoutOpeningCredentialStorage() throws {
        for argument in ["help", "-h", "--help"] {
            let result = try runCLI(arguments: [argument])
            XCTAssertEqual(result.code, 0)
            XCTAssertTrue(result.output.contains("codex-switch"))
            XCTAssertTrue(result.output.contains("setup"))
            XCTAssertTrue(result.output.contains("recover"))
        }
    }

    func testRemovedArgumentsFailBeforeOpeningCredentialStorage() throws {
        for arguments in [["--no-restart"], ["switch"], ["doctor"], ["--app-server-launch"], ["add", "extra"]] {
            let result = try runCLI(arguments: arguments)
            XCTAssertEqual(result.code, 2, arguments.joined(separator: " "))
            XCTAssertFalse(result.output.contains("切り替えました"))
            XCTAssertFalse(result.output.contains("CODEX_HOME"))
        }
    }

    func testPipedMutationsAreRejectedBeforeOpeningCredentialStorage() throws {
        for arguments in [[], ["setup"], ["add"], ["recover"]] {
            let result = try runCLI(arguments: arguments)
            XCTAssertEqual(result.code, 1)
            XCTAssertFalse(result.output.isEmpty)
            XCTAssertFalse(result.output.contains("CODEX_HOME"))
            XCTAssertFalse(result.output.contains("切り替えました"))
        }
    }

    func testSignalsAtConfirmationReturnInterruptExitCodesWithoutAccessingCredentials() throws {
        for signal in [SIGINT, SIGTERM] {
            var master: Int32 = -1
            var slave: Int32 = -1
            guard openpty(&master, &slave, nil, nil, nil) == 0 else {
                return XCTFail("Could not create the isolated terminal fixture")
            }
            defer {
                _ = Darwin.close(master)
                _ = Darwin.close(slave)
            }
            let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
                .appendingPathComponent("codex-switch")
            let process = Process()
            process.executableURL = binary
            process.arguments = ["setup"]
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = "/invalid-codex-switch-help-fixture"
            process.environment = environment
            process.standardInput = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            try process.run()
            defer {
                if process.isRunning {
                    _ = kill(process.processIdentifier, SIGKILL)
                    process.waitUntilExit()
                }
            }

            var captured = Data()
            let promptDeadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < promptDeadline {
                var descriptor = pollfd(
                    fd: output.fileHandleForReading.fileDescriptor,
                    events: Int16(POLLIN), revents: 0
                )
                if poll(&descriptor, 1, 50) > 0 && descriptor.revents & Int16(POLLIN) != 0 {
                    var bytes = [UInt8](repeating: 0, count: 4096)
                    let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                    if count > 0 { captured.append(contentsOf: bytes.prefix(count)) }
                }
                if String(decoding: captured, as: UTF8.self).contains("[y/N]") { break }
            }
            guard process.isRunning,
                  String(decoding: captured, as: UTF8.self).contains("[y/N]") else {
                XCTFail("CLI did not reach the confirmation prompt")
                continue
            }
            XCTAssertEqual(kill(process.processIdentifier, signal), 0)
            let stopDeadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < stopDeadline { usleep(10_000) }
            guard !process.isRunning else {
                XCTFail("CLI did not stop after the fixture signal")
                continue
            }
            process.waitUntilExit()
            captured.append(output.fileHandleForReading.readDataToEndOfFile())
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 128 + signal)
            let text = String(decoding: captured, as: UTF8.self)
            XCTAssertFalse(text.contains("CODEX_HOME"))
            XCTAssertFalse(text.contains("完了しました"))
            XCTAssertFalse(text.contains("切り替えました"))
        }
    }

    private func runCLI(arguments: [String]) throws -> (code: Int32, output: String) {
        let binary = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("codex-switch")
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        // These paths deliberately cannot be used. Help and argument rejection
        // must happen before resolving the real account service.
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = "/invalid-codex-switch-help-fixture"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("CLI did not terminate within the fixture timeout")
            let stopDeadline = Date().addingTimeInterval(1)
            while process.isRunning && Date() < stopDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
