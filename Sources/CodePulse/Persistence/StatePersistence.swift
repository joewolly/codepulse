import Foundation

protocol StatePersisting: AnyObject {
    func load() -> AppState
    func save(_ state: AppState)
}

/// Exposes a safe recovery path without making state-loading failures destructive.
protocol StatePersistenceRecoveryProviding: AnyObject {
    var recoveryIssue: PersistenceRecoveryIssue? { get }
    func exportRecoveryCopy(to fileURL: URL) throws
}

struct PersistenceRecoveryIssue: Equatable {
    enum Kind: Equatable {
        case unreadableState
        case recoveredFromBackup
        case unsupportedFutureVersion(Int)
        case writeFailed
    }

    let kind: Kind
    let detail: String
    let recoveryFileURL: URL?

    var userMessage: String {
        switch kind {
        case .unreadableState:
            return "CodePulse could not read its saved state. Your existing file was left untouched. Export a recovery copy before making changes."
        case .recoveredFromBackup:
            return "CodePulse could not complete a state migration, so it is using the last known-good backup for this launch. Your original file was left untouched."
        case .unsupportedFutureVersion(let version):
            return "This CodePulse state uses schema version \(version), which is newer than this app supports. Your existing file was left untouched."
        case .writeFailed:
            return "CodePulse could not safely save your latest change. The last known-good state remains available for recovery."
        }
    }
}

struct StateMigrationRecord: Codable, Equatable {
    let identifier: String
    let fromVersion: Int
    let toVersion: Int
    let migratedAt: Date
}

struct StatePersistenceEnvelope: Codable, Equatable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let createdAt: Date
    var migrationHistory: [StateMigrationRecord]
    let payload: AppState
}

private enum StatePersistenceError: LocalizedError {
    case unsupportedFutureVersion(Int)
    case unreadableState
    case noRecoveryCopy

    var errorDescription: String? {
        switch self {
        case .unsupportedFutureVersion(let version):
            return "Unsupported future state schema version \(version)."
        case .unreadableState:
            return "The saved CodePulse state could not be decoded."
        case .noRecoveryCopy:
            return "No recovery copy is available."
        }
    }
}

final class JSONFilePersistence: StatePersisting, StatePersistenceRecoveryProviding {
    let fileURL: URL
    let backupURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let now: () -> Date
    private let atomicWrite: (Data, URL) throws -> Void
    private var lastLoadedState = AppState()
    private var recoveryData: Data?
    private var envelopeCreatedAt: Date?
    private var migrationHistory: [StateMigrationRecord] = []

    private(set) var recoveryIssue: PersistenceRecoveryIssue?

