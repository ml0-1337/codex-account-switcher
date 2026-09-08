import Darwin
import XCTest
@testable import CodexSwitchCore

final class CancellationTokenTests: XCTestCase {
    func testUncancelledOperationCanProceed() throws {
        let token = CancellationToken()
        XCTAssertNil(token.exitCode)
        XCTAssertNoThrow(try token.check())
    }

    func testFirstSignalDeterminesExitCodeAndCheckThrows() {
        let token = CancellationToken()
        token.cancel(signal: SIGTERM)
        token.cancel(signal: SIGINT)
        XCTAssertEqual(token.exitCode, 143)
        XCTAssertThrowsError(try token.check()) { error in
            XCTAssertEqual((error as? OperationInterrupted)?.exitCode, 143)
        }
    }

    func testUserCancellationHasInterruptExitCode() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertEqual(token.exitCode, 130)
    }
}
