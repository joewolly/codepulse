import Foundation
import CodePulseIntegration
import XCTest
@testable import CodePulse

@MainActor
final class DigestTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()

    // MARK: - Period calculation

    func testDailyPeriodIsPreviousCompletedCalendarDay() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let period = DigestPeriodCalculator.completedPeriod(kind: .daily, referenceDate: reference, calendar: calendar)
        XCTAssertEqual(period.interval.start, date(year: 2023, month: 1, day: 3))
        XCTAssertEqual(period.interval.end, date(year: 2023, month: 1, day: 4))
        XCTAssertEqual(period.comparisonInterval?.start, date(year: 2023, month: 1, day: 2))
        XCTAssertEqual(period.comparisonInterval?.end, date(year: 2023, month: 1, day: 3))
    }

    func testWeeklyPeriodIsPreviousCompletedCalendarWeek() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let period = DigestPeriodCalculator.completedPeriod(kind: .weekly, referenceDate: reference, calendar: calendar)
        XCTAssertEqual(period.interval.start, date(year: 2022, month: 12, day: 26))
        XCTAssertEqual(period.interval.end, date(year: 2023, month: 1, day: 2))
        XCTAssertEqual(period.comparisonInterval?.start, date(year: 2022, month: 12, day: 19))
        XCTAssertEqual(period.comparisonInterval?.end, date(year: 2022, month: 12, day: 26))
    }

    func testCustomFirstWeekdayChangesWeeklyPeriod() {
        var sundayCalendar = calendar
        sundayCalendar.firstWeekday = 1
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let period = DigestPeriodCalculator.completedPeriod(
            kind: .weekly,
            referenceDate: reference,
            calendar: sundayCalendar
        )
        XCTAssertEqual(period.interval.start, date(year: 2022, month: 12, day: 25))
        XCTAssertEqual(period.interval.end, date(year: 2023, month: 1, day: 1))
    }

    func testDailyPeriodAcrossDSTSpringForward() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Denver")!
        dstCalendar.locale = Locale(identifier: "en_US_POSIX")
        dstCalendar.firstWeekday = 2
        let reference = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 13, hour: 12))!
        let period = DigestPeriodCalculator.completedPeriod(
            kind: .daily,
            referenceDate: reference,
            calendar: dstCalendar
        )
        let dayStart = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 12))!
        let nextDay = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 13))!
        XCTAssertEqual(period.interval.start, dayStart)
        XCTAssertEqual(period.interval.end, nextDay)
        XCTAssertEqual(period.interval.duration, 23 * 3_600, accuracy: 0.001)
        XCTAssertEqual(try! XCTUnwrap(period.comparisonInterval).duration, 24 * 3_600, accuracy: 0.001)
    }

    func testDailyPeriodAcrossDSTFallBack() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Denver")!
        dstCalendar.locale = Locale(identifier: "en_US_POSIX")
        dstCalendar.firstWeekday = 2
        let reference = dstCalendar.date(from: DateComponents(year: 2022, month: 11, day: 7, hour: 12))!
        let period = DigestPeriodCalculator.completedPeriod(
            kind: .daily,
            referenceDate: reference,
            calendar: dstCalendar
        )
        XCTAssertEqual(period.interval.duration, 25 * 3_600, accuracy: 0.001)
        XCTAssertEqual(try! XCTUnwrap(period.comparisonInterval).duration, 24 * 3_600, accuracy: 0.001)
    }

    func testWeeklyPeriodAcrossDSTSpringForward() {
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Denver")!
        dstCalendar.locale = Locale(identifier: "en_US_POSIX")
        dstCalendar.firstWeekday = 2
        let reference = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 13, hour: 12))!
        let period = DigestPeriodCalculator.completedPeriod(
            kind: .weekly,
            referenceDate: reference,
            calendar: dstCalendar
        )
        let weekStart = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 6))!
        let weekEnd = dstCalendar.date(from: DateComponents(year: 2023, month: 3, day: 13))!
        XCTAssertEqual(period.interval.start, weekStart)
        XCTAssertEqual(period.interval.end, weekEnd)
    }

    func testNextDeliveryDateUsesCalendarSemantics() {
        let settings = DigestSettings(dailyTime: DigestDeliveryTime(hour: 9, minute: 0))
        let reference = date(year: 2023, month: 1, day: 4, hour: 8)
        let due = DigestPeriodCalculator.nextDeliveryDate(
            kind: .daily,
            after: reference,
            settings: settings,
            calendar: calendar
        )
        XCTAssertEqual(due, date(year: 2023, month: 1, day: 4, hour: 9))
    }

    func testDeliveryDateReturnsDailyPeriodEndAtExactMidnight() {
        let settings = DigestSettings(dailyTime: DigestDeliveryTime(hour: 0, minute: 0))
        let periodEnd = date(year: 2023, month: 1, day: 4)
        let due = DigestPeriodCalculator.deliveryDate(
            kind: .daily,
            forPeriodEnding: periodEnd,
            settings: settings,
            calendar: calendar
        )
        XCTAssertEqual(due, periodEnd)
    }

    func testDeliveryDateReturnsWeeklyPeriodEndAtExactMondayMidnight() {
        let settings = DigestSettings(
            weeklyWeekday: .monday,
            weeklyTime: DigestDeliveryTime(hour: 0, minute: 0)
        )
        let periodEnd = date(year: 2023, month: 1, day: 2)
        let due = DigestPeriodCalculator.deliveryDate(
            kind: .weekly,
            forPeriodEnding: periodEnd,
            settings: settings,
            calendar: calendar
        )
        XCTAssertEqual(due, periodEnd)
    }

    func testNextDeliveryDateRemainsStrictlyFutureAfterSundayNight() {
        let settings = DigestSettings(dailyTime: DigestDeliveryTime(hour: 0, minute: 0))
        let reference = date(year: 2023, month: 1, day: 1, hour: 23, minute: 30)
        let due = DigestPeriodCalculator.nextDeliveryDate(
            kind: .daily,
            after: reference,
            settings: settings,
            calendar: calendar
        )
        XCTAssertEqual(due, date(year: 2023, month: 1, day: 2))
    }

    func testDigestDeliveryTimeDecodingClampsOutOfRangeComponentsAndPreservesRoundTrip() throws {
        let decoder = JSONDecoder()
        let malformed = try decoder.decode(
            DigestDeliveryTime.self,
            from: Data(#"{"hour":100,"minute":-20}"#.utf8)
        )
        XCTAssertEqual(malformed, DigestDeliveryTime(hour: 23, minute: 0))

        let otherMalformed = try decoder.decode(
            DigestDeliveryTime.self,
            from: Data(#"{"hour":-1,"minute":60}"#.utf8)
        )
        XCTAssertEqual(otherMalformed, DigestDeliveryTime(hour: 0, minute: 59))

        let normal = DigestDeliveryTime(hour: 14, minute: 35)
        let encoded = try JSONEncoder().encode(normal)
        XCTAssertEqual(try decoder.decode(DigestDeliveryTime.self, from: encoded), normal)
    }

    func testMalformedDigestDeliveryTimeDoesNotMakeAppStateUndecodable() throws {
        let data = Data("""
        {
            "settings": {
                "digests": {
                    "dailyEnabled": true,
                    "dailyTime": {"hour": 100, "minute": -20},
                    "weeklyEnabled": false,
                    "weeklyWeekday": 2,
                    "weeklyTime": {"hour": -1, "minute": 60}
                }
            }
        }
        """.utf8)

        let state = try JSONDecoder().decode(AppState.self, from: data)

        XCTAssertEqual(state.settings.digests.dailyTime, DigestDeliveryTime(hour: 23, minute: 0))
        XCTAssertEqual(state.settings.digests.weeklyTime, DigestDeliveryTime(hour: 0, minute: 59))
    }

    func testDigestTimeEditorUsesInjectedCalendarForReadAndWrite() {
        var editorCalendar = Calendar(identifier: .gregorian)
        editorCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        editorCalendar.locale = Locale(identifier: "en_US_POSIX")
        let referenceDate = Date(timeIntervalSince1970: 0)
        let time = DigestDeliveryTime(hour: 7, minute: 45)

        let pickerDate = DigestTimeEditorSupport.date(
            for: time,
            calendar: editorCalendar,
            referenceDate: referenceDate
        )
        let pickerComponents = editorCalendar.dateComponents([.hour, .minute], from: pickerDate)
        XCTAssertEqual(pickerComponents.hour, 7)
        XCTAssertEqual(pickerComponents.minute, 45)

        let editedDate = editorCalendar.date(
            from: DateComponents(year: 1970, month: 1, day: 1, hour: 18, minute: 20)
        )!
        XCTAssertEqual(
            DigestTimeEditorSupport.time(from: editedDate, calendar: editorCalendar, fallback: time),
            DigestDeliveryTime(hour: 18, minute: 20)
        )
    }

    // MARK: - Metrics

    func testDailyDigestMetricsAndComparison() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let previousDay = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "CodePulse",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 3, hour: 12),
            pauseIntervals: [
                PauseInterval(
                    startedAt: date(year: 2023, month: 1, day: 3, hour: 11),
                    endedAt: date(year: 2023, month: 1, day: 3, hour: 11, minute: 30)
                )
            ]
        )
        let dayBefore = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "Other",
            type: .planning,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 2, hour: 9),
            endedAt: date(year: 2023, month: 1, day: 2, hour: 10),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [previousDay, dayBefore]

        let summary = DigestCalculator.summary(state: state, kind: .daily, referenceDate: reference, calendar: calendar)

        XCTAssertEqual(summary.totalActiveTime, 5_400, accuracy: 0.001) // 2h minus 30m pause
        XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(summary.topProject?.label, "CodePulse")
        XCTAssertEqual(try! XCTUnwrap(summary.topProject?.duration), 5_400, accuracy: 0.001)
        XCTAssertEqual(summary.topType?.label, "Coding")
        XCTAssertEqual(try! XCTUnwrap(summary.comparisonTotalActiveTime), 3_600, accuracy: 0.001)
        XCTAssertEqual(summary.comparisonSessionCount, 1)
        XCTAssertEqual(summary.activeTimeDelta ?? -1, 1_800, accuracy: 0.001)
        XCTAssertEqual(summary.sessionCountDelta, 0)
    }

    func testDigestTopProjectExcludesOnlySyntheticNoProjectBucket() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let userProjectID = UUID()
        let syntheticNoProject = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 9),
            endedAt: date(year: 2023, month: 1, day: 3, hour: 12),
            pauseIntervals: []
        )
        let realProjectNamedNoProject = CompletedSession(
            id: UUID(),
            projectID: userProjectID,
            projectName: "No Project",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 13),
            endedAt: date(year: 2023, month: 1, day: 3, hour: 14),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [syntheticNoProject, realProjectNamedNoProject]

        let insights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            interval: DigestPeriodCalculator.completedPeriod(
                kind: .daily,
                referenceDate: reference,
                calendar: calendar
            ).interval,
            comparisonInterval: nil,
            timeframe: .allTime
        )
        let summary = DigestCalculator.summary(
            state: state,
            kind: .daily,
            referenceDate: reference,
            calendar: calendar
        )

        XCTAssertEqual(insights.projectBreakdown.first?.id, "no-project")
        XCTAssertEqual(summary.topProject?.label, "No Project")
        XCTAssertEqual(summary.topProject?.duration ?? -1, 3_600, accuracy: 0.001)
    }

    func testWeeklyDigestMatchesSharedInsightsCalculation() {
        let reference = date(year: 2023, month: 1, day: 11, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "CodePulse",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 2, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 2, hour: 11),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [session]

        let digest = DigestCalculator.summary(state: state, kind: .weekly, referenceDate: reference, calendar: calendar)
        let insights = InsightsCalculator.summary(state: state, calendar: calendar, referenceDate: reference, timeframe: .lastWeek)

        XCTAssertEqual(digest.totalActiveTime, insights.totalDuration, accuracy: 0.001)
        XCTAssertEqual(digest.sessionCount, insights.sessionCount)
        XCTAssertEqual(digest.period.interval.start, insights.interval.start)
        XCTAssertEqual(digest.period.interval.end, insights.interval.end)
        XCTAssertEqual(digest.period.comparisonInterval, insights.comparisonInterval)
        XCTAssertEqual(digest.comparisonTotalActiveTime ?? -1, insights.comparisonDuration, accuracy: 0.001)
        XCTAssertEqual(digest.comparisonSessionCount, insights.comparisonSessionCount)
    }

    func testDeveloperToolParticipationIsReusedFromInsights() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let codex = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "codex-1",
            workingDirectory: "/tmp/CodePulse",
            firstActivityAt: date(year: 2023, month: 1, day: 3, hour: 10),
            lastActivityAt: date(year: 2023, month: 1, day: 3, hour: 11),
            model: "Some Model",
            profile: "Some Profile"
        )
        let openCode = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "opencode-1",
            workingDirectory: "/tmp/CodePulse",
            firstActivityAt: date(year: 2023, month: 1, day: 3, hour: 11),
            lastActivityAt: date(year: 2023, month: 1, day: 3, hour: 12)
        )
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 3, hour: 12),
            pauseIntervals: [],
            developerToolContexts: [codex, openCode]
        )
        var state = AppState()
        state.completedSessions = [session]

        let summary = DigestCalculator.summary(state: state, kind: .daily, referenceDate: reference, calendar: calendar)
        XCTAssertEqual(summary.developerToolParticipation.sessionsWithAnyTool, 1)
        XCTAssertEqual(summary.developerToolParticipation.sessionsWithCodex, 1)
        XCTAssertEqual(summary.developerToolParticipation.sessionsWithOpenCode, 1)
    }

    // MARK: - Session boundary correctness

    func testSessionCrossingMidnightContributesOnlyItsInPeriodPortion() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let crossing = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 4, hour: 1, minute: 30),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [crossing]

        let previousDay = DigestCalculator.summary(
            state: state, kind: .daily, referenceDate: reference, calendar: calendar
        )
        XCTAssertEqual(previousDay.totalActiveTime, 3_600, accuracy: 0.001)

        let currentDay = DigestCalculator.summary(
            state: state,
            kind: .daily,
            referenceDate: date(year: 2023, month: 1, day: 5, hour: 13),
            calendar: calendar
        )
        XCTAssertEqual(currentDay.totalActiveTime, 5_400, accuracy: 0.001)
    }

    func testPauseCrossingBoundaryIsSubtractedOnBothSides() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 23, minute: 30),
            endedAt: date(year: 2023, month: 1, day: 4, hour: 1, minute: 30),
            pauseIntervals: [
                PauseInterval(
                    startedAt: date(year: 2023, month: 1, day: 3, hour: 23, minute: 45),
                    endedAt: date(year: 2023, month: 1, day: 4, hour: 0, minute: 15)
                )
            ]
        )
        var state = AppState()
        state.completedSessions = [session]

        let previousDay = DigestCalculator.summary(
            state: state, kind: .daily, referenceDate: reference, calendar: calendar
        )
        XCTAssertEqual(previousDay.totalActiveTime, 900, accuracy: 0.001) // 30m − 15m

        let currentDay = DigestCalculator.summary(
            state: state,
            kind: .daily,
            referenceDate: date(year: 2023, month: 1, day: 5, hour: 13),
            calendar: calendar
        )
        XCTAssertEqual(currentDay.totalActiveTime, 4_500, accuracy: 0.001) // 90m − 15m
    }

    func testActiveSessionOverlappingCompletedPeriodContributesHistoricalPortion() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 10)
        let active = ActiveSession(
            projectID: nil,
            projectName: nil,
            type: .research,
            goal: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 22)
        )
        var state = AppState()
        state.activeSession = active

        let summary = DigestCalculator.summary(state: state, kind: .daily, referenceDate: reference, calendar: calendar)
        XCTAssertEqual(summary.totalActiveTime, 7_200, accuracy: 0.001) // 22:00 → midnight
        XCTAssertEqual(summary.sessionCount, 1)
    }

    func testSessionOverlappingWeekBoundaryIsNotDoubleCounted() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let crossing = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 1, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 2, hour: 1),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [crossing]

        let weekBefore = DigestCalculator.summary(
            state: state, kind: .weekly, referenceDate: reference, calendar: calendar
        )
        XCTAssertEqual(weekBefore.totalActiveTime, 3_600, accuracy: 0.001)
        XCTAssertEqual(weekBefore.sessionCount, 1)

        let weekAfter = DigestCalculator.summary(
            state: state,
            kind: .weekly,
            referenceDate: date(year: 2023, month: 1, day: 11, hour: 13),
            calendar: calendar
        )
        XCTAssertEqual(weekAfter.totalActiveTime, 3_600, accuracy: 0.001)
        XCTAssertEqual(weekAfter.sessionCount, 1)
        XCTAssertEqual(weekBefore.totalActiveTime + weekAfter.totalActiveTime, 7_200, accuracy: 0.001)
    }

    func testCompletedSessionOverlappingPeriodByOnlyPartOfDuration() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 3, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 4, hour: 2),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [session]

        let summary = DigestCalculator.summary(state: state, kind: .daily, referenceDate: reference, calendar: calendar)
        XCTAssertEqual(summary.totalActiveTime, 3_600, accuracy: 0.001)
    }

    func testZeroActivityPeriodHasNoFabricatedMetrics() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let summary = DigestCalculator.summary(state: AppState(), kind: .daily, referenceDate: reference, calendar: calendar)
        XCTAssertFalse(summary.hasActivity)
        XCTAssertNil(summary.topProject)
        XCTAssertNil(summary.topType)
        XCTAssertEqual(summary.sessionCount, 0)
        XCTAssertEqual(summary.totalActiveTime, 0)
        XCTAssertEqual(summary.developerToolParticipation, DigestDeveloperToolParticipation(
            sessionsWithAnyTool: 0,
            sessionsWithCodex: 0,
            sessionsWithOpenCode: 0
        ))
    }

    // MARK: - Composition

    func testComposesNormalDailyDigest() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let summary = DigestSummary(
            period: DigestPeriodCalculator.completedPeriod(kind: .daily, referenceDate: reference, calendar: calendar),
            totalActiveTime: 45_960, // 12h 46m
            sessionCount: 11,
            topProject: DigestTopItem(label: "CodePulse", duration: 25_920), // 7h 12m
            topType: DigestTopItem(label: "Coding", duration: 30_000),
            developerToolParticipation: DigestDeveloperToolParticipation(
                sessionsWithAnyTool: 8, sessionsWithCodex: 8, sessionsWithOpenCode: 0
            ),
            comparisonTotalActiveTime: 37_560, // +2h 20m delta
            comparisonSessionCount: 9
        )
        let content = DigestComposer.content(summary: summary, calendar: calendar)
        XCTAssertEqual(content.title, "Your CodePulse day")
        XCTAssertEqual(
            content.body,
            "12h 46m across 11 sessions, +2h 20m from the previous day. "
                + "CodePulse was your top project at 7h 12m. "
                + "Coding was your top work type at 8h 20m. "
                + "Codex participated in 8 sessions."
        )
    }

    func testComposesNormalWeeklyDigest() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let summary = DigestSummary(
            period: DigestPeriodCalculator.completedPeriod(kind: .weekly, referenceDate: reference, calendar: calendar),
            totalActiveTime: 7_200,
            sessionCount: 2,
            topProject: DigestTopItem(label: "CodePulse", duration: 7_200),
            topType: nil,
            developerToolParticipation: DigestDeveloperToolParticipation(
                sessionsWithAnyTool: 2, sessionsWithCodex: 1, sessionsWithOpenCode: 2
            ),
            comparisonTotalActiveTime: 3_600,
            comparisonSessionCount: 1
        )
        let content = DigestComposer.content(summary: summary, calendar: calendar)
        XCTAssertEqual(content.title, "Your CodePulse week")
        XCTAssertEqual(
            content.body,
            "2h 00m across 2 sessions, +1h 00m from the previous week. "
                + "CodePulse was your top project at 2h 00m. "
                + "Codex and OpenCode participated in 1 and 2 sessions, respectively."
        )
    }

    func testComposesZeroActivityDigest() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let summary = DigestSummary(
            period: DigestPeriodCalculator.completedPeriod(kind: .daily, referenceDate: reference, calendar: calendar),
            totalActiveTime: 0,
            sessionCount: 0,
            topProject: nil,
            topType: nil,
            developerToolParticipation: DigestDeveloperToolParticipation(
                sessionsWithAnyTool: 0, sessionsWithCodex: 0, sessionsWithOpenCode: 0
            ),
            comparisonTotalActiveTime: 0,
            comparisonSessionCount: 0
        )
        let content = DigestComposer.content(summary: summary, calendar: calendar)
        XCTAssertEqual(content.title, "Your CodePulse day")
        XCTAssertEqual(content.body, "No CodePulse activity was recorded yesterday.")

        let weekly = DigestSummary(
            period: DigestPeriodCalculator.completedPeriod(kind: .weekly, referenceDate: reference, calendar: calendar),
            totalActiveTime: 0,
            sessionCount: 0,
            topProject: nil,
            topType: nil,
            developerToolParticipation: DigestDeveloperToolParticipation(
                sessionsWithAnyTool: 0, sessionsWithCodex: 0, sessionsWithOpenCode: 0
            ),
            comparisonTotalActiveTime: nil,
            comparisonSessionCount: nil
        )
        XCTAssertEqual(
            DigestComposer.content(summary: weekly, calendar: calendar).body,
            "No CodePulse activity was recorded last week."
        )
    }

    func testCompositionOmitsMissingProjectAndToolParticipation() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let summary = DigestSummary(
            period: DigestPeriodCalculator.completedPeriod(kind: .daily, referenceDate: reference, calendar: calendar),
            totalActiveTime: 3_600,
            sessionCount: 1,
            topProject: nil,
            topType: DigestTopItem(label: "Coding", duration: 3_600),
            developerToolParticipation: DigestDeveloperToolParticipation(
                sessionsWithAnyTool: 0, sessionsWithCodex: 0, sessionsWithOpenCode: 0
            ),
            comparisonTotalActiveTime: 1_800,
            comparisonSessionCount: 1
        )
        let content = DigestComposer.content(summary: summary, calendar: calendar)
        XCTAssertEqual(
            content.body,
            "1h 00m across 1 session, +30m from the previous day. Coding was your top work type at 1h 00m."
        )
    }

    func testCompositionHandlesNegativeAndEqualComparison() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        func summary(delta: TimeInterval, comparisonSessions: Int) -> DigestSummary {
            DigestSummary(
                period: DigestPeriodCalculator.completedPeriod(kind: .daily, referenceDate: reference, calendar: calendar),
                totalActiveTime: 7_200,
                sessionCount: 2,
                topProject: nil,
                topType: nil,
                developerToolParticipation: DigestDeveloperToolParticipation(
                    sessionsWithAnyTool: 0, sessionsWithCodex: 0, sessionsWithOpenCode: 0
                ),
                comparisonTotalActiveTime: 7_200 - delta,
                comparisonSessionCount: comparisonSessions
            )
        }

        let negative = DigestComposer.content(summary: summary(delta: -3_600, comparisonSessions: 1), calendar: calendar)
        XCTAssertTrue(negative.body.contains("−1h 00m from the previous day"))

        let positive = DigestComposer.content(summary: summary(delta: 1_800, comparisonSessions: 1), calendar: calendar)
        XCTAssertTrue(positive.body.contains("+30m from the previous day"))

        let equal = DigestComposer.content(summary: summary(delta: 0, comparisonSessions: 2), calendar: calendar)
        XCTAssertTrue(equal.body.contains("same active time as the previous day"))

        let equalSessions = DigestComposer.content(summary: summary(delta: 0, comparisonSessions: 4), calendar: calendar)
        XCTAssertTrue(equalSessions.body.contains("2 fewer sessions than the previous day"))

        let oneMoreSession = DigestComposer.content(summary: summary(delta: 0, comparisonSessions: 1), calendar: calendar)
        XCTAssertTrue(oneMoreSession.body.contains("1 more session than the previous day"))
    }

    func testCompositionIsDeterministic() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let summary = DigestSummary(
            period: DigestPeriodCalculator.completedPeriod(kind: .weekly, referenceDate: reference, calendar: calendar),
            totalActiveTime: 9_000,
            sessionCount: 3,
            topProject: DigestTopItem(label: "CodePulse", duration: 5_400),
            topType: DigestTopItem(label: "Research", duration: 4_000),
            developerToolParticipation: DigestDeveloperToolParticipation(
                sessionsWithAnyTool: 3, sessionsWithCodex: 3, sessionsWithOpenCode: 0
            ),
            comparisonTotalActiveTime: 6_000,
            comparisonSessionCount: 2
        )
        let first = DigestComposer.content(summary: summary, calendar: calendar)
        let second = DigestComposer.content(summary: summary, calendar: calendar)
        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first.body,
            "2h 30m across 3 sessions, +50m from the previous week. "
                + "CodePulse was your top project at 1h 30m. "
                + "Research was your top work type at 1h 06m. "
                + "Codex participated in 3 sessions."
        )
    }

    // MARK: - Persistence

    func testLegacySettingsWithoutDigestsDecodeDisabled() throws {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(CodePulseSettings())) as! [String: Any]
        object.removeValue(forKey: "digests")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        let settings = try decoder.decode(CodePulseSettings.self, from: data)

        XCTAssertFalse(settings.digests.dailyEnabled)
        XCTAssertFalse(settings.digests.weeklyEnabled)
        XCTAssertEqual(settings.digests.dailyTime, .defaultMorning)
        XCTAssertEqual(settings.digests.weeklyTime, .defaultMorning)
        XCTAssertEqual(settings.digests.weeklyWeekday, .monday)
    }

    func testDigestSettingsRoundTrip() throws {
        let original = DigestSettings(
            dailyEnabled: true,
            dailyTime: DigestDeliveryTime(hour: 7, minute: 45),
            weeklyEnabled: true,
            weeklyWeekday: .friday,
            weeklyTime: DigestDeliveryTime(hour: 17, minute: 30)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DigestSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testMalformedDigestSettingsFailSoftToDisabled() throws {
        let encoder = JSONEncoder()
        var object = try JSONSerialization.jsonObject(with: encoder.encode(CodePulseSettings())) as! [String: Any]
        object["digests"] = "not-a-dictionary"
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        let settings = try decoder.decode(CodePulseSettings.self, from: data)
        XCTAssertFalse(settings.digests.dailyEnabled)
        XCTAssertFalse(settings.digests.weeklyEnabled)
    }

    func testDigestSettingsSurviveBackupRoundTrip() throws {
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        state.settings.digests.weeklyEnabled = true
        state.settings.digests.weeklyWeekday = .saturday
        state.settings.digests.weeklyTime = DigestDeliveryTime(hour: 8, minute: 15)

        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: date(year: 2023, month: 1, day: 4, hour: 13))
        let backup = try CodePulseBackupCodec.decode(data)
        XCTAssertEqual(backup.state.settings.digests, state.settings.digests)
    }

    func testDigestSettingsSurviveAppStateRoundTrip() throws {
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        state.settings.digests.dailyTime = DigestDeliveryTime(hour: 6, minute: 30)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(decoded.settings.digests, state.settings.digests)
    }

    func testDeliveryTimeClampsInvalidValues() {
        XCTAssertEqual(DigestDeliveryTime(hour: 25, minute: 61), DigestDeliveryTime(hour: 23, minute: 59))
        XCTAssertEqual(DigestDeliveryTime(hour: -1, minute: -5), DigestDeliveryTime(hour: 0, minute: 0))
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
