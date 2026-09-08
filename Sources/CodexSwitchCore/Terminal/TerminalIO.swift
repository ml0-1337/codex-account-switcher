import Darwin
import Dispatch
import Foundation

/// The two streams exposed by a terminal runner. Keeping stream selection in
/// the injected I/O surface makes command behavior testable without touching
/// the process's real standard streams.
public enum TerminalOutput: Sendable, Equatable {
    case standardOutput
    case standardError
}

/// Synchronous terminal input and output used by `TerminalRunner`.
///
/// `readLine(cancellation:)` must check the token while waiting when the
/// underlying input can block. The standard implementation polls stdin so a
/// signal delivered to `TerminalSignalMonitor` is observed promptly.
public protocol TerminalIO: AnyObject {
    var isInteractive: Bool { get }

    func readLine(cancellation: CancellationToken) throws -> String?
    func write(_ text: String, to output: TerminalOutput) throws
}

public extension TerminalIO {
    func writeLine(
        _ line: String,
        to output: TerminalOutput = .standardOutput
    ) throws {
        try write(line + "\n", to: output)
    }
}

/// Real process-terminal I/O for the executable adapter.
///
/// This type deliberately owns no process lifecycle and no application
/// behavior. It only polls and reads the supplied input descriptor and writes
/// bytes to the selected output descriptor.
public final class StandardTerminalIO: TerminalIO {
    public let isInteractive: Bool

    private let cancellation: CancellationToken
    private let inputDescriptor: Int32
    private let outputDescriptor: Int32
    private let errorDescriptor: Int32
    private let pollIntervalMilliseconds: Int32
    private var bufferedInput = Data()
    private var didReachEOF = false

    private static let diagnosticWriteTimeoutNanoseconds: UInt64 = 1_000_000_000
    private static let maximumWriteChunk = Int(PIPE_BUF)

    public init(
        cancellation: CancellationToken,
        inputDescriptor: Int32 = STDIN_FILENO,
        outputDescriptor: Int32 = STDOUT_FILENO,
        errorDescriptor: Int32 = STDERR_FILENO,
        interactive: Bool? = nil,
        pollIntervalMilliseconds: Int32 = 100
    ) {
        self.cancellation = cancellation
        self.inputDescriptor = inputDescriptor
        self.outputDescriptor = outputDescriptor
        self.errorDescriptor = errorDescriptor
        self.isInteractive = interactive ?? (Darwin.isatty(inputDescriptor) != 0)
        self.pollIntervalMilliseconds = max(pollIntervalMilliseconds, 1)
    }

    public func readLine(cancellation: CancellationToken) throws -> String? {
        guard inputDescriptor >= 0 else {
            throw CodexSwitchError.io("端末入力を読み取れません。")
        }

        while true {
            try cancellation.check()

            if let newlineIndex = bufferedInput.firstIndex(of: 0x0A) {
                let lineBytes = bufferedInput.prefix(upTo: newlineIndex)
                bufferedInput.removeSubrange(bufferedInput.startIndex...newlineIndex)
                return Self.decodeLine(lineBytes)
            }

            if didReachEOF {
                guard !bufferedInput.isEmpty else { return nil }
                let lineBytes = bufferedInput
                bufferedInput.removeAll(keepingCapacity: false)
                return Self.decodeLine(lineBytes)
            }

            try readAvailableInput(cancellation: cancellation)
        }
    }

    public func write(_ text: String, to output: TerminalOutput) throws {
        let descriptor: Int32
        switch output {
        case .standardOutput:
            descriptor = outputDescriptor
        case .standardError:
            descriptor = errorDescriptor
        }

        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        // stderr carries cancellation and cleanup diagnostics, so it must
        // remain writable after a signal. Its bounded deadline below
        // prevents a full or flow-stopped descriptor from hanging exit.
        if output == .standardOutput {
            try cancellation.check()
        }
        guard descriptor >= 0 else {
            throw CodexSwitchError.io("端末に出力できません。")
        }
        let deadline = output == .standardError
            ? DispatchTime.now().uptimeNanoseconds + Self.diagnosticWriteTimeoutNanoseconds
            : nil

        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                if deadline == nil {
                    try cancellation.check()
                }
                let timeout = try pollTimeoutMilliseconds(until: deadline)
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLOUT),
                    revents: 0
                )
                let pollResult = Darwin.poll(
                    &pollDescriptor,
                    1,
                    timeout
                )
                if pollResult < 0 {
                    if errno == EINTR { continue }
                    throw CodexSwitchError.io("端末に出力できません。")
                }
                if pollResult == 0 { continue }

                let invalidEvents = Int16(POLLERR | POLLHUP | POLLNVAL)
                if pollDescriptor.revents & invalidEvents != 0 {
                    throw CodexSwitchError.io("端末に出力できません。")
                }
                guard pollDescriptor.revents & Int16(POLLOUT) != 0 else {
                    continue
                }

                if deadline == nil {
                    try cancellation.check()
                }
                // Keep one write within macOS's PIPE_BUF so a pipe reported as
                // writable cannot be handed an oversized chunk that blocks
                // while the kernel waits to split it.
                let writeCount = min(rawBuffer.count - offset, Self.maximumWriteChunk)
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    writeCount
                )
                if result > 0 {
                    offset += result
                    continue
                }
                if result < 0, errno == EINTR { continue }
                throw CodexSwitchError.io("端末に出力できません。")
            }
        }
    }

    private func pollTimeoutMilliseconds(until deadline: UInt64?) throws -> Int32 {
        guard let deadline else { return pollIntervalMilliseconds }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else {
            throw CodexSwitchError.io("端末に出力できません。")
        }
        let remainingNanoseconds = deadline - now
        let remainingMilliseconds = max(
            UInt64(1),
            (remainingNanoseconds + 999_999) / 1_000_000
        )
        return Int32(
            min(UInt64(pollIntervalMilliseconds), remainingMilliseconds)
        )
    }

    private func readAvailableInput(cancellation: CancellationToken) throws {
        while true {
            try cancellation.check()

            var descriptor = pollfd(
                fd: inputDescriptor,
                events: Int16(POLLIN | POLLHUP),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, pollIntervalMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CodexSwitchError.io("端末入力を待機できません。")
            }
            if pollResult == 0 { return }

            let invalidEvents = Int16(POLLERR | POLLNVAL)
            if descriptor.revents & invalidEvents != 0 {
                throw CodexSwitchError.io("端末入力を読み取れません。")
            }

            var bytes = [UInt8](repeating: 0, count: 4096)
            let readCount = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(inputDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            if readCount > 0 {
                bufferedInput.append(contentsOf: bytes.prefix(readCount))
                return
            }
            if readCount == 0 {
                didReachEOF = true
                return
            }
            if errno == EINTR { continue }
            throw CodexSwitchError.io("端末入力を読み取れません。")
        }
    }

    private static func decodeLine(_ bytes: Data) -> String {
        var line = Array(bytes)
        if line.last == 0x0D {
            line.removeLast()
        }
        return String(decoding: line, as: UTF8.self)
    }
}
