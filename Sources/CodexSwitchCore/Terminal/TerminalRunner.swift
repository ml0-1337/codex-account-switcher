import Foundation

public struct TerminalAccountView: Equatable, Sendable {
    public let profiles: [AccountProfile]
    /// The profile whose credentials were last selected for the managed auth
    /// file. This is not a claim about the account currently running in the
    /// official ChatGPT application.
    public let lastSelectedProfileID: UUID?

    public init(
        profiles: [AccountProfile],
        lastSelectedProfileID: UUID? = nil
    ) {
        self.profiles = profiles
        self.lastSelectedProfileID = lastSelectedProfileID
    }
}

public struct TerminalActionResult: Equatable, Sendable {
    public let messages: [String]

    public init(messages: [String] = []) {
        self.messages = messages
    }

    public init(message: String) {
        self.messages = [message]
    }

    public static let none = TerminalActionResult()
}

public struct TerminalActionContext {
    public let cancellation: CancellationToken
    /// Progress is intentionally not redacted: the parent action may need to
    /// display a raw login URL or one-time code while the operation runs.
    public let progress: (String) -> Void
    /// Diagnostics are emitted to stderr without SafeText redaction for the
    /// trusted core callback that reports a retained temporary-home path.
    public let diagnostic: (String) -> Void

    public init(
        cancellation: CancellationToken,
        progress: @escaping (String) -> Void,
        diagnostic: @escaping (String) -> Void
    ) {
        self.cancellation = cancellation
        self.progress = progress
        self.diagnostic = diagnostic
    }

    public func checkCancellation() throws {
        try cancellation.check()
    }
}

public typealias TerminalAction =
    (TerminalActionContext) throws -> TerminalActionResult
public typealias TerminalSwitchAction =
    (UUID, TerminalActionContext) throws -> TerminalActionResult
public typealias TerminalAccountViewProvider =
    () throws -> TerminalAccountView

public struct TerminalActions {
    public let setup: TerminalAction
    public let add: TerminalAction
    public let switchTo: TerminalSwitchAction
    public let recover: TerminalAction

    public init(
        setup: @escaping TerminalAction,
        add: @escaping TerminalAction,
        switchTo: @escaping TerminalSwitchAction,
        recover: @escaping TerminalAction
    ) {
        self.setup = setup
        self.add = add
        self.switchTo = switchTo
        self.recover = recover
    }
}

public enum TerminalCommand: Equatable, Sendable {
    case select
    case setup
    case add
    case list
    case recover
    case help
}

public enum TerminalArgumentError: Error, LocalizedError, Sendable {
    case unsupportedArguments

    public var errorDescription: String? {
        "引数が不正です。利用できるコマンドは setup、add、list、recover、help、-h、--help です。"
    }
}

public enum TerminalCommandParser {
    public static func parse(_ arguments: [String]) throws -> TerminalCommand {
        guard arguments.count <= 1 else {
            throw TerminalArgumentError.unsupportedArguments
        }
        guard let argument = arguments.first else { return .select }

        switch argument {
        case "setup":
            return .setup
        case "add":
            return .add
        case "list":
            return .list
        case "recover":
            return .recover
        case "help", "-h", "--help":
            return .help
        default:
            throw TerminalArgumentError.unsupportedArguments
        }
    }
}

/// Synchronous command-line adapter. Account persistence and switching remain
/// injected actions; this type only owns command parsing, prompts, output, and
/// cancellation-aware terminal control flow.
public final class TerminalRunner {
    public let io: TerminalIO
    public let cancellation: CancellationToken

    private let accountViewProvider: TerminalAccountViewProvider
    private let actions: TerminalActions

    public init(
        io: TerminalIO,
        accountView: @escaping TerminalAccountViewProvider,
        actions: TerminalActions,
        cancellation: CancellationToken = CancellationToken()
    ) {
        self.io = io
        self.accountViewProvider = accountView
        self.actions = actions
        self.cancellation = cancellation
    }

    @discardableResult
    public func run(arguments: [String]) -> Int32 {
        do {
            let command = try TerminalCommandParser.parse(arguments)
            switch command {
            case .select:
                return withSignalMonitoring { selectAndSwitch() }
            case .setup:
                return setup()
            case .add:
                return add()
            case .list:
                return list()
            case .recover:
                return recover()
            case .help:
                return help()
            }
        } catch {
            reportFailure(error)
            return 2
        }
    }

    @discardableResult
    public func help() -> Int32 {
        let text = """
        使い方: codex-switch [setup|add|list|recover|help]

        引数なし       登録済みアカウントを選択して認証ファイルを切り替えます。
        setup          初回セットアップを実行します。
        add            アカウントを追加します。
        list           登録済みアカウントと最後に切替指定したアカウントを表示します。
        recover        中断された処理を復旧します。
        help, -h, --help
                       このヘルプを表示します。
        """
        do {
            try write(text + "\n", to: .standardOutput)
            return 0
        } catch {
            return handle(error)
        }
    }

