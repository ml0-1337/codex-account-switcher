import Darwin
import Foundation

public protocol AppServerTransport: AnyObject {
    func sendLine(
        _ data: Data,
        cancellation: CancellationToken?,
        writeTimeout: TimeInterval?
    ) throws
    func receiveLine(until deadline: Date) throws -> Data?
    func stop(gracefulTimeout: TimeInterval, terminateTimeout: TimeInterval) throws
}

public protocol AppServerTransportFactory {
    func makeTransport(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        maximumLineLength: Int,
        writeTimeout: TimeInterval,
        workingDirectory: URL
    ) throws -> any AppServerTransport
}

public struct NativeAppServerTransportFactory: AppServerTransportFactory, Sendable {
    public init() {}

    public func makeTransport(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        maximumLineLength: Int,
        writeTimeout: TimeInterval,
        workingDirectory: URL
    ) throws -> any AppServerTransport {
        try NativeAppServerTransport(
            executable: executable,
            arguments: arguments,
            environment: environment,
            maximumLineLength: maximumLineLength,
            writeTimeout: writeTimeout,
            workingDirectory: workingDirectory
        )
    }
}

public struct AppServerClientConfiguration: Sendable {
    public var arguments: [String]
    public var environment: [String: String]
    public var startupTimeout: TimeInterval
    public var requestTimeout: TimeInterval
    public var loginTimeout: TimeInterval
    public var notificationQueueLimit: Int
    public var maximumLineLength: Int
    public var writeTimeout: TimeInterval
    public var gracefulStopTimeout: TimeInterval
    public var terminateStopTimeout: TimeInterval

    public init(
        arguments: [String] = ["app-server", "--listen", "stdio://"],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        startupTimeout: TimeInterval = 15,
        requestTimeout: TimeInterval = 15,
        loginTimeout: TimeInterval = 15 * 60,
        notificationQueueLimit: Int = 256,
        maximumLineLength: Int = 4 * 1024 * 1024,
        writeTimeout: TimeInterval = 10,
        gracefulStopTimeout: TimeInterval = 5,
        terminateStopTimeout: TimeInterval = 5
    ) {
        self.arguments = arguments
        self.environment = environment
        self.startupTimeout = max(startupTimeout, 0)
        self.requestTimeout = max(requestTimeout, 0)
        self.loginTimeout = max(loginTimeout, 0)
        self.notificationQueueLimit = max(notificationQueueLimit, 1)
        self.maximumLineLength = max(maximumLineLength, 4_096)
        self.writeTimeout = max(writeTimeout, 0.1)
        self.gracefulStopTimeout = max(gracefulStopTimeout, 0)
        self.terminateStopTimeout = max(terminateStopTimeout, 0)
    }
}

public struct AppServerRPCError: Codable, Equatable, Sendable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public struct AppServerNotification: Equatable, Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}

public struct InitializeResponse: Decodable, Sendable, Equatable {
    public let userAgent: String?
    public let platformFamily: String?
    public let platformOS: String?

    enum CodingKeys: String, CodingKey {
        case userAgent
        case platformFamily
        case platformOS = "platformOs"
    }
}

public struct AccountReadResult: Decodable, Sendable, Equatable {
    public let account: AccountInfo?
    public let requiresOpenaiAuth: Bool

    public init(account: AccountInfo?, requiresOpenaiAuth: Bool) {
        self.account = account
        self.requiresOpenaiAuth = requiresOpenaiAuth
    }
}

/// Account metadata intentionally has no account ID. The durable account ID
/// comes only from the validated AuthBlob on disk.
public struct AccountInfo: Decodable, Sendable, Equatable {
    public let type: String
    public let email: String?
    public let planType: String?

    public init(type: String, email: String? = nil, planType: String? = nil) {
        self.type = type
        self.email = email
        self.planType = planType
    }
}

public struct DeviceCodeLoginResult: Decodable, Sendable, Equatable {
    public let type: String
    public let loginID: String
    public let verificationURL: String
    public let userCode: String

    enum CodingKeys: String, CodingKey {
        case type
        case loginID = "loginId"
        case verificationURL = "verificationUrl"
        case userCode
    }

