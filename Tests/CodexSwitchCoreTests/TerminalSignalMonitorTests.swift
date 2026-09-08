import Darwin
import XCTest
@testable import CodexSwitchCore

final class TerminalSignalMonitorTests: XCTestCase {
    func testSignalIsDeliveredToTokenOnDispatchQueue() {
        let token = CancellationToken()
        let monitor = TerminalSignalMonitor(token: token, signals: [SIGUSR1])
        monitor.start()
        defer { monitor.stop() }

        XCTAssertEqual(Darwin.kill(getpid(), SIGUSR1), 0)
        let deadline = Date().addingTimeInterval(1)
        while token.exitCode == nil && Date() < deadline {
            usleep(1_000)
        }
        XCTAssertEqual(token.exitCode, 128 + SIGUSR1)
    }

    func testStopRestoresSignalDispositionAfterSourceShutdown() {
        let signalNumber = SIGUSR1
        let originalHandler = Darwin.signal(signalNumber, SIG_DFL)
        defer { _ = Darwin.signal(signalNumber, originalHandler) }

        let token = CancellationToken()
        let monitor = TerminalSignalMonitor(token: token, signals: [signalNumber])
        monitor.start()

        let handlerDuringMonitoring = Darwin.signal(signalNumber, SIG_DFL)
        XCTAssertEqual(handlerBits(handlerDuringMonitoring), handlerBits(SIG_IGN))
        _ = Darwin.signal(signalNumber, handlerDuringMonitoring)

        monitor.stop()

        let handlerAfterShutdown = Darwin.signal(signalNumber, SIG_DFL)
        XCTAssertEqual(handlerBits(handlerAfterShutdown), handlerBits(SIG_DFL))
        _ = Darwin.signal(signalNumber, handlerAfterShutdown)
    }

    private func handlerBits(
        _ handler: (@convention(c) (Int32) -> Void)?
    ) -> UInt {
        unsafeBitCast(handler, to: UInt.self)
    }
}
