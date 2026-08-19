import CodePulseIntegration
import XCTest
@testable import CodePulse

final class HistoryPresentationTests: XCTestCase {
    func testSelectionResolverUsesNewestThenRetainsVisibleSelection() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            HistorySelectionResolver.resolve(currentID: nil, visibleIDs: [first, second]),
            first
        )
        XCTAssertEqual(
            HistorySelectionResolver.resolve(currentID: second, visibleIDs: [first, second]),
            second
        )
        XCTAssertEqual(
            HistorySelectionResolver.resolve(
                currentID: first,
                preferredID: second,
                visibleIDs: [first, second]
            ),
            second
        )
        XCTAssertEqual(
            HistorySelectionResolver.resolve(
                currentID: first,
                preferredID: third,
                visibleIDs: [first, second]
            ),
            first
        )
        XCTAssertEqual(
            HistorySelectionResolver.resolve(currentID: third, visibleIDs: [first, second]),
            first
        )
        XCTAssertNil(HistorySelectionResolver.resolve(currentID: second, visibleIDs: []))
    }

    func testSelectionResolverChoosesNearestSurvivorAfterDeletion() {
        let first = UUID()
        let second = UUID()
        let third = UUID()

        XCTAssertEqual(
            HistorySelectionResolver.afterDeletion(
                deletedID: second,
                currentID: second,
                visibleIDsBeforeDeletion: [first, second, third],
                visibleIDsAfterDeletion: [first, third]
            ),
            third
        )
        XCTAssertEqual(
            HistorySelectionResolver.afterDeletion(
                deletedID: third,
                currentID: third,
                visibleIDsBeforeDeletion: [first, second, third],
                visibleIDsAfterDeletion: [first, second]
            ),
            second
        )
        XCTAssertEqual(
            HistorySelectionResolver.afterDeletion(
                deletedID: first,
                currentID: third,
                visibleIDsBeforeDeletion: [first, second, third],
                visibleIDsAfterDeletion: [second, third]
            ),
            third
        )
        XCTAssertNil(
            HistorySelectionResolver.afterDeletion(
                deletedID: first,
                currentID: first,
                visibleIDsBeforeDeletion: [first],
                visibleIDsAfterDeletion: []
            )
        )
    }

    func testGitFormattingPreservesNilAndExplicitZero() {
        XCTAssertNil(HistoryGitFormatting.commitCount(nil))
        XCTAssertEqual(HistoryGitFormatting.commitCount(0), "0 commits")
        XCTAssertEqual(HistoryGitFormatting.commitCount(1), "1 commit")
        XCTAssertEqual(HistoryGitFormatting.commitCount(3), "3 commits")

        XCTAssertNil(HistoryGitFormatting.changes(filesChanged: nil, insertions: nil, deletions: nil))
        XCTAssertEqual(
            HistoryGitFormatting.changes(filesChanged: 0, insertions: 0, deletions: 0),
            "0 files changed"
        )
        XCTAssertEqual(
            HistoryGitFormatting.changes(filesChanged: 8, insertions: 142, deletions: 36),
            "8 files · +142 / -36"
        )
        XCTAssertEqual(
            HistoryGitFormatting.changes(filesChanged: 2, insertions: 4, deletions: nil),
            "2 files · +4"
        )
    }

    func testDeveloperToolPresentationBoundsInitialContextsAndPreservesOrder() {
        let contexts = (0..<20).map { index in
            DeveloperToolSessionContext(
                tool: index.isMultiple(of: 2) ? .codex : .opencode,
                externalSessionID: "session-\(index)",
                workingDirectory: "/tmp/codepulse",
                firstActivityAt: Date(timeIntervalSince1970: TimeInterval(index)),
                lastActivityAt: Date(timeIntervalSince1970: TimeInterval(index + 1))
            )
        }

        XCTAssertEqual(HistoryDeveloperToolPresentation.visibleContexts([], isExpanded: false).count, 0)
        XCTAssertEqual(HistoryDeveloperToolPresentation.visibleContexts(Array(contexts.prefix(8)), isExpanded: false).count, 8)
        XCTAssertEqual(HistoryDeveloperToolPresentation.remainingCount(Array(contexts.prefix(8))), 0)
        XCTAssertEqual(HistoryDeveloperToolPresentation.remainingCount(contexts), 12)
        XCTAssertEqual(
            HistoryDeveloperToolPresentation.visibleContexts(contexts, isExpanded: false).map(\.externalSessionID),
            contexts.prefix(8).map(\.externalSessionID)
        )
        XCTAssertEqual(
            HistoryDeveloperToolPresentation.visibleContexts(contexts, isExpanded: true).map(\.externalSessionID),
            contexts.map(\.externalSessionID)
        )
    }

    func testOptionalHistorySectionsUseMeaningfulText() {
        let empty = makeSession(goal: " \n", outcome: "\t")
        let goalOnly = makeSession(goal: "Plan", outcome: nil)
        let outcomeOnly = makeSession(goal: nil, outcome: "Done")

        XCTAssertFalse(HistoryDetailAvailability.hasJournal(empty))
        XCTAssertTrue(HistoryDetailAvailability.hasJournal(goalOnly))
        XCTAssertTrue(HistoryDetailAvailability.hasJournal(outcomeOnly))
        XCTAssertFalse(HistoryDetailAvailability.needsFollowUp(empty))
        XCTAssertTrue(HistoryDetailAvailability.needsFollowUp(goalOnly))
        XCTAssertFalse(HistoryDetailAvailability.needsFollowUp(outcomeOnly))
    }

    private func makeSession(goal: String?, outcome: String?) -> CompletedSession {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            goal: goal,
            outcome: outcome,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            pauseIntervals: []
        )
    }
}
