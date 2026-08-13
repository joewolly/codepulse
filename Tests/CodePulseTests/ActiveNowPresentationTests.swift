import Foundation
import XCTest
@testable import CodePulse

final class ActiveNowPresentationTests: XCTestCase {
    func testReviewGraceAccessibilityIncludesSafePresentationFields() {
        let run = CurrentActivityRun(
            runID: UUID(),
            activityID: UUID(),
            workspaceName: "CodePulse",
            activityTitle: "Concurrent UI",
            runKind: .agent,
            integration: .codex,
            model: "gpt-5.6",
            displayState: .reviewGrace(remaining: 75),
            activeDuration: 120,
            lastTransitionAt: Date(),
            isCodePulseOwnedManualRun: false
        )

        XCTAssertEqual(run.statusDescription, "Review grace: 00:01:15 remaining")
        XCTAssertTrue(run.accessibilitySummary.contains("CodePulse, Concurrent UI, Codex, gpt-5.6"))
        XCTAssertTrue(run.accessibilitySummary.contains("active 00:02:00"))
    }

    func testWaitingPresentationDoesNotDescribeWaitingAsActiveTime() {
        let run = CurrentActivityRun(
            runID: UUID(), activityID: UUID(), workspaceName: "Notes", activityTitle: "Organize",
            runKind: .agent, integration: .claudeCode, model: nil, displayState: .waiting,
            activeDuration: 30, lastTransitionAt: Date(), isCodePulseOwnedManualRun: false
        )
        XCTAssertEqual(run.statusDescription, "Waiting")
        XCTAssertTrue(run.accessibilitySummary.contains("Waiting, active 00:00:30"))
    }
}
