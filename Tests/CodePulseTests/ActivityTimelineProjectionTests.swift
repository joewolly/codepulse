import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class ActivityTimelineProjectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testOrdersTimelineChronologicallyAndRedactsRawRunMetadata() {
        let fixture = makeFixture()
        let graph = ActivityGraph(
            workspaces: [fixture.workspace],
            activities: [fixture.activity],
            runs: [
                Run(activityID: fixture.activity.id, kind: .agent, startedAt: start, intervals: [
                    Interval(state: .waiting, startedAt: start.addingTimeInterval(40), reason: "permission payload should not render"),
                    Interval(state: .active, startedAt: start.addingTimeInterval(10), endedAt: start.addingTimeInterval(40), reason: "raw lifecycle event")
                ], agentMetadata: AgentRunMetadata(integration: .codex, sessionFingerprint: "secret-session-fingerprint", model: "gpt-5.6", lastEventAt: start.addingTimeInterval(40))),
                Run(activityID: fixture.activity.id, kind: .manual, startedAt: start, intervals: [
                    Interval(state: .active, startedAt: start, endedAt: start.addingTimeInterval(10), reason: "manualSession")
                ], legacySessionID: UUID())
            ]
        )

        let entries = ActivityTimelineProjection.entries(activityID: fixture.activity.id, in: graph)
        XCTAssertEqual(entries.map(\.state), [.active, .active, .waiting])
        XCTAssertEqual(entries.map(\.runLabel), ["Manual timer", "Codex · gpt-5.6", "Codex · gpt-5.6"])
        let rendered = entries.map { "\($0.runLabel) \($0.stateLabel)" }.joined(separator: " ")
        XCTAssertFalse(rendered.contains("secret-session-fingerprint"))
        XCTAssertFalse(rendered.contains("permission payload"))
        XCTAssertFalse(rendered.contains("raw lifecycle event"))
    }

    func testProjectsLargeHistoriesWithoutDroppingIntervals() {
        let fixture = makeFixture()
        let intervals = (0..<2_000).map { offset in
            Interval(state: offset.isMultiple(of: 2) ? .active : .waiting, startedAt: start.addingTimeInterval(TimeInterval(offset)))
        }
        let graph = ActivityGraph(
            workspaces: [fixture.workspace],
            activities: [fixture.activity],
            runs: [Run(activityID: fixture.activity.id, kind: .manual, startedAt: start, intervals: intervals)]
        )

        let entries = ActivityTimelineProjection.entries(activityID: fixture.activity.id, in: graph)
        XCTAssertEqual(entries.count, 2_000)
        XCTAssertEqual(entries.first?.startedAt, start)
        XCTAssertEqual(entries.last?.startedAt, start.addingTimeInterval(1_999))
    }

    private func makeFixture() -> (workspace: Workspace, activity: Activity) {
        let workspace = Workspace(name: "Notes", createdAt: start, source: .manual)
        return (workspace, Activity(workspaceID: workspace.id, title: "Organize", createdAt: start))
    }
}
