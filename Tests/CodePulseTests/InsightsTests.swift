import Foundation
import CodePulseIntegration
import XCTest
@testable import CodePulse

private final class InsightsTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
final class InsightsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()

    func testCurrentWeekApportionsBoundaryPauseAndActiveSession() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let crossingDayStart = date(year: 2023, month: 1, day: 3, hour: 23, minute: 30)
        let crossingDay = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "CodePulse",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: crossingDayStart,
            endedAt: date(year: 2023, month: 1, day: 4, hour: 1, minute: 30),
            pauseIntervals: [
                PauseInterval(
                    startedAt: date(year: 2023, month: 1, day: 3, hour: 23, minute: 45),
                    endedAt: date(year: 2023, month: 1, day: 4, hour: 0, minute: 15)
                )
            ]
        )
        let crossingWeek = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "Boundary",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 1, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 2, hour: 1),
            pauseIntervals: []
        )
        let previousWeek = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "Earlier",
            type: .planning,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2022, month: 12, day: 30, hour: 10),
            endedAt: date(year: 2022, month: 12, day: 30, hour: 12),
            pauseIntervals: []
        )
        let active = ActiveSession(
            projectID: nil,
            projectName: nil,
            type: .research,
            goal: nil,
            startedAt: date(year: 2023, month: 1, day: 4, hour: 12)
        )
        var state = AppState()
        state.completedSessions = [crossingDay, crossingWeek, previousWeek]
        state.activeSession = active

        let summary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        )

        XCTAssertEqual(summary.interval.start, date(year: 2023, month: 1, day: 2, hour: 0))
        XCTAssertEqual(summary.totalDuration, 12_600, accuracy: 0.001) // 1.5h + 1h + 1h
        XCTAssertEqual(summary.comparisonDuration, 10_800, accuracy: 0.001) // 1h boundary + 2h prior
        XCTAssertEqual(summary.difference, 1_800, accuracy: 0.001)

        XCTAssertEqual(summary.projectBreakdown.map(\.label), ["CodePulse", "Boundary", "No Project"])
        XCTAssertEqual(summary.projectBreakdown.map(\.duration), [5_400, 3_600, 3_600])
        XCTAssertEqual(summary.typeBreakdown.map(\.label), ["Coding", "Research"])

        let jan3 = summary.dailyActivity.first { calendar.isDate($0.date, inSameDayAs: crossingDayStart) }
        let jan4 = summary.dailyActivity.first { calendar.isDate($0.date, inSameDayAs: reference) }
        XCTAssertEqual(try XCTUnwrap(jan3?.duration), 900, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(jan4?.duration), 8_100, accuracy: 0.001) // 1h 15m crossing-day + 1h active
    }

    func testPreviousWeekAndEmptyStateAreDeterministic() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2022, month: 12, day: 28, hour: 10),
            endedAt: date(year: 2022, month: 12, day: 28, hour: 11),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [session]

        let lastWeek = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .lastWeek
        )
        XCTAssertEqual(lastWeek.totalDuration, 3_600, accuracy: 0.001)
        XCTAssertEqual(lastWeek.projectBreakdown.first?.label, "No Project")
        XCTAssertEqual(lastWeek.typeBreakdown.first?.label, "Coding")

        let empty = InsightsCalculator.summary(
            state: AppState(),
            calendar: calendar,
            referenceDate: reference
        )
        XCTAssertFalse(empty.hasActivity)
        XCTAssertTrue(empty.projectBreakdown.isEmpty)
        XCTAssertTrue(empty.typeBreakdown.isEmpty)
        XCTAssertEqual(empty.dailyActivity.count, 7)
        XCTAssertTrue(empty.dailyActivity.allSatisfy { $0.duration == 0 })

        let last30 = InsightsCalculator.summary(
            state: AppState(),
            calendar: calendar,
            referenceDate: reference,
            timeframe: .last30Days
        )
        XCTAssertEqual(last30.dailyActivity.count, 30)
    }

    func testLegacySessionTypeCountsAsCodingInInsights() throws {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 4, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 4, hour: 11),
            pauseIntervals: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(session)) as! [String: Any]
        object.removeValue(forKey: "type")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(CompletedSession.self, from: data)

        var state = AppState()
        state.completedSessions = [legacy]
        let summary = InsightsCalculator.summary(state: state, calendar: calendar, referenceDate: reference)
        XCTAssertEqual(summary.typeBreakdown.first?.label, "Coding")
    }

    func testLegacySessionWithoutGoalOrOutcomeIsUntracked() throws {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 4, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 4, hour: 11),
            pauseIntervals: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(session)) as! [String: Any]
        object.removeValue(forKey: "goal")
        object.removeValue(forKey: "outcome")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(
            CompletedSession.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        var state = AppState()
        state.completedSessions = [legacy]
        let insights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        ).goalOutcomeInsights

        XCTAssertEqual(insights.completedSessionCount, 1)
        XCTAssertEqual(insights.untrackedCount, 1)
        XCTAssertEqual(insights.sessionsWithGoal, 0)
        XCTAssertEqual(insights.sessionsWithOutcome, 0)
        XCTAssertNil(insights.closedLoopRate)
    }

    func testSummaryExposesCountAverageAndLongestUsingClippedActiveTime() {
        let reference = date(year: 2023, month: 1, day: 11, hour: 13)
        let crossingWeek = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 8, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 9, hour: 2),
            pauseIntervals: [
                PauseInterval(
                    startedAt: date(year: 2023, month: 1, day: 9, hour: 0),
                    endedAt: date(year: 2023, month: 1, day: 9, hour: 0, minute: 30)
                )
            ]
        )
        let completed = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .debugging,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 10, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 10, hour: 12),
            pauseIntervals: [
                PauseInterval(
                    startedAt: date(year: 2023, month: 1, day: 10, hour: 11),
                    endedAt: date(year: 2023, month: 1, day: 10, hour: 11, minute: 30)
                )
            ]
        )
        var active = ActiveSession(
            projectID: nil,
            projectName: nil,
            type: .research,
            goal: nil,
            startedAt: date(year: 2023, month: 1, day: 11, hour: 11)
        )
        active.pauseIntervals = [
            PauseInterval(
                startedAt: date(year: 2023, month: 1, day: 11, hour: 12),
                endedAt: date(year: 2023, month: 1, day: 11, hour: 12, minute: 30)
            )
        ]
        var state = AppState()
        state.completedSessions = [crossingWeek, completed]
        state.activeSession = active

        let summary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        )

        XCTAssertEqual(summary.sessionCount, 3)
        XCTAssertEqual(summary.totalDuration, 16_200, accuracy: 0.001)
        XCTAssertEqual(summary.averageSessionDuration, 5_400, accuracy: 0.001)
        XCTAssertEqual(summary.longestSessionDuration, 5_400, accuracy: 0.001)
    }

    func testTimeframesAndComparisonsUseCalendarBoundaries() {
        let reference = date(year: 2023, month: 1, day: 15, hour: 13)
        let state = AppState()

        let thisWeek = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .thisWeek
        )
        XCTAssertEqual(thisWeek.interval.start, date(year: 2023, month: 1, day: 9))
        XCTAssertEqual(thisWeek.interval.end, date(year: 2023, month: 1, day: 16))
        XCTAssertEqual(thisWeek.comparisonInterval?.start, date(year: 2023, month: 1, day: 2))
        XCTAssertEqual(thisWeek.comparisonInterval?.end, date(year: 2023, month: 1, day: 9))
        XCTAssertEqual(thisWeek.comparisonSessionCount, 0)

        let lastWeek = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .lastWeek
        )
        XCTAssertEqual(lastWeek.interval.start, date(year: 2023, month: 1, day: 2))
        XCTAssertEqual(lastWeek.comparisonInterval?.start, date(year: 2022, month: 12, day: 26))

        let thisMonth = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .thisMonth
        )
        XCTAssertEqual(thisMonth.interval.start, date(year: 2023, month: 1, day: 1))
        XCTAssertEqual(thisMonth.interval.end, date(year: 2023, month: 2, day: 1))
        XCTAssertEqual(thisMonth.comparisonInterval?.start, date(year: 2022, month: 12, day: 1))

        let last30 = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .last30Days
        )
        XCTAssertEqual(last30.interval.start, date(year: 2022, month: 12, day: 17))
        XCTAssertEqual(last30.interval.end, date(year: 2023, month: 1, day: 16))
        XCTAssertEqual(last30.comparisonInterval?.start, date(year: 2022, month: 11, day: 17))

        let last90 = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .last90Days
        )
        XCTAssertEqual(last90.interval.start, date(year: 2022, month: 10, day: 18))
        XCTAssertEqual(last90.interval.end, date(year: 2023, month: 1, day: 16))

        let allTime = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .allTime
        )
        XCTAssertNil(allTime.comparisonInterval)
        XCTAssertNil(allTime.durationDifference)
        XCTAssertNil(allTime.comparisonSessionCount)
    }

    func testSessionCountCountsBoundaryOverlapOnceAndAverageUsesClippedDuration() {
        let reference = date(year: 2023, month: 1, day: 9, hour: 12)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 8, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 9, hour: 1),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [session]

        let summary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .thisWeek
        )

        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.totalDuration, 3_600, accuracy: 0.001)
        XCTAssertEqual(summary.averageSessionDuration, 3_600, accuracy: 0.001)
    }

    func testGoalOutcomeInsightsPartitionCompletedSessionsAndExcludeActive() throws {
        let reference = date(year: 2023, month: 1, day: 11, hour: 13)
        let projectID = UUID()
        func completed(
            goal: String?,
            outcome: String?,
            projectID: UUID? = nil,
            hour: Int
        ) -> CompletedSession {
            let start = date(year: 2023, month: 1, day: 10, hour: hour)
            return CompletedSession(
                id: UUID(),
                projectID: projectID,
                projectName: projectID == nil ? nil : "Tracked",
                goal: goal,
                outcome: outcome,
                startedAt: start,
                endedAt: start.addingTimeInterval(3_600),
                pauseIntervals: []
            )
        }

        let closedLoop = completed(goal: "Ship", outcome: "Shipped", projectID: projectID, hour: 9)
        let needsFollowUp = completed(goal: "Review", outcome: nil, projectID: projectID, hour: 10)
        let outcomeOnly = completed(goal: nil, outcome: "Noted", hour: 11)
        let untracked = completed(goal: " \n ", outcome: "\t", hour: 12)
        let otherProject = completed(goal: "Other", outcome: "Done", projectID: UUID(), hour: 13)
        let active = ActiveSession(
            projectID: projectID,
            projectName: "Tracked",
            goal: "Still working",
            startedAt: date(year: 2023, month: 1, day: 11, hour: 11)
        )

        var state = AppState()
        state.completedSessions = [closedLoop, needsFollowUp, outcomeOnly, untracked, otherProject]
        state.activeSession = active

        let insights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        ).goalOutcomeInsights

        XCTAssertEqual(insights.completedSessionCount, 5)
        XCTAssertEqual(insights.sessionsWithGoal, 3)
        XCTAssertEqual(insights.sessionsWithOutcome, 3)
        XCTAssertEqual(insights.closedLoopCount, 2)
        XCTAssertEqual(insights.needsFollowUpCount, 1)
        XCTAssertEqual(insights.outcomeOnlyCount, 1)
        XCTAssertEqual(insights.untrackedCount, 1)
        XCTAssertEqual(insights.closedLoopCount + insights.needsFollowUpCount, insights.sessionsWithGoal)
        XCTAssertEqual(insights.closedLoopCount + insights.outcomeOnlyCount, insights.sessionsWithOutcome)
        XCTAssertEqual(
            insights.closedLoopCount + insights.needsFollowUpCount + insights.outcomeOnlyCount + insights.untrackedCount,
            insights.completedSessionCount
        )
        XCTAssertEqual(try XCTUnwrap(insights.closedLoopRate), 2.0 / 3.0, accuracy: 0.000_001)

        let projectInsights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            project: .projectID(projectID)
        ).goalOutcomeInsights
        XCTAssertEqual(projectInsights.completedSessionCount, 2)
        XCTAssertEqual(projectInsights.closedLoopCount, 1)
        XCTAssertEqual(projectInsights.needsFollowUpCount, 1)
        XCTAssertEqual(projectInsights.sessionsWithOutcome, 1)

        let noGoals = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            goal: "\n\t",
            outcome: " ",
            startedAt: date(year: 2023, month: 1, day: 10, hour: 15),
            endedAt: date(year: 2023, month: 1, day: 10, hour: 16),
            pauseIntervals: []
        )
        var noGoalState = AppState()
        noGoalState.completedSessions = [noGoals]
        let noGoalInsights = InsightsCalculator.summary(
            state: noGoalState,
            calendar: calendar,
            referenceDate: reference
        ).goalOutcomeInsights
        XCTAssertEqual(noGoalInsights.completedSessionCount, 1)
        XCTAssertEqual(noGoalInsights.closedLoopCount, 0)
        XCTAssertNil(noGoalInsights.closedLoopRate)
    }

    func testGoalOutcomeInsightsUseTimeframeOverlap() {
        let reference = date(year: 2023, month: 1, day: 11, hour: 13)
        let crossing = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            goal: "Cross boundary",
            outcome: "Recorded",
            startedAt: date(year: 2023, month: 1, day: 8, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 9, hour: 1),
            pauseIntervals: []
        )
        let previous = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            goal: "Previous",
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 8, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 8, hour: 11),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [crossing, previous]

        let thisWeek = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .thisWeek
        ).goalOutcomeInsights
        XCTAssertEqual(thisWeek.completedSessionCount, 1)
        XCTAssertEqual(thisWeek.closedLoopCount, 1)

        let lastWeek = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .lastWeek
        ).goalOutcomeInsights
        XCTAssertEqual(lastWeek.completedSessionCount, 2)
        XCTAssertEqual(lastWeek.closedLoopCount, 1)
        XCTAssertEqual(lastWeek.needsFollowUpCount, 1)
    }

    func testProjectFiltersIncludeNoProjectAndDeletedHistoricalProject() {
        let reference = date(year: 2023, month: 1, day: 11, hour: 13)
        let configuredID = UUID()
        let deletedID = UUID()
        let configured = CompletedSession(
            id: UUID(),
            projectID: configuredID,
            projectName: "Configured",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 11, hour: 9),
            endedAt: date(year: 2023, month: 1, day: 11, hour: 10),
            pauseIntervals: []
        )
        let deleted = CompletedSession(
            id: UUID(),
            projectID: deletedID,
            projectName: "Deleted Project",
            type: .debugging,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 11, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 11, hour: 12),
            pauseIntervals: []
        )
        let noProject = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .research,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 11, hour: 12),
            endedAt: date(year: 2023, month: 1, day: 11, hour: 13),
            pauseIntervals: []
        )
        let namedNoProject = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Configured",
            type: .planning,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 10, hour: 9),
            endedAt: date(year: 2023, month: 1, day: 10, hour: 10),
            pauseIntervals: []
        )
        var state = AppState()
        state.projects = [ProjectRecord(id: configuredID, name: "Configured")]
        state.completedSessions = [configured, deleted, noProject, namedNoProject]

        let configuredSummary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            project: .projectID(configuredID)
        )
        XCTAssertEqual(configuredSummary.totalDuration, 3_600, accuracy: 0.001)
        XCTAssertEqual(configuredSummary.sessionCount, 1)

        let deletedSummary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            project: .projectID(deletedID)
        )
        XCTAssertEqual(deletedSummary.totalDuration, 7_200, accuracy: 0.001)
        XCTAssertEqual(deletedSummary.projectBreakdown.first?.label, "Deleted Project")

        let noProjectSummary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            project: .noProject
        )
        XCTAssertEqual(noProjectSummary.totalDuration, 3_600, accuracy: 0.001)
        XCTAssertEqual(noProjectSummary.projectBreakdown.first?.label, "No Project")

        let store = SessionStore(
            persistence: InsightsTestPersistence(state),
            clock: InsightsTestClock(reference),
            calendar: calendar,
            automaticallyRefresh: false
        )
        XCTAssertTrue(store.insightsProjectOptions.contains {
            $0.filter == .projectID(deletedID) && $0.title == "Deleted Project"
        })
        let configuredOptions = store.insightsProjectOptions.filter { $0.title == "Configured" }
        XCTAssertEqual(configuredOptions.count, 1)
        XCTAssertTrue(configuredOptions.first?.filter == .projectID(configuredID))
        XCTAssertFalse(store.insightsProjectOptions.contains { $0.filter == .historicalName("Configured") })
    }

    func testInsightsProjectOptionsUseMostRecentHistoricalProjectName() {
        let reference = date(year: 2023, month: 1, day: 11, hour: 13)
        let historicalID = UUID()
        let newer = CompletedSession(
            id: UUID(),
            projectID: historicalID,
            projectName: "Newest Name",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 11, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 11, hour: 11),
            pauseIntervals: []
        )
        let older = CompletedSession(
            id: UUID(),
            projectID: historicalID,
            projectName: "Older Name",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 9, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 9, hour: 11),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [newer, older]

        let store = SessionStore(
            persistence: InsightsTestPersistence(state),
            clock: InsightsTestClock(reference),
            calendar: calendar,
            automaticallyRefresh: false
        )

        XCTAssertEqual(
            store.insightsProjectOptions.first(where: { $0.filter == .projectID(historicalID) })?.title,
            "Newest Name"
        )
    }

    func testDeveloperToolParticipationUsesOverlappingSessionSemantics() {
        let reference = date(year: 2023, month: 1, day: 11, hour: 18)
        let codex = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "codex-1",
            workingDirectory: "/tmp/CodePulse",
            firstActivityAt: date(year: 2023, month: 1, day: 11, hour: 9),
            lastActivityAt: date(year: 2023, month: 1, day: 11, hour: 10),
            model: " GPT-5.6 Sol ",
            profile: "Builder",
            eventCount: 2
        )
        let codexDuplicate = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "codex-2",
            workingDirectory: "/tmp/CodePulse",
            firstActivityAt: date(year: 2023, month: 1, day: 11, hour: 9),
            lastActivityAt: date(year: 2023, month: 1, day: 11, hour: 11),
            model: "GPT-5.6 Sol",
            profile: "Builder"
        )
        let openCode = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "opencode-1",
            workingDirectory: "/tmp/CodePulse",
            firstActivityAt: date(year: 2023, month: 1, day: 11, hour: 11),
            lastActivityAt: date(year: 2023, month: 1, day: 11, hour: 12),
            model: "DeepSeek V4 Flash",
            profile: "Reviewer"
        )
        let both = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "opencode-2",
            workingDirectory: "/tmp/CodePulse",
            firstActivityAt: date(year: 2023, month: 1, day: 11, hour: 13),
            lastActivityAt: date(year: 2023, month: 1, day: 11, hour: 14),
            model: "DeepSeek V4 Flash"
        )
        let bothCodex = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "codex-3",
            workingDirectory: "/tmp/CodePulse",
            firstActivityAt: date(year: 2023, month: 1, day: 11, hour: 13),
            lastActivityAt: date(year: 2023, month: 1, day: 11, hour: 14),
            model: "GPT-5.6 Sol"
        )

        func makeSession(
            id: Int,
            startHour: Int,
            endHour: Int,
            contexts: [DeveloperToolSessionContext]
        ) -> CompletedSession {
            CompletedSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                projectID: nil,
                projectName: nil,
                type: .coding,
                goal: nil,
                outcome: nil,
                startedAt: date(year: 2023, month: 1, day: 11, hour: startHour),
                endedAt: date(year: 2023, month: 1, day: 11, hour: endHour),
                pauseIntervals: [],
                developerToolContexts: contexts
            )
        }

        var state = AppState()
        state.completedSessions = [
            makeSession(id: 1, startHour: 9, endHour: 10, contexts: [codex, codexDuplicate]),
            makeSession(id: 2, startHour: 10, endHour: 12, contexts: [openCode]),
            makeSession(id: 3, startHour: 13, endHour: 15, contexts: [both, bothCodex]),
            makeSession(id: 4, startHour: 15, endHour: 16, contexts: [])
        ]

        let insights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        ).developerToolInsights

        XCTAssertEqual(insights.sessionsWithCodex, 2)
        XCTAssertEqual(insights.sessionsWithOpenCode, 2)
        XCTAssertEqual(insights.sessionsWithBoth, 1)
        XCTAssertEqual(insights.sessionsWithAnyTool, 3)
        XCTAssertEqual(insights.sessionsWithNoTool, 1)
        XCTAssertEqual(insights.modelBreakdown.first(where: { $0.label == "GPT-5.6 Sol" })?.count, 2)
        XCTAssertEqual(insights.modelBreakdown.first(where: { $0.label == "DeepSeek V4 Flash" })?.count, 2)
        XCTAssertEqual(insights.profileBreakdown.first(where: { $0.label == "Builder" })?.count, 1)
        XCTAssertEqual(insights.profileBreakdown.first(where: { $0.label == "Reviewer" })?.count, 1)
    }

    func testGitInsightsKeepPartialMetricsUnavailableInsteadOfZero() {
        let reference = date(year: 2023, month: 1, day: 11, hour: 13)
        func session(id: Int, context: GitSessionContext?) -> CompletedSession {
            CompletedSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                projectID: nil,
                projectName: nil,
                type: .coding,
                goal: nil,
                outcome: nil,
                startedAt: date(year: 2023, month: 1, day: 11, hour: 9 + id),
                endedAt: date(year: 2023, month: 1, day: 11, hour: 10 + id),
                pauseIntervals: [],
                gitContext: context
            )
        }
        let complete = GitSessionContext(
            repositoryRoot: "/tmp/repository",
            commitCount: 2,
            filesChanged: 3,
            insertions: 12,
            deletions: 4
        )
        let partial = GitSessionContext(repositoryRoot: "/tmp/partial", commitCount: 1)
        var state = AppState()
        state.completedSessions = [session(id: 1, context: complete), session(id: 2, context: partial)]

        let insights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        ).gitInsights

        XCTAssertEqual(insights.sessionsWithGitContext, 2)
        XCTAssertNil(insights.totalFilesChanged)
        XCTAssertNil(insights.totalInsertions)
        XCTAssertNil(insights.totalDeletions)
        XCTAssertEqual(insights.totalCommits, 3)
    }

    func testGitHubInsightsUseRepositoryAndPullRequestIdentity() throws {
        let reference = date(year: 2023, month: 1, day: 11, hour: 18)
        let firstPR = GitHubPullRequestSnapshot(
            number: 7,
            title: "First PR",
            state: .open,
            isDraft: false,
            url: "https://github.com/owner/one/pull/7"
        )
        let secondRepositorySameNumber = GitHubPullRequestSnapshot(
            number: 7,
            title: "Other repository PR",
            state: .open,
            isDraft: false,
            url: "https://github.com/owner/two/pull/7"
        )
        func context(_ repository: String, _ pullRequest: GitHubPullRequestSnapshot?) -> GitHubSessionContext {
            GitHubSessionContext(
                repositoryNameWithOwner: repository,
                repositoryURL: "https://github.com/\(repository)",
                pullRequest: pullRequest
            )
        }
        func session(id: Int, startHour: Int, endHour: Int, context: GitHubSessionContext) -> CompletedSession {
            CompletedSession(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
                projectID: nil,
                projectName: nil,
                type: .coding,
                goal: nil,
                outcome: nil,
                startedAt: date(year: 2023, month: 1, day: 11, hour: startHour),
                endedAt: date(year: 2023, month: 1, day: 11, hour: endHour),
                pauseIntervals: [],
                githubContext: context
            )
        }
        var state = AppState()
        state.completedSessions = [
            session(id: 1, startHour: 9, endHour: 10, context: context("owner/one", firstPR)),
            session(id: 2, startHour: 10, endHour: 12, context: context("OWNER/ONE", firstPR)),
            session(id: 3, startHour: 13, endHour: 15, context: context("owner/two", secondRepositorySameNumber))
        ]

        let insights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        ).githubInsights

        XCTAssertEqual(insights.sessionsWithGitHubContext, 3)
        XCTAssertEqual(insights.sessionsWithPullRequest, 3)
        XCTAssertEqual(insights.uniqueRepositories, 2)
        XCTAssertEqual(insights.uniquePullRequests, 2)
        XCTAssertEqual(insights.repositoryBreakdown.first?.label, "owner/one")
        XCTAssertEqual(try XCTUnwrap(insights.repositoryBreakdown.first?.duration), 10_800, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(insights.repositoryBreakdown.last?.duration), 7_200, accuracy: 0.001)
    }

    func testDailyActivityUsesLocalDayAndDSTBoundary() throws {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Denver")!
        dstCalendar.locale = Locale(identifier: "en_US_POSIX")
        dstCalendar.firstWeekday = 2
        let start = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 12, hour: 1, minute: 30))!
        let end = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 12, hour: 3, minute: 30))!
        let reference = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 13, hour: 12))!
        var state = AppState()
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: start,
            endedAt: end,
            pauseIntervals: []
        )]

        let summary = InsightsCalculator.summary(
            state: state,
            calendar: dstCalendar,
            referenceDate: reference,
            timeframe: .thisMonth
        )

        XCTAssertEqual(summary.totalDuration, 3_600, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(summary.dailyActivity.first(where: {
            dstCalendar.isDate($0.date, inSameDayAs: start)
        })?.duration), 3_600, accuracy: 0.001)
    }

    func testNonDefaultFirstWeekdayChangesWeekBoundary() {
        var sundayCalendar = calendar
        sundayCalendar.firstWeekday = 1
        let reference = date(year: 2023, month: 1, day: 7, hour: 12)
        let summary = InsightsCalculator.summary(
            state: AppState(),
            calendar: sundayCalendar,
            referenceDate: reference,
            timeframe: .thisWeek
        )
        XCTAssertEqual(summary.interval.start, date(year: 2023, month: 1, day: 1))
        XCTAssertEqual(summary.interval.end, date(year: 2023, month: 1, day: 8))
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

private final class InsightsTestPersistence: StatePersisting {
    private var state: AppState

    init(_ state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}
