import Darwin
import XCTest
@testable import CodexSwitchCore

final class TerminalRunnerTests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    private func profile(id: UUID, name: String) throws -> AccountProfile {
        try AccountProfile(id: id, displayName: name)
    }

    private func view() throws -> TerminalAccountView {
        TerminalAccountView(
            profiles: [
                try profile(id: firstID, name: "alice@example.com"),
                try profile(id: secondID, name: "bob@example.com"),
            ],
            lastSelectedProfileID: secondID
        )
    }

    private func makeRunner(
        input: [String?] = [],
        interactive: Bool = true,
        token: CancellationToken = CancellationToken(),
        failWhen: String? = nil,
        cancelOnWriteContaining: String? = nil,
        cancelOnWriteSignal: Int32 = SIGINT,
        interruptOnWriteContaining: String? = nil,
        interruptOnWriteSignal: Int32 = SIGINT,
        accountView: @escaping () throws -> TerminalAccountView = {
            TerminalAccountView(profiles: [])
        },
        setup: TerminalAction? = nil,
        add: TerminalAction? = nil,
        switchTo: TerminalSwitchAction? = nil,
        recover: TerminalAction? = nil,
        reloadOutcome: AppServerReloadOutcome = .notRunning
    ) -> (TerminalRunner, RecordingTerminalIO) {
        let io = RecordingTerminalIO(
            input: input,
            interactive: interactive,
            failWhen: failWhen,
            cancelOnWriteContaining: cancelOnWriteContaining,
            cancelOnWriteSignal: cancelOnWriteSignal,
            interruptOnWriteContaining: interruptOnWriteContaining,
            interruptOnWriteSignal: interruptOnWriteSignal,
            cancellation: token
        )
        let noOp: TerminalAction = { _ in .none }
        let actions = TerminalActions(
            setup: setup ?? noOp,
            add: add ?? noOp,
            switchTo: switchTo ?? { _, _ in .none },
            recover: recover ?? noOp
        )
        let runner = TerminalRunner(
            io: io,
            accountView: accountView,
            actions: actions,
            cancellation: token,
            reloadAppServer: { _ in reloadOutcome }
        )
        return (runner, io)
    }

    func testNoArgumentsSelectsConfirmsAndPrintsExactSwitchSuccessLines() throws {
        let accountView = try view()
        var switchedID: UUID?
        let (runner, io) = makeRunner(
            input: ["1", "y"],
            accountView: { accountView },
            switchTo: { profileID, _ in
                switchedID = profileID
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: []), 0)
        XCTAssertEqual(switchedID, firstID)
        XCTAssertTrue(io.standardOutput.hasSuffix(Self.switchSuccessText))
    }

    func testListIsAllowedWhenInputIsPipedAndShowsLastSwitchSpecifiedAccount() throws {
        let accountView = try view()
        var providerCalls = 0
        let (runner, io) = makeRunner(
            interactive: false,
            accountView: {
                providerCalls += 1
                return accountView
            }
        )

        XCTAssertEqual(runner.list(), 0)
        XCTAssertEqual(providerCalls, 1)
        XCTAssertTrue(io.standardOutput.contains("alice@example.com"))
        XCTAssertTrue(io.standardOutput.contains("bob@example.com"))
        XCTAssertTrue(io.standardOutput.contains("最後に切替指定したアカウント"))
        XCTAssertFalse(io.standardOutput.contains("現在のアカウント"))
    }

    func testListOutputCancellationReturnsSignalExitCode() throws {
        let accountView = try view()
        for signal in [SIGINT, SIGTERM] {
            let (runner, _) = makeRunner(
                interruptOnWriteContaining: "登録済みアカウント:",
                interruptOnWriteSignal: signal,
                accountView: { accountView }
            )

            XCTAssertEqual(runner.run(arguments: ["list"]), 128 + signal)
        }
    }

    func testHelpIsAllowedWhenInputIsPipedAndDoesNotLoadAccountView() {
        var providerCalls = 0
        let (runner, io) = makeRunner(
            interactive: false,
            accountView: {
                providerCalls += 1
                return TerminalAccountView(profiles: [])
            }
        )

        XCTAssertEqual(runner.run(arguments: ["--help"]), 0)
        XCTAssertEqual(providerCalls, 0)
        XCTAssertTrue(io.standardOutput.contains("setup"))
        XCTAssertTrue(io.standardOutput.contains("recover"))
    }

    func testHelpOutputCancellationReturnsSignalExitCode() {
        for signal in [SIGINT, SIGTERM] {
            let (runner, _) = makeRunner(
                interactive: false,
                interruptOnWriteContaining: "使い方:",
                interruptOnWriteSignal: signal
            )

            XCTAssertEqual(runner.run(arguments: ["help"]), 128 + signal)
        }
    }

    func testUnknownExtraAndRemovedArgumentsAreRejectedWithoutLoadingOrActing() {
        for arguments in [["unknown"], ["list", "extra"], ["--no-restart"], ["switch"], ["doctor"]] {
            var providerCalls = 0
            var actionCalls = 0
            let (runner, _) = makeRunner(
                accountView: {
                    providerCalls += 1
                    return TerminalAccountView(profiles: [])
                },
                setup: { _ in
                    actionCalls += 1
                    return .none
                }
            )

            XCTAssertEqual(runner.run(arguments: arguments), 2, arguments.joined(separator: " "))
            XCTAssertEqual(providerCalls, 0, arguments.joined(separator: " "))
            XCTAssertEqual(actionCalls, 0, arguments.joined(separator: " "))
        }
    }

    func testMutatingCommandsRefusePipedInput() {
        for command in [["setup"], ["add"], ["recover"]] {
            var actionCalls = 0
            let (runner, _) = makeRunner(
                interactive: false,
                setup: { _ in
                    actionCalls += 1
                    return .none
                },
                add: { _ in
                    actionCalls += 1
                    return .none
                },
                recover: { _ in
                    actionCalls += 1
                    return .none
                }
            )
            XCTAssertEqual(runner.run(arguments: command), 1)
            XCTAssertEqual(actionCalls, 0)
        }
    }

    func testDefaultSelectionRefusesPipedInputBeforeLoadingAccounts() {
        var providerCalls = 0
        let (runner, io) = makeRunner(
            interactive: false,
            accountView: {
                providerCalls += 1
                return TerminalAccountView(profiles: [])
            }
        )

        XCTAssertEqual(runner.run(arguments: []), 1)
        XCTAssertEqual(providerCalls, 0)
        XCTAssertTrue(io.standardError.contains("対話型端末"))
    }

    func testConfirmationDefaultsToNoWithoutCallingMutation() {
        var actionCalls = 0
        let (runner, io) = makeRunner(
            input: [""],
            add: { _ in
                actionCalls += 1
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: ["add"]), 130)
        XCTAssertEqual(actionCalls, 0)
        XCTAssertTrue(io.standardError.contains("キャンセル"))
    }

    func testInvalidSelectionRepromptsAndProvidesClearCancel() throws {
        let accountView = try view()
        var actionCalls = 0
        let (runner, io) = makeRunner(
            input: ["9", "1", "y"],
            accountView: { accountView },
            switchTo: { _, _ in
                actionCalls += 1
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: []), 0)
        XCTAssertEqual(actionCalls, 1)
        XCTAssertTrue(io.standardOutput.contains("キャンセル"))
        XCTAssertTrue(io.standardError.contains("選択が不正"))
    }

    func testSelectionPromptOutputCancellationReturnsSignalExitCode() throws {
        let accountView = try view()
        for signal in [SIGINT, SIGTERM] {
            let (runner, _) = makeRunner(
                input: ["1", "y"],
                interruptOnWriteContaining: "切り替えるアカウント番号",
                interruptOnWriteSignal: signal,
                accountView: { accountView }
            )

            XCTAssertEqual(runner.run(arguments: []), 128 + signal)
        }
    }

    func testSelectionCancelAndEOFReturnInterruptExitCode() throws {
        let accountView = try view()
        for input in [["q"], [nil]] {
            var actionCalls = 0
            let (runner, _) = makeRunner(
                input: input,
                accountView: { accountView },
                switchTo: { _, _ in
                    actionCalls += 1
                    return .none
                }
            )
            XCTAssertEqual(runner.run(arguments: []), 130)
            XCTAssertEqual(actionCalls, 0)
        }
    }

    func testPreCancelledSIGTERMReturns143WithoutRunningAction() throws {
        let token = CancellationToken()
        token.cancel(signal: SIGTERM)
        var actionCalls = 0
        let (runner, _) = makeRunner(
            token: token,
            accountView: { try self.view() },
            switchTo: { _, _ in
                actionCalls += 1
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: []), 143)
        XCTAssertEqual(actionCalls, 0)
    }

    func testActionFailureReturnsOneAndLogsBoundedError() {
        let failure = CodexSwitchError.process("failed with opaque-\(String(repeating: "a", count: 48))")
        let (runner, io) = makeRunner(
            input: ["y"],
            add: { _ in throw failure }
        )

        XCTAssertEqual(runner.run(arguments: ["add"]), 1)
        XCTAssertTrue(io.standardError.contains("エラー"))
        XCTAssertFalse(io.standardError.contains(String(repeating: "a", count: 48)))
    }

    func testActionProgressKeepsIntendedLoginURLAndCodeVisible() {
        let loginURL = "https://login.example.test/authorize?email=alice@example.com"
        let userCode = "ABCD-EFGH"
        let (runner, io) = makeRunner(
            input: ["y"],
            add: { context in
                context.progress(loginURL)
                context.progress("ログインコード: \(userCode)")
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: ["add"]), 0)
        XCTAssertTrue(io.standardOutput.contains(loginURL))
        XCTAssertTrue(io.standardOutput.contains(userCode))
    }

    func testActionResultOutputCancellationReturnsSignalExitCode() {
        for signal in [SIGINT, SIGTERM] {
            let (runner, _) = makeRunner(
                input: ["y"],
                interruptOnWriteContaining: "完了メッセージ",
                interruptOnWriteSignal: signal,
                add: { _ in TerminalActionResult(message: "完了メッセージ") }
            )

            XCTAssertEqual(runner.run(arguments: ["add"]), 128 + signal)
        }
    }

    func testSwitchSuccessIsPrintedOnlyAfterCompletedAction() throws {
        var completed = false
        let accountView = try view()
        let (runner, io) = makeRunner(
            input: ["1", "y"],
            accountView: { accountView },
            switchTo: { _, _ in
                XCTAssertFalse(completed)
                completed = true
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: []), 0)
        XCTAssertTrue(completed)
        XCTAssertTrue(io.standardOutput.contains("認証ファイルを選択したアカウントに切り替えました。"))
    }

    func testSwitchCancelledAfterActionDoesNotPrintSuccess() throws {
        let token = CancellationToken()
        let accountView = try view()
        let (runner, io) = makeRunner(
            input: ["1", "y"],
            token: token,
            accountView: { accountView },
            switchTo: { _, _ in
                token.cancel()
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: []), 130)
        XCTAssertFalse(io.standardOutput.contains("認証ファイルを選択したアカウントに切り替えました。"))
    }

    func testSelectionConfirmationDeclineReturns130WithoutCallingSwitch() throws {
        let accountView = try view()
        var actionCalls = 0
        let (runner, io) = makeRunner(
            input: ["1", "n"],
            accountView: { accountView },
            switchTo: { _, _ in
                actionCalls += 1
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: []), 130)
        XCTAssertEqual(actionCalls, 0)
        XCTAssertTrue(io.standardError.contains("キャンセル"))
        XCTAssertFalse(io.standardOutput.contains("認証ファイルを選択したアカウントに切り替えました。"))
    }

    func testCancellationWithCleanupFailureKeepsFailureDiagnosticVisible() {
        let token = CancellationToken()
        let temporaryHome = "/private/tmp/codex-login-fixture"
        let (runner, io) = makeRunner(
            input: ["y"],
            token: token,
            add: { context in
                token.cancel()
                context.diagnostic(
                    "ログイン用一時ホームを保持しています: \(temporaryHome)"
                )
                throw CodexSwitchError.process(
                    "ログイン用一時ホームの後片付けに失敗しました: \(temporaryHome)"
                )
            }
        )

        XCTAssertEqual(runner.run(arguments: ["add"]), 130)
        XCTAssertTrue(io.standardError.contains("後片付けに失敗しました"))
        XCTAssertTrue(io.standardError.contains(temporaryHome))
        XCTAssertTrue(io.standardError.contains("キャンセル"))
        XCTAssertFalse(io.standardOutput.contains(temporaryHome))
    }

    func testCancellationFailureDiagnosticPreservesSIGINTAndSIGTERMExitCodes() {
        let temporaryHome = "/private/tmp/codex-login-signal-fixture"
        for signal in [SIGINT, SIGTERM] {
            let token = CancellationToken()
            let (runner, io) = makeRunner(
                input: ["y"],
                token: token,
                add: { context in
                    token.cancel(signal: signal)
                    context.diagnostic(
                        "終了確認に失敗したため一時ホームを保持しています: \(temporaryHome)"
                    )
                    throw CodexSwitchError.process("終了確認に失敗しました。")
                }
            )

            XCTAssertEqual(runner.run(arguments: ["add"]), 128 + signal)
            XCTAssertTrue(io.standardError.contains(temporaryHome))
            XCTAssertTrue(io.standardError.contains("終了確認に失敗したため"))
            XCTAssertTrue(io.standardError.contains("キャンセル"))
        }
    }

    func testProgressOutputFailureCancelsActionButReturnsOne() {
        var actionContinued = false
        let (runner, io) = makeRunner(
            input: ["y"],
            failWhen: "login-url",
            add: { context in
                context.progress("login-url")
                try context.checkCancellation()
                actionContinued = true
                return .none
            }
        )

        XCTAssertEqual(runner.run(arguments: ["add"]), 1)
        XCTAssertEqual(runner.cancellation.exitCode, 130)
        XCTAssertTrue(io.standardError.contains("fixture output failure"))
        XCTAssertFalse(actionContinued)
    }

    func testSwitchSuccessTextIsAnExactOutputSuffix() throws {
        let accountView = try view()
        let (runner, io) = makeRunner(
            input: ["1", "y"],
            accountView: { accountView },
            switchTo: { _, _ in .none }
        )

        XCTAssertEqual(runner.run(arguments: []), 0)
        XCTAssertTrue(io.standardOutput.hasSuffix(Self.switchSuccessText))
    }

    func testSwitchSuccessReportsBackendReload() throws {
        let accountView = try view()
        let (runner, io) = makeRunner(
            input: ["1", "y"],
            accountView: { accountView },
            switchTo: { _, _ in .none },
            reloadOutcome: .reloaded(previousPIDs: [200], currentPIDs: [900])
        )

        XCTAssertEqual(runner.run(arguments: []), 0)
        XCTAssertTrue(io.standardOutput.hasSuffix(
            "認証ファイルを選択したアカウントに切り替えました。\n"
            + "ChatGPTアプリのバックエンドを再起動しました。新しいアカウントで動作します。\n"
        ))
    }

    func testSwitchSuccessFallsBackToManualRestartOnIndeterminateReload() throws {
        let accountView = try view()
        let (runner, io) = makeRunner(
            input: ["1", "y"],
            accountView: { accountView },
            switchTo: { _, _ in .none },
            reloadOutcome: .indeterminate
        )

        XCTAssertEqual(runner.run(arguments: []), 0)
        XCTAssertTrue(io.standardOutput.hasSuffix(
            "認証ファイルを選択したアカウントに切り替えました。\n"
            + "バックエンドを再起動できませんでした。ChatGPTアプリを手動で再起動してください。\n"
        ))
    }

    func testCancellationDuringFinalSwitchWritePreservesSignalExitCode() throws {
        let accountView = try view()
        for signal in [SIGINT, SIGTERM] {
            let token = CancellationToken()
            let (runner, io) = makeRunner(
                input: ["1", "y"],
                token: token,
                cancelOnWriteContaining: "認証ファイルを選択したアカウントに切り替えました。",
                cancelOnWriteSignal: signal,
                accountView: { accountView },
                switchTo: { _, _ in .none }
            )

            XCTAssertEqual(runner.run(arguments: []), 128 + signal)
            XCTAssertTrue(io.standardOutput.hasSuffix(Self.switchSuccessText))
        }
    }

    func testFinalSwitchOutputCancellationReturnsSignalExitCode() throws {
        let accountView = try view()
        for signal in [SIGINT, SIGTERM] {
            let (runner, _) = makeRunner(
                input: ["1", "y"],
                interruptOnWriteContaining: "認証ファイルを選択したアカウントに切り替えました。",
                interruptOnWriteSignal: signal,
                accountView: { accountView },
                switchTo: { _, _ in .none }
            )

            XCTAssertEqual(runner.run(arguments: []), 128 + signal)
        }
    }

    private static let switchSuccessText =
        "認証ファイルを選択したアカウントに切り替えました。\n"
        + "起動中のバックエンドが見つかりませんでした。次回の起動時に反映されます。\n"
}

