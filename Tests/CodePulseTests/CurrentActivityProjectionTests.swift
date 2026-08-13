import Foundation
import XCTest
@testable import CodePulse

final class CurrentActivityProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testProjectsNoCurrentRunsFromAnEmptyGraph() {
        XCTAssertTrue(CurrentActivityProjection.runs(in: ActivityGraph(), at: start).isEmpty)
    }

    func testProjectsOneActiveManualRun() {
        let fixture = makeFixture()
        let run = Run(activityID: fixture.activity.id, kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)], legacySessionID: UUID())
        let projected = CurrentActivityProjection.runs(in: ActivityGraph(workspaces: [fixture.workspace], activities: [fixture.activity], runs: [run]), at: start.addingTimeInterval(30))

        XCTAssertEqual(projected.count, 1)
        XCTAssertEqual(projected.first?.workspaceName, "Notes")
        XCTAssertEqual(projected.first?.displayState, .active)
        XCTAssertEqual(projected.first?.activeDuration, 30)
        XCTAssertTrue(projected.first?.isCodePulseOwnedManualRun ?? false)
    }

    func testOrdersActiveBeforeReviewGraceAndWaitingAcrossActivities() {
        let first = makeFixture(name: "First", title: "Active")
        let second = makeFixture(name: "Second", title: "Review")
        let third = makeFixture(name: "Third", title: "Waiting")
        let now = start.addingTimeInterval(100)
        let graph = ActivityGraph(
            workspaces: [first.workspace, second.workspace, third.workspace],
            activities: [first.activity, second.activity, third.activity],
            runs: [
                agentRun(activityID: first.activity.id, state: .active, lastEventAt: start.addingTimeInterval(10)),
                agentRun(activityID: second.activity.id, state: .reviewGrace, lastEventAt: start.addingTimeInterval(30), deadline: start.addingTimeInterval(160)),
                agentRun(activityID: third.activity.id, state: .waiting, lastEventAt: start.addingTimeInterval(90))
            ]
        )

        let projected = CurrentActivityProjection.runs(in: graph, at: now)
        XCTAssertEqual(projected.map(\.activityTitle), ["Active", "Review", "Waiting"])
        XCTAssertEqual(projected[1].displayState, .reviewGrace(remaining: 60))
        XCTAssertEqual(projected[2].displayState, .waiting)
    }

    private func makeFixture(name: String = "Notes", title: String = "Organize") -> (workspace: Workspace, activity: Activity) {
        let workspace = Workspace(name: name, createdAt: start, source: .manual)
        return (workspace, Activity(workspaceID: workspace.id, title: title, createdAt: start))
    }

    private func agentRun(activityID: UUID, state: AgentRunState, lastEventAt: Date, deadline: Date? = nil) -> Run {
        Run(
            activityID: activityID,
            kind: .agent,
            startedAt: start,
            intervals: [Interval(state: state == .waiting ? .waiting : .active, startedAt: start)],
            agentMetadata: AgentRunMetadata(
                integration: .codex,
                sessionFingerprint: UUID().uuidString,
                state: state,
                lastEventAt: lastEventAt,
                reviewGraceDeadline: deadline
            )
        )
    }
}
