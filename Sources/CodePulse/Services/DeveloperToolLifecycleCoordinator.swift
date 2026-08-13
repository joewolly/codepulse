import CodePulseIntegration
import Foundation

protocol DeveloperToolLifecycleCoordinating {
    func apply(
        _ event: DeveloperEventV2,
        sessionFingerprint: String,
        parentSessionFingerprint: String?,
        to state: inout AppState
    ) -> Bool

    func reconcile(state: inout AppState, now: Date) -> Bool
}

/// Owns the activity-graph effects of validated developer-tool lifecycle
/// events. The inbox remains the trust boundary; this coordinator receives
/// only normalized metadata and never reads hook bodies or integration files.
struct DeveloperToolLifecycleCoordinator: DeveloperToolLifecycleCoordinating {
    private let workspaceResolver: GitWorkspaceResolving
    private let localTaskResolver: LocalTaskResolving

    init(
        workspaceResolver: GitWorkspaceResolving = SystemGitWorkspaceResolver(),
        localTaskResolver: LocalTaskResolving = SystemLocalTaskResolver()
    ) {
        self.workspaceResolver = workspaceResolver
        self.localTaskResolver = localTaskResolver
    }

    func apply(
        _ event: DeveloperEventV2,
        sessionFingerprint: String,
        parentSessionFingerprint: String?,
        to state: inout AppState
    ) -> Bool {
        guard [.codex, .claudeCode, .openCode].contains(event.integration),
              event.eventKind != .integrationError else {
            return false
        }

        if let runIndex = state.activityGraph.runs.firstIndex(where: {
            $0.kind == .agent &&
            $0.agentMetadata?.integration == event.integration &&
            $0.agentMetadata?.sessionFingerprint == sessionFingerprint
        }) {
            let applied = AgentRunLifecycle.apply(
                event,
                to: &state.activityGraph.runs[runIndex],
                reviewGrace: TimeInterval(state.settings.agentReviewGraceSeconds)
            )
            if applied {
                if let model = event.model {
                    state.activityGraph.runs[runIndex].agentMetadata?.model = model
                }
                classifyActivity(
                    id: state.activityGraph.runs[runIndex].activityID,
                    event: event,
                    in: &state.activityGraph
                )
            }
            return applied
        }

        // A terminal event without a previously observed run cannot establish
        // trustworthy timing. Preserve its redacted diagnostic only.
        guard event.eventKind == .sessionStarted ||
                event.eventKind == .activityObserved ||
                event.eventKind == .permissionRequested,
              let workspaceIndex = workspaceIndex(for: event, in: &state) else {
            return false
        }

        let workspaceID = state.activityGraph.workspaces[workspaceIndex].id
        state.activityGraph.workspaces[workspaceIndex].updatedAt = max(
            state.activityGraph.workspaces[workspaceIndex].updatedAt,
            event.observedAt
        )

        let activityID: UUID
        if let existing = ActivityGraphRepository.matchingManualActivityID(
            in: state.activityGraph,
            workspaceID: workspaceID,
            at: event.observedAt
        ) {
            activityID = existing
        } else {
            let activity = Activity(
                workspaceID: workspaceID,
                title: "\(event.integration.title) session",
                createdAt: event.observedAt
            )
            state.activityGraph.activities.append(activity)
            activityID = activity.id
        }

        var run = Run(
            activityID: activityID,
            kind: .agent,
            startedAt: event.observedAt,
            agentMetadata: AgentRunMetadata(
                integration: event.integration,
                sessionFingerprint: sessionFingerprint,
                parentSessionFingerprint: parentSessionFingerprint,
                model: event.model,
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
        classifyActivity(id: activityID, event: event, in: &state.activityGraph)
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

    private func workspaceIndex(for event: DeveloperEventV2, in state: inout AppState) -> Int? {
        if let index = matchingWorkspaceIndex(for: event, in: state.activityGraph) {
            return index
        }
        if let identity = workspaceResolver.resolve(workingDirectory: event.workingDirectory) {
            if let index = GitWorkspaceIdentityMatcher.workspaceIndex(for: identity, in: state.activityGraph) {
                guard state.activityGraph.workspaces[index].automaticDiscoveryEnabled else { return index }
                if !state.activityGraph.workspaces[index].roots.contains(where: { $0.path == identity.worktreeRoot }) {
                    state.activityGraph.workspaces[index].roots.append(WorkspaceRoot(path: identity.worktreeRoot, kind: .gitWorktree, addedAt: event.observedAt, gitIdentity: identity))
                }
                return index
            }
            guard state.settings.automaticGitWorkspaceDiscoveryEnabled else { return nil }
            state.activityGraph.workspaces.append(Workspace(
                name: URL(fileURLWithPath: identity.worktreeRoot).lastPathComponent,
                roots: [WorkspaceRoot(path: identity.worktreeRoot, kind: .gitWorktree, addedAt: event.observedAt, gitIdentity: identity)],
                createdAt: event.observedAt,
                source: .automatic
            ))
            return state.activityGraph.workspaces.index(before: state.activityGraph.workspaces.endIndex)
        }
        return localWorkspaceIndex(for: event, in: &state)
    }

    private func localWorkspaceIndex(for event: DeveloperEventV2, in state: inout AppState) -> Int? {
        guard let identity = localTaskResolver.resolve(workingDirectory: event.workingDirectory) else { return nil }
        if let index = state.activityGraph.workspaces.indices.first(where: {
            state.activityGraph.workspaces[$0].localTaskIdentity?.canonicalPath == identity.canonicalPath
        }) { return index }
        let root = identity.isTransient ? [] : [WorkspaceRoot(
            path: identity.canonicalPath,
            kind: identity.isFile ? .localFile : .folder,
            addedAt: event.observedAt
        )]
        state.activityGraph.workspaces.append(Workspace(
            name: identity.displayName,
            roots: root,
            createdAt: event.observedAt,
            source: identity.isTransient ? .transientLocalTask : .automatic,
            localTaskIdentity: identity
        ))
        return state.activityGraph.workspaces.index(before: state.activityGraph.workspaces.endIndex)
    }

    private func classifyActivity(id: UUID, event: DeveloperEventV2, in graph: inout ActivityGraph) {
        guard let activityIndex = graph.activities.firstIndex(where: { $0.id == id }),
              let workspace = graph.workspaces.first(where: { $0.id == graph.activities[activityIndex].workspaceID }) else {
            return
        }
        let classifications = ActivityClassificationRuleEngine.metadataClassifications(event: event, workspace: workspace)
        graph.activities[activityIndex].applyClassifications(classifications)
        graph.activities[activityIndex].updatedAt = max(graph.activities[activityIndex].updatedAt, event.observedAt)
    }

}
