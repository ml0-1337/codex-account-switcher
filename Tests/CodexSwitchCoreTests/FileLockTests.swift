import Foundation
import XCTest
@testable import CodexSwitchCore

final class FileLockTests: XCTestCase {
    func testRejectsSymbolicLinkInIntermediateDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let actualParent = root.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actualParent, withIntermediateDirectories: false)
        let linkedParent = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: actualParent
        )

        XCTAssertThrowsError(
            try FileLock(url: linkedParent.appendingPathComponent("switch.lock"))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: actualParent.appendingPathComponent("switch.lock").path
            )
        )
    }
}
