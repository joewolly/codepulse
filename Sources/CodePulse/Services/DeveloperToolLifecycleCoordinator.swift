import CodePulseIntegration
import Foundation

protocol DeveloperToolLifecycleCoordinating {
    func apply(
        _ event: DeveloperEventV2,
        sessionFingerprint: String,
        to state: inout AppState
    ) -> Bool

    func reconcile(state: inout AppState, now: Date) -> Bool
}

/// Owns the activity-graph effects of validated developer-tool lifecycle
/// events. The inbox remains the trust boundary; this coordinator receives
/// only normalized metadata and never reads hook bodies or integration files.
struct DeveloperToolLifecycleCoordinator: DeveloperToolLifecycleCoordinating {
    func apply(
        _ event: DeveloperEventV2,
        sessionFingerprint: String,
        to state: inout AppState
    ) -> Bool {
        guard event.integration == .codex,
              event.eventKind != .integrationError else {
            return false
        }

        if let runIndex = state.activityGraph.runs.firstIndex(where: {
            $0.kind == .agent &&
            $0.agentMetadata?.integration == event.integration &&
            $0.agentMetadata?.sessionFingerprint == sessionFingerprint
        }) {
            return AgentRunLifecycle.apply(
                event,
                to: &state.activityGraph.runs[runIndex],
                reviewGrace: TimeInterval(state.settings.agentReviewGraceSeconds)
            )
        }

        // A terminal event without a previously observed run cannot establish
        // trustworthy timing. Preserve its redacted diagnostic only.
        guard event.eventKind == .sessionStarted ||
                event.eventKind == .activityObserved ||
                event.eventKind == .permissionRequested,
              let workspaceIndex = matchingWorkspaceIndex(for: event, in: state.activityGraph) else {
            return false
        }

        let workspaceID = state.activityGraph.workspaces[workspaceIndex].id
        state.activityGraph.workspaces[workspaceIndex].updatedAt = max(
            state.activityGraph.workspaces[workspaceIndex].updatedAt,
            event.observedAt
        )

        let activity = Activity(
            workspaceID: workspaceID,
            title: "Codex session",
            createdAt: event.observedAt
        )
        state.activityGraph.activities.append(activity)

        var run = Run(
            activityID: activity.id,
            kind: .agent,
            startedAt: event.observedAt,
            agentMetadata: AgentRunMetadata(
                integration: event.integration,
                sessionFingerprint: sessionFingerprint,
                lastEventAt: event.observedAt
            )
        )
        guard AgentRunLifecycle.apply(
            event,
            to: &run,
            reviewGrace: TimeInterval(state.settings.agentReviewGraceSeconds)
        ) else {
            return false
        }
        state.activityGraph.runs.append(run)
        return true
    }

    func reconcile(state: inout AppState, now: Date) -> Bool {
        ActivityGraphRepository.reconcileAgentRuns(in: &state.activityGraph, now: now)
    }

    private func matchingWorkspaceIndex(
        for event: DeveloperEventV2,
        in graph: ActivityGraph
    ) -> Int? {
        graph.workspaces.indices
            .filter { workspaceIndex in
                graph.workspaces[workspaceIndex].roots.contains { root in
                    DeveloperToolProjectPathMatcher.matches(
                        projectPath: root.path,
                        workingDirectory: event.workingDirectory
                    )
                }
            }
            .max { lhs, rhs in
                let lhsLength = graph.workspaces[lhs].roots.map(\.path.count).max() ?? 0
                let rhsLength = graph.workspaces[rhs].roots.map(\.path.count).max() ?? 0
                return lhsLength < rhsLength
            }
    }
}