    @discardableResult
    public func list() -> Int32 {
        do {
            try cancellation.check()
            let view = try accountViewProvider()
            try cancellation.check()
            try renderList(view)
            return 0
        } catch {
            return handle(error)
        }
    }

    @discardableResult
    public func setup() -> Int32 {
        runConfirmedMutation(
            prompt: "セットアップを実行しますか？ [y/N]: ",
            action: actions.setup
        )
    }

    @discardableResult
    public func add() -> Int32 {
        runConfirmedMutation(
            prompt: "アカウント追加を実行しますか？ [y/N]: ",
            action: actions.add
        )
    }

    @discardableResult
    public func recover() -> Int32 {
        runConfirmedMutation(
            prompt: "中断された処理を復旧しますか？ [y/N]: ",
            action: actions.recover
        )
    }

    private func selectAndSwitch() -> Int32 {
        guard requireInteractive() else { return 1 }

        do {
            try cancellation.check()
            let view = try accountViewProvider()
            try cancellation.check()
            guard !view.profiles.isEmpty else {
                try? writeLine("登録済みアカウントがありません。", to: .standardError)
                return 1
            }
            try renderList(view)

            while true {
                try cancellation.check()
                try write(
                    "切り替えるアカウント番号を入力してください（キャンセル: q）。\n",
                    to: .standardOutput
                )
                let input = try readLineOrCancellation()
                switch input {
                case let .cancelled(exitCode):
                    reportCancellation(exitCode)
                    return exitCode
                case let .failed(error):
                    return handle(error)
                case .eof:
                    reportCancellation(130)
                    return 130
                case let .value(value):
                    if Self.isCancellationWord(value) {
                        reportCancellation(cancellation.exitCode ?? 130)
                        return cancellation.exitCode ?? 130
                    }
                    guard let profile = selectedProfile(from: value, in: view.profiles) else {
                        try? writeLine("選択が不正です。番号を入力するか、キャンセルしてください。", to: .standardError)
                        continue
                    }

                    switch try confirmation(
                        prompt: "\(profile.displayName) に切り替えますか？ [y/N]: "
                    ) {
                    case .yes:
                        return performSwitch(profile.id)
                    case let .cancelled(exitCode):
                        reportCancellation(exitCode)
                        return exitCode
                    }
                }
            }
        } catch {
            return handle(error)
        }
    }

    private func runConfirmedMutation(
        prompt: String,
        action: @escaping TerminalAction
    ) -> Int32 {
        guard requireInteractive() else { return 1 }
        return withSignalMonitoring {
            do {
                try cancellation.check()
                switch try confirmation(prompt: prompt) {
                case .yes:
                    return performAction(action)
                case let .cancelled(exitCode):
                    reportCancellation(exitCode)
                    return exitCode
                }
            } catch {
                return handle(error)
            }
        }
    }

    private func performAction(_ action: @escaping TerminalAction) -> Int32 {
        let outputState = ProgressOutputState()
        let context = TerminalActionContext(
            cancellation: cancellation,
            progress: { [weak self, weak outputState] text in
                guard let self, let outputState else { return }
                self.emitProgress(text, outputState: outputState)
            },
            diagnostic: { [weak self] text in
                self?.emitDiagnostic(text)
            }
        )

        do {
            try cancellation.check()
            let result = try action(context)
            try cancellation.check()
            guard outputState.error == nil else {
                if let error = outputState.error { reportFailure(error) }
                return 1
            }
            try writeMessages(result.messages)
            try cancellation.check()
            return 0
        } catch {
            return handleActionFailure(error, outputState: outputState)
        }
    }

    private func performSwitch(_ profileID: UUID) -> Int32 {
        performAction { context in
            _ = try self.actions.switchTo(profileID, context)
            // The shared action runner checks cancellation and output errors
            // before emitting this exact two-line success message.
            return TerminalActionResult(message:
                "認証ファイルを選択したアカウントに切り替えました。\n"
                + "ChatGPTアプリを手動で再起動してください。\n"
            )
        }
    }

    private func renderList(_ view: TerminalAccountView) throws {
        if view.profiles.isEmpty {
            try write(
                "登録済みアカウントはありません。\n最後に切替指定したアカウント: なし\n",
                to: .standardOutput
            )
            return
        }

        try write("登録済みアカウント:\n", to: .standardOutput)
        for (offset, profile) in view.profiles.enumerated() {
            let marker = profile.id == view.lastSelectedProfileID
                ? " (最後に切替指定したアカウント)"
                : ""
            try write(
                "\(offset + 1). \(profile.displayName)\(marker)\n",
                to: .standardOutput
            )
        }

        let selectedName = view.profiles.first {
            $0.id == view.lastSelectedProfileID
        }?.displayName ?? "なし"
        try write(
            "最後に切替指定したアカウント: \(selectedName)\n",
            to: .standardOutput
        )
    }

