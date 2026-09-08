import Darwin
import Foundation
import XCTest
@testable import CodexSwitchCore

final class AppServerClientTests: XCTestCase {
    func testNativeTransportStartsFixtureInSuppliedCodexHome() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let transport = try NativeAppServerTransportFactory().makeTransport(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s\\n%s\\n' \"$PWD\" \"$CODEX_HOME\""],
            environment: ["CODEX_HOME": directory.path],
            maximumLineLength: 4_096,
            writeTimeout: 1,
            workingDirectory: directory
        )
        defer { try? transport.stop(gracefulTimeout: 0.1, terminateTimeout: 0.5) }

        let first = try transport.receiveLine(until: Date().addingTimeInterval(1))
        let second = try transport.receiveLine(until: Date().addingTimeInterval(1))
        XCTAssertEqual(String(decoding: try XCTUnwrap(first), as: UTF8.self), expectedWorkingDirectory(for: directory))
        XCTAssertEqual(String(decoding: try XCTUnwrap(second), as: UTF8.self), directory.path)
    }

    func testHandshakeAndAccountLoginUseDocumentedJSONLRequests() throws {
        let transport = FixtureTransport()
        let client = try AppServerClient(
            codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
            codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            transport: transport
        )

        _ = try client.initialize()
        let account = try client.accountRead(refreshToken: false)
        XCTAssertEqual(account.account?.type, "chatgpt")
        XCTAssertEqual(account.account?.email, "person@example.com")
        XCTAssertEqual(try client.accountLoginStartDeviceCode().loginID, "fixture-login")
        let completion = try client.waitForLoginCompleted(loginID: "fixture-login", timeout: 1)
        XCTAssertTrue(completion.success)
        try client.accountLoginCancel(loginID: "fixture-login")

        XCTAssertEqual(transport.methods, [
            "initialize", "initialized", "account/read", "account/login/start",
            "account/login/cancel",
        ])
        let accountRequest = try XCTUnwrap(transport.objects.first(where: {
            $0["method"]?.stringValue == "account/read"
        }))
        XCTAssertEqual(accountRequest["params"]?.objectValue?["refreshToken"]?.boolValue, false)
    }

    func testDeviceCodeResponseWithVerificationURLAndWithoutAuthURLIsValid() throws {
        let transport = FixtureTransport()
        let client = try AppServerClient(
            codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
            codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            transport: transport
        )

        _ = try client.initialize()
        let result = try client.accountLoginStartDeviceCode()

        XCTAssertEqual(result.verificationURL, "https://auth.openai.com/codex/device")
    }

    func testDeviceCodeResponseRequiresVerificationURL() throws {
        for response in [
            FixtureTransport.DeviceCodeResponse.missingVerificationURL,
            .authURLOnly,
            .bothURLsMissing,
        ] {
            let transport = FixtureTransport()
            transport.deviceCodeResponse = response
            let client = try AppServerClient(
                codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
                codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
                transport: transport
            )
            _ = try client.initialize()

            XCTAssertThrowsError(try client.accountLoginStartDeviceCode()) { error in
                XCTAssertTrue(error is CodexSwitchError)
            }
        }
    }

    func testAccountReadRequiresExplicitBooleanRequiresOpenaiAuth() throws {
        for value in [FixtureTransport.AccountAuthField.missing, .null] {
            let transport = FixtureTransport()
            transport.accountAuthField = value
            let client = try AppServerClient(
                codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
                codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
                transport: transport
            )
            _ = try client.initialize()

            XCTAssertThrowsError(try client.accountRead()) { error in
                XCTAssertTrue(error is CodexSwitchError)
            }
        }
    }

    func testCancellationIsCheckedButCloseStillRunsCleanup() throws {
        let transport = FixtureTransport()
        let token = CancellationToken()
        let client = try AppServerClient(
            codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
            codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            transport: transport,
            cancellation: token
        )
        _ = try client.initialize()
        token.cancel(signal: SIGTERM)

        XCTAssertThrowsError(try client.accountRead()) { error in
            XCTAssertTrue(error is OperationInterrupted)
        }
        XCTAssertNoThrow(try client.close())
        XCTAssertEqual(transport.stopCount, 1)
    }

    func testLoginCancelBypassesCancellationAndBoundsWriteToCleanupTimeout() throws {
        let transport = FixtureTransport()
        let token = CancellationToken()
        let client = try AppServerClient(
            codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
            codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            transport: transport,
            cancellation: token
        )
        _ = try client.initialize()
        token.cancel(signal: SIGTERM)

        XCTAssertNoThrow(try client.accountLoginCancel(loginID: "fixture-login", timeout: 0.1))
        XCTAssertTrue(transport.cancelRequestBypassedCancellation)
        XCTAssertEqual(try XCTUnwrap(transport.cancelRequestWriteTimeout), 0.1, accuracy: 0.001)
    }

    func testInitializerDoesNotSendHandshakeUntilExplicitInitialization() throws {
        let transport = FixtureTransport()
        let client = try AppServerClient(
            codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
            codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            transport: transport
        )

        XCTAssertTrue(transport.methods.isEmpty)
        _ = try client.initialize()
        XCTAssertEqual(transport.methods, ["initialize", "initialized"])
    }

    func testDeadlineExpiresDespiteContinuousUnrelatedNotifications() throws {
        let transport = FixtureTransport()
        let client = try AppServerClient(
            codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
            codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            transport: transport
        )
        _ = try client.initialize()
        transport.alwaysReturnUnrelatedLoginNotifications = true

        let start = Date()
        XCTAssertThrowsError(
            try client.waitForLoginCompleted(loginID: "wanted-login", timeout: 0.1)
        ) { error in
            guard case let CodexSwitchError.appServer(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("タイムアウト"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testResponseDeadlineExpiresDespiteContinuousUnrelatedResponses() throws {
        let transport = FixtureTransport()
        let client = try AppServerClient(
            codexExecutable: URL(fileURLWithPath: "/tmp/codex-fixture"),
            codexHome: URL(fileURLWithPath: "/tmp/codex-home", isDirectory: true),
            transport: transport
        )
        _ = try client.initialize()
        transport.alwaysReturnUnrelatedResponses = true

        let start = Date()
        XCTAssertThrowsError(try client.accountRead(timeout: 0.1)) { error in
            guard case let CodexSwitchError.appServer(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("タイムアウト"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testEOFWithoutAnyOutputIsClosedTransportError() throws {
        let transport = try makeNativeTransport(
            command: ":",
            maximumLineLength: 4_096
        )
        defer { try? transport.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        XCTAssertThrowsError(try transport.receiveLine(until: Date().addingTimeInterval(1))) { error in
            guard case let CodexSwitchError.process(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("閉じ"))
        }
    }

    func testHUPDrainsMoreThan64KiBBeforeReturningEOFPartialLine() throws {
        let transport = try makeNativeTransport(
            command: "head -c 100000 /dev/zero",
            maximumLineLength: 200_000
        )
        defer { try? transport.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        let line = try XCTUnwrap(transport.receiveLine(until: Date().addingTimeInterval(1)))
        XCTAssertEqual(line.count, 100_000)
        XCTAssertThrowsError(try transport.receiveLine(until: Date().addingTimeInterval(1)))
    }

    func testShortJSONLBurstIsValidatedPerLine() throws {
        let transport = try makeNativeTransport(
            command: "printf 'abc\\nxyz\\n'",
            maximumLineLength: 4
        )
        defer { try? transport.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        let first = try XCTUnwrap(transport.receiveLine(until: Date().addingTimeInterval(1)))
        let second = try XCTUnwrap(transport.receiveLine(until: Date().addingTimeInterval(1)))
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "abc")
        XCTAssertEqual(String(decoding: second, as: UTF8.self), "xyz")
    }

    func testSingleJSONLLineOverMaximumIsRejected() throws {
        let transport = try makeNativeTransport(
            command: "printf 'abcde\\n'",
            maximumLineLength: 4
        )
        defer { try? transport.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        XCTAssertThrowsError(try transport.receiveLine(until: Date().addingTimeInterval(1))) { error in
            guard case let CodexSwitchError.appServer(message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("長すぎ"))
        }
    }

    func testChattyStderrDoesNotStarveStdout() throws {
        let transport = try makeNativeTransport(
            command: "yes x >&2 & child=$!; sleep 0.05; printf 'ready\\n'; kill $child; wait $child 2>/dev/null",
            maximumLineLength: 4_096
        )
        defer { try? transport.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        let line = try XCTUnwrap(transport.receiveLine(until: Date().addingTimeInterval(1)))
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "ready")
    }

    func testStderrOnlyChildHonorsReceiveLineDeadline() throws {
        let transport = try makeNativeTransport(
            command: "yes x >&2 & child=$!; sleep 0.3; kill $child; wait $child 2>/dev/null",
            maximumLineLength: 4_096
        )
        defer { try? transport.stop(gracefulTimeout: 0, terminateTimeout: 0.5) }

        let start = Date()
        XCTAssertNil(try transport.receiveLine(until: start.addingTimeInterval(0.05)))
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
    }

    private final class FixtureTransport: AppServerTransport {
        var responses: [Data] = []
        var objects: [[String: JSONValue]] = []
        var stopCount = 0
        enum DeviceCodeResponse: Equatable {
            case valid
            case missingVerificationURL
            case authURLOnly
            case bothURLsMissing
        }

        enum AccountAuthField {
            case valid
            case missing
            case null
        }

        var deviceCodeResponse: DeviceCodeResponse = .valid
        var accountAuthField: AccountAuthField = .valid
        var alwaysReturnUnrelatedLoginNotifications = false
        var alwaysReturnUnrelatedResponses = false
        var cancelRequestBypassedCancellation = false
        var cancelRequestWriteTimeout: TimeInterval?

        var methods: [String] {
            objects.compactMap { $0["method"]?.stringValue }
        }

        func sendLine(
            _ data: Data,
            cancellation: CancellationToken?,
            writeTimeout: TimeInterval?
        ) throws {
            _ = cancellation
            let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
            objects.append(object)
            guard let method = object["method"]?.stringValue else { return }
            if method == "account/login/cancel" {
                cancelRequestBypassedCancellation = cancellation == nil
                cancelRequestWriteTimeout = writeTimeout
            }
            let id = object["id"] ?? .integer(1)
            switch method {
            case "initialize":
                enqueue(["id": id, "result": .object(["platformOs": .string("macOS")])])
            case "account/read":
                var accountResult: [String: JSONValue] = [
                    "account": .object([
                        "type": .string("chatgpt"),
                        "email": .string("person@example.com"),
                        "planType": .string("team"),
                    ]),
                ]
                switch accountAuthField {
                case .valid:
                    accountResult["requiresOpenaiAuth"] = .bool(true)
                case .missing:
                    break
                case .null:
                    accountResult["requiresOpenaiAuth"] = .null
                }
                enqueue(["id": id, "result": .object(accountResult)])
            case "account/login/start":
                var result: [String: JSONValue] = [
                    "type": .string("chatgptDeviceCode"),
                    "loginId": .string("fixture-login"),
                    "userCode": .string("ABCD-1234"),
                ]
                if deviceCodeResponse == .valid {
                    result["verificationUrl"] = .string("https://auth.openai.com/codex/device")
                } else if deviceCodeResponse == .authURLOnly {
                    result["authUrl"] = .string("https://auth.openai.com/codex/device")
                }
                enqueue(["id": id, "result": .object(result)])
                enqueue(["method": .string("account/login/completed"), "params": .object([
                    "loginId": .string("fixture-login"),
                    "success": .bool(true),
                    "error": .null,
                ])])
            case "account/login/cancel":
                enqueue(["id": id, "result": .object([:])])
            default:
                enqueue(["id": id, "result": .object([:])])
            }
        }

        func receiveLine(until deadline: Date) throws -> Data? {
            _ = deadline
            if alwaysReturnUnrelatedLoginNotifications {
                var data = try! JSONEncoder().encode(JSONValue.object([
                    "method": .string("account/login/completed"),
                    "params": .object([
                        "loginId": .string("other-login"),
                        "success": .bool(true),
                        "error": .null,
                    ]),
                ]))
                data.append(10)
                return data
            }
            if alwaysReturnUnrelatedResponses {
                var data = try! JSONEncoder().encode(JSONValue.object([
                    "id": .integer(999),
                    "result": .object([:]),
                ]))
                data.append(10)
                return data
            }
            guard !responses.isEmpty else { return nil }
            return responses.removeFirst()
        }

        func stop(gracefulTimeout: TimeInterval, terminateTimeout: TimeInterval) throws {
            _ = gracefulTimeout
            _ = terminateTimeout
            stopCount += 1
        }

        private func enqueue(_ object: [String: JSONValue]) {
            var data = try! JSONEncoder().encode(JSONValue.object(object))
            data.append(10)
            responses.append(data)
        }
    }

    private func makeNativeTransport(
        command: String,
        maximumLineLength: Int
    ) throws -> any AppServerTransport {
        try NativeAppServerTransportFactory().makeTransport(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", command],
            environment: [:],
            maximumLineLength: maximumLineLength,
            writeTimeout: 1,
            workingDirectory: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
    }

    private func expectedWorkingDirectory(for directory: URL) -> String {
        directory.path.hasPrefix("/var/") || directory.path.hasPrefix("/tmp/")
            ? "/private\(directory.path)"
            : directory.path
    }
}
