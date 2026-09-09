import Foundation
import XCTest
@testable import CodexSwitchCore

final class CodexInstallationTests: XCTestCase {
    func testNativeVerifierRejectsAdHocSignedExecutable() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fixture-tool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let codesign = URL(fileURLWithPath: "/usr/bin/codesign")
        let signing = try NativeCommand.run(
            executable: codesign,
            arguments: ["--force", "--sign", "-", executable.path]
        )
        XCTAssertEqual(signing.status, 0)

        XCTAssertThrowsError(try CodexInstallation.inspectSignature(at: executable) { arguments in
            try NativeCommand.run(executable: codesign, arguments: arguments)
        }) { error in
            guard case CodexInstallationError.signatureInvalid = error else {
                return XCTFail("Expected ad-hoc code to fail the official signer requirement")
            }
        }
    }

    func testMatchingTeamMetadataDoesNotBypassAnUntrustedCertificateChain() throws {
        var displayedMetadata = false
        XCTAssertThrowsError(try CodexInstallation.inspectSignature(
            at: URL(fileURLWithPath: "/fixture/Codex.app"),
            runCodesign: { arguments in
                if arguments.contains("--verify") {
                    // The lookalike's own signature is valid, but it does not
                    // satisfy the verifier's independent signer requirement.
                    return NativeCommandResult(status: arguments.contains("-R") ? 1 : 0, output: "")
                }
                displayedMetadata = true
                return NativeCommandResult(
                    status: 0,
                    output: "TeamIdentifier=\(CodexInstallation.officialTeamIdentifier)\n"
                )
            }
        )) { error in
            guard case CodexInstallationError.signatureInvalid = error else {
                return XCTFail("Expected the untrusted signer to be rejected")
            }
        }
        XCTAssertFalse(displayedMetadata)
    }

    func testSignatureInspectionRequiresAppleIssuedCertificateAndOfficialTeam() throws {
        var requirements: [String] = []
        let signature = try CodexInstallation.inspectSignature(
            at: URL(fileURLWithPath: "/fixture/Codex.app"),
            runCodesign: { arguments in
                if let index = arguments.firstIndex(of: "-R"), index + 1 < arguments.count {
                    requirements.append(arguments[index + 1])
                }
                return NativeCommandResult(
                    status: 0,
                    output: "TeamIdentifier=\(CodexInstallation.officialTeamIdentifier)\n"
                )
            }
        )

        let requirement = try XCTUnwrap(requirements.first)
        XCTAssertTrue(requirement.contains("anchor apple generic"))
        XCTAssertTrue(requirement.contains("certificate leaf[subject.OU] = \"\(CodexInstallation.officialTeamIdentifier)\""))
        XCTAssertEqual(signature.teamIdentifier, CodexInstallation.officialTeamIdentifier)
    }
}