    public init(type: String, loginID: String, verificationURL: String, userCode: String) {
        self.type = type
        self.loginID = loginID
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

public struct LoginCompletedNotification: Decodable, Sendable, Equatable {
    public let loginID: String?
    public let success: Bool
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case loginID = "loginId"
        case success
        case error
    }
}

public struct ConfigReadResult: Decodable, Sendable, Equatable {
    public let config: JSONValue
}

public final class AppServerClient: @unchecked Sendable {
    private let transport: any AppServerTransport
    private let configuration: AppServerClientConfiguration
    private let cancellation: CancellationToken?
    private var nextRequestID: Int64 = 1
    private var initializedResponse: InitializeResponse?
    private var closed = false
    private var notificationQueue: [AppServerNotification] = []
    private var deferredResponses: [WireMessage] = []

    public init(
        codexExecutable: URL,
        codexHome: URL,
        configuration: AppServerClientConfiguration = AppServerClientConfiguration(),
        processFactory: any AppServerTransportFactory = NativeAppServerTransportFactory(),
        transport: (any AppServerTransport)? = nil,
        cancellation: CancellationToken? = nil
    ) throws {
        guard codexExecutable.isFileURL, codexExecutable.path.hasPrefix("/") else {
            throw CodexSwitchError.invalidInput("Codex実行ファイルには絶対パスを指定してください。")
        }
        guard codexHome.isFileURL, codexHome.path.hasPrefix("/") else {
            throw CodexSwitchError.invalidInput("CODEX_HOMEには絶対パスを指定してください。")
        }

        self.configuration = configuration
        self.cancellation = cancellation
        if let transport {
            self.transport = transport
        } else {
            var environment = configuration.environment
            environment["CODEX_HOME"] = codexHome.standardizedFileURL.path
            self.transport = try processFactory.makeTransport(
                executable: codexExecutable.standardizedFileURL,
                arguments: configuration.arguments,
                environment: environment,
                maximumLineLength: configuration.maximumLineLength,
                writeTimeout: configuration.writeTimeout,
                workingDirectory: codexHome.standardizedFileURL
            )
        }
    }

    deinit {
        if !closed {
            try? transport.stop(
                gracefulTimeout: configuration.gracefulStopTimeout,
                terminateTimeout: configuration.terminateStopTimeout
            )
        }
    }

    @discardableResult
    public func initialize() throws -> InitializeResponse {
        try ensureOpen()
        if let initializedResponse { return initializedResponse }
        let requestID = allocateRequestID()
        let params: JSONValue = .object([
            "clientInfo": .object([
                "name": .string("codex_account_switcher"),
                "title": .string("Codex Account Switcher"),
                "version": .string("0.1.0"),
            ])
        ])
        try send(method: "initialize", id: requestID, params: params)
        let result = try waitForResponse(id: requestID, timeout: configuration.startupTimeout)
        let response = try decode(InitializeResponse.self, from: result, context: "initialize")
        // The official server requires this notification only after its
        // initialize response has been consumed.
        try send(method: "initialized", id: nil, params: .object([:]))
        initializedResponse = response
        return response
    }

    public func accountRead(
        refreshToken: Bool = false,
        timeout: TimeInterval? = nil
    ) throws -> AccountReadResult {
        let result = try request(
            method: "account/read",
            params: .object(["refreshToken": .bool(refreshToken)]),
            timeout: timeout ?? configuration.requestTimeout
        )
        return try decode(AccountReadResult.self, from: result, context: "account/read")
    }

    public func accountLoginStartDeviceCode(
        timeout: TimeInterval? = nil
    ) throws -> DeviceCodeLoginResult {
        let result = try request(
            method: "account/login/start",
            params: .object(["type": .string("chatgptDeviceCode")]),
            timeout: timeout ?? configuration.requestTimeout
        )
        let login = try decode(DeviceCodeLoginResult.self, from: result, context: "account/login/start")
        guard login.type == "chatgptDeviceCode",
              !login.loginID.isEmpty,
              login.loginID.count <= 512,
              !login.verificationURL.isEmpty,
              !login.userCode.isEmpty
        else {
            throw CodexSwitchError.appServer("Device Codeログインの応答が不正です。")
        }
        return login
    }

