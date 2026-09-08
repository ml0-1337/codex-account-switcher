import Foundation

public enum CodexSwitchError: Error, LocalizedError, Sendable {
    case invalidInput(String)
    case unsafeFile(String)
    case io(String)
    case keychain(String)
    case state(String)
    case appServer(String)
    case process(String)
    case cancelled(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidInput(message),
             let .unsafeFile(message),
             let .io(message),
             let .keychain(message),
             let .state(message),
             let .appServer(message),
             let .process(message),
             let .cancelled(message):
            message
        }
    }
}
