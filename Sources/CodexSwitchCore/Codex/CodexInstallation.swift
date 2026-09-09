import AppKit
import Foundation

public struct CodexSignature: Sendable, Equatable {
    public let identifier: String?
    public let teamIdentifier: String?
    public let cdHash: String?
    public let authorities: [String]

    public init(
        identifier: String?,
        teamIdentifier: String?,
        cdHash: String?,
        authorities: [String]
    ) {
        self.identifier = identifier
        self.teamIdentifier = teamIdentifier
        self.cdHash = cdHash
        self.authorities = authorities
    }
}

public enum CodexInstallationError: Error, LocalizedError, Sendable {
    case applicationNotFound
    case invalidBundle
    case bundleIdentifierMismatch(String?)
    case missingCodexExecutable
    case codexNotExecutable
    case codexVersionUnavailable
    case signatureInvalid
    case signatureTeamMismatch(String?)

    public var errorDescription: String? {
        switch self {
        case .applicationNotFound: return "公式ChatGPTアプリが見つかりません。"
        case .invalidBundle: return "ChatGPTアプリのバンドルを読み取れません。"
        case let .bundleIdentifierMismatch(identifier):
            return "ChatGPTアプリのBundle IDが一致しません（\(identifier ?? "不明")）。"
        case .missingCodexExecutable: return "ChatGPTアプリに同梱されたCodex実行ファイルが見つかりません。"
        case .codexNotExecutable: return "同梱Codexを実行できません。"
        case .codexVersionUnavailable: return "同梱Codexのバージョンを確認できません。"
        case .signatureInvalid: return "ChatGPTアプリまたは同梱Codexのコード署名を検証できません。"
        case let .signatureTeamMismatch(teamIdentifier):
            return "ChatGPTアプリの署名チームが想定と異なります（\(teamIdentifier ?? "不明")）。"
        }
    }
}

/// Validated information about the official ChatGPT bundle. Discovery and
/// signature verification are intentionally called only by setup/add's lazy
/// session provider; list/switch/recover never construct this type.
public struct CodexInstallation: Sendable, Equatable {
    public static let officialBundleIdentifier = "com.openai.codex"
    public static let officialTeamIdentifier = "2DC432GLL2"

    public let applicationURL: URL
    public let bundleIdentifier: String
    public let applicationVersion: String
    public let buildNumber: String
    public let codexExecutableURL: URL
    public let codexVersion: String
    public let signature: CodexSignature
    public let codexSignature: CodexSignature

    public init(
        applicationURL: URL,
        bundleIdentifier: String,
        applicationVersion: String,
        buildNumber: String,
        codexExecutableURL: URL,
        codexVersion: String,
        signature: CodexSignature,
        codexSignature: CodexSignature? = nil
    ) {
        self.applicationURL = applicationURL
        self.bundleIdentifier = bundleIdentifier
        self.applicationVersion = applicationVersion
        self.buildNumber = buildNumber
        self.codexExecutableURL = codexExecutableURL
        self.codexVersion = codexVersion
        self.signature = signature
        self.codexSignature = codexSignature ?? signature
    }

