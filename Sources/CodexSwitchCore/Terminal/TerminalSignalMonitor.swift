import Darwin
import Dispatch
import Foundation

/// Delivers SIGINT and SIGTERM to a cancellation token on a Dispatch queue.
///
/// POSIX signal handlers are never used to touch `CancellationToken`. The
/// process disposition is temporarily changed to `SIG_IGN`, then Dispatch
/// signal sources receive the signal and invoke the lock-based token API on
/// their queue.
public final class TerminalSignalMonitor {
    private let token: CancellationToken
    private let signalNumbers: [Int32]
    private let queue: DispatchQueue
    private let queueKey: DispatchSpecificKey<UInt8>
    private let stateLock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var previousHandlers: [(Int32, (@convention(c) (Int32) -> Void)?)] = []
    private var cancellationGroup: DispatchGroup?
    private var isStarted = false
    private var isStopping = false

    public init(
        token: CancellationToken,
        signals: [Int32] = [SIGINT, SIGTERM]
    ) {
        self.token = token
        self.signalNumbers = Array(Set(signals.filter { $0 > 0 })).sorted()
        let queue = DispatchQueue(
            label: "app.codex-account-switcher.terminal-signals",
            qos: .userInitiated
        )
        let queueKey = DispatchSpecificKey<UInt8>()
        queue.setSpecific(key: queueKey, value: 1)
        self.queue = queue
        self.queueKey = queueKey
    }

    public func start() {
        stateLock.lock()
        guard !isStarted, !isStopping else {
            stateLock.unlock()
            return
        }
        isStarted = true
        let cancellationGroup = DispatchGroup()
        self.cancellationGroup = cancellationGroup

        for signalNumber in signalNumbers {
            // Dispatch requires the process disposition to ignore the signal;
            // the event handler below runs later on `queue`, not here.
            let previousHandler = Darwin.signal(signalNumber, SIG_IGN)
            previousHandlers.append((signalNumber, previousHandler))

            cancellationGroup.enter()
            let source = DispatchSource.makeSignalSource(
                signal: signalNumber,
                queue: queue
            )
            source.setCancelHandler {
                cancellationGroup.leave()
            }
            source.setEventHandler { [weak self] in
                self?.token.cancel(signal: signalNumber)
            }
            source.resume()
            sources.append(source)
        }
        stateLock.unlock()
    }

    public func stop() {
        stateLock.lock()
        guard isStarted, !isStopping else {
            stateLock.unlock()
            return
        }
        isStarted = false
        isStopping = true
        let sourcesToCancel = sources
        sources.removeAll(keepingCapacity: false)
        let handlersToRestore = previousHandlers
        previousHandlers.removeAll(keepingCapacity: false)
        let cancellationGroup = self.cancellationGroup
        self.cancellationGroup = nil
        let calledOnSourceQueue = DispatchQueue.getSpecific(key: queueKey) != nil
        stateLock.unlock()

        let finish = { [weak self] in
            for (signalNumber, previousHandler) in handlersToRestore {
                _ = Darwin.signal(signalNumber, previousHandler)
            }
            self?.markRestored()
        }

        guard let cancellationGroup else {
            finish()
            return
        }

        if calledOnSourceQueue {
            cancellationGroup.notify(queue: queue, execute: finish)
        }
        for source in sourcesToCancel {
            source.cancel()
        }
        if !calledOnSourceQueue {
            cancellationGroup.wait()
            finish()
        }
    }

    private func markRestored() {
        stateLock.lock()
        isStopping = false
        stateLock.unlock()
    }

    deinit {
        stop()
    }
}