    public func waitForLoginCompleted(
        loginID: String,
        timeout: TimeInterval? = nil
    ) throws -> LoginCompletedNotification {
        let notification = try waitForNotification(
            method: "account/login/completed",
            timeout: timeout ?? configuration.loginTimeout
        ) { params in
            guard let params,
                  let candidate = try? self.decode(
                    LoginCompletedNotification.self,
                    from: params,
                    context: "account/login/completed"
                  )
            else { return false }
            return candidate.loginID == loginID
        }
        let completed = try decode(
            LoginCompletedNotification.self,
            from: notification.params ?? .object([:]),
            context: "account/login/completed"
        )
        guard completed.loginID == loginID else {
            throw CodexSwitchError.appServer("ログイン完了通知の識別子が一致しません。")
        }
        return completed
    }

    /// Cancellation cleanup must remain possible after the shared token is
    /// set, so this one request intentionally bypasses the token check.
    public func accountLoginCancel(
        loginID: String,
        timeout: TimeInterval? = nil
    ) throws {
        guard !loginID.isEmpty, loginID.count <= 512 else {
            throw CodexSwitchError.invalidInput("ログイン識別子が不正です。")
        }
        _ = try request(
            method: "account/login/cancel",
            params: .object(["loginId": .string(loginID)]),
            timeout: timeout ?? configuration.requestTimeout,
            checkCancellation: false
        )
    }

    public func configRead(
        includeLayers: Bool = false,
        timeout: TimeInterval? = nil
    ) throws -> ConfigReadResult {
        let result = try request(
            method: "config/read",
            params: .object(["includeLayers": .bool(includeLayers)]),
            timeout: timeout ?? configuration.requestTimeout
        )
        return try decode(ConfigReadResult.self, from: result, context: "config/read")
    }

    public func waitForNotification(
        method: String,
        timeout: TimeInterval? = nil,
        matching: ((JSONValue?) -> Bool)? = nil
    ) throws -> AppServerNotification {
        try ensureOpen()
        guard !method.isEmpty else {
            throw CodexSwitchError.invalidInput("通知メソッド名が空です。")
        }
        let deadline = Date().addingTimeInterval(max(timeout ?? configuration.requestTimeout, 0))
        while true {
            try checkCancellation()
            guard Date() < deadline else { throw timeoutError(for: method) }
            if let index = notificationQueue.firstIndex(where: {
                $0.method == method && (matching?($0.params) ?? true)
            }) {
                return notificationQueue.remove(at: index)
            }

            let receiveDeadline = min(deadline, Date().addingTimeInterval(0.1))
            guard let message = try receiveMessage(until: receiveDeadline) else {
                if Date() >= deadline { throw timeoutError(for: method) }
                continue
            }
            if Date() >= deadline { throw timeoutError(for: method) }
            if let notification = try route(message),
               notification.method == method,
               (matching?(notification.params) ?? true)
            {
                if let index = notificationQueue.lastIndex(of: notification) {
                    notificationQueue.remove(at: index)
                }
                return notification
            }
        }
    }

    public func drainNotifications() -> [AppServerNotification] {
        defer { notificationQueue.removeAll(keepingCapacity: true) }
        return notificationQueue
    }

    public func close() throws {
        guard !closed else { return }
        // Deliberately do not call checkCancellation here: cleanup must run on
        // Ctrl-C/SIGTERM even when request handling has been interrupted.
        try transport.stop(
            gracefulTimeout: configuration.gracefulStopTimeout,
            terminateTimeout: configuration.terminateStopTimeout
        )
        closed = true
    }

    private func request(
        method: String,
        params: JSONValue?,
        timeout: TimeInterval,
        checkCancellation shouldCheckCancellation: Bool = true
    ) throws -> JSONValue {
        try ensureInitialized()
        if shouldCheckCancellation { try checkCancellation() }
        let requestID = allocateRequestID()
        try send(
            method: method,
            id: requestID,
            params: params,
            checkCancellation: shouldCheckCancellation,
            writeTimeout: shouldCheckCancellation ? nil : timeout
        )
        return try waitForResponse(
            id: requestID,
            timeout: timeout,
            checkCancellation: shouldCheckCancellation
        )
    }

