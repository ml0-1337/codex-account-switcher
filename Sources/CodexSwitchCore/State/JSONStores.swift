import Foundation

public protocol StateStoreProtocol {
    func loadOrCreate() throws -> SwitcherState
    func save(_ state: SwitcherState) throws
}

public protocol SwitchJournalStoreProtocol {
    func load() throws -> SwitchJournal?
    func save(_ journal: SwitchJournal) throws
    func remove() throws
}

public protocol RegistrationStoreProtocol {
    func load() throws -> PendingCredentialRegistration?
    func save(_ registration: PendingCredentialRegistration) throws
    func remove() throws
}

private enum JSONCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            guard let microseconds = encodedMicroseconds(for: date) else {
                throw EncodingError.invalidValue(date, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Date is outside the supported microsecond range."
                ))
            }
            try container.encode(microseconds)
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let microseconds = try container.decode(Int64.self)
            let date = Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
            guard encodedMicroseconds(for: date) != nil else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Date cannot be represented in the supported microsecond range."
                )
            }
            return date
        }
        return decoder
    }

    private static func encodedMicroseconds(for date: Date) -> Int64? {
        Int64(exactly: (date.timeIntervalSince1970 * 1_000_000).rounded())
    }
}

private struct SchemaVersionProbe: Decodable {
    let schemaVersion: Int
}

public final class StateStore: StateStoreProtocol, Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func loadOrCreate() throws -> SwitcherState {
        guard let data = try AtomicFileWriter.readSecureFileIfPresent(
            paths.stateFile,
            maximumSize: 1_048_576
        ) else {
            return SwitcherState(sharedCodexHome: paths.codexHome.path)
        }

        let decoded: SwitcherState
        do {
            let decoder = JSONCoding.decoder()
            let version = try decoder.decode(SchemaVersionProbe.self, from: data).schemaVersion
            switch version {
            case SwitcherState.currentSchemaVersion:
                decoded = try decoder.decode(SwitcherState.self, from: data)
            default:
                throw CodexSwitchError.state("保存されている状態の形式に対応していません。")
            }
        } catch let error as CodexSwitchError {
            throw error
        } catch {
            throw CodexSwitchError.state("保存されている切替ツールの状態を読み取れません。")
        }
        return try decoded.validated(expectedCodexHome: paths.codexHome)
    }

    public func save(_ state: SwitcherState) throws {
        _ = try state.validated(expectedCodexHome: paths.codexHome)
        try paths.ensureRuntimeDirectories()
        do {
            try AtomicFileWriter.write(JSONCoding.encoder().encode(state), to: paths.stateFile)
        } catch let error as CodexSwitchError {
            throw error
        } catch {
            throw CodexSwitchError.state("切替ツールの状態を保存できません。")
        }
    }
}

public final class JournalStore: SwitchJournalStoreProtocol, Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func load() throws -> SwitchJournal? {
        guard let data = try AtomicFileWriter.readSecureFileIfPresent(
            paths.journalFile,
            maximumSize: 65_536
        ) else { return nil }
        do {
            let decoder = JSONCoding.decoder()
            let version = try decoder.decode(SchemaVersionProbe.self, from: data).schemaVersion
            guard version == SwitchJournal.currentSchemaVersion else {
                // In particular, v1/v2 journals are not interpreted as v3.
                if version < SwitchJournal.currentSchemaVersion {
                    throw CodexSwitchError.state(
                        "未完了の切替記録が旧形式です。旧版で未完了の処理を解消してから再実行してください。"
                    )
                }
                throw CodexSwitchError.state("未完了の切替記録の形式に対応していません。")
            }
            return try decoder.decode(SwitchJournal.self, from: data).validated()
        } catch let error as CodexSwitchError {
            throw error
        } catch {
            throw CodexSwitchError.state("未完了の切替記録を読み取れません。")
        }
    }

    public func save(_ journal: SwitchJournal) throws {
        _ = try journal.validated()
        try paths.ensureRuntimeDirectories()
        do {
            try AtomicFileWriter.write(JSONCoding.encoder().encode(journal), to: paths.journalFile)
        } catch let error as CodexSwitchError {
            throw error
        } catch {
            throw CodexSwitchError.state("未完了の切替記録を保存できません。")
        }
    }

    public func remove() throws {
        try AtomicFileWriter.removeSecureFileIfPresent(paths.journalFile)
    }
}

public final class RegistrationStore: RegistrationStoreProtocol, Sendable {
    private let paths: AppPaths

    public init(paths: AppPaths) {
        self.paths = paths
    }

    public func load() throws -> PendingCredentialRegistration? {
        guard let data = try AtomicFileWriter.readSecureFileIfPresent(
            paths.registrationJournalFile,
            maximumSize: 32_768
        ) else { return nil }
        do {
            let decoder = JSONCoding.decoder()
            let version = try decoder.decode(SchemaVersionProbe.self, from: data).schemaVersion
            guard version == PendingCredentialRegistration.currentSchemaVersion else {
                if version < PendingCredentialRegistration.currentSchemaVersion {
                    throw CodexSwitchError.state(
                        "未完了の認証登録記録が旧形式です。旧版で未完了の処理を解消してから再実行してください。"
                    )
                }
                throw CodexSwitchError.state("未完了の認証登録記録の形式に対応していません。")
            }
            return try decoder.decode(PendingCredentialRegistration.self, from: data).validated()
        } catch let error as CodexSwitchError {
            throw error
        } catch {
            throw CodexSwitchError.state("未完了の認証登録記録を読み取れません。")
        }
    }

    public func save(_ registration: PendingCredentialRegistration) throws {
        _ = try registration.validated()
        try paths.ensureRuntimeDirectories()
        do {
            try AtomicFileWriter.write(
                JSONCoding.encoder().encode(registration),
                to: paths.registrationJournalFile
            )
        } catch let error as CodexSwitchError {
            throw error
        } catch {
            throw CodexSwitchError.state("未完了の認証登録記録を保存できません。")
        }
    }

    public func remove() throws {
        try AtomicFileWriter.removeSecureFileIfPresent(paths.registrationJournalFile)
    }
}
