import CodexSwitchCore
import Darwin
import Foundation

// A closed output pipe is an I/O failure, not an unhandled process signal.
_ = signal(SIGPIPE, SIG_IGN)

let cancellation = CancellationToken()
let io = StandardTerminalIO(cancellation: cancellation)

func makeCoordinator(for context: TerminalActionContext) throws -> SwitchCoordinator {
    try context.checkCancellation()
    return SwitchCoordinator(
        paths: try AppPaths.current(),
        vault: KeychainVault(),
        cancellation: context.cancellation,
        progress: { progress in
            switch progress {
            case let .preparing(message):
                context.progress(message)
            case let .waitingForLogin(verificationURL, userCode):
                context.progress("ブラウザで次のURLを開き、コードを入力してください。")
                context.progress("URL: \(verificationURL.absoluteString)")
                context.progress("コード: \(userCode)")
            case let .cleanupFailed(temporaryHome, reason):
                context.diagnostic("一時認証を削除できませんでした: \(temporaryHome.path)")
                context.diagnostic("理由: \(reason)")
            case .savingCurrentAccount, .materializingTarget, .validatingTarget, .completed:
                // Success comes only from the synchronous method's return.
                break
            }
        }
    )
}

let actions = TerminalActions(
    setup: { context in
        let profile = try makeCoordinator(for: context).setup()
        return TerminalActionResult(message: "登録済みアカウント: \(profile.displayName)")
    },
    add: { context in
        let profile = try makeCoordinator(for: context).add()
        return TerminalActionResult(message: "\(profile.displayName) を追加しました。")
    },
    switchTo: { profileID, context in
        let outcome = try makeCoordinator(for: context).switchAccount(targetProfileID: profileID)
        guard outcome.changed else {
            throw CodexSwitchError.state("既に選択されているアカウントです。認証ファイルは変更していません。")
        }
        return .none
    },
    recover: { context in
        switch try makeCoordinator(for: context).recover() {
        case let .repairedSwitch(profile), let .repairedRegistration(profile), let .repairedState(profile):
            return TerminalActionResult(message: "\(profile.displayName) の管理情報を復旧しました。")
        case .discardedRegistration:
            return TerminalActionResult(
                message: "未保存の追加記録を取り消しました。アカウントを追加するには add を再実行してください。"
            )
        case .noPendingOperation:
            return TerminalActionResult(message: "復旧する処理はありません。")
        }
    }
)

let runner = TerminalRunner(
    io: io,
    accountView: {
        // Resolve account storage lazily: help, argument errors, and refused
        // non-interactive mutations must not access credentials or state.
        let state = try SwitchCoordinator(
            paths: AppPaths.current(),
            vault: KeychainVault(),
            cancellation: cancellation
        ).list()
        return TerminalAccountView(
            profiles: state.profiles,
            lastSelectedProfileID: state.activeProfileID
        )
    },
    actions: actions,
    cancellation: cancellation
)

exit(runner.run(arguments: Array(CommandLine.arguments.dropFirst())))