    private func send(
        method: String,
        id: Int64?,
        params: JSONValue?,
        checkCancellation shouldCheckCancellation: Bool = true,
        writeTimeout: TimeInterval? = nil
    ) throws {
        if shouldCheckCancellation { try checkCancellation() }
        var object: [String: JSONValue] = ["method": .string(method)]
        if let id { object["id"] = .integer(id) }
        if let params { object["params"] = params }
        do {
            var data = try JSONEncoder().encode(JSONValue.object(object))
            data.append(10)
            try transport.sendLine(
                data,
                cancellation: shouldCheckCancellation ? cancellation : nil,
                writeTimeout: writeTimeout
            )
        } catch let error as CodexSwitchError {
            throw error
        } catch let error as OperationInterrupted {
            throw error
        } catch {
            throw CodexSwitchError.appServer("app-server要求をJSONへ変換または送信できません。")
        }
    }

    private func sendErrorResponse(id: JSONValue, code: Int, message: String) throws {
        var data = try JSONEncoder().encode(JSONValue.object([
            "id": id,
            "error": .object([
                "code": .integer(Int64(code)),
                "message": .string(message),
            ]),
        ]))
        data.append(10)
        try transport.sendLine(data, cancellation: cancellation, writeTimeout: nil)
    }

    private func waitForResponse(
        id: Int64,
        timeout: TimeInterval,
        checkCancellation shouldCheckCancellation: Bool = true
    ) throws -> JSONValue {
        let expectedID = JSONValue.integer(id)
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while true {
            if shouldCheckCancellation { try checkCancellation() }
            guard Date() < deadline else { throw timeoutError(for: "request") }
            if let index = deferredResponses.firstIndex(where: { $0.id == expectedID }) {
                return try responseValue(from: deferredResponses.remove(at: index), method: "request")
            }
            let receiveDeadline = min(deadline, Date().addingTimeInterval(0.1))
            guard let message = try receiveMessage(until: receiveDeadline) else {
                if Date() >= deadline { throw timeoutError(for: "request") }
                continue
            }
            if Date() >= deadline { throw timeoutError(for: "request") }
            if let messageID = message.id, messageID == expectedID, message.method == nil {
                return try responseValue(from: message, method: "request")
            }
            _ = try route(message)
        }
    }

    private func responseValue(from message: WireMessage, method: String) throws -> JSONValue {
        if let error = message.error {
            throw CodexSwitchError.appServer(
                "app-serverの\(method)要求が失敗しました（code \(error.code)）。"
            )
        }
        guard let result = message.result else {
            throw CodexSwitchError.appServer("app-serverの\(method)応答にresultがありません。")
        }
        return result
    }

    private func receiveMessage(until deadline: Date) throws -> WireMessage? {
        guard let line = try transport.receiveLine(until: deadline) else { return nil }
        guard !line.isEmpty else {
            throw CodexSwitchError.appServer("app-serverから空のJSONL行を受信しました。")
        }
        do {
            return try JSONDecoder().decode(WireMessage.self, from: line)
        } catch {
            throw CodexSwitchError.appServer("app-serverから不正なJSONLを受信しました。")
        }
    }

    @discardableResult
    private func route(_ message: WireMessage) throws -> AppServerNotification? {
        if let method = message.method {
            if let id = message.id {
                try sendErrorResponse(id: id, code: -32000, message: "Unsupported server request")
                return nil
            }
            let notification = AppServerNotification(method: method, params: message.params)
            notificationQueue.append(notification)
            if notificationQueue.count > configuration.notificationQueueLimit {
                notificationQueue.removeFirst(notificationQueue.count - configuration.notificationQueueLimit)
            }
            return notification
        }
        if message.id != nil {
            deferredResponses.append(message)
            if deferredResponses.count > configuration.notificationQueueLimit {
                deferredResponses.removeFirst(deferredResponses.count - configuration.notificationQueueLimit)
            }
            return nil
        }
        throw CodexSwitchError.appServer("app-serverメッセージにmethodまたはidがありません。")
    }

    private func decode<T: Decodable>(_ type: T.Type, from value: JSONValue, context: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
        } catch {
            throw CodexSwitchError.appServer("app-serverの\(context)応答形式が不正です。")
        }
    }

