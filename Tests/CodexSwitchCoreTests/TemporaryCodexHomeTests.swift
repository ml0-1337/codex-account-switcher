import Foundation
import XCTest
@testable import CodexSwitchCore

final class TemporaryCodexHomeTests: XCTestCase {
    func testCleanupRejectsReplacementAtTombstoneAndPreservesExactPath() throws {
        let fixture = try Fixture()
        let home = try TemporaryCodexHome(paths: fixture.paths)
        home.preserveUntilSystemTemporaryCleanup()
        var operations = TemporaryHomeCleanupOperations.system
        operations.rename = { source, destination in
            try TemporaryHomeCleanupOperations.system.rename(source, destination)
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        home.cleanupOperations = operations

        XCTAssertThrowsError(try home.cleanup())
        XCTAssertTrue(home.preservedPath.lastPathComponent.hasPrefix(".deleting-"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.preservedPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.url.path))
        XCTAssertFalse(home.cleanupFailureReason?.isEmpty == true)

        try FileManager.default.removeItem(at: home.preservedPath)
    }

    func testCleanupRetriesRemovalFromExistingTombstoneAfterDeleteFailure() throws {
        let fixture = try Fixture()
        let home = try TemporaryCodexHome(paths: fixture.paths)
        var removeCount = 0
        var operations = TemporaryHomeCleanupOperations.system
        operations.remove = { url in
            removeCount += 1
            if removeCount == 1 {
                throw CodexSwitchError.io("fixture delete failure")
            }
            try TemporaryHomeCleanupOperations.system.remove(url)
        }
        home.cleanupOperations = operations

        XCTAssertThrowsError(try home.cleanup())
        let tombstone = home.preservedPath
        XCTAssertTrue(tombstone.lastPathComponent.hasPrefix(".deleting-"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tombstone.path))
        XCTAssertEqual(removeCount, 1)

        XCTAssertNoThrow(try home.cleanup())
        XCTAssertEqual(removeCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

    private final class Fixture {
        let root: URL
        let paths: AppPaths

        init() throws {
            root = try makeTemporaryDirectory()
            let home = root.appendingPathComponent("home", isDirectory: true)
            let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: codexHome.path)
            paths = AppPaths(
                homeDirectory: home,
                codexHome: codexHome,
                stateRoot: root.appendingPathComponent("state", isDirectory: true)
            )
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }
}
