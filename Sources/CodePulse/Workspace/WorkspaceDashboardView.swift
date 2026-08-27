import SwiftUI

struct WorkspaceDashboardSnapshot: Equatable {
    let workspace: WorkspaceRecord
    let activeProjectCount: Int
    let archivedProjectCount: Int
    /// Kept as a derived compatibility value for existing callers. The
    /// Dashboard renders `intelligence.resumeItems` instead.
    let recentProjects: [ProjectRecord]
    let recentSessions: [CompletedSession]
    let activeSession: ActiveSession?
    let totalTrackedDuration: TimeInterval
    let sessionCount: Int
    let projectBreakdown: [InsightsBreakdown]
    let intelligence: WorkspaceIntelligenceSnapshot
}

enum WorkspaceDashboardCalculator {
    static func snapshot(
        state: AppState,
        calendar: Calendar,
        referenceDate: Date,
        workspaceID: UUID,
        timeframe: InsightsTimeframe = .last30Days
    ) -> WorkspaceDashboardSnapshot? {
        guard let workspace = state.workspaces.first(where: { $0.id == workspaceID }) else {
            return nil
        }
        let projects = state.projects.filter { $0.workspaceID == workspaceID }
        let projectIDs = Set(projects.map(\.id))
        let recentProjects = projects
            .sorted { lhs, rhs in
                let lhsDate = lhs.lastUsedAt ?? lhs.createdAt
                let rhsDate = rhs.lastUsedAt ?? rhs.createdAt
                if lhsDate != rhsDate { return lhsDate > rhsDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(5)
        let recentSessions = state.completedSessions
            .filter { session in
                guard let projectID = session.projectID else { return false }
                return projectIDs.contains(projectID)
            }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .prefix(5)
        let activeSession: ActiveSession? = state.activeSession.flatMap { session in
            guard let projectID = session.projectID, projectIDs.contains(projectID) else { return nil }
            return session
        }
        let summary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: referenceDate,
            timeframe: timeframe,
            workspace: .workspaceID(workspaceID)
        )
        guard let intelligence = WorkspaceIntelligenceCalculator.snapshot(
            state: state,
            workspaceID: workspaceID,
            summary: summary,
            referenceDate: referenceDate
        ) else {
            return nil
        }
        return WorkspaceDashboardSnapshot(
            workspace: workspace,
            activeProjectCount: projects.filter(\.isActive).count,
            archivedProjectCount: projects.filter(\.isArchived).count,
            recentProjects: Array(recentProjects),
            recentSessions: Array(recentSessions),
            activeSession: activeSession,
            totalTrackedDuration: summary.totalDuration,
            sessionCount: summary.sessionCount,
            projectBreakdown: summary.projectBreakdown,
            intelligence: intelligence
        )
    }
}

/// A compact, read-only view of the selected workspace. All numbers come from
/// the existing project/session and Insights pipelines; no workspace-level
/// analytics are persisted.
struct WorkspaceDashboardView: View {
    @EnvironmentObject private var store: SessionStore

    private let timeframe: InsightsTimeframe = .last30Days

