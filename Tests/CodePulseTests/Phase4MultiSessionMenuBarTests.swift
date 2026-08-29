import Foundation
import CodePulseIntegration
import XCTest
@testable import CodePulse

private final class Phase4Clock: SessionClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}

private final class Phase4Persistence: StatePersisting {
    var state: AppState
    var failCritical = false
    var failSaves = false
    var loadStatus: StateLoadStatus = .loaded
    init(_ state: AppState) { self.state = state }
    func load() -> AppState { state }
    func save(_ state: AppState) { if failSaves { loadStatus = .unreadable } else { self.state = state } }
    func saveCritical(_ state: AppState) throws {
        if failCritical { throw Phase4SaveError() }
        self.state = state
    }
}

private struct Phase4SaveError: Error {}

@MainActor
final class Phase4MultiSessionMenuBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testBaseRoutesAreExactlyZeroOneAndMany() {
        let p = MenuBarPopoverPresentation(), a = uuid(1), b = uuid(2), c = uuid(3)
        XCTAssertEqual(p.route(activeSessionIDs: []), .idle)
        XCTAssertEqual(p.route(activeSessionIDs: [a]), .soleSession(a))
        XCTAssertEqual(p.route(activeSessionIDs: [a, b]), .activeSessionsHub)
        XCTAssertEqual(p.route(activeSessionIDs: [c, a, b]), .activeSessionsHub)
    }

    func testSelectedRowRoutesByExactUUIDInNontrivialOrder() {
        var p = MenuBarPopoverPresentation()
        let a = uuid(1), b = uuid(2), c = uuid(3)
        p.selectSession(b)
        XCTAssertEqual(p.route(activeSessionIDs: [c, a, b]), .selectedSession(b))
    }

    func testSelectedRunningSessionFinishesWithoutLosingIdentity() throws {
        let store = makeStore(AppState())
        let a = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "A"))
        let b = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B"))
        let c = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "C"))
        var p = MenuBarPopoverPresentation(); p.selectSession(a)
        let bBefore = store.state.activeSession(id: b), cBefore = store.state.activeSession(id: c)
        XCTAssertTrue(store.finish(sessionID: a))
        p.reconcile(activeSessionIDs: store.state.activeSessions.map(\.id))
        XCTAssertEqual(p.selectedSessionID, a)
        XCTAssertEqual(p.route(activeSessionIDs: store.state.activeSessions.map(\.id)), .selectedSession(a))
        XCTAssertEqual(store.state.activeSession(id: a)?.phase, .finishing)
        XCTAssertEqual(store.state.activeSession(id: b), bBefore)
        XCTAssertEqual(store.state.activeSession(id: c), cBefore)
    }

    func testSavingSelectedFinishingSessionReturnsToHubWithoutAutoSelection() {
        let store = makeStore(stateWithSessions([finishing(1), running(2), paused(3)]))
        var p = MenuBarPopoverPresentation(); p.selectSession(uuid(1))
        let survivors = Array(store.state.activeSessions.dropFirst())
        XCTAssertTrue(store.saveFinishedSession(sessionID: uuid(1), outcome: "Done"))
        p.reconcile(activeSessionIDs: store.state.activeSessions.map(\.id))
        XCTAssertNil(p.selectedSessionID)
        XCTAssertEqual(store.state.activeSessions, survivors)
        XCTAssertEqual(p.route(activeSessionIDs: store.state.activeSessions.map(\.id)), .activeSessionsHub)
    }

    func testDiscardingSelectedFinishingSessionLeavingOneReturnsToSoleDetail() {
        let store = makeStore(stateWithSessions([finishing(1), running(2)]))
        var p = MenuBarPopoverPresentation(); p.selectSession(uuid(1))
        XCTAssertTrue(store.discardSession(sessionID: uuid(1)))
        p.reconcile(activeSessionIDs: store.state.activeSessions.map(\.id))
        XCTAssertNil(p.selectedSessionID)
        XCTAssertEqual(p.route(activeSessionIDs: store.state.activeSessions.map(\.id)), .soleSession(uuid(2)))
    }

    func testSavingOnlyFinishingSessionReturnsToIdle() {
        let store = makeStore(stateWithSessions([finishing(1)]))
        var p = MenuBarPopoverPresentation()
        XCTAssertTrue(store.saveFinishedSession(sessionID: uuid(1), outcome: nil))
        p.reconcile(activeSessionIDs: [])
        XCTAssertEqual(p.route(activeSessionIDs: []), .idle)
    }

    func testOneSessionNewSessionFlowCreatesDistinctUUIDAndReturnsToHub() throws {
        let store = makeStore(AppState())
        let a = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "A"))
        let aBefore = try XCTUnwrap(store.state.activeSession(id: a))
        var p = MenuBarPopoverPresentation(); p.showNewSession(activeSessionIDs: [a])
        XCTAssertEqual(p.route(activeSessionIDs: [a]), .newSession)
        let b = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B"))
        p.didCreateSession()
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(store.state.activeSession(id: a), aBefore)
        XCTAssertNil(p.selectedSessionID)
        XCTAssertEqual(p.route(activeSessionIDs: store.state.activeSessions.map(\.id)), .activeSessionsHub)
    }

    func testHubNewSessionFlowPreservesExistingSessionsAndReturnsToHub() throws {
        let store = makeStore(stateWithSessions([running(1), paused(2)]))
        let before = store.state.activeSessions
        var p = MenuBarPopoverPresentation(); p.showNewSession(activeSessionIDs: before.map(\.id))
        let c = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "C"))
        p.didCreateSession()
        XCTAssertEqual(Array(store.state.activeSessions.prefix(2)), before)
        XCTAssertEqual(store.state.activeSessions.last?.id, c)
        XCTAssertEqual(p.route(activeSessionIDs: store.state.activeSessions.map(\.id)), .activeSessionsHub)
    }

    func testCancelNewSessionReturnsToAutomaticBaseRouteWithoutMutation() {
        for sessions in [[running(1)], [running(1), paused(2)]] {
            let before = sessions
            var p = MenuBarPopoverPresentation(); p.showNewSession(activeSessionIDs: sessions.map(\.id)); p.closeNewSession()
            XCTAssertEqual(sessions, before)
            let expected: MenuBarPopoverRoute = sessions.count == 1 ? .soleSession(uuid(1)) : .activeSessionsHub
            XCTAssertEqual(p.route(activeSessionIDs: sessions.map(\.id)), expected)
        }
    }

    func testSixteenSessionPresentationDisablesCreationAndStoreRejectsSeventeenth() {
        let sessions = (1...16).map { running($0) }
        let availability = MenuBarNewSessionAvailability(activeSessionCount: sessions.count)
        XCTAssertFalse(availability.canStart)
        XCTAssertEqual(availability.capacityMessage, "Session limit reached (16)")
        let store = makeStore(stateWithSessions(sessions)), before = store.state
        XCTAssertNil(store.createManualSession(projectID: nil, goal: "Seventeenth"))
        XCTAssertEqual(store.state, before)
    }

    func testSelectedSessionInvalidationKeepsExistingAndClearsRemovedForEveryBaseCount() {
        let a = uuid(1), b = uuid(2), c = uuid(3)
        var kept = MenuBarPopoverPresentation(); kept.selectSession(b); kept.reconcile(activeSessionIDs: [c, b, a])
        XCTAssertEqual(kept.selectedSessionID, b)
        XCTAssertEqual(kept.route(activeSessionIDs: [c, b, a]), .selectedSession(b))
        let cases: [([UUID], MenuBarPopoverRoute)] = [([b, c], .activeSessionsHub), ([b], .soleSession(b)), ([], .idle)]
        for (remaining, expected) in cases {
            var removed = MenuBarPopoverPresentation(); removed.selectSession(a); removed.reconcile(activeSessionIDs: remaining)
            XCTAssertNil(removed.selectedSessionID)
            XCTAssertEqual(removed.route(activeSessionIDs: remaining), expected)
        }
    }

    func testTargetedPersistenceFailureScopesAtomicErrorToAffectedSession() {
        let persistence = Phase4Persistence(stateWithSessions([running(1), running(2)])), store = makeStore(persistence: persistence)
        let bBefore = store.state.activeSession(id: uuid(2)); persistence.failCritical = true
        XCTAssertFalse(store.pause(sessionID: uuid(1)))
        XCTAssertNotNil(store.lifecycleError?.message)
        XCTAssertEqual(store.lifecycleError?.affectedSessionID, uuid(1))
        XCTAssertEqual(store.state.activeSession(id: uuid(2)), bBefore)
    }

    func testGeneralPersistenceFailureCannotInheritPriorSessionAttribution() {
        let persistence = Phase4Persistence(stateWithSessions([running(1)])), store = makeStore(persistence: persistence)
        persistence.failCritical = true
        XCTAssertFalse(store.pause(sessionID: uuid(1)))
        XCTAssertEqual(store.lifecycleError?.affectedSessionID, uuid(1))
        XCTAssertNil(store.createManualSession(projectID: nil, goal: "General failure"))
        XCTAssertNotNil(store.lifecycleError?.message)
        XCTAssertNil(store.lifecycleError?.affectedSessionID)
    }

    func testSuccessfulTargetedRetryClearsCompleteErrorPresentation() {
        let persistence = Phase4Persistence(stateWithSessions([running(1)])), store = makeStore(persistence: persistence)
        persistence.failCritical = true; XCTAssertFalse(store.pause(sessionID: uuid(1))); XCTAssertNotNil(store.lifecycleError)
        persistence.failCritical = false; XCTAssertTrue(store.pause(sessionID: uuid(1))); XCTAssertNil(store.lifecycleError)
    }

    func testNoOpOutcomeUpdateLeavesExistingAtomicErrorCoherent() {
        let persistence = Phase4Persistence(stateWithSessions([running(1), finishing(2, outcome: "Done")])), store = makeStore(persistence: persistence)
        persistence.failCritical = true; XCTAssertFalse(store.pause(sessionID: uuid(1)))
        let before = store.lifecycleError
        XCTAssertTrue(store.updateFinishingOutcome(sessionID: uuid(2), outcome: "Done"))
        XCTAssertEqual(store.lifecycleError, before)
        XCTAssertEqual(store.lifecycleError?.affectedSessionID, uuid(1))
    }

    func testPerSessionGitCaptureGatesOnlyAffectedSelectedPresentation() throws {
        let store = makeStore(stateWithSessions([finishing(1), finishing(2), running(3)]))
        store.setGitCaptureStateForPresentationTesting(SessionGitCaptureState(startStatus: .running, activeStage: .start), sessionID: uuid(1))
        XCTAssertFalse(try XCTUnwrap(MenuBarSessionControlPresentation.resolve(sessionID: uuid(1), store: store)).canSave)
        XCTAssertTrue(try XCTUnwrap(MenuBarSessionControlPresentation.resolve(sessionID: uuid(2), store: store)).canSave)
        XCTAssertTrue(try XCTUnwrap(MenuBarSessionControlPresentation.resolve(sessionID: uuid(3), store: store)).canUseLifecycleControls)
        XCTAssertTrue(store.pause(sessionID: uuid(3)))
    }

    func testDebouncedOutcomeTargetsRemainBoundAcrossSelectionChanges() {
        let store = makeStore(stateWithSessions([finishing(1, outcome: "A"), finishing(2, outcome: "B")]))
        var p = MenuBarPopoverPresentation(); p.selectSession(uuid(1))
        let pendingA = MenuBarOutcomeUpdate(sessionID: uuid(1), outcome: "A edited")
        p.selectSession(uuid(2)); pendingA.apply(to: store)
        MenuBarOutcomeUpdate(sessionID: uuid(2), outcome: "B edited").apply(to: store)
        XCTAssertEqual(store.state.activeSession(id: uuid(1))?.outcome, "A edited")
        XCTAssertEqual(store.state.activeSession(id: uuid(2))?.outcome, "B edited")
    }

    func testWorkspaceSwitchPreservesSessionsAndGlobalHubRows() {
        let first = WorkspaceRecord(id: uuid(31), name: "First", createdAt: now), second = WorkspaceRecord(id: uuid(32), name: "Second", createdAt: now)
        let projects = [ProjectRecord(id: uuid(41), workspaceID: first.id, name: "A", createdAt: now), ProjectRecord(id: uuid(42), workspaceID: second.id, name: "B", createdAt: now), ProjectRecord(id: uuid(43), workspaceID: second.id, name: "C", createdAt: now)]
        let sessions = [running(1, project: projects[0]), paused(2, project: projects[1]), finishing(3, project: projects[2])]
        let store = makeStore(AppState(workspaces: [first, second], projects: projects, activeSessions: sessions, settings: CodePulseSettings(selectedWorkspaceID: first.id)))
        XCTAssertTrue(store.selectWorkspace(id: second.id))
        XCTAssertEqual(store.state.activeSessions, sessions)
        XCTAssertEqual(Set(MenuBarSessionPresentation.sorted(state: store.state).map(\.id)), Set(sessions.map(\.id)))
    }

    func testDeveloperToolPresentationSupportsMultiOwnerAndContextOnlyLegacySessions() {
        var multi = running(1); multi.developerToolContexts = [toolContext(.opencode, id: "open"), toolContext(.codex, id: "codex")]
        multi.automationMetadata = SessionAutomationMetadata(
            startedByRuleID: uuid(101),
            startedByRuleName: "Developer Tools",
            startedBySource: .developerTool(tool: .codex, externalSessionID: "codex"),
            lastMatchingSignalAt: now,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(tool: .opencode, externalSessionID: "open", isActive: true, lastSignalAt: now)]
        )
        var contextOnly = running(2); contextOnly.developerToolContexts = [toolContext(.opencode, id: "context")]
        let state = stateWithSessions([multi, contextOnly])
        XCTAssertEqual(
            multi.developerToolOwnershipIdentities,
            Set([
                DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "codex"),
                DeveloperToolThreadIdentity(tool: .opencode, externalSessionID: "open")
            ])
        )
        let rows = MenuBarSessionPresentation.sorted(state: state)
        XCTAssertEqual(rows.first(where: { $0.id == multi.id })?.developerToolLabel, "Codex + OpenCode")
        XCTAssertEqual(rows.first(where: { $0.id == contextOnly.id })?.developerToolLabel, "OpenCode")
        XCTAssertNil(contextOnly.automationMetadata)
    }

    func testStatusBarPreferencesCoverZeroOneAndManyWithoutConcatenation() {
        var idle = AppState(); idle.settings.idleAppearance = .code
        XCTAssertTrue(MenuBarLabelPresentation.shouldRenderText(state: idle)); idle.settings.idleAppearance = .iconOnly
        XCTAssertFalse(MenuBarLabelPresentation.shouldRenderText(state: idle))
        for display in MenuBarDisplay.allCases {
            var one = stateWithSessions([running(1, projectName: "Project")]); one.settings.menuBarDisplay = display
            XCTAssertEqual(MenuBarLabelPresentation.text(state: one, now: now), display == .projectAndTimer ? "Project · 0:00" : "0:00")
            XCTAssertEqual(MenuBarLabelPresentation.shouldRenderText(state: one), display != .iconOnly)
            var many = stateWithSessions([running(1), paused(2), finishing(3)]); many.settings.menuBarDisplay = display
            XCTAssertEqual(MenuBarLabelPresentation.text(state: many, now: now), "3 sessions")
            XCTAssertEqual(MenuBarLabelPresentation.shouldRenderText(state: many), display != .iconOnly)
            XCTAssertEqual(makeStore(many).menuBarAccessibilityText, "CodePulse, 3 active sessions, 1 running, 1 paused, 1 finishing")
        }
    }

    private func makeStore(_ state: AppState) -> SessionStore { makeStore(persistence: Phase4Persistence(state)) }
    private func makeStore(persistence: Phase4Persistence) -> SessionStore { SessionStore(persistence: persistence, clock: Phase4Clock(now), automaticallyRefresh: false) }
    private func stateWithSessions(_ sessions: [ActiveSession]) -> AppState { AppState(activeSessions: sessions) }
    private func running(_ suffix: Int, project: ProjectRecord? = nil, projectName: String? = nil) -> ActiveSession { ActiveSession(id: uuid(suffix), projectID: project?.id, projectName: project?.name ?? projectName, startedAt: now) }
    private func paused(_ suffix: Int, project: ProjectRecord? = nil) -> ActiveSession { var s = running(suffix, project: project); _ = s.pause(at: now.addingTimeInterval(1)); return s }
    private func finishing(_ suffix: Int, project: ProjectRecord? = nil, outcome: String? = nil) -> ActiveSession { var s = running(suffix, project: project); _ = s.finish(at: now.addingTimeInterval(1)); s.outcome = outcome; return s }
    private func uuid(_ suffix: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))! }
    private func toolContext(_ tool: DeveloperTool, id: String) -> DeveloperToolSessionContext { DeveloperToolSessionContext(tool: tool, externalSessionID: id, workingDirectory: "/tmp/\(id)", firstActivityAt: now, lastActivityAt: now, eventCount: 1) }
}