private final class RecordingTerminalIO: TerminalIO {
    let isInteractive: Bool
    private var input: [String?]
    private let failWhen: String?
    private let cancelOnWriteContaining: String?
    private let cancelOnWriteSignal: Int32
    private let interruptOnWriteContaining: String?
    private let interruptOnWriteSignal: Int32
    private let cancellation: CancellationToken
    private(set) var output: [(TerminalOutput, String)] = []

    init(
        input: [String?],
        interactive: Bool,
        failWhen: String? = nil,
        cancelOnWriteContaining: String? = nil,
        cancelOnWriteSignal: Int32 = SIGINT,
        interruptOnWriteContaining: String? = nil,
        interruptOnWriteSignal: Int32 = SIGINT,
        cancellation: CancellationToken
    ) {
        self.input = input
        self.isInteractive = interactive
        self.failWhen = failWhen
        self.cancelOnWriteContaining = cancelOnWriteContaining
        self.cancelOnWriteSignal = cancelOnWriteSignal
        self.interruptOnWriteContaining = interruptOnWriteContaining
        self.interruptOnWriteSignal = interruptOnWriteSignal
        self.cancellation = cancellation
    }

    func readLine(cancellation: CancellationToken) throws -> String? {
        try cancellation.check()
        guard !input.isEmpty else { return nil }
        return input.removeFirst()
    }

    func write(_ text: String, to output: TerminalOutput) throws {
        if output == .standardOutput,
           let interruptOnWriteContaining,
           text.contains(interruptOnWriteContaining) {
            throw OperationInterrupted(signal: interruptOnWriteSignal)
        }
        if let failWhen, text.contains(failWhen) {
            throw CodexSwitchError.io("fixture output failure")
        }
        self.output.append((output, text))
        if let cancelOnWriteContaining,
           text.contains(cancelOnWriteContaining) {
            cancellation.cancel(signal: cancelOnWriteSignal)
        }
    }

    var standardOutput: String {
        output.filter { $0.0 == .standardOutput }.map(\.1).joined()
    }

    var standardError: String {
        output.filter { $0.0 == .standardError }.map(\.1).joined()
    }
}