    private func allocateRequestID() -> Int64 {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func ensureOpen() throws {
        guard !closed else { throw CodexSwitchError.process("app-server接続はすでに終了しています。") }
    }

    private func ensureInitialized() throws {
        try ensureOpen()
        guard initializedResponse != nil else {
            throw CodexSwitchError.appServer("app-serverの初期化が完了していません。")
        }
    }

    private func checkCancellation() throws {
        try cancellation?.check()
    }

    private func timeoutError(for operation: String) -> CodexSwitchError {
        .appServer("app-serverの\(operation)応答がタイムアウトしました。")
    }

    private struct WireMessage: Decodable {
        let id: JSONValue?
        let method: String?
        let params: JSONValue?
        let result: JSONValue?
        let error: AppServerRPCError?
    }
}

public struct ValidatedDeviceCodeLogin: Sendable, Equatable {
    public let verificationURL: URL
    public let userCode: String

    public init(verificationURL rawURL: String, userCode rawCode: String) throws {
        guard rawURL.count <= 2_048,
              rawURL.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              let host = components.host?.lowercased(),
              Self.isTrustedHost(host),
              let url = components.url
        else {
            throw CodexSwitchError.appServer("Device CodeログインのURLを安全に確認できません。")
        }
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty,
              code.count <= 128,
              code.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else {
            throw CodexSwitchError.appServer("Device Codeログインのコードが不正です。")
        }
        verificationURL = url
        userCode = code
    }

    private static func isTrustedHost(_ host: String) -> Bool {
        host == "openai.com"
            || host.hasSuffix(".openai.com")
            || host == "chatgpt.com"
            || host.hasSuffix(".chatgpt.com")
    }
}

private final class NativeAppServerTransport: AppServerTransport, @unchecked Sendable {
    private let process: NativeProcess
    private let maximumLineLength: Int
    private let writeTimeout: TimeInterval
    private static let maximumDrainReads = 8
    private static let writePollingSlice: TimeInterval = 0.05
    private var outputBuffer = Data()
    private var outputClosed = false
    private var errorClosed = false
    private var inputClosed = false
    private var stopped = false

    init(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        maximumLineLength: Int,
        writeTimeout: TimeInterval,
        workingDirectory: URL
    ) throws {
        self.process = try NativeProcess(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
        self.maximumLineLength = maximumLineLength
        self.writeTimeout = writeTimeout
        setNonBlocking(process.standardOutput)
        setNonBlocking(process.standardError)
        setNonBlocking(process.standardInput)
        _ = fcntl(process.standardInput, F_SETNOSIGPIPE, 1)
    }

    deinit {
        if !stopped {
            try? stop(gracefulTimeout: 0, terminateTimeout: 0.25)
        }
    }

    func sendLine(
        _ data: Data,
        cancellation: CancellationToken?,
        writeTimeout requestedWriteTimeout: TimeInterval?
    ) throws {
        guard !inputClosed, !stopped else {
            throw CodexSwitchError.process("app-serverの入力が閉じています。")
        }
        let timeout = min(
            writeTimeout,
            max(requestedWriteTimeout ?? writeTimeout, 0)
        )
        let deadline = Date().addingTimeInterval(timeout)
        do {
            try cancellation?.check()
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    try cancellation?.check()
                    let count = Darwin.write(
                        process.standardInput,
                        baseAddress.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count > 0 {
                        offset += count
                    } else if count < 0, errno == EINTR {
                        continue
                    } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        try waitWritable(until: deadline, cancellation: cancellation)
                    } else {
                        throw CodexSwitchError.process("app-serverへ要求を書き込めません。")
                    }
                }
            }
        } catch let error as CodexSwitchError {
            throw error
        } catch let error as OperationInterrupted {
            throw error
        } catch {
            throw CodexSwitchError.process("app-serverへ要求を書き込めません。")
        }
    }

