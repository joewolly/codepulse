import SwiftUI

struct WorkspaceDashboardSnapshot: Equatable {
    let workspace: WorkspaceRecord
    let activeProjectCount: Int
    let archivedProjectCount: Int
    let recentProjects: [ProjectRecord]
    let recentSessions: [CompletedSession]
    let activeSession: ActiveSession?
    let totalTrackedDuration: TimeInterval
    let sessionCount: Int
    let projectBreakdown: [InsightsBreakdown]
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
        return WorkspaceDashboardSnapshot(
            workspace: workspace,
            activeProjectCount: projects.filter(\.isActive).count,
            archivedProjectCount: projects.filter(\.isArchived).count,
            recentProjects: Array(recentProjects),
            recentSessions: Array(recentSessions),
            activeSession: activeSession,
            totalTrackedDuration: summary.totalDuration,
            sessionCount: summary.sessionCount,
            projectBreakdown: summary.projectBreakdown
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
                        recentProjects(snapshot)
                        recentSessions(snapshot)
                        if let activeSession = snapshot.activeSession {
                            activeSessionContext(activeSession)
                        }
                        distribution(snapshot)
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
        HStack(spacing: 12) {
            dashboardMetric("Active Projects", value: snapshot.activeProjectCount.formatted())
            dashboardMetric("Archived Projects", value: snapshot.archivedProjectCount.formatted())
            dashboardMetric("Tracked Time", value: CodePulseFormatting.duration(snapshot.totalTrackedDuration))
            dashboardMetric("Sessions", value: snapshot.sessionCount.formatted())
        }
    }

    @ViewBuilder
    private func dashboardMetric(_ title: String, value: String) -> some View {
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
    }

    @ViewBuilder
    private func recentProjects(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent Projects")
                .font(.headline)
            if snapshot.recentProjects.isEmpty {
                Text("No Projects in this Workspace yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.recentProjects) { project in
                    HStack(spacing: 8) {
                        Image(systemName: project.isArchived ? "archivebox" : "folder")
                            .foregroundStyle(.secondary)
                        Text(project.name)
                            .lineLimit(1)
                        Spacer()
                        if project.isArchived {
                            Text("Archived")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
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
    private func distribution(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project Distribution")
                .font(.headline)
            if snapshot.projectBreakdown.isEmpty {
                Text("No tracked activity in the last 30 days.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(snapshot.projectBreakdown.prefix(8)) { item in
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

}
