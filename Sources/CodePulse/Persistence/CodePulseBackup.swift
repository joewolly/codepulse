import Foundation

enum CodePulseBackupError: LocalizedError, Equatable {
    case unsupportedFormat
    case unsupportedVersion(Int)
    case malformedJSON
    case malformedEnvelope
    case missingRequiredField(String)
    case malformedHistoryField(String)
    case malformedConfiguration
    case invalidTimeline
    case duplicateIdentifier(String)
    case inputTooLarge

    static let maximumInputBytes = 128 * 1024 * 1024

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file is not a CodePulse backup."
        case .unsupportedVersion(let version) where version > CodePulseBackup.currentVersion:
            return "This backup was created by a newer CodePulse version and cannot be restored safely."
        case .unsupportedVersion:
            return "This CodePulse backup uses an unsupported backup version."
        case .malformedJSON, .malformedEnvelope:
            return "CodePulse could not read this backup because its JSON is malformed."
        case .missingRequiredField(let field):
            return "This backup is missing required \(field) data."
        case .malformedHistoryField(let field):
            return "This backup contains corrupted \(field) data and cannot be restored safely."
        case .malformedConfiguration:
            return "This backup contains malformed configuration data and cannot be restored safely."
        case .invalidTimeline:
            return "This backup contains invalid session timeline data and cannot be restored safely."
        case .duplicateIdentifier(let field):
            return "This backup contains duplicate \(field) identifiers and cannot be restored safely."
        case .inputTooLarge:
            return "This backup is larger than CodePulse's 128 MiB safety limit."
        }
    }
}

struct CodePulseBackup: Codable, Equatable {
    static let format = "codepulse-backup"
    static let currentVersion = 1

    let format: String
    let version: Int
    let exportedAt: Date
    let state: AppState

    init(exportedAt: Date, state: AppState, version: Int = CodePulseBackup.currentVersion) {
        self.format = Self.format
        self.version = version
        self.exportedAt = exportedAt
        self.state = state
    }
}

struct CodePulseBackupPreview: Equatable {
    let format: String
    let version: Int
    let exportedAt: Date
    let projectCount: Int
    let completedSessionCount: Int
    let presetCount: Int
    let automationRuleCount: Int
    let includesActiveSession: Bool
    let earliestSavedSessionAt: Date?
    let latestSavedSessionAt: Date?
    let projectsNeedingRelinkCount: Int

    init(backup: CodePulseBackup, state: AppState) {
        self.format = backup.format
        self.version = backup.version
        self.exportedAt = backup.exportedAt
        self.projectCount = state.projects.count
        self.completedSessionCount = state.completedSessions.count
        self.presetCount = state.sessionPresets.count
        self.automationRuleCount = state.automationRules.count
        self.includesActiveSession = state.activeSession != nil

        let dates = state.completedSessions.flatMap { [$0.startedAt, $0.endedAt] }
        self.earliestSavedSessionAt = dates.min()
        self.latestSavedSessionAt = dates.max()
        self.projectsNeedingRelinkCount = state.projects.filter(\.requiresRelink).count
    }
}

enum CodePulseBackupCodec {
    static func encode(state: AppState, exportedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(CodePulseBackup(
            exportedAt: exportedAt,
            state: portableState(from: state)
        ))
    }

