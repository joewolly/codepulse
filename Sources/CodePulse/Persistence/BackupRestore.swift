import Foundation

enum CodePulseBackupValidator {
    static func validate(_ state: AppState) throws {
        try validateUniqueIDs(state.projects.map(\.id), field: "project")
        try validateUniqueIDs(state.completedSessions.map(\.id), field: "session")
        try validateUniqueIDs(state.sessionPresets.map(\.id), field: "preset")
        try validateUniqueIDs(state.automationRules.map(\.id), field: "automation rule")

        if let activeID = state.activeSession?.id,
           state.completedSessions.contains(where: { $0.id == activeID }) {
            throw CodePulseBackupError.duplicateIdentifier("session")
        }

        for session in state.completedSessions {
            try validateCompletedSession(session)
        }
        if let activeSession = state.activeSession {
            try validateActiveSession(activeSession)
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
        for interval in intervals {
            guard interval.startedAt >= start else {
                throw CodePulseBackupError.invalidTimeline
            }
            if let endedAt = interval.endedAt {
                guard endedAt >= interval.startedAt,
                      end.map({ endedAt <= $0 }) ?? true else {
                    throw CodePulseBackupError.invalidTimeline
                }
            } else {
                openCount += 1
                guard allowsOpenInterval else {
                    throw CodePulseBackupError.invalidTimeline
                }
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
}

enum BackupRestoreNormalizer {
    static func normalize(
        _ state: AppState,
        preservingLaunchAtLogin launchAtLogin: Bool
    ) throws -> AppState {
        try CodePulseBackupValidator.validate(state)

        var restored = state
        restored.settings.launchAtLogin = launchAtLogin
        restored.settings.automationEnabled = false
        restored.controlProcessing = nil
        restored.developerToolIntegration = nil

        if var activeSession = restored.activeSession,
           var metadata = activeSession.automationMetadata {
            // The timeline and captured contexts are portable. Claims and
            // pending lifecycle work belong to the machine that created them.
            metadata.controlEnabled = false
            metadata.pendingAutomaticSave = false
            metadata.claims = []
            activeSession.automationMetadata = metadata
            restored.activeSession = activeSession
        }

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
            guard let projectID = restored.settings.specificProjectID,
                  let project = restored.projects.first(where: { $0.id == projectID }),
                  !project.requiresRelink else {
                restored.settings.defaultProjectBehavior = .lastUsed
                restored.settings.specificProjectID = nil
                return restored
            }
        case .lastUsed, .noProject:
            restored.settings.specificProjectID = nil
        }

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
