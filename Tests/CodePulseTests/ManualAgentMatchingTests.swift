import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

private struct MatchingNoGitResolver: GitWorkspaceResolving {
    func resolve(workingDirectory: String) -> GitWorkspaceIdentity? { nil }
}

final class ManualAgentMatchingTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let path = "/Volumes/Archive/notes"

    func testAttachesOnlyAnUnambiguousOverlappingManualActivity() {
        let workspace = matchingWorkspace()
        let activity = Activity(workspaceID: workspace.id, title: "Organize", createdAt: start)
        let manual = Run(activityID: activity.id, kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)])
        let coordinator = DeveloperToolLifecycleCoordinator(workspaceResolver: MatchingNoGitResolver())
        var state = AppState(activityGraph: ActivityGraph(workspaces: [workspace], activities: [activity], runs: [manual]))

        XCTAssertTrue(coordinator.apply(event(session: "matching"), sessionFingerprint: "matching", parentSessionFingerprint: nil, to: &state))
        XCTAssertEqual(state.activityGraph.activities.count, 1)
        XCTAssertEqual(state.activityGraph.runs.last?.activityID, activity.id)
    }

    func testDoesNotAttachWhenNoManualActivityIsActiveOrMatchIsAmbiguous() {
        let workspace = matchingWorkspace()
        let ended = Activity(workspaceID: workspace.id, title: "Ended", createdAt: start)
        let unrelatedWorkspace = Workspace(name: "Other", createdAt: start, source: .manual)
        let unrelated = Activity(workspaceID: unrelatedWorkspace.id, title: "Other", createdAt: start)
        let coordinator = DeveloperToolLifecycleCoordinator(workspaceResolver: MatchingNoGitResolver())
        var noMatch = AppState(activityGraph: ActivityGraph(
            workspaces: [workspace, unrelatedWorkspace],
            activities: [ended, unrelated],
            runs: [
                Run(activityID: ended.id, kind: .manual, startedAt: start, endedAt: start.addingTimeInterval(10), intervals: [
                    Interval(state: .active, startedAt: start, endedAt: start.addingTimeInterval(10))
                ]),
                Run(activityID: unrelated.id, kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)])
            ]
        ))

        XCTAssertTrue(coordinator.apply(event(session: "ended"), sessionFingerprint: "ended", parentSessionFingerprint: nil, to: &noMatch))
        XCTAssertEqual(noMatch.activityGraph.activities.count, 3)

        let first = Activity(workspaceID: workspace.id, title: "First", createdAt: start)
        let second = Activity(workspaceID: workspace.id, title: "Second", createdAt: start)
        var ambiguous = AppState(activityGraph: ActivityGraph(
            workspaces: [workspace],
            activities: [first, second],
            runs: [
                Run(activityID: first.id, kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)]),
                Run(activityID: second.id, kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)])
            ]
        ))
        XCTAssertTrue(coordinator.apply(event(session: "ambiguous"), sessionFingerprint: "ambiguous", parentSessionFingerprint: nil, to: &ambiguous))
        XCTAssertEqual(ambiguous.activityGraph.activities.count, 3)
    }

    private func matchingWorkspace() -> Workspace {
        Workspace(
            name: "Notes",
            roots: [WorkspaceRoot(path: path, addedAt: start)],
            createdAt: start,
            source: .manual
        )
    }

    private func event(session: String) -> DeveloperEventV2 {
        DeveloperEventV2(
            integration: .codex,
            eventKind: .sessionStarted,
            observedAt: start.addingTimeInterval(20),
            idempotencyKey: "manual-match-\(session)-0123456789",
            externalSessionKey: session,
            workingDirectory: path,
            parserVersion: "test",
            integrationVersion: "test"
        )
    }
}