    static func decode(_ data: Data) throws -> CodePulseBackup {
        guard data.count <= CodePulseBackupError.maximumInputBytes else {
            throw CodePulseBackupError.inputTooLarge
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw CodePulseBackupError.malformedJSON
        }
        guard let root = object as? [String: Any] else {
            throw CodePulseBackupError.malformedEnvelope
        }
        guard let format = root["format"] as? String else {
            throw CodePulseBackupError.malformedEnvelope
        }
        guard format == CodePulseBackup.format else {
            throw CodePulseBackupError.unsupportedFormat
        }
        guard let version = root["version"] as? Int else {
            throw CodePulseBackupError.malformedEnvelope
        }
        guard version == CodePulseBackup.currentVersion else {
            throw CodePulseBackupError.unsupportedVersion(version)
        }
        guard let state = root["state"] as? [String: Any] else {
            throw CodePulseBackupError.missingRequiredField("state")
        }

        try requireHistoryArray("projects", in: state)
        try requireHistoryArray("completedSessions", in: state)
        guard state["settings"] is [String: Any] else {
            throw CodePulseBackupError.missingRequiredField("settings")
        }
        try validateUniqueIdentifiers("projects", label: "project", in: state)
        try validateUniqueIdentifiers("completedSessions", label: "session", in: state)
        try validateUniqueIdentifiers("sessionPresets", label: "preset", in: state, optional: true)
        try validateUniqueIdentifiers("automationRules", label: "automation rule", in: state, optional: true)
        try validateActiveSessionIdentifier(in: state)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: CodePulseBackup
        do {
            backup = try decoder.decode(CodePulseBackup.self, from: data)
        } catch let error as DecodingError {
            let codingPath = Self.codingPath(for: error)
            if codingPathContainsHistory(codingPath) {
                throw CodePulseBackupError.malformedHistoryField(historyField(for: codingPath))
            }
            throw CodePulseBackupError.malformedConfiguration
        } catch {
            throw CodePulseBackupError.malformedConfiguration
        }

        do {
            try CodePulseBackupValidator.validate(backup.state)
        } catch let error as CodePulseBackupError {
            throw error
        } catch {
            throw CodePulseBackupError.invalidTimeline
        }
        return backup
    }

    static func portableState(from state: AppState) -> AppState {
        var portable = state
        portable.controlProcessing = nil
        portable.developerToolIntegration = nil
        portable.localInputAcceptanceDate = nil
        return portable
    }

    private static func requireHistoryArray(_ key: String, in state: [String: Any]) throws {
        guard state[key] != nil else {
            throw CodePulseBackupError.missingRequiredField(historyField(for: key))
        }
        guard state[key] is [[String: Any]] else {
            throw CodePulseBackupError.malformedHistoryField(historyField(for: key))
        }
    }

    private static func validateUniqueIdentifiers(
        _ key: String,
        label: String,
        in state: [String: Any],
        optional: Bool = false
    ) throws {
        guard let raw = state[key] else {
            if optional { return }
            throw CodePulseBackupError.missingRequiredField(historyField(for: key))
        }
        guard let records = raw as? [[String: Any]] else {
            throw CodePulseBackupError.malformedConfiguration
        }
        var identifiers = Set<String>()
        for record in records {
            guard let id = record["id"] as? String, UUID(uuidString: id) != nil else {
                throw CodePulseBackupError.malformedHistoryField(label)
            }
            guard identifiers.insert(id.lowercased()).inserted else {
                throw CodePulseBackupError.duplicateIdentifier(label)
            }
        }
    }

    private static func validateActiveSessionIdentifier(in state: [String: Any]) throws {
        guard let raw = state["activeSession"] as? [String: Any] else { return }
        guard let id = raw["id"] as? String, UUID(uuidString: id) != nil else {
            throw CodePulseBackupError.malformedHistoryField("active session")
        }
        guard let completed = state["completedSessions"] as? [[String: Any]] else { return }
        if completed.contains(where: { ($0["id"] as? String)?.lowercased() == id.lowercased() }) {
            throw CodePulseBackupError.duplicateIdentifier("session")
        }
    }

    private static func codingPathContainsHistory(_ codingPath: [CodingKey]) -> Bool {
        codingPath.contains { key in
            ["projects", "completedSessions", "activeSession"].contains(key.stringValue)
        }
    }

    private static func historyField(for codingPath: [CodingKey]) -> String {
        if codingPath.contains(where: { $0.stringValue == "projects" }) { return "project" }
        if codingPath.contains(where: { $0.stringValue == "activeSession" }) { return "active session" }
        return "saved session"
    }

    private static func historyField(for key: String) -> String {
        switch key {
        case "projects": return "project"
        case "completedSessions": return "saved session"
        case "activeSession": return "active session"
        default: return key
        }
    }

    private static func codingPath(for error: DecodingError) -> [CodingKey] {
        switch error {
        case .typeMismatch(_, let context),
             .valueNotFound(_, let context),
             .keyNotFound(_, let context),
             .dataCorrupted(let context):
            return context.codingPath
        @unknown default:
            return []
        }
    }
}
