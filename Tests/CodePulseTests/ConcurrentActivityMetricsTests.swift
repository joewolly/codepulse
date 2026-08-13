import Foundation
import XCTest
@testable import CodePulse

final class ConcurrentActivityMetricsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testOverlappingManualAndAgentsUseUnionForWallActiveAndSumForRuntime() {
        let graph = graph(runs: [
            manual(active: 0...60),
            agent(active: 30...90),
            agent(active: 45...75)
        ])

        let metrics = ConcurrentActivityMetricsCalculator.calculate(in: graph, at: start.addingTimeInterval(120))
        XCTAssertEqual(metrics.personalWallActive, 60)
        XCTAssertEqual(metrics.agentRuntime, 90)
        XCTAssertEqual(metrics.agentWaiting, 0)
        XCTAssertEqual(metrics.combinedWallActive, 90)
    }

    func testWaitingContributesZeroToActiveMetricsAndRemainsSeparatelySummed() {
        let graph = graph(runs: [
            manual(active: 0...30),
            agent(active: 10...40, waiting: 40...100),
            agent(active: 20...50)
        ])

        let metrics = ConcurrentActivityMetricsCalculator.calculate(in: graph, at: start.addingTimeInterval(120))
        XCTAssertEqual(metrics.personalWallActive, 30)
        XCTAssertEqual(metrics.agentRuntime, 60)
        XCTAssertEqual(metrics.agentWaiting, 60)
        XCTAssertEqual(metrics.combinedWallActive, 50)
    }

    private func graph(runs: [Run]) -> ActivityGraph {
        let workspace = Workspace(name: "Metrics", createdAt: start, source: .manual)
        let activity = Activity(workspaceID: workspace.id, title: "Concurrent", createdAt: start)
        return ActivityGraph(
            workspaces: [workspace],
            activities: [activity],
            runs: runs.map { run in
                Run(id: run.id, activityID: activity.id, kind: run.kind, startedAt: run.startedAt, endedAt: run.endedAt, intervals: run.intervals, agentMetadata: run.agentMetadata)
            }
        )
    }

    private func manual(active: ClosedRange<TimeInterval>) -> Run {
        Run(activityID: UUID(), kind: .manual, startedAt: start.addingTimeInterval(active.lowerBound), endedAt: start.addingTimeInterval(active.upperBound), intervals: [
            Interval(state: .active, startedAt: start.addingTimeInterval(active.lowerBound), endedAt: start.addingTimeInterval(active.upperBound))
        ])
    }

    private func agent(active: ClosedRange<TimeInterval>, waiting: ClosedRange<TimeInterval>? = nil) -> Run {
        var intervals = [Interval(state: .active, startedAt: start.addingTimeInterval(active.lowerBound), endedAt: start.addingTimeInterval(active.upperBound))]
        if let waiting {
            intervals.append(Interval(state: .waiting, startedAt: start.addingTimeInterval(waiting.lowerBound), endedAt: start.addingTimeInterval(waiting.upperBound)))
        }
        return Run(activityID: UUID(), kind: .agent, startedAt: start.addingTimeInterval(active.lowerBound), endedAt: start.addingTimeInterval(waiting?.upperBound ?? active.upperBound), intervals: intervals)
    }
}