    public static func discover(
        applicationURL explicitURL: URL? = nil,
        cancellation: CancellationToken? = nil
    ) throws -> CodexInstallation {
        try cancellation?.check()
        let applicationURL = try resolveApplicationURL(explicitURL: explicitURL)
        try cancellation?.check()
        guard let bundle = Bundle(url: applicationURL) else {
            throw CodexInstallationError.invalidBundle
        }
        guard bundle.bundleIdentifier == Self.officialBundleIdentifier else {
            throw CodexInstallationError.bundleIdentifierMismatch(bundle.bundleIdentifier)
        }
        guard let applicationVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !applicationVersion.isEmpty,
              !buildNumber.isEmpty
        else {
            throw CodexInstallationError.invalidBundle
        }

        let codexURL = applicationURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        guard FileManager.default.fileExists(atPath: codexURL.path) else {
            throw CodexInstallationError.missingCodexExecutable
        }
        guard FileManager.default.isExecutableFile(atPath: codexURL.path) else {
            throw CodexInstallationError.codexNotExecutable
        }

        let signature = try inspectSignature(at: applicationURL, cancellation: cancellation)
        try cancellation?.check()
        let codexSignature = try inspectSignature(at: codexURL, cancellation: cancellation)
        if signature.teamIdentifier != Self.officialTeamIdentifier
               || codexSignature.teamIdentifier != Self.officialTeamIdentifier
        {
            throw CodexInstallationError.signatureTeamMismatch(
                codexSignature.teamIdentifier ?? signature.teamIdentifier
            )
        }
        let codexVersion = try readCodexVersion(at: codexURL, cancellation: cancellation)
        try cancellation?.check()
        return CodexInstallation(
            applicationURL: applicationURL,
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            applicationVersion: applicationVersion,
            buildNumber: buildNumber,
            codexExecutableURL: codexURL,
            codexVersion: codexVersion,
            signature: signature,
            codexSignature: codexSignature
        )
    }

    private static func resolveApplicationURL(explicitURL: URL?) throws -> URL {
        let candidate = explicitURL ?? URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        var candidates = [candidate]
        if explicitURL == nil,
           let fallback = NSWorkspace.shared.urlForApplication(
               withBundleIdentifier: Self.officialBundleIdentifier
           )
        {
            candidates.append(fallback)
        }
        for candidate in candidates {
            let standardized = candidate.standardizedFileURL
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
               isDirectory.boolValue
            {
                return standardized
            }
        }
        throw CodexInstallationError.applicationNotFound
    }

    private static func inspectSignature(
        at url: URL,
        cancellation: CancellationToken?
    ) throws -> CodexSignature {
        try inspectSignature(at: url) { arguments in
            try runCodesign(arguments: arguments, cancellation: cancellation)
        }
    }

    static func inspectSignature(
        at url: URL,
        runCodesign: ([String]) throws -> NativeCommandResult
    ) throws -> CodexSignature {
        // A valid self-signed signature can claim arbitrary certificate
        // metadata. Require an Apple-issued identity for the official team.
        let requirement = "=anchor apple generic and certificate leaf[subject.OU] = \"\(officialTeamIdentifier)\""
        let verification = try runCodesign([
            "--verify", "--deep", "--strict", "--verbose=0", "-R", requirement, url.path,
        ])
        guard verification.status == 0 else { throw CodexInstallationError.signatureInvalid }
        let details = try runCodesign(
            ["--display", "--verbose=4", url.path]
        )
        guard details.status == 0 else { throw CodexInstallationError.signatureInvalid }
        let lines = details.output.split(whereSeparator: \.isNewline).map(String.init)
        return CodexSignature(
            identifier: value(after: "Identifier=", in: lines),
            teamIdentifier: value(after: "TeamIdentifier=", in: lines),
            cdHash: value(after: "CDHash=", in: lines),
            authorities: lines
                .filter { $0.hasPrefix("Authority=") }
                .compactMap { value(after: "Authority=", in: [$0]) }
        )
    }

    private static func readCodexVersion(
        at url: URL,
        cancellation: CancellationToken?
    ) throws -> String {
        let result = try NativeCommand.run(
            executable: url,
            arguments: ["--version"],
            cancellation: cancellation
        )
        guard result.status == 0,
              let firstLine = result.output.split(whereSeparator: \.isNewline)
                .map(String.init).first,
              !firstLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw CodexInstallationError.codexVersionUnavailable }
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runCodesign(
        arguments: [String],
        cancellation: CancellationToken?
    ) throws -> NativeCommandResult {
        try NativeCommand.run(
            executable: URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: arguments,
            cancellation: cancellation
        )
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        lines.first(where: { $0.hasPrefix(prefix) }).map {
            String($0.dropFirst(prefix.count))
        }
    }
}
