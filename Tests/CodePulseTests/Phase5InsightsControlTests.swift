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

    private var fixedID: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    private func span(_ start: TimeInterval, _ end: TimeInterval) -> DateInterval { DateInterval(start: base.addingTimeInterval(start), end: base.addingTimeInterval(end)) }
    private func completed(_ start: TimeInterval, _ end: TimeInterval, projectID: UUID? = nil) -> CompletedSession { CompletedSession(id: UUID(), projectID: projectID, projectName: projectID == nil ? nil : "P", goal: nil, outcome: nil, startedAt: base.addingTimeInterval(start), endedAt: base.addingTimeInterval(end), pauseIntervals: []) }
    private func active(_ start: TimeInterval, id: UUID, project: ProjectRecord? = nil) -> ActiveSession { ActiveSession(id: id, projectID: project?.id, projectName: project?.name, startedAt: base.addingTimeInterval(start)) }
    private func summary(completed: [CompletedSession]) -> InsightsSummary { InsightsCalculator.summary(state: AppState(completedSessions: completed), calendar: calendar, referenceDate: base.addingTimeInterval(3_600), interval: span(-3_600, 3_600), comparisonInterval: nil, timeframe: .allTime) }
    private func assertMetrics(_ values: [(TimeInterval, TimeInterval)], active: TimeInterval, activity: TimeInterval) { let value = summary(completed: values.map { completed($0.0, $0.1) }); XCTAssertEqual(value.activeTime, active); XCTAssertEqual(value.sessionActivity, activity) }
    private func json<T: Encodable>(_ value: T) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder.iso8601.encode(value)) as! [String: Any] }
    private func makeStore(state: AppState, now: Date) -> SessionStore { SessionStore(persistence: Phase5Persistence(state), clock: Phase5Clock(now), calendar: calendar, automaticallyRefresh: false) }
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