    init(
        fileURL: URL = JSONFilePersistence.defaultFileURL(),
        now: @escaping () -> Date = Date.init,
        atomicWrite: @escaping (Data, URL) throws -> Void = { data, url in
            try data.write(to: url, options: .atomic)
        }
    ) {
        self.fileURL = fileURL
        self.backupURL = fileURL.appendingPathExtension("backup")
        self.now = now
        self.atomicWrite = atomicWrite

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> AppState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            recoveryIssue = nil
            return lastLoadedState
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let loaded = try decodeAndMigrate(data)
            lastLoadedState = loaded
            recoveryIssue = nil
            return loaded
        } catch {
            let unreadableData = try? Data(contentsOf: fileURL)
            if case StatePersistenceError.unsupportedFutureVersion = error {
                recoveryData = unreadableData ?? recoveryData
                let issue = makeRecoveryIssue(for: error)
                recoveryIssue = issue
                NSLog("CodePulse could not load local state: %@", issue.detail)
                return lastLoadedState
            }
            if let backupData = try? Data(contentsOf: backupURL),
               let recoveredState = try? decodeStateForBackupValidation(backupData) {
                lastLoadedState = recoveredState
                recoveryData = backupData
                let issue = PersistenceRecoveryIssue(
                    kind: .recoveredFromBackup,
                    detail: error.localizedDescription,
                    recoveryFileURL: backupURL
                )
                recoveryIssue = issue
                NSLog("CodePulse recovered local state from backup after load failure: %@", issue.detail)
                return recoveredState
            }
            recoveryData = unreadableData ?? recoveryData
            let issue = makeRecoveryIssue(for: error)
            recoveryIssue = issue
            NSLog("CodePulse could not load local state: %@", issue.detail)
            return lastLoadedState
        }
    }

    func save(_ state: AppState) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try retainLastKnownGoodFile()
            let envelope = StatePersistenceEnvelope(
                schemaVersion: StatePersistenceEnvelope.currentSchemaVersion,
                createdAt: envelopeCreatedAt ?? now(),
                migrationHistory: migrationHistory,
                payload: state
            )
            try atomicWrite(encoder.encode(envelope), fileURL)
            lastLoadedState = state
            envelopeCreatedAt = envelope.createdAt
            migrationHistory = envelope.migrationHistory
            recoveryIssue = nil
        } catch {
            let issue = PersistenceRecoveryIssue(
                kind: .writeFailed,
                detail: error.localizedDescription,
                recoveryFileURL: existingRecoveryFileURL
            )
            recoveryIssue = issue
            NSLog("CodePulse could not save local state: %@", issue.detail)
        }
    }

    func exportRecoveryCopy(to fileURL: URL) throws {
        if let recoveryData {
            try recoveryData.write(to: fileURL, options: .atomic)
            return
        }
        if FileManager.default.fileExists(atPath: backupURL.path) {
            let data = try Data(contentsOf: backupURL)
            try data.write(to: fileURL, options: .atomic)
            return
        }
        throw StatePersistenceError.noRecoveryCopy
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return directory.appendingPathComponent("CodePulse/state.json")
    }

    private func decodeAndMigrate(_ data: Data) throws -> AppState {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw StatePersistenceError.unreadableState
        }

        if let version = root["schemaVersion"] as? Int {
            guard version <= StatePersistenceEnvelope.currentSchemaVersion else {
                throw StatePersistenceError.unsupportedFutureVersion(version)
            }
            let envelope = try decoder.decode(StatePersistenceEnvelope.self, from: data)
            let migrated = try migrate(envelope)
            if migrated != envelope {
                try writeMigratedEnvelope(migrated, replacing: data)
            }
            envelopeCreatedAt = migrated.createdAt
            migrationHistory = migrated.migrationHistory
            return migrated.payload
        }

        let legacyState = try decoder.decode(AppState.self, from: data)
        let legacyEnvelope = StatePersistenceEnvelope(
            schemaVersion: 1,
            createdAt: now(),
            migrationHistory: [],
            payload: legacyState
        )
        let migrated = try migrate(legacyEnvelope)
        try writeMigratedEnvelope(migrated, replacing: data)
        envelopeCreatedAt = migrated.createdAt
        migrationHistory = migrated.migrationHistory
        return legacyState
    }

    private func migrate(_ envelope: StatePersistenceEnvelope) throws -> StatePersistenceEnvelope {
        var migrated = envelope
        while migrated.schemaVersion < StatePersistenceEnvelope.currentSchemaVersion {
            switch migrated.schemaVersion {
            case 1:
                migrated = migrateVersion1ToVersion2(migrated)
            default:
                throw StatePersistenceError.unreadableState
            }
        }
        guard migrated.schemaVersion == StatePersistenceEnvelope.currentSchemaVersion else {
            throw StatePersistenceError.unreadableState
        }
        return migrated
    }

    private func migrateVersion1ToVersion2(_ envelope: StatePersistenceEnvelope) -> StatePersistenceEnvelope {
        precondition(envelope.schemaVersion == 1)
        var history = envelope.migrationHistory
        if !history.contains(where: { $0.identifier == "legacy-state-to-envelope" }) {
            history.append(StateMigrationRecord(
                identifier: "legacy-state-to-envelope",
                fromVersion: 1,
                toVersion: 2,
                migratedAt: now()
            ))
        }
        return StatePersistenceEnvelope(
            schemaVersion: 2,
            createdAt: envelope.createdAt,
            migrationHistory: history,
            payload: envelope.payload
        )
    }

    private func writeMigratedEnvelope(_ envelope: StatePersistenceEnvelope, replacing existingData: Data) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // The original remains both at its normal path until the atomic write
        // succeeds and as an explicit recovery copy afterwards.
        try atomicWrite(existingData, backupURL)
        try atomicWrite(encoder.encode(envelope), fileURL)
    }

    private func retainLastKnownGoodFile() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let existingData = try Data(contentsOf: fileURL)
        _ = try decodeStateForBackupValidation(existingData)
        try atomicWrite(existingData, backupURL)
    }

    private func decodeStateForBackupValidation(_ data: Data) throws -> AppState {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw StatePersistenceError.unreadableState
        }
        if let version = root["schemaVersion"] as? Int {
            guard version <= StatePersistenceEnvelope.currentSchemaVersion else {
                throw StatePersistenceError.unsupportedFutureVersion(version)
            }
            return try decoder.decode(StatePersistenceEnvelope.self, from: data).payload
        }
        return try decoder.decode(AppState.self, from: data)
    }

    private var existingRecoveryFileURL: URL? {
        FileManager.default.fileExists(atPath: backupURL.path) ? backupURL : nil
    }

    private func makeRecoveryIssue(for error: Error) -> PersistenceRecoveryIssue {
        let kind: PersistenceRecoveryIssue.Kind
        if case let StatePersistenceError.unsupportedFutureVersion(version) = error {
            kind = .unsupportedFutureVersion(version)
        } else {
            kind = .unreadableState
        }
        return PersistenceRecoveryIssue(
            kind: kind,
            detail: error.localizedDescription,
            recoveryFileURL: existingRecoveryFileURL
        )
    }
}
