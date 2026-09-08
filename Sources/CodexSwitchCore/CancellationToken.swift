import Darwin
import Foundation

public struct OperationInterrupted: Error, Sendable, LocalizedError {
    public let signal: Int32
    public var exitCode: Int32 { 128 + signal }
    public var errorDescription: String? { "処理を中断しました。" }
}

/// Shared by the terminal and the owned login process. Signal callbacks must
/// run on a Dispatch queue, never call this lock-based API in a POSIX handler.
public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var receivedSignal: Int32?

    public init() {}

    public func cancel(signal: Int32 = SIGINT) {
        lock.lock()
        defer { lock.unlock() }
        if receivedSignal == nil { receivedSignal = signal }
    }

    public var exitCode: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return receivedSignal.map { 128 + $0 }
    }

    public func check() throws {
        lock.lock()
        let signal = receivedSignal
        lock.unlock()
        if let signal { throw OperationInterrupted(signal: signal) }
    }
}
