import Foundation

/// Version boundaries for the on-disk AppState document.
///
/// The pre-workspace document was effectively schema 1, although it did not
/// persist an explicit version marker. Schema 2 is the first canonical
/// workspace-aware representation.
enum CodePulseStateSchema {
    static let legacyVersion = 1
    static let currentVersion = 2
}

struct WorkspaceRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    static let defaultName = "Default Workspace"

    static func defaultWorkspace(
        id: UUID = implicitDefaultID,
        at date: Date = defaultCreationDate
    ) -> WorkspaceRecord {
        WorkspaceRecord(id: id, name: defaultName, createdAt: date, updatedAt: date)
    }

    /// ProjectRecord's compatibility initializer uses this only for
    /// in-memory states assembled by older callers. It is never published as
    /// a canonical workspace identity: AppState remaps it to the generated
    /// default workspace when no workspace list was supplied.
    static var implicitDefaultID: UUID { AppState.defaultWorkspaceID }
    static let defaultCreationDate = Date(
        timeIntervalSince1970: floor(Date().timeIntervalSince1970)
    )
}

/// Decode-only representation of a pre-workspace project. Keeping this DTO
/// separate from ProjectRecord lets the canonical decoder remain strict about
/// the required workspaceID field.
struct LegacyProjectRecord: Decodable {
    let id: UUID
    let workspaceID: UUID?
    let name: String
    let folderPath: String?
    let bookmarkData: Data?
    let createdAt: Date
    let lastUsedAt: Date?
    let archivedAt: Date?

    func migrated(to workspaceID: UUID) -> ProjectRecord {
        ProjectRecord(
            id: id,
            workspaceID: workspaceID,
            name: name,
            folderPath: folderPath,
            bookmarkData: bookmarkData,
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            archivedAt: archivedAt
        )
    }
}

enum AppStateIntegrityError: LocalizedError, Equatable {
    case unsupportedSchemaVersion(Int)
    case noWorkspaces
    case duplicateWorkspaceID
    case duplicateProjectID
    case danglingProjectWorkspace(UUID)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "CodePulse state schema version \(version) is unsupported."
        case .noWorkspaces:
            return "CodePulse state does not contain a workspace."
        case .duplicateWorkspaceID:
            return "CodePulse state contains duplicate workspace identifiers."
        case .duplicateProjectID:
            return "CodePulse state contains duplicate project identifiers."
        case .danglingProjectWorkspace(let id):
            return "Project \(id.uuidString) references a missing workspace."
        }
    }
}

enum AppStateIntegrityValidator {
    static func validate(_ state: AppState) throws {
        guard state.schemaVersion == CodePulseStateSchema.currentVersion else {
            throw AppStateIntegrityError.unsupportedSchemaVersion(state.schemaVersion)
        }
        guard !state.workspaces.isEmpty else {
            throw AppStateIntegrityError.noWorkspaces
        }

        let workspaceIDs = state.workspaces.map(\.id)
        guard Set(workspaceIDs).count == workspaceIDs.count else {
            throw AppStateIntegrityError.duplicateWorkspaceID
        }

        let projectIDs = state.projects.map(\.id)
        guard Set(projectIDs).count == projectIDs.count else {
            throw AppStateIntegrityError.duplicateProjectID
        }

        let workspaceIDSet = Set(workspaceIDs)
        for project in state.projects {
            guard workspaceIDSet.contains(project.workspaceID) else {
                throw AppStateIntegrityError.danglingProjectWorkspace(project.workspaceID)
            }
        }
    }

    /// selectedWorkspaceID is a presentation preference, so a missing or
    /// stale value is normalized to a valid workspace. Project membership is
    /// deliberately not repaired here; a dangling relationship is a data
    /// integrity failure and must remain visible to the load/restore boundary.
    static func normalizeSelectedWorkspace(in state: inout AppState) {
        let workspaceIDs = Set(state.workspaces.map(\.id))
        guard let selected = state.settings.selectedWorkspaceID,
              workspaceIDs.contains(selected) else {
            state.settings.selectedWorkspaceID = state.workspaces.first?.id
            return
        }
    }
}

enum AppStateLegacyMigration {
    static func migrate(
        projects: [LegacyProjectRecord],
        completedSessions: [CompletedSession],
        activeSession: ActiveSession?,
        settings: CodePulseSettings,
        sessionPresets: [SessionPreset],
        developerToolIntegration: DeveloperToolIntegrationProcessingState?,
        automationRules: [SessionAutomationRule],
        controlProcessing: CodePulseControlProcessingState?,
        localInputAcceptanceDate: Date?
    ) -> AppState {
        // A pre-workspace state has no relationship to preserve. The single
        // existing ID case is retained only for compatibility with synthetic
        // callers that encoded a workspaceID before the schema marker was
        // introduced; real legacy installs take the fresh UUID path.
        let existingIDs = Set(projects.compactMap(\.workspaceID))
        let workspaceID = existingIDs.count == 1
            ? existingIDs.first!
            : UUID()
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let createdAt = projects.map(\.createdAt).min() ?? now
        let workspace = WorkspaceRecord(
            id: workspaceID,
            name: WorkspaceRecord.defaultName,
            createdAt: createdAt,
            updatedAt: now
        )
        var migratedSettings = settings
        migratedSettings.selectedWorkspaceID = workspace.id

        return AppState(
            schemaVersion: CodePulseStateSchema.currentVersion,
            workspaces: [workspace],
            projects: projects.map { $0.migrated(to: workspace.id) },
            completedSessions: completedSessions,
            activeSession: activeSession,
            settings: migratedSettings,
            sessionPresets: sessionPresets,
            developerToolIntegration: developerToolIntegration,
            automationRules: automationRules,
            controlProcessing: controlProcessing,
            localInputAcceptanceDate: localInputAcceptanceDate
        )
    }
}
