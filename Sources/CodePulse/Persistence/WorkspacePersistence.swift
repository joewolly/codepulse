import CodePulseIntegration
import Foundation

/// Version boundaries for the on-disk AppState document.
///
/// The pre-workspace document was effectively schema 1, although it did not
/// persist an explicit version marker. Schema 2 is the first canonical
/// workspace-aware representation. Schema 3 is the canonical concurrent
/// active-session collection representation.
enum CodePulseStateSchema {
    static let legacyVersion = 1
    static let currentVersion = 3
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
/// separate from ProjectRecord keeps the historical schema free of any
/// workspace relationship.
struct LegacyProjectRecord: Decodable {
    let id: UUID
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
    case activeSessionLimitExceeded(Int)
    case duplicateActiveSessionID(UUID)
    case activeSessionHistoryCollision(UUID)
    case invalidActiveSession(UUID)
    case danglingActiveSessionProject(UUID)
    case archivedActiveSessionProject(UUID)
    case invalidActiveSessionProjectWorkspace(UUID)
    case selfReferentialGitAmbiguity(UUID)
    case duplicateDeveloperToolOwnership(DeveloperTool, String)
    case malformedDeveloperToolOwnership
    case duplicateRetiredDeveloperToolThread(DeveloperTool, String)
    case duplicateReservedDeveloperToolThread(DeveloperTool, String)
    case orphanedDeveloperToolReservation(DeveloperTool, String)
    case missingDeveloperToolReservation(DeveloperTool, String)
    case retiredDeveloperToolCapacityExceeded
    case multipleApplicationAutomationOwners

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
        case .activeSessionLimitExceeded(let count):
            return "CodePulse state contains \(count) active sessions; the maximum is 16."
        case .duplicateActiveSessionID(let id):
            return "CodePulse state contains duplicate active session identifier \(id.uuidString)."
        case .activeSessionHistoryCollision(let id):
            return "Active session \(id.uuidString) is also present in completed history."
        case .invalidActiveSession(let id):
            return "Active session \(id.uuidString) has an invalid timeline or pause structure."
        case .danglingActiveSessionProject(let id):
            return "Active session \(id.uuidString) references a missing project."
        case .archivedActiveSessionProject(let id):
            return "Active session \(id.uuidString) references an archived project."
        case .invalidActiveSessionProjectWorkspace(let id):
            return "Active session \(id.uuidString) references an invalid project/workspace relationship."
        case .selfReferentialGitAmbiguity(let id):
            return "Session \(id.uuidString) contains a self-referential Git ambiguity conflict."
        case .duplicateDeveloperToolOwnership(let tool, let externalSessionID):
            return "Developer-tool ownership \(tool.rawValue):\(externalSessionID) is claimed more than once."
        case .malformedDeveloperToolOwnership:
            return "CodePulse state contains malformed developer-tool ownership metadata."
        case .duplicateRetiredDeveloperToolThread(let tool, let externalSessionID):
            return "Retired developer-tool identity \(tool.rawValue):\(externalSessionID) is duplicated."
        case .duplicateReservedDeveloperToolThread(let tool, let externalSessionID):
            return "Reserved developer-tool identity \(tool.rawValue):\(externalSessionID) is duplicated."
        case .orphanedDeveloperToolReservation(let tool, let externalSessionID):
            return "Reserved developer-tool identity \(tool.rawValue):\(externalSessionID) has no active owning Session."
        case .missingDeveloperToolReservation(let tool, let externalSessionID):
            return "Active developer-tool identity \(tool.rawValue):\(externalSessionID) has no retirement reservation."
        case .retiredDeveloperToolCapacityExceeded:
            return "CodePulse state exceeds the retired/reserved developer-tool capacity."
        case .multipleApplicationAutomationOwners:
            return "CodePulse state contains more than one application-trigger-owned active Session."
        }
    }
}

