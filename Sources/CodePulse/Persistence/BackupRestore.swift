import Foundation

enum CodePulseBackupValidator {
    static func validate(_ state: AppState) throws {
        try validateWorkspaceGraph(state)
        try validateUniqueIDs(state.projects.map(\.id), field: "project")
        try validateUniqueIDs(state.completedSessions.map(\.id), field: "session")
        try validateUniqueIDs(state.sessionPresets.map(\.id), field: "preset")
        try validateUniqueIDs(state.automationRules.map(\.id), field: "automation rule")

        try validateUniqueIDs(state.activeSessions.map(\.id), field: "session")
        if state.activeSessions.contains(where: { active in
            state.completedSessions.contains(where: { $0.id == active.id })
        }) {
            throw CodePulseBackupError.duplicateIdentifier("session")
        }

        for session in state.completedSessions {
            try validateCompletedSession(session)
        }
        for activeSession in state.activeSessions {
            try validateActiveSession(activeSession)
            if let projectID = activeSession.projectID {
                guard let project = state.projects.first(where: { $0.id == projectID }),
                      !project.isArchived,
                      state.workspaces.contains(where: { $0.id == project.workspaceID }) else {
                    throw CodePulseBackupError.invalidWorkspaceReference
                }
            }
        }

        do {
            try AppStateIntegrityValidator.validate(state)
        } catch let error as AppStateIntegrityError {
            switch error {
            case .duplicateActiveSessionID, .activeSessionHistoryCollision:
                throw CodePulseBackupError.duplicateIdentifier("session")
            case .activeSessionLimitExceeded,
                 .invalidActiveSession,
                 .danglingActiveSessionProject,
                 .archivedActiveSessionProject,
                 .invalidActiveSessionProjectWorkspace,
                 .duplicateDeveloperToolOwnership,
                 .malformedDeveloperToolOwnership,
                 .duplicateRetiredDeveloperToolThread,
                 .duplicateReservedDeveloperToolThread,
                 .missingDeveloperToolReservation,
                 .orphanedDeveloperToolReservation:
                throw CodePulseBackupError.invalidTimeline
            default:
                throw CodePulseBackupError.invalidWorkspaceReference
            }
        }
    }

    private static func validateCompletedSession(_ session: CompletedSession) throws {
        guard session.endedAt >= session.startedAt else {
            throw CodePulseBackupError.invalidTimeline
        }
        try validatePauseIntervals(
            session.pauseIntervals,
            start: session.startedAt,
            end: session.endedAt,
            allowsOpenInterval: false,
            requiresOpenInterval: false
        )
    }

    private static func validateActiveSession(_ session: ActiveSession) throws {
        switch session.phase {
        case .idle:
            throw CodePulseBackupError.invalidTimeline
        case .running, .paused:
            guard session.endedAt == nil else {
                throw CodePulseBackupError.invalidTimeline
            }
        case .finishing:
            guard let endedAt = session.endedAt, endedAt >= session.startedAt else {
                throw CodePulseBackupError.invalidTimeline
            }
        }

        let end = session.endedAt
        let allowsOpenInterval = session.phase == .paused
        let requiresOpenInterval = session.phase == .paused
        try validatePauseIntervals(
            session.pauseIntervals,
            start: session.startedAt,
            end: end,
            allowsOpenInterval: allowsOpenInterval,
            requiresOpenInterval: requiresOpenInterval
        )
    }

    private static func validatePauseIntervals(
        _ intervals: [PauseInterval],
        start: Date,
        end: Date?,
        allowsOpenInterval: Bool,
        requiresOpenInterval: Bool
    ) throws {
        try validateUniqueIDs(intervals.map(\.id), field: "pause interval")
        var openCount = 0
        var previousEnd: Date?
        var previousIntervalIsOpen = false
        for interval in intervals.sorted(by: { $0.startedAt < $1.startedAt }) {
            guard interval.startedAt >= start else {
                throw CodePulseBackupError.invalidTimeline
            }
            guard !previousIntervalIsOpen,
                  previousEnd.map({ interval.startedAt >= $0 }) ?? true else {
                throw CodePulseBackupError.invalidTimeline
            }
            if let endedAt = interval.endedAt {
                guard endedAt >= interval.startedAt,
                      end.map({ endedAt <= $0 }) ?? true else {
                    throw CodePulseBackupError.invalidTimeline
                }
                previousEnd = endedAt
                previousIntervalIsOpen = false
            } else {
                openCount += 1
                guard allowsOpenInterval else {
                    throw CodePulseBackupError.invalidTimeline
                }
                previousEnd = nil
                previousIntervalIsOpen = true
            }
            if let end, interval.startedAt > end {
                throw CodePulseBackupError.invalidTimeline
            }
        }

        guard openCount <= 1,
              !requiresOpenInterval || openCount == 1 else {
            throw CodePulseBackupError.invalidTimeline
        }
    }

