import CodePulseControlClient
import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

@MainActor
final class Phase5InsightsControlTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    func test01UnionMergesFullOverlap() { XCTAssertEqual(ActivityCoverageCalculator.unionDuration([span(0, 60), span(0, 60)]), 60) }
    func test02UnionMergesPartialOverlap() { XCTAssertEqual(ActivityCoverageCalculator.unionDuration([span(0, 60), span(30, 90)]), 90) }
    func test03UnionPreservesDisjointIntervals() { XCTAssertEqual(ActivityCoverageCalculator.unionDuration([span(0, 60), span(90, 120)]), 90) }
    func test04UnionMergesTouchingIntervals() { XCTAssertEqual(ActivityCoverageCalculator.union([span(0, 60), span(60, 90)]).count, 1) }
    func test05UnionDropsZeroDuration() { XCTAssertTrue(ActivityCoverageCalculator.union([DateInterval(start: base, end: base)]).isEmpty) }
    func test06UnionSortsDeterministically() { XCTAssertEqual(ActivityCoverageCalculator.union([span(30, 60), span(0, 20)]).map(\.start), [base, base.addingTimeInterval(30)]) }

    func test07ActiveIntervalsRemovePauseBeforeUnion() {
        let values = ActivityCoverageCalculator.activeIntervals(
            startedAt: base, endedAt: base.addingTimeInterval(120),
            pauseIntervals: [PauseInterval(startedAt: base.addingTimeInterval(30), endedAt: base.addingTimeInterval(60))],
            in: span(0, 120), referenceDate: base.addingTimeInterval(120)
        )
        XCTAssertEqual(values.reduce(0) { $0 + $1.duration }, 90)
    }

    func test08ActiveIntervalsNormalizeOverlappingPauses() {
        let values = ActivityCoverageCalculator.activeIntervals(
            startedAt: base, endedAt: base.addingTimeInterval(120),
            pauseIntervals: [
                PauseInterval(startedAt: base.addingTimeInterval(20), endedAt: base.addingTimeInterval(60)),
                PauseInterval(startedAt: base.addingTimeInterval(40), endedAt: base.addingTimeInterval(80))
            ], in: span(0, 120), referenceDate: base.addingTimeInterval(120)
        )
        XCTAssertEqual(values.reduce(0) { $0 + $1.duration }, 60)
    }

    func test09FullyOverlappingSessionsDistinguishMetrics() { assertMetrics([(0, 60), (0, 60)], active: 60, activity: 120) }
    func test10PartialOverlapDistinguishesMetrics() { assertMetrics([(0, 60), (30, 90)], active: 90, activity: 120) }
    func test11NonOverlapMetricsMatch() { assertMetrics([(0, 60), (90, 120)], active: 90, activity: 90) }

    func test12BreakdownsRemainSessionActivity() {
        let projectID = UUID()
        let summary = summary(completed: [completed(0, 60, projectID: projectID), completed(30, 90, projectID: projectID)])
        XCTAssertEqual(summary.projectBreakdown.first?.duration, 120)
        XCTAssertEqual(summary.typeBreakdown.first?.duration, 120)
    }

    func test13AverageUsesSessionActivity() {
        let value = summary(completed: [completed(0, 60), completed(30, 90)])
        XCTAssertEqual(value.averageSessionDuration, 60)
    }

    func test14ComparisonCalculatesBothMetricClasses() {
        let state = AppState(completedSessions: [completed(0, 60), completed(30, 90), completed(-120, -60)])
        let value = InsightsCalculator.summary(
            state: state, calendar: calendar, referenceDate: base.addingTimeInterval(120),
            interval: span(0, 120), comparisonInterval: span(-120, 0), timeframe: .allTime
        )
        XCTAssertEqual(value.activeTime, 90)
        XCTAssertEqual(value.sessionActivity, 120)
        XCTAssertEqual(value.comparisonActiveTime, 60)
        XCTAssertEqual(value.comparisonSessionActivity, 60)
    }

    func test15AllTimeIncludesEarliestOfMultipleLiveSessions() {
        var state = AppState()
        state.activeSessions = [active(-600, id: UUID()), active(-300, id: UUID())]
        let interval = InsightsCalculator.interval(for: .allTime, state: state, calendar: calendar, referenceDate: base)
        XCTAssertLessThanOrEqual(interval.start, calendar.startOfDay(for: base.addingTimeInterval(-600)))
    }

    func test16MultipleLiveSessionsAppearInInsights() {
        var state = AppState()
        state.activeSessions = [active(0, id: UUID()), active(30, id: UUID())]
        let value = InsightsCalculator.summary(state: state, calendar: calendar, referenceDate: base.addingTimeInterval(90), interval: span(0, 90), comparisonInterval: nil, timeframe: .allTime)
        XCTAssertEqual(value.sessionCount, 2)
        XCTAssertEqual(value.activeTime, 90)
        XCTAssertEqual(value.sessionActivity, 150)
    }

    func test17DailyActivityUnionsOverlap() { XCTAssertEqual(summary(completed: [completed(0, 60), completed(30, 90)]).dailyActivity.reduce(0) { $0 + $1.duration }, 90) }
    func test18FocusActiveTimeUsesUnion() { XCTAssertEqual(summary(completed: [completed(0, 60), completed(30, 90)]).focusInsights.totalActiveDuration, 90) }
    func test19ConcurrentProjectStartIsNotSwitch() { XCTAssertEqual(summary(completed: [completed(0, 60, projectID: UUID()), completed(30, 90, projectID: UUID())]).focusInsights.projectSwitchCount, 0) }
    func test20SequentialProjectStartIsSwitch() { XCTAssertEqual(summary(completed: [completed(0, 60, projectID: UUID()), completed(65, 120, projectID: UUID())]).focusInsights.projectSwitchCount, 1) }
    func test21SustainedShareNeverExceedsOne() { XCTAssertLessThanOrEqual(summary(completed: [completed(0, 3_600), completed(0, 3_600)]).focusInsights.sustainedFocusShare ?? 2, 1) }

    func test22TodayTotalUnionsCompletedAndLive() {
        var state = AppState(completedSessions: [completed(0, 60)])
        state.activeSessions = [active(30, id: UUID())]
        let store = makeStore(state: state, now: base.addingTimeInterval(90))
        XCTAssertEqual(store.todayTotal(at: base.addingTimeInterval(90)), 90)
    }

    func test23WorkspaceSnapshotIncludesAllWorkspaceSessions() throws {
        let workspace = WorkspaceRecord(name: "W")
        let project = ProjectRecord(workspaceID: workspace.id, name: "P", createdAt: base)
        var state = AppState(workspaces: [workspace], projects: [project])
        state.activeSessions = [active(0, id: UUID(), project: project), active(30, id: UUID(), project: project)]
        let value = try XCTUnwrap(WorkspaceDashboardCalculator.snapshot(state: state, calendar: calendar, referenceDate: base.addingTimeInterval(90), workspaceID: workspace.id, timeframe: .allTime))
        XCTAssertEqual(value.activeSessionCount, 2)
        XCTAssertEqual(value.activeTime, 90)
        XCTAssertEqual(value.sessionActivity, 150)
    }

    func test24WorkspaceSnapshotExcludesOtherWorkspace() throws {
        let first = WorkspaceRecord(name: "One"), second = WorkspaceRecord(name: "Two")
        let a = ProjectRecord(workspaceID: first.id, name: "A", createdAt: base)
        let b = ProjectRecord(workspaceID: second.id, name: "B", createdAt: base)
        var state = AppState(workspaces: [first, second], projects: [a, b])
        state.activeSessions = [active(0, id: UUID(), project: a), active(0, id: UUID(), project: b)]
        let value = try XCTUnwrap(WorkspaceDashboardCalculator.snapshot(state: state, calendar: calendar, referenceDate: base.addingTimeInterval(60), workspaceID: first.id, timeframe: .allTime))
        XCTAssertEqual(value.activeSessionCount, 1)
        XCTAssertEqual(state.activeSessions.count, 2)
    }

    func test25ParserReadsPauseSessionID() throws { XCTAssertEqual(try CodePulseControlCLIParser.parse(arguments: ["pause", "--session-id", fixedID.uuidString], issuedAt: base).command.action, .pauseSession(fixedID)) }
    func test26ParserReadsResumeSessionID() throws { XCTAssertEqual(try CodePulseControlCLIParser.parse(arguments: ["resume", "--session-id", fixedID.uuidString], issuedAt: base).command.action, .resumeSession(fixedID)) }
    func test27ParserReadsFinishSessionID() throws { XCTAssertEqual(try CodePulseControlCLIParser.parse(arguments: ["finish", "--session-id", fixedID.uuidString], issuedAt: base).command.action, .finishSession(fixedID)) }
    func test28ParserRejectsMalformedSessionID() { XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["pause", "--session-id", "bad"], issuedAt: base)) }
    func test29ParserRejectsMissingSessionID() { XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["pause", "--session-id"], issuedAt: base)) }
    func test30ParserRejectsDuplicateSessionID() { XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["pause", "--session-id", fixedID.uuidString, "--session-id", fixedID.uuidString], issuedAt: base)) }

    func test31V2CodecRoundTripsTargetedLifecycle() throws {
        let command = CodePulseControlCommand(issuedAt: base, action: .pauseSession(fixedID))
        XCTAssertEqual(try CodePulseControlCommandCodec.decode(CodePulseControlCommandCodec.encode(command)), command)
    }

    func test32V1RejectsSessionIDField() throws {
        var object = try json(CodePulseControlCommand(schemaVersion: 1, issuedAt: base, action: .pause))
        var action = object["action"] as! [String: Any]
        action["sessionID"] = fixedID.uuidString
        object["action"] = action
        XCTAssertThrowsError(try CodePulseControlCommandCodec.decode(JSONSerialization.data(withJSONObject: object)))
    }

    func test33UnknownSchemaRejected() throws {
        let command = CodePulseControlCommand(schemaVersion: 99, issuedAt: base, action: .status)
        XCTAssertThrowsError(try CodePulseControlCommandCodec.decode(CodePulseControlCommandCodec.encode(command)))
    }

    func test34V2StatusZeroIsEmpty() { XCTAssertTrue(makeStore(state: AppState(), now: base).controlStatus().sessions.isEmpty) }
    func test35V2StatusManyContainsEveryID() {
        let a = UUID(), b = UUID()
        var state = AppState(); state.activeSessions = [active(0, id: b), active(0, id: a)]
        XCTAssertEqual(makeStore(state: state, now: base.addingTimeInterval(60)).controlStatus().sessions.map(\.sessionID), [a, b].sorted { $0.uuidString < $1.uuidString })
    }

    func test36ExplicitPauseMutatesOnlyTarget() {
        let a = UUID(), b = UUID(); var state = AppState(); state.activeSessions = [active(0, id: a), active(0, id: b)]
        let store = makeStore(state: state, now: base)
        let response = store.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .pauseSession(a)), at: base)
        XCTAssertEqual(response.result, .success)
        XCTAssertEqual(store.state.activeSession(id: a)?.phase, .paused)
        XCTAssertEqual(store.state.activeSession(id: b)?.phase, .running)
    }

    func test37NoIDMultipleEligibleIsAmbiguous() {
        var state = AppState(); state.activeSessions = [active(0, id: UUID()), active(0, id: UUID())]
        let store = makeStore(state: state, now: base)
        XCTAssertEqual(store.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .pause), at: base).result, .ambiguousSession)
        XCTAssertTrue(store.state.activeSessions.allSatisfy { $0.phase == .running })
    }

    func test38LegacyV1StatusDecodesWithoutUUID() throws {
        let status = CodePulseControlStatus(schemaVersion: 1, phase: "running", project: "P", sessionType: "coding", elapsedSeconds: 1, automationControlled: false)
        let response = CodePulseControlResponse(schemaVersion: 1, commandID: UUID(), result: .success, message: "ok", status: status)
        let decoded = try CodePulseControlResponseCodec.decode(CodePulseControlResponseCodec.encode(response))
        XCTAssertEqual(decoded.status?.sessions, [])
        XCTAssertEqual(decoded.status?.phase, "running")
    }

    func test39StatusPrivacyExcludesContentFields() throws {
        var state = AppState(); state.activeSessions = [ActiveSession(projectName: "P", type: .coding, goal: "secret goal", startedAt: base)]
        let data = try JSONEncoder().encode(makeStore(state: state, now: base).controlStatus())
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for forbidden in ["goal", "outcome", "prompt", "transcript", "command", "source", "diff", "token", "key"] { XCTAssertFalse(text.contains(forbidden)) }
    }

    func test40ForeignConcurrentProjectDoesNotSplitGracePeriodFocusBlock() {
        let a = UUID(), b = UUID()
        let value = summary(completed: [
            completed(0, 1_200, projectID: a),
            completed(900, 1_500, projectID: b),
            completed(1_800, 3_600, projectID: a)
        ])
        XCTAssertEqual(value.focusInsights.longestFocusBlockDuration, 3_000)
        XCTAssertEqual(value.focusInsights.sustainedFocusDuration, 3_000)
        XCTAssertLessThanOrEqual(value.focusInsights.sustainedFocusDuration, value.activeTime)
    }

    func test41PauseInterleavingUsesActualActiveSegmentsForSwitches() {
        let a = UUID(), b = UUID()
        let pausedA = completed(
            0, 3_600, projectID: a,
            pauses: [PauseInterval(startedAt: base.addingTimeInterval(600), endedAt: base.addingTimeInterval(3_000))]
        )
        let value = summary(completed: [pausedA, completed(1_200, 1_800, projectID: b)])
        XCTAssertEqual(value.focusInsights.projectSwitchCount, 1)
    }

    func test42TiedConcurrentCandidatesDoNotCreateUUIDOrderSwitches() {
        let value = summary(completed: [
            completed(0, 600, projectID: UUID()),
            completed(600, 1_200, projectID: UUID()),
            completed(600, 1_200, projectID: UUID())
        ])
        XCTAssertEqual(value.focusInsights.projectSwitchCount, 0)
    }

    func test43SustainedHourlyAndDayMetricsAreUnionBased() {
        let value = summary(completed: [completed(0, 3_600, projectID: UUID()), completed(0, 3_600, projectID: UUID())])
        XCTAssertEqual(value.focusInsights.sustainedFocusDuration, 3_600)
        XCTAssertEqual(value.focusInsights.hourlySustainedFocus.reduce(0) { $0 + $1.duration }, 3_600)
        XCTAssertEqual(value.focusInsights.bestFocusDay?.duration, 3_600)
        XCTAssertLessThanOrEqual(value.focusInsights.sustainedFocusDuration, value.activeTime)
    }

    func test44DirectControlStartCreatesConcurrentSessionAndReturnsExactUUID() throws {
        let project = ProjectRecord(name: "B", createdAt: base)
        var state = AppState(projects: [project]); let existing = UUID()
        state.activeSessions = [active(0, id: existing)]
        let store = makeStore(state: state, now: base.addingTimeInterval(60))
        let response = store.processControlCommand(CodePulseControlCommand(issuedAt: base.addingTimeInterval(60), action: .startManual(projectName: "B", sessionType: "coding", goal: nil)), at: base.addingTimeInterval(60))
        XCTAssertEqual(response.result, .success)
        let newID = try XCTUnwrap(response.sessionID)
        XCTAssertNotEqual(newID, existing)
        XCTAssertEqual(Set(store.state.activeSessions.map(\.id)), [existing, newID])
        XCTAssertEqual(response.status?.sessions.count, 2)
        XCTAssertEqual(store.state.projects.first?.lastUsedAt, base.addingTimeInterval(60))
    }

    func test45PresetNameControlStartCreatesConcurrentSession() throws {
        let (store, existing, preset) = concurrentPresetStore()
        let response = store.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .startPreset(name: preset.name)), at: base)
        XCTAssertEqual(response.result, .success)
        XCTAssertNotEqual(try XCTUnwrap(response.sessionID), existing)
        XCTAssertEqual(store.state.activeSessions.count, 2)
    }

    func test46PresetIDControlStartCreatesConcurrentSession() throws {
        let (store, existing, preset) = concurrentPresetStore()
        let response = store.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .startPresetID(preset.id)), at: base)
        XCTAssertEqual(response.result, .success)
        XCTAssertNotEqual(try XCTUnwrap(response.sessionID), existing)
        XCTAssertEqual(response.status?.sessions.count, 2)
    }

    func test47SeventeenthControlStartRejectsWithoutMutatingSixteen() {
        let project = ProjectRecord(name: "P", createdAt: base)
        var state = AppState(projects: [project])
        state.activeSessions = (0..<16).map { active(TimeInterval($0), id: UUID()) }
        let before = state.activeSessions
        let store = makeStore(state: state, now: base)
        let response = store.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .startManual(projectName: "P", sessionType: "coding", goal: nil)), at: base)
        XCTAssertEqual(response.result, .invalidStateTransition)
        XCTAssertEqual(store.state.activeSessions, before)
    }

    func test48TargetedMissingAndWrongPhaseNeverFallBack() {
        let running = UUID(), paused = UUID()
        var pausedSession = active(0, id: paused)
        pausedSession.phase = .paused
        pausedSession.pauseIntervals = [PauseInterval(startedAt: base)]
        var state = AppState(); state.activeSessions = [active(0, id: running), pausedSession]
        let store = makeStore(state: state, now: base)
        XCTAssertEqual(store.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .pauseSession(UUID())), at: base).result, .invalidStateTransition)
        XCTAssertEqual(store.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .pauseSession(paused)), at: base).result, .invalidStateTransition)
        XCTAssertEqual(store.state.activeSession(id: running)?.phase, .running)
    }

    func test49NoIDEligibilityZeroOneManyContract() {
        let empty = makeStore(state: AppState(), now: base)
        XCTAssertEqual(empty.processControlCommand(CodePulseControlCommand(issuedAt: base, action: .pause), at: base).result, .invalidStateTransition)
        var oneState = AppState(); oneState.activeSessions = [active(0, id: UUID())]
        XCTAssertEqual(makeStore(state: oneState, now: base).processControlCommand(CodePulseControlCommand(issuedAt: base, action: .pause), at: base).result, .success)
        var manyState = AppState(); manyState.activeSessions = [active(0, id: UUID()), active(0, id: UUID())]
        XCTAssertEqual(makeStore(state: manyState, now: base).processControlCommand(CodePulseControlCommand(issuedAt: base, action: .pause), at: base).result, .ambiguousSession)
    }

    func test50V1LifecycleSuccessFailureAmbiguityAndReplayStayV1() throws {
        let id = UUID(); var state = AppState(); state.activeSessions = [active(0, id: id)]
        let store = makeStore(state: state, now: base)
        let pause = CodePulseControlCommand(schemaVersion: 1, id: UUID(), issuedAt: base, action: .pause)
        let success = store.processControlCommand(pause, at: base)
        XCTAssertEqual(success.schemaVersion, 1)
        XCTAssertNil(success.sessionID)
        XCTAssertEqual(success.status?.schemaVersion, 1)
        XCTAssertEqual(try CodePulseControlResponseCodec.decode(CodePulseControlResponseCodec.encode(success)), success)
        XCTAssertEqual(store.processControlCommand(pause, at: base), success)

        let failure = store.processControlCommand(CodePulseControlCommand(schemaVersion: 1, issuedAt: base, action: .pause), at: base)
        XCTAssertEqual(failure.schemaVersion, 1)
        XCTAssertEqual(failure.result, .invalidStateTransition)

        var concurrent = AppState(); concurrent.activeSessions = [active(0, id: UUID()), active(0, id: UUID())]
        let ambiguous = makeStore(state: concurrent, now: base).processControlCommand(CodePulseControlCommand(schemaVersion: 1, issuedAt: base, action: .pause), at: base)
        XCTAssertEqual(ambiguous.schemaVersion, 1)
        XCTAssertEqual(ambiguous.result, .commandRejected)
        XCTAssertNil(ambiguous.status)
        XCTAssertNil(ambiguous.sessionID)
    }

    func test51CodecRejectsHybridStatusesAndImpossibleV1Fields() throws {
        let v1 = CodePulseControlStatus(phase: "idle", elapsedSeconds: 0, automationControlled: false)
        let v2 = CodePulseControlStatus(sessions: [])
        for response in [
            CodePulseControlResponse(schemaVersion: 1, commandID: UUID(), result: .success, message: "ok", status: v2),
            CodePulseControlResponse(schemaVersion: 2, commandID: UUID(), result: .success, message: "ok", status: v1),
            CodePulseControlResponse(schemaVersion: 1, commandID: UUID(), result: .success, message: "ok", sessionID: UUID()),
            CodePulseControlResponse(schemaVersion: 1, commandID: UUID(), result: .ambiguousSession, message: "no")
        ] {
            XCTAssertThrowsError(try CodePulseControlResponseCodec.encode(response))
        }
        XCTAssertEqual(v1.schemaVersion, 1)
    }

    func test52StatusWorkspaceAndHumanZeroOneManyRemainTruthful() {
        let workspace = WorkspaceRecord(name: "Actual")
        let project = ProjectRecord(workspaceID: workspace.id, name: "P", createdAt: base)
        var state = AppState(workspaces: [workspace], projects: [project])
        state.activeSessions = [active(0, id: fixedID, project: project)]
        let status = makeStore(state: state, now: base).controlStatus()
        XCTAssertEqual(status.sessions.first?.workspaceName, "Actual")
        XCTAssertTrue(CodePulseControlCLIFormatter.humanStatus(CodePulseControlStatus(sessions: [])).contains("idle"))
        XCTAssertTrue(CodePulseControlCLIFormatter.humanStatus(status).contains(fixedID.uuidString))
        let many = CodePulseControlStatus(sessions: status.sessions + [CodePulseControlSessionStatus(sessionID: UUID(), sessionType: "coding", phase: "running", elapsedSeconds: 0, automationControlled: false)])
        XCTAssertTrue(CodePulseControlCLIFormatter.humanStatus(many).contains("2 active sessions"))
    }

    func test53DigestOverlapCarriesActiveTimeUnionAndSessionActivitySum() {
        let period = DigestPeriod(kind: .daily, interval: span(0, 120), comparisonInterval: nil)
        let value = DigestCalculator.summary(
            state: AppState(completedSessions: [completed(0, 60), completed(30, 90)]),
            period: period,
            referenceDate: base.addingTimeInterval(120),
            calendar: calendar
        )
        XCTAssertEqual(value.totalActiveTime, 90)
        XCTAssertEqual(value.sessionActivity, 120)
    }

    func test54MarkdownNamesBothMetricClassesAndSessionActivityTables() {
        let report = InsightsMarkdownExporter.markdown(
            summary: summary(completed: [completed(0, 60, projectID: UUID()), completed(30, 90, projectID: UUID())]),
            projectTitle: "All Projects",
            calendar: calendar
        )
        XCTAssertTrue(report.contains("Active Time"))
        XCTAssertTrue(report.contains("Session Activity"))
        XCTAssertTrue(report.contains("| Type | Session Activity |"))
        XCTAssertTrue(report.contains("| Project | Session Activity |"))
    }

    func test55WorkspaceLargestProjectShareUsesSessionActivityDenominator() throws {
        let workspace = WorkspaceRecord(name: "W")
        let a = ProjectRecord(workspaceID: workspace.id, name: "A", createdAt: base)
        let b = ProjectRecord(workspaceID: workspace.id, name: "B", createdAt: base)
        let state = AppState(workspaces: [workspace], projects: [a, b], completedSessions: [
            completed(0, 60, projectID: a.id),
            completed(0, 60, projectID: a.id),
            completed(0, 60, projectID: b.id)
        ])
        let value = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: base.addingTimeInterval(120),
            workspaceID: workspace.id, timeframe: .allTime
        ))
        XCTAssertEqual(value.patterns.largestProjectTimeShare ?? -1, 2.0 / 3.0, accuracy: 0.000_001)
    }

    func test56LocalDayDSTActiveTimeRemainsUnionBased() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Denver"))
        let start = try XCTUnwrap(local.date(from: DateComponents(year: 2023, month: 3, day: 12, hour: 1, minute: 30)))
        let end = try XCTUnwrap(local.date(from: DateComponents(year: 2023, month: 3, day: 12, hour: 3, minute: 30)))
        let reference = try XCTUnwrap(local.date(from: DateComponents(year: 2023, month: 3, day: 13, hour: 12)))
        let session = CompletedSession(
            id: UUID(), projectID: nil, projectName: nil, type: .coding, goal: nil, outcome: nil,
            startedAt: start, endedAt: end, pauseIntervals: []
        )
        let value = InsightsCalculator.summary(
            state: AppState(completedSessions: [session, session]),
            calendar: local, referenceDate: reference, timeframe: .thisMonth
        )
        XCTAssertEqual(value.activeTime, 3_600)
        XCTAssertEqual(value.sessionActivity, 7_200)
        XCTAssertEqual(try XCTUnwrap(value.dailyActivity.first { local.isDate($0.date, inSameDayAs: start) }).duration, 3_600)
    }

    private var fixedID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    private func span(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval { DateInterval(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end)) }
    private func completed(_ start: TimeInterval, _ end: TimeInterval, projectID: UUID? = nil, pauses: [PauseInterval] = []) -> CompletedSession { CompletedSession(id: UUID(), projectID: projectID, projectName: projectID == nil ? nil : "P", goal: nil, outcome: nil, startedAt: base.addingTimeInterval(start), endedAt: base.addingTimeInterval(end), pauseIntervals: pauses) }
    private func active(_ start: TimeInterval, id: UUID, project: ProjectRecord? = nil) -> ActiveSession { ActiveSession(id: id, projectID: project?.id, projectName: project?.name, startedAt: base.addingTimeInterval(start)) }
    private func summary(completed: [CompletedSession]) -> InsightsSummary { InsightsCalculator.summary(state: AppState(completedSessions: completed), calendar: calendar, referenceDate: base.addingTimeInterval(3_600), interval: span(-3_600, 3_600), comparisonInterval: nil, timeframe: .allTime) }
    private func assertMetrics(_ values: [(TimeInterval, TimeInterval)], active: TimeInterval, activity: TimeInterval) { let value = summary(completed: values.map { completed($0.0, $0.1) }); XCTAssertEqual(value.activeTime, active); XCTAssertEqual(value.sessionActivity, activity) }
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder.iso8601.encode(value)) as! [String: Any] }
    private func makeStore(state: AppState, now: Date) -> SessionStore { SessionStore(persistence: Phase5Persistence(state), clock: Phase5Clock(now), calendar: calendar, automaticallyRefresh: false) }
    private func concurrentPresetStore() -> (SessionStore, UUID, SessionPreset) {
        let project = ProjectRecord(name: "B", createdAt: base)
        let preset = SessionPreset(name: "B Coding", projectID: project.id, sessionType: .coding)
        let existing = UUID()
        var state = AppState(projects: [project], sessionPresets: [preset])
        state.activeSessions = [active(-60, id: existing)]
        return (makeStore(state: state, now: base), existing, preset)
    }
}

private final class Phase5Persistence: StatePersisting {
    var state: AppState
    init(_ state: AppState) { self.state = state }
    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private final class Phase5Clock: SessionClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
}