enum AppStateIntegrityValidator {
    static func validate(_ state: AppState, at date: Date = Date()) throws {
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

        guard state.activeSessions.count <= ConcurrentSessionLimits.maximumActiveSessions else {
            throw AppStateIntegrityError.activeSessionLimitExceeded(state.activeSessions.count)
        }
        let applicationOwnerCount = state.activeSessions.filter { session in
            if case .application = session.automationMetadata?.startedBySource { return true }
            return false
        }.count
        guard applicationOwnerCount <= 1 else {
            throw AppStateIntegrityError.multipleApplicationAutomationOwners
        }

        let activeIDs = state.activeSessions.map(\.id)
        var activeIDSet = Set<UUID>()
        for id in activeIDs {
            guard activeIDSet.insert(id).inserted else {
                throw AppStateIntegrityError.duplicateActiveSessionID(id)
            }
            guard !state.completedSessions.contains(where: { $0.id == id }) else {
                throw AppStateIntegrityError.activeSessionHistoryCollision(id)
            }
        }

        let projectsByID = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
        let workspaceIDsByProjectID = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0.workspaceID) })
        for session in state.activeSessions {
            guard session.isValidConcurrentTimeline else {
                throw AppStateIntegrityError.invalidActiveSession(session.id)
            }
            if let projectID = session.projectID {
                guard let project = projectsByID[projectID] else {
                    throw AppStateIntegrityError.danglingActiveSessionProject(session.id)
                }
                guard !project.isArchived else {
                    throw AppStateIntegrityError.archivedActiveSessionProject(session.id)
                }
                guard workspaceIDSet.contains(project.workspaceID),
                      workspaceIDsByProjectID[projectID] == project.workspaceID else {
                    throw AppStateIntegrityError.invalidActiveSessionProjectWorkspace(session.id)
                }
            }
            if session.gitContext?.ambiguityConflictIDs.contains(session.id) == true {
                throw AppStateIntegrityError.selfReferentialGitAmbiguity(session.id)
            }
        }
        for session in state.completedSessions {
            if session.gitContext?.ambiguityConflictIDs.contains(session.id) == true {
                throw AppStateIntegrityError.selfReferentialGitAmbiguity(session.id)
            }
        }

        var ownershipIDs = Set<DeveloperToolThreadIdentity>()
        for session in state.activeSessions {
            if let metadata = session.automationMetadata {
                if let startedIdentity = metadata.startedBySource.developerToolThreadIdentity,
                   !startedIdentity.isValid,
                   !(startedIdentity.externalSessionID.isEmpty && metadata.claims.isEmpty) {
                    throw AppStateIntegrityError.malformedDeveloperToolOwnership
                }
                for claim in metadata.claims {
                    if let identity = claim.source.developerToolThreadIdentity,
                       !identity.isValid {
                        throw AppStateIntegrityError.malformedDeveloperToolOwnership
                    }
                }
            }
            for identity in session.developerToolOwnershipIdentities {
                guard identity.isValid else {
                    throw AppStateIntegrityError.malformedDeveloperToolOwnership
                }
                guard ownershipIDs.insert(identity).inserted else {
                    throw AppStateIntegrityError.duplicateDeveloperToolOwnership(
                        identity.tool,
                        identity.externalSessionID
                    )
                }
            }
        }

        if let processing = state.developerToolIntegration {
            var retiredIDs = Set<DeveloperToolThreadIdentity>()
            for retired in processing.retiredDeveloperToolThreads {
                guard retired.isValid else {
                    throw AppStateIntegrityError.malformedDeveloperToolOwnership
                }
                guard retiredIDs.insert(retired.identity).inserted else {
                    throw AppStateIntegrityError.duplicateRetiredDeveloperToolThread(
                        retired.tool,
                        retired.externalSessionID
                    )
                }
            }

            var reservedIDs = Set<DeveloperToolThreadIdentity>()
            for reserved in processing.reservedDeveloperToolThreads {
                guard reserved.isValid else {
                    throw AppStateIntegrityError.malformedDeveloperToolOwnership
                }
                guard reservedIDs.insert(reserved).inserted else {
                    throw AppStateIntegrityError.duplicateReservedDeveloperToolThread(
                        reserved.tool,
                        reserved.externalSessionID
                    )
                }
            }

            let protectedRetiredIDs = Set(
                processing.retiredDeveloperToolThreads
                    .filter { $0.isProtected(at: date) }
                    .map(\.identity)
            )
            guard protectedRetiredIDs.isDisjoint(with: ownershipIDs),
                  protectedRetiredIDs.isDisjoint(with: reservedIDs) else {
                throw AppStateIntegrityError.malformedDeveloperToolOwnership
            }

            for identity in reservedIDs.subtracting(ownershipIDs) {
                throw AppStateIntegrityError.orphanedDeveloperToolReservation(
                    identity.tool,
                    identity.externalSessionID
                )
            }
            for identity in ownershipIDs.subtracting(reservedIDs) {
                throw AppStateIntegrityError.missingDeveloperToolReservation(
                    identity.tool,
                    identity.externalSessionID
                )
            }
        } else if let identity = state.developerToolOwnershipIdentities.sorted(by: {
            if $0.tool != $1.tool { return $0.tool.rawValue < $1.tool.rawValue }
            return $0.externalSessionID < $1.externalSessionID
        }).first {
            throw AppStateIntegrityError.missingDeveloperToolReservation(
                identity.tool,
                identity.externalSessionID
            )
        }

        guard state.developerToolThreadCapacityUsed(at: date) <= ConcurrentSessionLimits.maximumProtectedDeveloperToolThreads else {
            throw AppStateIntegrityError.retiredDeveloperToolCapacityExceeded
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
        let workspaceID = UUID()
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

        var migrated = AppState(
            schemaVersion: CodePulseStateSchema.currentVersion,
            workspaces: [workspace],
            projects: projects.map { $0.migrated(to: workspace.id) },
            completedSessions: completedSessions,
            activeSessions: activeSession.map { [$0] } ?? [],
            settings: migratedSettings,
            sessionPresets: sessionPresets,
            developerToolIntegration: developerToolIntegration,
            automationRules: automationRules,
            controlProcessing: controlProcessing,
            localInputAcceptanceDate: localInputAcceptanceDate
        )
        migrated.seedDeveloperToolReservationsFromActiveOwnership(at: now)
        return migrated
    }
}
