import Foundation
import CodePulseIntegration
import XCTest
@testable import CodePulse

private final class JournalTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class JournalTestPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private final class JournalNoopGitService: GitServicing, @unchecked Sendable {
    private(set) var captureCount = 0

    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? {
        captureCount += 1
        return nil
    }

    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? {
        captureCount += 1
        return nil
    }
}

@MainActor
final class JournalTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        return calendar
    }()

    func testNewSessionTypeDefaultsToCodingAndPersists() {
        let start = date(year: 2023, month: 8, day: 9, hour: 10)
        let clock = JournalTestClock(start)
        let persistence = JournalTestPersistence()
        let store = SessionStore(
            persistence: persistence,
            clock: clock,
            calendar: calendar,
            automaticallyRefresh: false
        )

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil, type: .debugging))
        XCTAssertEqual(store.activeSession?.type, .debugging)
        clock.now = start.addingTimeInterval(90)
        XCTAssertTrue(store.finish())
        XCTAssertTrue(store.saveFinishedSession(outcome: nil))
        XCTAssertEqual(persistence.state.completedSessions.first?.type, .debugging)
    }

    func testLegacyActiveAndCompletedSessionsWithoutTypeDecodeAsCoding() throws {
        let session = ActiveSession(
            projectID: nil,
            projectName: nil,
            type: .research,
            goal: "Read",
            startedAt: date(year: 2023, month: 8, day: 9, hour: 10)
        )
        let completed = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .review,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 8, day: 9, hour: 10),
            endedAt: date(year: 2023, month: 8, day: 9, hour: 11),
            pauseIntervals: []
        )

        let activeData = try removingType(from: session)
        let completedData = try removingType(from: completed)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(ActiveSession.self, from: activeData).type, .coding)
        XCTAssertEqual(try decoder.decode(CompletedSession.self, from: completedData).type, .coding)
    }

    func testLegacySettingsWithoutShortcutSettingKeepTheSafeDefault() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(AppState())) as! [String: Any]
        var settings = object["settings"] as! [String: Any]
        settings.removeValue(forKey: "globalShortcutEnabled")
        object["settings"] = settings

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            AppState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(restored.settings.globalShortcutEnabled)
    }

    func testHistoryQueryCombinesSearchAndAllFilters() {
        let projectID = UUID()
        let start = date(year: 2023, month: 8, day: 9, hour: 10)
        let matching = CompletedSession(
            id: UUID(),
            projectID: projectID,
            projectName: "CodePulse",
            type: .debugging,
            goal: "Investigate attribution",
            outcome: "Fixed branch attribution",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            pauseIntervals: [],
            gitContext: GitSessionContext(
                repositoryRoot: "/tmp/codepulse",
                branchAtStart: "feature/journal",
                startWasDetached: false
            )
        )
        let wrongType = CompletedSession(
            id: UUID(),
            projectID: projectID,
            projectName: "CodePulse",
            type: .coding,
            goal: "Investigate attribution",
            outcome: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            pauseIntervals: [],
            gitContext: matching.gitContext
        )

        let query = HistoryQuery(
            searchText: "  ATTRIBUTION ",
            project: .projectID(projectID),
            date: .last7Days,
            type: .debugging,
            git: .gitSessions
        )

        XCTAssertTrue(query.matches(matching, calendar: calendar, referenceDate: start))
        XCTAssertFalse(query.matches(wrongType, calendar: calendar, referenceDate: start))
    }

    func testHistoryGoalOutcomeFiltersUseMeaningfulTextAndCompose() {
        let projectID = UUID()
        let start = date(year: 2023, month: 8, day: 9, hour: 10)
        func session(
            goal: String?,
            outcome: String?,
            projectID: UUID? = nil,
            projectName: String? = nil
        ) -> CompletedSession {
            CompletedSession(
                id: UUID(),
                projectID: projectID,
                projectName: projectName,
                type: .debugging,
                goal: goal,
                outcome: outcome,
                startedAt: start,
                endedAt: start.addingTimeInterval(600),
                pauseIntervals: []
            )
        }

        let closedLoop = session(goal: "Plan", outcome: "Done", projectID: projectID, projectName: "CodePulse")
        let needsFollowUp = session(goal: "Follow up", outcome: nil, projectID: projectID, projectName: "CodePulse")
        let outcomeOnly = session(goal: nil, outcome: "Recorded")
        let untracked = session(goal: "\n", outcome: " \t")

        XCTAssertFalse(HistoryQuery().hasRestrictions)
        XCTAssertTrue(HistoryQuery(goalOutcome: .needsFollowUp).hasRestrictions)

        let all = [closedLoop, needsFollowUp, outcomeOnly, untracked]
        XCTAssertEqual(
            all.filter { HistoryQuery().matches($0, calendar: calendar, referenceDate: start) }.count,
            all.count
        )
        XCTAssertEqual(
            all.filter { HistoryQuery(goalOutcome: .needsFollowUp).matches($0, calendar: calendar, referenceDate: start) },
            [needsFollowUp]
        )
        XCTAssertEqual(
            all.filter { HistoryQuery(goalOutcome: .closedLoop).matches($0, calendar: calendar, referenceDate: start) },
            [closedLoop]
        )

        let composed = HistoryQuery(
            searchText: "follow",
            project: .projectID(projectID),
            date: .today,
            type: .debugging,
            goalOutcome: .needsFollowUp
        )
        XCTAssertTrue(composed.matches(needsFollowUp, calendar: calendar, referenceDate: start))
        XCTAssertFalse(composed.matches(closedLoop, calendar: calendar, referenceDate: start))
        XCTAssertFalse(composed.matches(outcomeOnly, calendar: calendar, referenceDate: start))
        XCTAssertFalse(composed.matches(untracked, calendar: calendar, referenceDate: start))
    }

    func testEditingFollowUpOutcomeClosesLoopAndRefreshesInsights() {
        let start = date(year: 2023, month: 8, day: 9, hour: 10)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: "Finish the workflow",
            outcome: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            pauseIntervals: []
        )
        let persistence = JournalTestPersistence(AppState(completedSessions: [session]))
        let insightsReference = start.addingTimeInterval(7_200)
        let store = SessionStore(
            persistence: persistence,
            clock: JournalTestClock(insightsReference),
            calendar: calendar,
            automaticallyRefresh: false
        )

        let beforeRevision = store.stateRevision
        let followUp = HistoryQuery(goalOutcome: .needsFollowUp)
        XCTAssertEqual(store.historySessions(for: followUp, referenceDate: start).map(\.id), [session.id])
        XCTAssertEqual(
            InsightsCalculator.summary(state: store.state, calendar: calendar, referenceDate: insightsReference)
                .goalOutcomeInsights.needsFollowUpCount,
            1
        )

        XCTAssertTrue(store.updateCompletedSession(
            id: session.id,
            type: .coding,
            goal: session.goal,
            outcome: "Completed the workflow",
            project: .keepSnapshot,
            startedAt: session.startedAt
        ))

        XCTAssertGreaterThan(store.stateRevision, beforeRevision)
        XCTAssertTrue(store.historySessions(for: followUp, referenceDate: start).isEmpty)
        XCTAssertEqual(
            store.historySessions(
                for: HistoryQuery(goalOutcome: .closedLoop),
                referenceDate: start
            ).map(\.id),
            [session.id]
        )
        let after = InsightsCalculator.summary(
            state: store.state,
            calendar: calendar,
            referenceDate: insightsReference
        ).goalOutcomeInsights
        XCTAssertEqual(after.closedLoopCount, 1)
        XCTAssertEqual(after.needsFollowUpCount, 0)
    }

    func testHistoryQuerySupportsNoProjectAndNonGitSessions() {
        let start = date(year: 2023, month: 8, day: 9, hour: 10)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: "Local notes",
            outcome: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            pauseIntervals: []
        )
        let query = HistoryQuery(
            searchText: "notes",
            project: .noProject,
            date: .today,
            type: .coding,
            git: .nonGitSessions
        )

        XCTAssertTrue(query.matches(session, calendar: calendar, referenceDate: start))
        XCTAssertFalse(query.matches(
            CompletedSession(
                id: UUID(),
                projectID: nil,
                projectName: "Named",
                goal: nil,
                outcome: nil,
                startedAt: start,
                endedAt: start.addingTimeInterval(600),
                pauseIntervals: []
            ),
            calendar: calendar,
            referenceDate: start
        ))
    }

    func testHistoryQuerySearchesDeveloperToolAndGitHubMetadata() {
        let start = date(year: 2023, month: 8, day: 9, hour: 10)
        let developerContext = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "codex-session",
            workingDirectory: "/tmp/codepulse",
            firstActivityAt: start,
            lastActivityAt: start.addingTimeInterval(300),
            model: "GPT-5.6 Sol",
            profile: "Builder"
        )
        let pullRequest = GitHubPullRequestSnapshot(
            number: 42,
            title: "Improve session intelligence",
            state: .open,
            isDraft: false,
            url: "https://github.com/owner/repository/pull/42"
        )
        let matching = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "CodePulse",
            type: .review,
            goal: "Inspect insights",
            outcome: "Documented the result",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            pauseIntervals: [],
            githubContext: GitHubSessionContext(
                repositoryNameWithOwner: "owner/repository",
                repositoryURL: "https://github.com/owner/repository",
                pullRequest: pullRequest
            ),
            developerToolContexts: [developerContext]
        )
        let unrelated = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Other",
            type: .coding,
            goal: "Unrelated",
            outcome: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            pauseIntervals: []
        )

        for searchText in [
            "Codex", "GPT-5.6", "Builder", "owner/repository", "42", "Improve session intelligence"
        ] {
            let query = HistoryQuery(searchText: searchText)
            XCTAssertTrue(query.matches(matching, calendar: calendar, referenceDate: start), searchText)
            XCTAssertFalse(query.matches(unrelated, calendar: calendar, referenceDate: start), searchText)
        }
    }

    func testHistoryDeveloperToolFiltersTreatMultipleContextsAsOneToolParticipation() {
        let start = date(year: 2023, month: 8, day: 9, hour: 10)
        let codex = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "codex-1",
            workingDirectory: "/tmp/codepulse",
            firstActivityAt: start,
            lastActivityAt: start
        )
        let codexAgain = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "codex-2",
            workingDirectory: "/tmp/codepulse",
            firstActivityAt: start,
            lastActivityAt: start
        )
        let openCode = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "opencode-1",
            workingDirectory: "/tmp/codepulse",
            firstActivityAt: start,
            lastActivityAt: start
        )
        let codexSession = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            pauseIntervals: [],
            developerToolContexts: [codex, codexAgain]
        )
        let openCodeSession = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            pauseIntervals: [],
            developerToolContexts: [openCode]
        )
        let noToolSession = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            pauseIntervals: []
        )

        let sessions = [codexSession, openCodeSession, noToolSession]
        XCTAssertEqual(sessions.filter {
            HistoryQuery(developerTool: .anyTool).matches($0, calendar: calendar, referenceDate: start)
        }.count, 3)
        XCTAssertEqual(sessions.filter {
            HistoryQuery(developerTool: .codex).matches($0, calendar: calendar, referenceDate: start)
        }.count, 1)
        XCTAssertEqual(sessions.filter {
            HistoryQuery(developerTool: .openCode).matches($0, calendar: calendar, referenceDate: start)
        }.count, 1)
        XCTAssertEqual(sessions.filter {
            HistoryQuery(developerTool: .noDeveloperTool).matches($0, calendar: calendar, referenceDate: start)
        }.count, 1)
    }

    func testHistoryGroupsFilterBeforeGroupingAndUseVisibleTotals() {
        let reference = date(year: 2023, month: 8, day: 9, hour: 12)
        let first = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "One",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 8, day: 9, hour: 9),
            endedAt: date(year: 2023, month: 8, day: 10, hour: 10),
            pauseIntervals: []
        )
        let second = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Two",
            type: .debugging,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 8, day: 9, hour: 11),
            endedAt: date(year: 2023, month: 8, day: 9, hour: 12),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [first, second]
        let store = SessionStore(
            persistence: JournalTestPersistence(state),
            clock: JournalTestClock(reference),
            calendar: calendar,
            automaticallyRefresh: false
        )

        let groups = store.historyGroups(
            for: HistoryQuery(type: .debugging),
            referenceDate: reference
        )

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.sessions.map(\.id), [second.id])
        XCTAssertEqual(try XCTUnwrap(groups.first?.totalDuration), 3_600, accuracy: 0.001)
    }

    func testShiftEditPreservesDurationPauseOffsetsAndGitSnapshot() {
        let originalStart = date(year: 2023, month: 8, day: 9, hour: 10)
        let originalEnd = originalStart.addingTimeInterval(4 * 3_600)
        let gitContext = GitSessionContext(
            repositoryRoot: "/tmp/repository",
            branchAtStart: "main",
            startHeadSHA: "start",
            startWasDetached: false,
            branchAtEnd: "feature",
            endHeadSHA: "end",
            endWasDetached: false,
            commitCount: 2,
            filesChanged: 3,
            insertions: 12,
            deletions: 4
        )
        let original = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "CodePulse",
            type: .coding,
            goal: "Original",
            outcome: "Done",
            startedAt: originalStart,
            endedAt: originalEnd,
            pauseIntervals: [
                PauseInterval(startedAt: originalStart.addingTimeInterval(3_600), endedAt: originalStart.addingTimeInterval(5_400))
            ],
            gitContext: gitContext
        )
        var state = AppState()
        state.completedSessions = [original]
        let gitService = JournalNoopGitService()
        let persistence = JournalTestPersistence(state)
        let store = SessionStore(
            persistence: persistence,
            clock: JournalTestClock(originalEnd),
            calendar: calendar,
            gitService: gitService,
            automaticallyRefresh: false
        )

        let editedStart = originalStart.addingTimeInterval(86_400)
        XCTAssertTrue(store.updateCompletedSession(
            id: original.id,
            type: .review,
            goal: "  Revised goal  ",
            outcome: "  ",
            project: .keepSnapshot,
            startedAt: editedStart
        ))

        let edited = store.completedSession(id: original.id)!
        XCTAssertEqual(edited.type, .review)
        XCTAssertEqual(edited.goal, "Revised goal")
        XCTAssertNil(edited.outcome)
        XCTAssertEqual(edited.activeDuration, original.activeDuration, accuracy: 0.001)
        XCTAssertEqual(edited.startedAt, editedStart)
        XCTAssertEqual(edited.endedAt, originalEnd.addingTimeInterval(86_400))
        XCTAssertEqual(edited.pauseIntervals[0].startedAt, original.pauseIntervals[0].startedAt.addingTimeInterval(86_400))
        XCTAssertEqual(edited.gitContext, gitContext)
        XCTAssertEqual(gitService.captureCount, 0)
        XCTAssertEqual(persistence.state.completedSessions.first, edited)
    }

    func testProjectRemovalDoesNotEraseHistoricalName() {
        let projectID = UUID()
        var state = AppState()
        state.projects = [ProjectRecord(id: projectID, name: "Old Name")]
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: projectID,
            projectName: "Old Name",
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 8, day: 9, hour: 10),
            endedAt: date(year: 2023, month: 8, day: 9, hour: 11),
            pauseIntervals: []
        )]
        let store = SessionStore(
            persistence: JournalTestPersistence(state),
            clock: JournalTestClock(date(year: 2023, month: 8, day: 9, hour: 12)),
            calendar: calendar,
            automaticallyRefresh: false
        )

        store.deleteProject(id: projectID)

        XCTAssertTrue(store.state.projects.isEmpty)
        XCTAssertEqual(store.state.completedSessions.first?.projectName, "Old Name")
        XCTAssertEqual(store.historyProjectOptions.first?.title, "Old Name")
    }

    func testCompletedSessionCanBeReassignedToCurrentProjectOrNoProject() {
        let projectID = UUID()
        var state = AppState()
        state.projects = [ProjectRecord(id: projectID, name: "Current")]
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Old Snapshot",
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 8, day: 9, hour: 10),
            endedAt: date(year: 2023, month: 8, day: 9, hour: 11),
            pauseIntervals: []
        )
        state.completedSessions = [session]
        let store = SessionStore(
            persistence: JournalTestPersistence(state),
            clock: JournalTestClock(date(year: 2023, month: 8, day: 9, hour: 12)),
            calendar: calendar,
            automaticallyRefresh: false
        )

        XCTAssertTrue(store.updateCompletedSession(
            id: session.id,
            type: .coding,
            goal: nil,
            outcome: nil,
            project: .project(projectID),
            startedAt: session.startedAt
        ))
        XCTAssertEqual(store.completedSession(id: session.id)?.projectID, projectID)
        XCTAssertEqual(store.completedSession(id: session.id)?.projectName, "Current")

        XCTAssertTrue(store.updateCompletedSession(
            id: session.id,
            type: .coding,
            goal: nil,
            outcome: nil,
            project: .noProject,
            startedAt: session.startedAt
        ))
        XCTAssertNil(store.completedSession(id: session.id)?.projectID)
        XCTAssertNil(store.completedSession(id: session.id)?.projectName)
    }

    private func date(year: Int, month: Int, day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func removingType<T: Encodable>(from value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let object = try JSONSerialization.jsonObject(with: encoder.encode(value))
        var dictionary = try XCTUnwrap(object as? [String: Any])
        dictionary.removeValue(forKey: "type")
        return try JSONSerialization.data(withJSONObject: dictionary)
    }
}
