import Darwin
import XCTest
@testable import CodexSwitchCore

final class AtomicFileWriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = try makeTemporaryDirectory()
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testWritesAndReplacesRegularFileWithOwnerOnlyPermissions() throws {
        let file = temporaryDirectory.appendingPathComponent("state.json")
        try AtomicFileWriter.write(Data("first".utf8), to: file)
        try AtomicFileWriter.write(Data("second".utf8), to: file, requireExistingRegularFile: true)

        XCTAssertEqual(
            try AtomicFileWriter.readSecureFile(file, maximumSize: 100),
            Data("second".utf8)
        )
        var information = stat()
        XCTAssertEqual(Darwin.lstat(file.path, &information), 0)
        XCTAssertEqual(information.st_mode & mode_t(0o777), mode_t(0o600))
        XCTAssertEqual(information.st_uid, getuid())
        XCTAssertEqual(information.st_nlink, 1)
    }

    func testRefusesToReplaceSymbolicLink() throws {
        let target = temporaryDirectory.appendingPathComponent("target")
        let link = temporaryDirectory.appendingPathComponent("state.json")
        try Data("unchanged".utf8).write(to: target)
        XCTAssertEqual(Darwin.symlink(target.path, link.path), 0)

        XCTAssertThrowsError(try AtomicFileWriter.write(Data("replacement".utf8), to: link))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testSecureReadRejectsGroupReadableFile() throws {
        let file = temporaryDirectory.appendingPathComponent("state.json")
        try Data("fixture".utf8).write(to: file)
        XCTAssertEqual(chmod(file.path, mode_t(0o640)), 0)

        XCTAssertThrowsError(try AtomicFileWriter.readSecureFile(file, maximumSize: 100))
    }

    func testRejectsHardLinkedExistingFile() throws {
        let original = temporaryDirectory.appendingPathComponent("original.json")
        let destination = temporaryDirectory.appendingPathComponent("state.json")
        try Data("fixture".utf8).write(to: original)
        XCTAssertEqual(chmod(original.path, mode_t(0o600)), 0)
        XCTAssertEqual(Darwin.link(original.path, destination.path), 0)

        XCTAssertThrowsError(
            try AtomicFileWriter.write(
                Data("replacement".utf8),
                to: destination,
                requireExistingRegularFile: true
            )
        )
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "fixture")
    }

    func testRejectsWritableParentDirectory() throws {
        XCTAssertEqual(chmod(temporaryDirectory.path, mode_t(0o770)), 0)
        defer { _ = chmod(temporaryDirectory.path, mode_t(0o700)) }

        let file = temporaryDirectory.appendingPathComponent("state.json")
        XCTAssertThrowsError(try AtomicFileWriter.write(Data("fixture".utf8), to: file))
    }

    func testRejectsWritableIntermediateDirectory() throws {
        let writable = temporaryDirectory.appendingPathComponent("writable", isDirectory: true)
        let parent = writable.appendingPathComponent("parent", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(writable.path, mode_t(0o770)), 0)

        let file = parent.appendingPathComponent("state.json")
        XCTAssertThrowsError(try AtomicFileWriter.write(Data("fixture".utf8), to: file))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testSecureReadRejectsSymbolicLink() throws {
        let target = temporaryDirectory.appendingPathComponent("target")
        let link = temporaryDirectory.appendingPathComponent("state.json")
        try AtomicFileWriter.write(Data("unchanged".utf8), to: target)
        XCTAssertEqual(Darwin.symlink(target.path, link.path), 0)

        XCTAssertThrowsError(try AtomicFileWriter.readSecureFile(link, maximumSize: 100))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "unchanged")
    }

    func testRejectsSymbolicLinkInAnIntermediateDirectory() throws {
        let actualParent = temporaryDirectory.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actualParent, withIntermediateDirectories: false)
        let linkedParent = temporaryDirectory.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: actualParent
        )
        let destination = linkedParent.appendingPathComponent("state.json")

        XCTAssertThrowsError(
            try AtomicFileWriter.write(Data("fixture".utf8), to: destination)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: actualParent.appendingPathComponent("state.json").path
            )
        )
    }
}
