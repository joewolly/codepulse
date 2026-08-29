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
    case invalidWorkspaceReference
    case duplicateIdentifier(String)
    case multipleActiveSessionsUnsupported
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
        case .invalidWorkspaceReference:
            return "This backup contains a project that references a missing workspace and cannot be restored safely."
        case .duplicateIdentifier(let field):
            return "This backup contains duplicate \(field) identifiers and cannot be restored safely."
        case .multipleActiveSessionsUnsupported:
            return "Backup version 2 cannot represent multiple active Sessions; finish or discard all but one active Session before exporting."
        case .inputTooLarge:
            return "This backup is larger than CodePulse's 128 MiB safety limit."
        }
    }
}

struct CodePulseBackup: Codable, Equatable {
    static let format = "codepulse-backup"
    static let currentVersion = 2

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

    private enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        // AppState performs version-1/version-2 migration into canonical
        // schema 3 in memory. The codec validates the raw wire shape before
        // this decode, so a schema-3 payload cannot be accepted as v2.
        state = try container.decode(AppState.self, forKey: .state)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(version, forKey: .version)
        try container.encode(exportedAt, forKey: .exportedAt)
        guard version == Self.currentVersion else {
            throw EncodingError.invalidValue(
                version,
                .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "Only backup version 2 can be exported in this phase."
                )
            )
        }
        try container.encode(PortableBackupStateV2(state: state), forKey: .state)
    }
}

/// Compatibility wire DTO for backup version 2. Canonical AppState remains
/// schema 3; this representation is used only at the portable serialization
/// boundary and intentionally has no machine-local processing metadata.
private struct PortableBackupStateV2: Encodable {
    let schemaVersion = CodePulseStateSchema.legacyVersion + 1
    let workspaces: [WorkspaceRecord]
    let projects: [ProjectRecord]
    let completedSessions: [CompletedSession]
    let activeSession: ActiveSession?
    let settings: CodePulseSettings
    let sessionPresets: [SessionPreset]
    let automationRules: [SessionAutomationRule]

    init(state: AppState) throws {
        guard state.activeSessions.count <= 1 else {
            throw CodePulseBackupError.multipleActiveSessionsUnsupported
        }
        workspaces = state.workspaces
        projects = state.projects
        completedSessions = state.completedSessions
        activeSession = state.soleActiveSession
        settings = state.settings
        sessionPresets = state.sessionPresets
        automationRules = state.automationRules
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, workspaces, projects, completedSessions, activeSession
        case settings, sessionPresets, automationRules
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(workspaces, forKey: .workspaces)
        try container.encode(projects, forKey: .projects)
        try container.encode(completedSessions, forKey: .completedSessions)
        // Keep the singular field visible even when there is no active
        // Session; a v2 document never carries an activeSessions collection.
        try container.encode(activeSession, forKey: .activeSession)
        try container.encode(settings, forKey: .settings)
        try container.encode(sessionPresets, forKey: .sessionPresets)
        try container.encode(automationRules, forKey: .automationRules)
    }
}

struct CodePulseBackupPreview: Equatable {
    let format: String
    let version: Int
    let exportedAt: Date
    let projectCount: Int
    let completedSessionCount: Int
    let workspaceCount: Int
    let presetCount: Int
    let automationRuleCount: Int
    let activeSessionCount: Int
    let includesActiveSession: Bool
    let earliestSavedSessionAt: Date?
    let latestSavedSessionAt: Date?
    let projectsNeedingRelinkCount: Int

    init(backup: CodePulseBackup, state: AppState) {
        self.format = backup.format
        self.version = backup.version
        self.exportedAt = backup.exportedAt
        self.projectCount = state.projects.count
        self.workspaceCount = state.workspaces.count
        self.completedSessionCount = state.completedSessions.count
        self.presetCount = state.sessionPresets.count
        self.automationRuleCount = state.automationRules.count
        self.activeSessionCount = state.activeSessions.count
        self.includesActiveSession = !state.activeSessions.isEmpty

        let dates = state.completedSessions.flatMap { [$0.startedAt, $0.endedAt] }
        self.earliestSavedSessionAt = dates.min()
        self.latestSavedSessionAt = dates.max()
        self.projectsNeedingRelinkCount = state.projects.filter(\.requiresRelink).count
    }
}

