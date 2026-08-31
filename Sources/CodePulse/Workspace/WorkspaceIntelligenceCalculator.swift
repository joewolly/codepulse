import Foundation

/// Derived, presentation-only observations for one Workspace's Dashboard
/// window. This type deliberately contains no persisted Workspace state.
struct WorkspaceActivityPatterns: Equatable {
    let projectsTouched: Int
    let projectBreakdown: [InsightsBreakdown]
    let largestProjectTimeShare: Double?
    let rapidProjectSwitches: Int
    let sustainedFocusShare: Double?

    var projectCount: Int { projectsTouched }
    var projectTimeAllocation: [InsightsBreakdown] { projectBreakdown }
    var largestProjectShare: Double? { largestProjectTimeShare }
    var rapidProjectSwitchCount: Int { rapidProjectSwitches }

    var hasActivity: Bool {
        !projectBreakdown.isEmpty || rapidProjectSwitches > 0 || sustainedFocusShare != nil
    }
}

/// Locally recorded context for returning to one active Project. The latest
/// completed session is selected deterministically by the calculator.
struct WorkspaceResumeItem: Equatable, Identifiable {
    let projectID: UUID
    let projectName: String
    let lastActivityAt: Date
    let latestSessionID: UUID
    let latestSessionType: SessionType
    let goal: String?
    let outcome: String?
    let hasUnrecordedOutcome: Bool
    let gitBranch: String?
    let githubPullRequest: GitHubPullRequestSnapshot?
    let githubRepositoryNameWithOwner: String?
    let developerToolContext: String?

    var id: UUID { projectID }
    var latestSessionTypeTitle: String { latestSessionType.title }
    var hasCodeContext: Bool { gitBranch != nil || githubPullRequest != nil }
    var outcomeIsMissing: Bool { hasUnrecordedOutcome }

    var pullRequestNumber: Int? { githubPullRequest?.number }
    var pullRequestTitle: String? { githubPullRequest?.title }
}

struct WorkspaceContinuationHint: Equatable, Identifiable {
    enum Kind: String, Equatable, Hashable {
        case outcomeFollowUp
        case resumeRecentProject
        case recentCodeContext
    }

    let id: String
    let kind: Kind
    let message: String
    let projectID: UUID
    let sessionID: UUID

    init(
        kind: Kind,
        message: String,
        projectID: UUID,
        sessionID: UUID,
        contextKey: String? = nil
    ) {
        self.kind = kind
        self.message = message
        self.projectID = projectID
        self.sessionID = sessionID
        let suffix = contextKey.map { ":\($0)" } ?? ""
        self.id = "\(kind.rawValue):\(projectID.uuidString):\(sessionID.uuidString)\(suffix)"
    }
}

struct WorkspaceIntelligenceSnapshot: Equatable {
    let patterns: WorkspaceActivityPatterns
    let resumeItems: [WorkspaceResumeItem]
    let continuationHints: [WorkspaceContinuationHint]

    var hasActivity: Bool { patterns.hasActivity || !resumeItems.isEmpty }
    var resumeContext: [WorkspaceResumeItem] { resumeItems }
    var hints: [WorkspaceContinuationHint] { continuationHints }
}

enum WorkspaceIntelligenceCalculator {
    static let dashboardTimeframe: InsightsTimeframe = .last30Days
    static let resumeItemLimit = 4
    static let continuationHintLimit = 3

