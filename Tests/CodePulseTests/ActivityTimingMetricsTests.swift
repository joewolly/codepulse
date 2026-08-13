import Foundation
import XCTest
@testable import CodePulse

final class ActivityTimingMetricsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testSeparatesManualAndAgentTimingWhileCalculatingCombinedWallActive() {
        let workspace = Workspace(name: "Notes", createdAt: start, source: .manual)
        let activity = Activity(workspaceID: workspace.id, title: "Organize", createdAt: start)
        let agentMetadata = AgentRunMetadata(integration: .codex, sessionFingerprint: "agent", parentSessionFingerprint: nil, lastEventAt: start)
        let graph = ActivityGraph(
            workspaces: [workspace],
            activities: [activity],
            runs: [
                Run(activityID: activity.id, kind: .manual, startedAt: start, endedAt: start.addingTimeInterval(60), intervals: [Interval(state: .active, startedAt: start, endedAt: start.addingTimeInterval(60))]),
                Run(activityID: activity.id, kind: .agent, startedAt: start.addingTimeInterval(30), endedAt: start.addingTimeInterval(90), intervals: [Interval(state: .active, startedAt: start.addingTimeInterval(30), endedAt: start.addingTimeInterval(90))], agentMetadata: agentMetadata),
                Run(activityID: activity.id, kind: .agent, startedAt: start.addingTimeInterval(45), endedAt: start.addingTimeInterval(120), intervals: [
                    Interval(state: .waiting, startedAt: start.addingTimeInterval(45), endedAt: start.addingTimeInterval(75)),
                    Interval(state: .active, startedAt: start.addingTimeInterval(75), endedAt: start.addingTimeInterval(120))
                ], agentMetadata: agentMetadata)
            ]
        )

        let metrics = ActivityTimingMetricsCalculator.calculate(activityID: activity.id, in: graph, at: start.addingTimeInterval(150))
        XCTAssertEqual(metrics.manualActive, 60)
        XCTAssertEqual(metrics.agentRuntime, 105)
        XCTAssertEqual(metrics.agentWaiting, 30)
        XCTAssertEqual(metrics.elapsedSpan, 120)
        XCTAssertEqual(metrics.combinedWallActive, 120)
    }
}