enum CodePulseBackupCodec {
    static func encode(state: AppState, exportedAt: Date) throws -> Data {
        guard state.activeSessions.count <= 1 else {
            // Fail before the caller can create a file or preview for an
            // unrepresentable version-2 payload.
            throw CodePulseBackupError.multipleActiveSessionsUnsupported
        }
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
        guard version == 1 || version == CodePulseBackup.currentVersion else {
            throw CodePulseBackupError.unsupportedVersion(version)
        }
        guard let state = root["state"] as? [String: Any] else {
            throw CodePulseBackupError.missingRequiredField("state")
        }

        try requireHistoryArray("projects", in: state)
        try requireHistoryArray("completedSessions", in: state)
        if version == 1 {
            try rejectWorkspaceMetadataFromLegacyState(state)
        }
        if version == CodePulseBackup.currentVersion {
            guard let schemaVersion = state["schemaVersion"] as? Int,
                  schemaVersion == CodePulseStateSchema.legacyVersion + 1 else {
                throw CodePulseBackupError.missingRequiredField("workspace schema")
            }
            // Backup v2 has a single, optional activeSession field. A
            // collection here is a schema-3 hybrid and must not be accepted
            // as a permanent v2 format.
            guard state["activeSessions"] == nil else {
                throw CodePulseBackupError.malformedConfiguration
            }
            try requireHistoryArray("workspaces", in: state)
            try validateUniqueIdentifiers("workspaces", label: "workspace", in: state)
        }
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
        } catch let error as AppStateIntegrityError {
            // AppState performs collection-level integrity validation while it
            // decodes schema-3 state. Preserve the backup boundary's more
            // specific diagnostics instead of collapsing those failures into
            // a generic configuration error.
            switch error {
            case .danglingProjectWorkspace,
                 .noWorkspaces,
                 .duplicateWorkspaceID,
                 .invalidActiveSessionProjectWorkspace,
                 .danglingActiveSessionProject,
                 .archivedActiveSessionProject:
                throw CodePulseBackupError.invalidWorkspaceReference
            case .duplicateProjectID:
                throw CodePulseBackupError.duplicateIdentifier("project")
            case .duplicateActiveSessionID,
                 .activeSessionHistoryCollision:
                throw CodePulseBackupError.duplicateIdentifier("session")
            case .activeSessionLimitExceeded,
                 .invalidActiveSession,
                 .selfReferentialGitAmbiguity,
                 .duplicateDeveloperToolOwnership,
                 .malformedDeveloperToolOwnership,
                 .duplicateRetiredDeveloperToolThread,
                 .duplicateReservedDeveloperToolThread,
                 .orphanedDeveloperToolReservation,
                 .missingDeveloperToolReservation,
                 .retiredDeveloperToolCapacityExceeded,
                 .multipleApplicationAutomationOwners:
                throw CodePulseBackupError.invalidTimeline
            case .unsupportedSchemaVersion:
                throw CodePulseBackupError.malformedConfiguration
            }
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

    private static func rejectWorkspaceMetadataFromLegacyState(_ state: [String: Any]) throws {
        guard state["workspaces"] == nil else {
            throw CodePulseBackupError.malformedConfiguration
        }

        if let rawSchemaVersion = state["schemaVersion"] {
            guard let schemaVersion = rawSchemaVersion as? Int,
                  schemaVersion == CodePulseStateSchema.legacyVersion else {
                throw CodePulseBackupError.malformedConfiguration
            }
        }

        if let projects = state["projects"] as? [[String: Any]],
           projects.contains(where: { $0["workspaceID"] != nil }) {
            throw CodePulseBackupError.malformedConfiguration
        }

        if let settings = state["settings"] as? [String: Any],
           settings["selectedWorkspaceID"] != nil {
            throw CodePulseBackupError.malformedConfiguration
        }
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
        var identifiers = Set<String>()
        if let rawCollection = state["activeSessions"] {
            guard let records = rawCollection as? [[String: Any]] else {
                throw CodePulseBackupError.malformedHistoryField("active session")
            }
            for record in records {
                guard let id = record["id"] as? String, UUID(uuidString: id) != nil else {
                    throw CodePulseBackupError.malformedHistoryField("active session")
                }
                guard identifiers.insert(id.lowercased()).inserted else {
                    throw CodePulseBackupError.duplicateIdentifier("session")
                }
            }
        }
        if let rawValue = state["activeSession"], !(rawValue is NSNull) {
            // A backup carrying both representations is ambiguous. Schema 2
            // migration accepts the singular form; schema 3 must be
            // collection-only and AppState's decoder enforces that boundary.
            guard state["activeSessions"] == nil else {
                throw CodePulseBackupError.malformedConfiguration
            }
            guard let raw = state["activeSession"] as? [String: Any],
                  let id = raw["id"] as? String,
                  UUID(uuidString: id) != nil else {
                throw CodePulseBackupError.malformedHistoryField("active session")
            }
            identifiers.insert(id.lowercased())
        }
        if let completed = state["completedSessions"] as? [[String: Any]] {
            if completed.contains(where: { record in
                guard let id = record["id"] as? String else { return false }
                return identifiers.contains(id.lowercased())
            }) {
                throw CodePulseBackupError.duplicateIdentifier("session")
            }
        }
    }

    private static func codingPathContainsHistory(_ codingPath: [CodingKey]) -> Bool {
        codingPath.contains { key in
            ["projects", "completedSessions", "activeSession", "activeSessions"].contains(key.stringValue)
        }
    }

    private static func historyField(for codingPath: [CodingKey]) -> String {
        if codingPath.contains(where: { $0.stringValue == "projects" }) { return "project" }
        if codingPath.contains(where: { ["activeSession", "activeSessions"].contains($0.stringValue) }) {
            return "active session"
        }
        return "saved session"
    }

    private static func historyField(for key: String) -> String {
        switch key {
        case "projects": return "project"
        case "completedSessions": return "saved session"
        case "activeSession": return "active session"
        case "activeSessions": return "active session"
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
