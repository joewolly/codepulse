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
    func save(_ state: AppState) {
        if failSaves { loadStatus = .unreadable } else { self.state = state }
    }
    func saveCritical(_ state: AppState) throws {
        if failCritical { throw Phase4SaveError() }
        self.state = state
    }
}

private struct Phase4SaveError: Error {}

@MainActor
final class Phase4MultiSessionMenuBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    func testZeroOneAndManyAccessibilityRoutes() throws {
        let store = makeStore(AppState())
        XCTAssertEqual(store.menuBarAccessibilityText, "CodePulse, ready to start a session")
        XCTAssertEqual(MenuBarLabelPresentation.text(state: store.state, now: now), "Code")

        let first = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "First", at: now.addingTimeInterval(-60)))
        XCTAssertEqual(store.menuBarAccessibilityText, "CodePulse, running, No Project, Coding, 00:01:00")
        XCTAssertEqual(MenuBarLabelPresentation.text(state: store.state, now: now), "0:01")

        let second = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "Second", at: now.addingTimeInterval(-30)))
        XCTAssertEqual(
            store.menuBarAccessibilityText,
            "CodePulse, 2 active sessions, 2 running, 0 paused, 0 finishing"
        )
        XCTAssertEqual(MenuBarLabelPresentation.text(state: store.state, now: now), "2 sessions")
        XCTAssertNotEqual(first, second)
    }

    func testPresentationGroupsEverySessionByOwningWorkspaceDeterministically() {
        let alpha = WorkspaceRecord(id: uuid(1), name: "Alpha", createdAt: now)
        let beta = WorkspaceRecord(id: uuid(2), name: "Beta", createdAt: now)
        let projectA = ProjectRecord(id: uuid(11), workspaceID: alpha.id, name: "Project A", createdAt: now)
        let projectB = ProjectRecord(id: uuid(12), workspaceID: alpha.id, name: "Project B", createdAt: now)
        let projectC = ProjectRecord(id: uuid(13), workspaceID: beta.id, name: "Project C", createdAt: now)
        var a = ActiveSession(id: uuid(21), projectID: projectA.id, projectName: projectA.name, startedAt: now.addingTimeInterval(-300))
        a.developerToolContexts = [toolContext(.codex, id: "a")]
        var b = ActiveSession(id: uuid(22), projectID: projectB.id, projectName: projectB.name, startedAt: now.addingTimeInterval(-200))
        _ = b.pause(at: now.addingTimeInterval(-100))
        var c = ActiveSession(id: uuid(23), projectID: projectC.id, projectName: projectC.name, startedAt: now.addingTimeInterval(-100))
        c.developerToolContexts = [toolContext(.opencode, id: "c")]
        _ = c.finish(at: now.addingTimeInterval(-20))
        let state = AppState(workspaces: [beta, alpha], projects: [projectC, projectB, projectA], activeSessions: [c, b, a])

        let rows = MenuBarSessionPresentation.sorted(state: state)
        XCTAssertEqual(rows.map(\.id), [a.id, b.id, c.id])
        XCTAssertEqual(rows.map(\.workspaceName), ["Alpha", "Alpha", "Beta"])
        XCTAssertEqual(rows.map(\.phaseTitle), ["Running", "Paused", "Finishing"])
        XCTAssertEqual(rows.map(\.developerToolLabel), ["Codex", nil, "OpenCode"])
    }

    func testTargetedControlsAndIndependentFinishingOutcomes() throws {
        let store = makeStore(AppState())
        let a = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "A", at: now.addingTimeInterval(-100)))
        let b = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B", at: now.addingTimeInterval(-90)))
        XCTAssertTrue(store.pause(sessionID: b, at: now.addingTimeInterval(-20)))
        XCTAssertEqual(store.state.activeSession(id: a)?.phase, .running)
        XCTAssertTrue(store.finish(sessionID: a, at: now.addingTimeInterval(-10)))
        XCTAssertTrue(store.finish(sessionID: b, at: now.addingTimeInterval(-5)))
        XCTAssertTrue(store.updateFinishingOutcome(sessionID: a, outcome: "Outcome A"))
        XCTAssertTrue(store.updateFinishingOutcome(sessionID: b, outcome: "Outcome B"))
        XCTAssertTrue(store.saveFinishedSession(sessionID: a, outcome: "Outcome A final"))
        XCTAssertEqual(store.state.completedSessions.first(where: { $0.id == a })?.outcome, "Outcome A final")
        XCTAssertEqual(store.state.activeSession(id: b)?.outcome, "Outcome B")
    }

    func testElapsedDurationIsPerSessionAndPausedOrFinishingIsFixed() throws {
        let store = makeStore(AppState())
        let running = try XCTUnwrap(store.createManualSession(projectID: nil, goal: nil, at: now.addingTimeInterval(-100)))
        let paused = try XCTUnwrap(store.createManualSession(projectID: nil, goal: nil, at: now.addingTimeInterval(-100)))
        XCTAssertTrue(store.pause(sessionID: paused, at: now.addingTimeInterval(-40)))
        XCTAssertEqual(store.elapsedDuration(for: running), 100)
        XCTAssertEqual(store.elapsedDuration(for: paused), 60)
        XCTAssertTrue(store.finish(sessionID: running, at: now.addingTimeInterval(-10)))
        XCTAssertEqual(store.elapsedDuration(for: running), 90)
    }

    func testManualConcurrencyAndSixteenSessionCapacityPreserveExistingSessions() throws {
        let store = makeStore(AppState())
        let first = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "First"))
        let firstSnapshot = try XCTUnwrap(store.state.activeSession(id: first))
        for index in 1..<ConcurrentSessionLimits.maximumActiveSessions {
            XCTAssertNotNil(store.createManualSession(projectID: nil, goal: "Session \(index)"))
        }
        XCTAssertEqual(store.state.activeSessions.count, 16)
        XCTAssertEqual(store.state.activeSession(id: first), firstSnapshot)
        let before = store.state
        XCTAssertNil(store.createManualSession(projectID: nil, goal: "Seventeenth"))
        XCTAssertEqual(store.state, before)
    }

    func testWorkspaceSwitchDuringRunningPausedAndFinishingPreservesAllSessions() throws {
        let first = WorkspaceRecord(id: uuid(31), name: "First", createdAt: now)
        let second = WorkspaceRecord(id: uuid(32), name: "Second", createdAt: now)
        let store = makeStore(AppState(workspaces: [first, second], settings: CodePulseSettings(selectedWorkspaceID: first.id)))
        let running = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "running"))
        let paused = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "paused"))
        let finishing = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "finishing"))
        XCTAssertTrue(store.pause(sessionID: paused))
        XCTAssertTrue(store.finish(sessionID: finishing))
        let sessions = store.state.activeSessions
        XCTAssertTrue(store.selectWorkspace(id: second.id))
        XCTAssertEqual(store.selectedWorkspaceID, second.id)
        XCTAssertEqual(store.state.activeSessions, sessions)
        XCTAssertEqual(store.state.activeSession(id: running)?.phase, .running)
    }

    func testWorkspaceSelectionFailurePreservesSelectionAndSessions() throws {
        let first = WorkspaceRecord(id: uuid(41), name: "First", createdAt: now)
        let second = WorkspaceRecord(id: uuid(42), name: "Second", createdAt: now)
        let persistence = Phase4Persistence(AppState(workspaces: [first, second], settings: CodePulseSettings(selectedWorkspaceID: first.id)))
        let store = makeStore(persistence: persistence)
        _ = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "A"))
        let sessions = store.state.activeSessions
        persistence.failSaves = true
        XCTAssertFalse(store.selectWorkspace(id: second.id))
        XCTAssertEqual(store.selectedWorkspaceID, first.id)
        XCTAssertEqual(store.state.activeSessions, sessions)
    }

    private func makeStore(_ state: AppState) -> SessionStore {
        makeStore(persistence: Phase4Persistence(state))
    }

    private func makeStore(persistence: Phase4Persistence) -> SessionStore {
        SessionStore(persistence: persistence, clock: Phase4Clock(now), automaticallyRefresh: false)
    }

    private func uuid(_ suffix: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!
    }

    private func toolContext(_ tool: DeveloperTool, id: String) -> DeveloperToolSessionContext {
        DeveloperToolSessionContext(
            tool: tool,
            externalSessionID: id,
            workingDirectory: "/tmp/\(id)",
            firstActivityAt: now.addingTimeInterval(-50),
            lastActivityAt: now,
            eventCount: 1
        )
    }
}