    private static func validateUniqueIDs(_ ids: [UUID], field: String) throws {
        guard Set(ids).count == ids.count else {
            throw CodePulseBackupError.duplicateIdentifier(field)
        }
    }

    private static func validateWorkspaceGraph(_ state: AppState) throws {
        guard state.schemaVersion == CodePulseStateSchema.currentVersion,
              !state.workspaces.isEmpty else {
            throw CodePulseBackupError.invalidWorkspaceReference
        }
        try validateUniqueIDs(state.workspaces.map(\.id), field: "workspace")
        let workspaceIDs = Set(state.workspaces.map(\.id))
        for project in state.projects {
            guard workspaceIDs.contains(project.workspaceID) else {
                throw CodePulseBackupError.invalidWorkspaceReference
            }
        }
    }
}

enum BackupRestoreNormalizer {
    static func normalize(
        _ state: AppState,
        preservingLaunchAtLogin launchAtLogin: Bool
    ) throws -> AppState {
        var restored = state
        // A portable backup intentionally omits machine-local reservations.
        // Recreate them from the persisted active ownership metadata at this
        // controlled restore boundary before validating the candidate.
        restored.seedDeveloperToolReservationsFromActiveOwnership()
        AppStateIntegrityValidator.normalizeSelectedWorkspace(in: &restored)
        try CodePulseBackupValidator.validate(restored)
        restored.settings.launchAtLogin = launchAtLogin
        restored.settings.automationEnabled = false
        // Onboarding is informational machine state. Restoring local data
        // must never turn that data replacement into a mandatory first-run
        // flow, including when a backup was exported before the flag existed.
        restored.settings.hasCompletedOnboarding = true
        restored.controlProcessing = nil
        restored.developerToolIntegration = nil
        restored.localInputAcceptanceDate = nil

        for index in restored.activeSessions.indices {
            var activeSession = restored.activeSessions[index]
            guard var metadata = activeSession.automationMetadata else { continue }
            // The timeline and captured contexts are portable. Claims and
            // pending lifecycle work belong to the machine that created them,
            // but ownership-bearing claims remain as inactive metadata so a
            // restored active Session cannot silently release a Thread.
            metadata.controlEnabled = false
            metadata.pendingAutomaticSave = false
            metadata.claims = metadata.claims.map { claim in
                var claim = claim
                claim.isActive = false
                return claim
            }
            activeSession.automationMetadata = metadata
            restored.activeSessions[index] = activeSession
        }

        // Reset local ledgers, then immediately account for any ownership that
        // remains on imported active Sessions. This keeps the candidate valid
        // for the transactional replacement below.
        restored.seedDeveloperToolReservationsFromActiveOwnership()

        restored.automationRules = restored.automationRules.map { rule in
            var normalized = rule.canonicalized()
            guard normalized.isValid,
                  let preset = restored.sessionPresets.first(where: { $0.id == normalized.presetID }),
                  preset.isValid,
                  let projectID = preset.projectID,
                  let project = restored.projects.first(where: { $0.id == projectID }),
                  !project.requiresRelink else {
                normalized.isEnabled = false
                return normalized
            }
            return normalized
        }

        switch restored.settings.defaultProjectBehavior {
        case .specificProject:
            let selectedProjectIsValid: Bool = {
                guard let projectID = restored.settings.specificProjectID,
                      let project = restored.projects.first(where: { $0.id == projectID }) else {
                    return false
                }
                return project.isActive && !project.requiresRelink
            }()
            guard selectedProjectIsValid else {
                restored.settings.defaultProjectBehavior = .lastUsed
                restored.settings.specificProjectID = nil
                break
            }
        case .lastUsed, .noProject:
            restored.settings.specificProjectID = nil
        }

        try AppStateIntegrityValidator.validate(restored)
        return restored
    }
}

struct BackupRestoreCandidate {
    let backup: CodePulseBackup
    let state: AppState
    let preview: CodePulseBackupPreview
}

struct BackupRestoreResult {
    let preview: CodePulseBackupPreview
    let recoveryBackupURL: URL
}

enum BackupRestoreError: LocalizedError {
    case activeSession
    case fileUnreadable
    case persistenceUnavailable
    case persistence(StatePersistenceError)

    var errorDescription: String? {
        switch self {
        case .activeSession:
            return "Finish or discard the current session before restoring a backup."
        case .fileUnreadable:
            return "CodePulse could not read the selected backup file."
        case .persistenceUnavailable:
            return "CodePulse cannot safely restore data using the current persistence store."
        case .persistence(let error):
            return error.localizedDescription
        }
    }
}