    private func selectedProfile(
        from input: String,
        in profiles: [AccountProfile]
    ) -> AccountProfile? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(normalized), number > 0, number <= profiles.count else {
            return nil
        }
        return profiles[number - 1]
    }

    private enum Confirmation {
        case yes
        case cancelled(Int32)
    }

    private func confirmation(prompt: String) throws -> Confirmation {
        try write(prompt, to: .standardOutput)

        switch try readLineOrCancellation() {
        case let .cancelled(exitCode):
            return .cancelled(exitCode)
        case let .failed(error):
            throw error
        case .eof:
            return .cancelled(130)
        case let .value(value):
            if Self.isCancellationWord(value) {
                return .cancelled(cancellation.exitCode ?? 130)
            }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["y", "yes", "はい"].contains(normalized) {
                return .yes
            }
            return .cancelled(130)
        }
    }

    private enum ReadResult {
        case value(String)
        case eof
        case cancelled(Int32)
        case failed(Error)
    }

    private func readLineOrCancellation() throws -> ReadResult {
        do {
            let value = try io.readLine(cancellation: cancellation)
            try cancellation.check()
            guard let value else { return .eof }
            return .value(value)
        } catch let interrupted as OperationInterrupted {
            return .cancelled(interrupted.exitCode)
        } catch {
            if let exitCode = cancellation.exitCode {
                return .cancelled(exitCode)
            }
            return .failed(error)
        }
    }

    private func requireInteractive() -> Bool {
        guard io.isInteractive else {
            try? writeLine("このコマンドは対話型端末でのみ実行できます。", to: .standardError)
            return false
        }
        return true
    }

    private func withSignalMonitoring(_ operation: () -> Int32) -> Int32 {
        let monitor = TerminalSignalMonitor(token: cancellation)
        monitor.start()
        defer { monitor.stop() }
        return operation()
    }

    private func handle(_ error: Error) -> Int32 {
        if let interrupted = error as? OperationInterrupted {
            reportCancellation(interrupted.exitCode)
            return interrupted.exitCode
        }
        if let switchError = error as? CodexSwitchError,
           case .cancelled = switchError {
            let exitCode = cancellation.exitCode ?? 130
            reportCancellation(exitCode)
            return exitCode
        }
        if let exitCode = cancellation.exitCode {
            // Cancellation does not erase a separate cleanup or operation
            // failure. Keep both diagnostics while preserving the signal's
            // exit status for the caller.
            reportFailure(error)
            reportCancellation(exitCode)
            return exitCode
        }
        reportFailure(error)
        return 1
    }

    private func handleActionFailure(
        _ error: Error,
        outputState: ProgressOutputState
    ) -> Int32 {
        guard let outputError = outputState.error else {
            return handle(error)
        }

        // A progress write failure cancels the shared operation so a parent
        // login action can unwind promptly. It is still an I/O failure, not a
        // user interrupt, so it takes precedence over the token's 130 code.
        reportFailure(outputError)
        if !Self.isCancellationError(error) {
            reportFailure(error)
        }
        return 1
    }

    private func reportFailure(_ error: Error) {
        let safeDescription = SafeText.bounded(error.localizedDescription)
        try? writeLine("エラー: \(safeDescription)", to: .standardError)
    }

    private func reportCancellation(_ exitCode: Int32) {
        try? writeLine("操作をキャンセルしました。", to: .standardError)
        _ = exitCode
    }

    private func emitProgress(
        _ text: String,
        outputState: ProgressOutputState
    ) {
        let outputText = text.hasSuffix("\n") ? text : text + "\n"
        do {
            try io.write(outputText, to: .standardOutput)
        } catch {
            if Self.isCancellationError(error) {
                return
            }
            if outputState.error == nil {
                outputState.error = error
            }
            // `CancellationToken.cancel` is lock-based but this callback runs
            // in the synchronous action, never in a POSIX signal handler.
            cancellation.cancel()
            return
        }
    }

    private func emitDiagnostic(_ text: String) {
        let outputText = text.hasSuffix("\n") ? text : text + "\n"
        try? write(outputText, to: .standardError)
    }

    private func writeMessages(_ messages: [String]) throws {
        for message in messages {
            try write(
                message.hasSuffix("\n") ? message : message + "\n",
                to: .standardOutput
            )
        }
    }

    private func write(
        _ text: String,
        to output: TerminalOutput
    ) throws {
        // Keep OperationInterrupted intact so every stdout caller can return
        // the originating SIGINT/SIGTERM exit code instead of treating it as
        // an ordinary output failure.
        try io.write(text, to: output)
    }

    private func writeLine(
        _ line: String,
        to output: TerminalOutput = .standardOutput
    ) throws {
        try write(line + "\n", to: output)
    }

    private static func isCancellationWord(_ value: String) -> Bool {
        ["q", "quit", "c", "cancel", "キャンセル", "終了"].contains {
            $0 == value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        if error is OperationInterrupted {
            return true
        }
        if let switchError = error as? CodexSwitchError,
           case .cancelled = switchError {
            return true
        }
        return false
    }

    private final class ProgressOutputState {
        var error: Error?
    }
}