    /// Calculates Workspace intelligence for an explicit Workspace ID. The
    /// selected Workspace setting is intentionally not consulted.
    static func snapshot(
        state: AppState,
        calendar: Calendar,
        referenceDate: Date,
        workspaceID: UUID,
        timeframe: InsightsTimeframe = dashboardTimeframe
    ) -> WorkspaceIntelligenceSnapshot? {
        guard state.workspaces.contains(where: { $0.id == workspaceID }) else {
            return nil
        }
        let summary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: referenceDate,
            timeframe: timeframe,
            workspace: .workspaceID(workspaceID)
        )
        return snapshot(
            state: state,
            workspaceID: workspaceID,
            summary: summary,
            referenceDate: referenceDate
        )
    }

    /// Dashboard integration point. The caller supplies the already-computed
    /// shared Insights summary so duration/focus work is not repeated.
    static func snapshot(
        state: AppState,
        workspaceID: UUID,
        summary: InsightsSummary,
        referenceDate: Date
    ) -> WorkspaceIntelligenceSnapshot? {
        guard state.workspaces.contains(where: { $0.id == workspaceID }) else {
            return nil
        }

        let projects = state.projects.filter { $0.workspaceID == workspaceID }
        let projectIDs = Set(projects.map(\.id))
        let patterns = WorkspaceActivityPatterns(
            projectsTouched: summary.projectBreakdown.count,
            projectBreakdown: summary.projectBreakdown,
            largestProjectTimeShare: largestProjectTimeShare(
                from: summary.projectBreakdown,
                totalDuration: summary.sessionActivity
            ),
            rapidProjectSwitches: summary.focusInsights.projectSwitchCount,
            sustainedFocusShare: summary.focusInsights.sustainedFocusShare
        )

        let activeProjectIDs = Set<UUID>(
            state.activeSessions.compactMap { active in
                guard let projectID = active.projectID, projectIDs.contains(projectID) else {
                    return nil
                }
                return projectID
            }
        )
        let allResumeItems = resumeItems(
            state: state,
            projects: projects,
            excluding: activeProjectIDs
        )
        let resumeItems = Array(allResumeItems.prefix(resumeItemLimit))
        let followUpCandidate = followUpCandidate(
            state: state,
            projects: projects,
            excluding: activeProjectIDs
        )
        let continuationHints = continuationHints(
            resumeItems: allResumeItems,
            followUpCandidate: followUpCandidate,
            hasActiveWorkspaceSession: !activeProjectIDs.isEmpty
        )

        return WorkspaceIntelligenceSnapshot(
            patterns: patterns,
            resumeItems: resumeItems,
            continuationHints: continuationHints
        )
    }

    private static func largestProjectTimeShare(
        from breakdown: [InsightsBreakdown],
        totalDuration: TimeInterval
    ) -> Double? {
        guard totalDuration > 0,
              let largest = breakdown.max(by: { lhs, rhs in
                  if lhs.duration != rhs.duration { return lhs.duration < rhs.duration }
                  return lhs.id > rhs.id
              }) else {
            return nil
        }
        return largest.duration / totalDuration
    }

    private static func resumeItems(
        state: AppState,
        projects: [ProjectRecord],
        excluding activeProjectIDs: Set<UUID>
    ) -> [WorkspaceResumeItem] {
        let activeProjects = projects.filter { project in
            project.isActive && !activeProjectIDs.contains(project.id)
        }

        return activeProjects.compactMap { project in
            let latest = state.completedSessions
                .filter { $0.projectID == project.id }
                .sorted(by: latestSessionPrecedes)
                .first
            guard let latest else { return nil }

            let goal = MeaningfulText.normalized(latest.goal)
            let outcome = MeaningfulText.normalized(latest.outcome)
            let developerToolContext = latest.developerToolContexts
                .sorted { lhs, rhs in
                    if lhs.lastActivityAt != rhs.lastActivityAt {
                        return lhs.lastActivityAt > rhs.lastActivityAt
                    }
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                .first?
                .displayName

            return WorkspaceResumeItem(
                projectID: project.id,
                projectName: project.name,
                lastActivityAt: latest.endedAt,
                latestSessionID: latest.id,
                latestSessionType: latest.type,
                goal: goal,
                outcome: outcome,
                hasUnrecordedOutcome: goal != nil && outcome == nil,
                gitBranch: MeaningfulText.normalized(latest.gitContext?.branchDisplay),
                githubPullRequest: latest.githubContext?.pullRequest,
                githubRepositoryNameWithOwner: MeaningfulText.normalized(
                    latest.githubContext?.repositoryNameWithOwner
                ),
                developerToolContext: MeaningfulText.normalized(developerToolContext)
            )
        }
        .sorted { lhs, rhs in
            if lhs.lastActivityAt != rhs.lastActivityAt {
                return lhs.lastActivityAt > rhs.lastActivityAt
            }
            if lhs.latestSessionID != rhs.latestSessionID {
                return lhs.latestSessionID.uuidString < rhs.latestSessionID.uuidString
            }
            return lhs.projectID.uuidString < rhs.projectID.uuidString
        }
        .map { $0 }
    }

    private static func latestSessionPrecedes(
        _ lhs: CompletedSession,
        _ rhs: CompletedSession
    ) -> Bool {
        if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private struct FollowUpCandidate {
        let projectID: UUID
        let projectName: String
        let sessionID: UUID
        let endedAt: Date
    }

    private static func followUpCandidate(
        state: AppState,
        projects: [ProjectRecord],
        excluding activeProjectIDs: Set<UUID>
    ) -> FollowUpCandidate? {
        let candidates = projects.filter { project in
            project.isActive && !activeProjectIDs.contains(project.id)
        }
        let projectsByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        return state.completedSessions
            .compactMap { session -> FollowUpCandidate? in
                guard let projectID = session.projectID,
                      let project = projectsByID[projectID],
                      MeaningfulText.normalized(session.goal) != nil,
                      MeaningfulText.normalized(session.outcome) == nil else {
                    return nil
                }
                return FollowUpCandidate(
                    projectID: projectID,
                    projectName: project.name,
                    sessionID: session.id,
                    endedAt: session.endedAt
                )
            }
            .sorted { lhs, rhs in
                if lhs.endedAt != rhs.endedAt { return lhs.endedAt > rhs.endedAt }
                return lhs.sessionID.uuidString < rhs.sessionID.uuidString
            }
            .first
    }

    private static func continuationHints(
        resumeItems: [WorkspaceResumeItem],
        followUpCandidate: FollowUpCandidate?,
        hasActiveWorkspaceSession: Bool
    ) -> [WorkspaceContinuationHint] {
        guard !resumeItems.isEmpty else { return [] }

        var hints: [WorkspaceContinuationHint] = []
        var usedEvidence: Set<String> = []

        // Priority 1: the newest recorded goal without a recorded outcome.
        if let followUp = followUpCandidate {
            hints.append(
                WorkspaceContinuationHint(
                    kind: .outcomeFollowUp,
                    message: "CodePulse has a recent goal for \(followUp.projectName) without a recorded outcome.",
                    projectID: followUp.projectID,
                    sessionID: followUp.sessionID
                )
            )
            usedEvidence.insert("\(followUp.projectID.uuidString):\(followUp.sessionID.uuidString)")
        }

        // Priority 2: only when no Project in this Workspace owns the active
        // session. Suppress a duplicate based on the same latest session.
        if !hasActiveWorkspaceSession,
           let recent = resumeItems.first,
           !usedEvidence.contains(evidenceKey(for: recent)) {
            hints.append(
                WorkspaceContinuationHint(
                    kind: .resumeRecentProject,
                    message: "\(recent.projectName) was the most recently active Project in this Workspace.",
                    projectID: recent.projectID,
                    sessionID: recent.latestSessionID
                )
            )
            usedEvidence.insert(evidenceKey(for: recent))
        }

        // Priority 3: branch or PR context is evidence in its own right. A
        // code-context hint may share a session with a follow-up hint, but it
        // is emitted only once and never claims current/live repository state.
        if let context = resumeItems.first(where: { $0.hasCodeContext }) {
            let contextLabel: String
            let contextKey: String
            if let pullRequest = context.githubPullRequest {
                contextLabel = "PR #\(pullRequest.number) was associated with the last recorded session for \(context.projectName)."
                contextKey = "pr-\(pullRequest.number)"
            } else if let branch = context.gitBranch {
                contextLabel = "The last recorded \(context.projectName) session used branch \(branch)."
                contextKey = "branch-\(branch)"
            } else {
                contextLabel = "The last recorded session for \(context.projectName) included code context."
                contextKey = "code-context"
            }
            hints.append(
                WorkspaceContinuationHint(
                    kind: .recentCodeContext,
                    message: contextLabel,
                    projectID: context.projectID,
                    sessionID: context.latestSessionID,
                    contextKey: contextKey
                )
            )
        }

        return Array(hints.prefix(continuationHintLimit))
    }

    private static func evidenceKey(for item: WorkspaceResumeItem) -> String {
        "\(item.projectID.uuidString):\(item.latestSessionID.uuidString)"
    }
}