    var body: some View {
        Group {
            if let snapshot = dashboardSnapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header(snapshot)
                        overview(snapshot)
                        if let activeSession = snapshot.activeSession {
                            activeSessionContext(activeSession)
                        }
                        resumeContext(snapshot)
                        continuationHints(snapshot)
                        patterns(snapshot)
                        recentSessions(snapshot)
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text("No Workspace")
                        .font(.headline)
                    Text("Create a Workspace in Settings to see its dashboard.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Workspace Dashboard")
        .frame(minWidth: 620, minHeight: 520)
        .accessibilityIdentifier("workspace-dashboard")
    }

    private var dashboardSnapshot: WorkspaceDashboardSnapshot? {
        guard let workspaceID = store.selectedWorkspaceID else { return nil }
        return WorkspaceDashboardCalculator.snapshot(
            state: store.state,
            calendar: store.calendar,
            referenceDate: store.now,
            workspaceID: workspaceID,
            timeframe: timeframe
        )
    }

    @ViewBuilder
    private func header(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(snapshot.workspace.name, systemImage: "square.grid.2x2")
                .font(.title2.weight(.semibold))
                .accessibilityLabel("Workspace Dashboard for \(snapshot.workspace.name)")
            Text("Activity across this Workspace's Projects · Last 30 Days")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func overview(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        Group {
            if snapshot.activeProjectCount == 0,
               snapshot.archivedProjectCount == 0,
               snapshot.sessionCount == 0,
               snapshot.activeSession == nil {
                Text("No recorded Workspace activity yet.")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("workspace-empty-state")
            } else {
                HStack(spacing: 12) {
                    dashboardMetric("Active Projects", value: snapshot.activeProjectCount.formatted(), identifier: "active-projects")
                    dashboardMetric("Archived Projects", value: snapshot.archivedProjectCount.formatted(), identifier: "archived-projects")
                    dashboardMetric("Tracked Time", value: CodePulseFormatting.duration(snapshot.totalTrackedDuration), identifier: "tracked-time")
                    dashboardMetric("Sessions", value: snapshot.sessionCount.formatted(), identifier: "sessions")
                }
            }
        }
    }

    @ViewBuilder
    private func dashboardMetric(_ title: String, value: String, identifier: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier.map { "workspace-metric-\($0)" } ?? "workspace-metric")
    }

    @ViewBuilder
    private func resumeContext(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Resume Context")
                .font(.headline)
                .accessibilityIdentifier("workspace-resume-context")
            if snapshot.intelligence.resumeItems.isEmpty {
                if snapshot.activeProjectCount > 0 {
                    Text("Finish a Project session to build local resume context.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("No active Projects with completed history yet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(snapshot.intelligence.resumeItems) { item in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            Text(item.projectName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Spacer()
                            Text("Last worked \(CodePulseFormatting.day(item.lastActivityAt, calendar: store.calendar)) · \(CodePulseFormatting.time(item.lastActivityAt))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 8) {
                            Label(item.latestSessionType.title, systemImage: item.latestSessionType.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let branch = item.gitBranch {
                                Label(branch, systemImage: "arrow.triangle.branch")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            if let pullRequest = item.githubPullRequest {
                                Label("PR #\(pullRequest.number)", systemImage: "arrow.triangle.pull")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        if let goal = item.goal {
                            Text("Goal: \(goal)")
                                .lineLimit(2)
                        }
                        if let outcome = item.outcome {
                            Text("Last recorded outcome: \(outcome)")
                                .lineLimit(2)
                                .foregroundStyle(.secondary)
                        } else if item.goal != nil {
                            Text("Outcome not recorded")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let developerTool = item.developerToolContext {
                            Text(developerTool)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("workspace-resume-card-\(item.projectID.uuidString)")
                }
            }
        }
    }

    @ViewBuilder
    private func recentSessions(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Completed Sessions")
                .font(.headline)
            if snapshot.recentSessions.isEmpty {
                Text("No completed sessions in this Workspace yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.recentSessions) { session in
                    HStack(spacing: 8) {
                        Text(session.projectName ?? "No Project")
                            .lineLimit(1)
                        Spacer()
                        Text(CodePulseFormatting.duration(session.activeDuration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text("\(CodePulseFormatting.day(session.startedAt, calendar: store.calendar)) · \(CodePulseFormatting.time(session.startedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func continuationHints(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        if !snapshot.intelligence.continuationHints.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Continuation Hints")
                    .font(.headline)
                    .accessibilityIdentifier("workspace-continuation-hints")
                ForEach(snapshot.intelligence.continuationHints) { hint in
                    Label(hint.message, systemImage: hint.kind.systemImage)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workspace-continuation-hint-\(hint.id)")
                }
            }
        }
    }

    @ViewBuilder
    private func patterns(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        let patterns = snapshot.intelligence.patterns
        VStack(alignment: .leading, spacing: 8) {
            Text("Workspace Patterns")
                .font(.headline)
                .accessibilityIdentifier("workspace-patterns")
            if patterns.projectBreakdown.isEmpty {
                Text("No tracked activity in the last 30 days.")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    dashboardMetric("Projects Touched", value: patterns.projectsTouched.formatted(), identifier: "projects-touched")
                    dashboardMetric(
                        "Largest Time Share",
                        value: patterns.largestProjectTimeShare.map { Self.percent($0) } ?? "Unavailable",
                        identifier: "largest-time-share"
                    )
                    dashboardMetric("Rapid Project Switches", value: patterns.rapidProjectSwitches.formatted(), identifier: "rapid-project-switches")
                    if let sustained = patterns.sustainedFocusShare {
                        dashboardMetric("Sustained Focus", value: Self.percent(sustained), identifier: "sustained-focus")
                    } else {
                        dashboardMetric("Sustained Focus", value: "Unavailable", identifier: "sustained-focus")
                    }
                }
                ForEach(patterns.projectBreakdown.prefix(8)) { item in
                    HStack(spacing: 8) {
                        Text(item.label)
                            .lineLimit(1)
                        Spacer()
                        Text(CodePulseFormatting.duration(item.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func activeSessionContext(_ session: ActiveSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Active Session")
                .font(.headline)
                .accessibilityIdentifier("workspace-active-session")
            HStack(spacing: 8) {
                Image(systemName: "play.circle.fill")
                    .foregroundStyle(.green)
                Text(session.projectName ?? "No Project")
                    .lineLimit(1)
                Text(session.type.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(CodePulseFormatting.duration(session.activeDuration(at: store.now), includeSeconds: true))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", max(0, min(value, 1)) * 100)
    }

}

private extension WorkspaceContinuationHint.Kind {
    var systemImage: String {
        switch self {
        case .outcomeFollowUp: return "text.badge.checkmark"
        case .resumeRecentProject: return "clock.arrow.circlepath"
        case .recentCodeContext: return "arrow.triangle.branch"
        }
    }
}
