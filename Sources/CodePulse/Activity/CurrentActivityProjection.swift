import CodePulseIntegration
import Foundation

struct CurrentActivityRun: Equatable, Identifiable {
    enum DisplayState: Equatable {
        case active
        case reviewGrace(remaining: TimeInterval)
        case waiting

        var title: String {
            switch self {
            case .active: return "Active"
            case .reviewGrace: return "Review grace"
            case .waiting: return "Waiting"
            }
        }

        var priority: Int {
            switch self {
            case .active: return 0
            case .reviewGrace: return 1
            case .waiting: return 2
            }
        }
    }

    let runID: UUID
    let activityID: UUID
    let workspaceName: String
    let activityTitle: String
    let runKind: RunKind
    let integration: DeveloperEventIntegration?
    let displayState: DisplayState
    let activeDuration: TimeInterval
    let lastTransitionAt: Date
    let isCodePulseOwnedManualRun: Bool

    var id: UUID { runID }
}

enum CurrentActivityProjection {
    static func runs(in graph: ActivityGraph, at now: Date) -> [CurrentActivityRun] {
        let activities = Dictionary(uniqueKeysWithValues: graph.activities.map { ($0.id, $0) })
        let workspaces = Dictionary(uniqueKeysWithValues: graph.workspaces.map { ($0.id, $0) })

        return graph.runs.compactMap { run -> CurrentActivityRun? in
            guard run.endedAt == nil,
                  let activity = activities[run.activityID],
                  let workspace = workspaces[activity.workspaceID],
                  let displayState = state(for: run, at: now) else {
                return nil
            }
            return CurrentActivityRun(
                runID: run.id,
                activityID: activity.id,
                workspaceName: workspace.name,
                activityTitle: activity.title,
                runKind: run.kind,
                integration: run.agentMetadata?.integration,
                displayState: displayState,
                activeDuration: activeDuration(for: run, at: now),
                lastTransitionAt: run.agentMetadata?.lastEventAt ?? run.intervals.last?.startedAt ?? run.startedAt,
                isCodePulseOwnedManualRun: run.kind == .manual && run.legacySessionID != nil
            )
        }
        .sorted {
            if $0.displayState.priority != $1.displayState.priority {
                return $0.displayState.priority < $1.displayState.priority
            }
            if $0.lastTransitionAt != $1.lastTransitionAt {
                return $0.lastTransitionAt > $1.lastTransitionAt
            }
            return $0.runID.uuidString < $1.runID.uuidString
        }
    }

    private static func state(for run: Run, at now: Date) -> CurrentActivityRun.DisplayState? {
        if let metadata = run.agentMetadata {
            switch metadata.state {
            case .active:
                return .active
            case .reviewGrace:
                return .reviewGrace(remaining: max(0, (metadata.reviewGraceDeadline ?? now).timeIntervalSince(now)))
            case .awaitingPermission, .waiting:
                return .waiting
            case .new, .ended, .orphaned:
                return nil
            }
        }
        guard let interval = run.openInterval else { return nil }
        return interval.state == .active ? .active : .waiting
    }

    private static func activeDuration(for run: Run, at now: Date) -> TimeInterval {
        run.intervals
            .filter { $0.state == .active }
            .reduce(0) { $0 + $1.duration(at: now) }
    }
}