    func receiveLine(until deadline: Date) throws -> Data? {
        while true {
            if let line = takeLine() { return line }
            if outputClosed {
                guard !outputBuffer.isEmpty else {
                    throw CodexSwitchError.process("app-serverの出力が閉じています。")
                }
                let partial = outputBuffer
                outputBuffer.removeAll(keepingCapacity: false)
                return partial
            }

            var descriptors = [
                pollfd(fd: process.standardOutput, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0),
                pollfd(
                    fd: errorClosed ? -1 : process.standardError,
                    events: errorClosed ? 0 : Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                ),
            ]
            let timeout = millisecondsUntil(deadline)
            guard timeout > 0 else { return nil }
            let result = descriptors.withUnsafeMutableBufferPointer { buffer in
                Darwin.poll(buffer.baseAddress, nfds_t(buffer.count), timeout)
            }
            if result < 0 {
                if errno == EINTR { continue }
                throw CodexSwitchError.process("app-serverの入出力を監視できません。")
            }
            if result == 0 { return nil }

            if descriptors[1].revents != 0 {
                try drainStderr()
            }
            if descriptors[0].revents != 0 {
                try readStdout()
            }
        }
    }

    func stop(gracefulTimeout: TimeInterval, terminateTimeout: TimeInterval) throws {
        guard !stopped else { return }
        closeInput()
        try process.stop(gracefulTimeout: gracefulTimeout, terminateTimeout: terminateTimeout)
        stopped = true
    }

    private func readStdout() throws {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        for _ in 0..<Self.maximumDrainReads {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(process.standardOutput, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                outputBuffer.append(contentsOf: buffer.prefix(count))
                try validateOutputBuffer()
                continue
            }
            if count == 0 {
                outputClosed = true
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw CodexSwitchError.process("app-serverの出力を読み取れません。")
        }
    }

    private func validateOutputBuffer() throws {
        guard outputBuffer.count <= maximumBufferedOutputBytes else {
            throw CodexSwitchError.appServer("app-serverのJSONL受信バッファが大きすぎます。")
        }

        var lineStart = outputBuffer.startIndex
        while lineStart < outputBuffer.endIndex,
              let newline = outputBuffer[lineStart...].firstIndex(of: 10)
        {
            guard outputBuffer.distance(from: lineStart, to: newline) <= maximumLineLength else {
                throw CodexSwitchError.appServer("app-serverのJSONL行が長すぎます。")
            }
            lineStart = outputBuffer.index(after: newline)
        }

        guard outputBuffer.distance(from: lineStart, to: outputBuffer.endIndex) <= maximumLineLength else {
            throw CodexSwitchError.appServer("app-serverのJSONL行が長すぎます。")
        }
    }

    private func drainStderr() throws {
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        for _ in 0..<Self.maximumDrainReads {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(process.standardError, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 { continue }
            if count == 0 {
                errorClosed = true
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw CodexSwitchError.process("app-serverのエラー出力を読み取れません。")
        }
    }

    private func takeLine() -> Data? {
        guard let newline = outputBuffer.firstIndex(of: 10) else { return nil }
        var line = Data(outputBuffer[..<newline])
        outputBuffer.removeSubrange(...newline)
        if line.last == 13 { line.removeLast() }
        return line
    }

    private func closeInput() {
        guard !inputClosed else { return }
        inputClosed = true
        process.closeInput()
    }

    private func waitWritable(
        until deadline: Date,
        cancellation: CancellationToken?
    ) throws {
        var descriptor = pollfd(
            fd: process.standardInput,
            events: Int16(POLLOUT | POLLHUP | POLLERR),
            revents: 0
        )
        while true {
            try cancellation?.check()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else {
                throw CodexSwitchError.process("app-serverへの書き込みがタイムアウトしました。")
            }
            let slice = min(remaining, Self.writePollingSlice)
            let timeout = max(Int32((slice * 1_000).rounded(.up)), 1)
            descriptor.revents = 0
            let result = Darwin.poll(&descriptor, 1, timeout)
            if result < 0, errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0, descriptor.revents & Int16(POLLOUT) != 0 else {
                throw CodexSwitchError.process("app-serverの入力が閉じています。")
            }
            return
        }
    }

    private func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        if flags >= 0 { _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) }
    }

    private static let minimumBufferedOutputBytes = 8 * 1024 * 1024
    private var maximumBufferedOutputBytes: Int {
        max(maximumLineLength, Self.minimumBufferedOutputBytes)
    }

    private func millisecondsUntil(_ deadline: Date) -> Int32 {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return 0 }
        return max(Int32(min(remaining * 1_000, Double(Int32.max)).rounded(.up)), 1)
    }
}
