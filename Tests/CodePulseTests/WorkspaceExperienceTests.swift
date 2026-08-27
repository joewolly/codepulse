import Foundation
import XCTest
@testable import CodePulse

private final class WorkspaceExperienceClock: SessionClock {
    let now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class WorkspaceExperiencePersistence: StatePersisting {
    var state: AppState
    var loadStatus: StateLoadStatus = .loaded
    var failSaves = false

    init(state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }

    func save(_ state: AppState) {
        if failSaves {
            loadStatus = .unreadable
        } else {
            self.state = state
        }
    }
}

@MainActor
final class WorkspaceExperienceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    func testWorkspaceMutationsSupportDuplicateNamesRenameArchivedMoveAndDeterministicSelection() throws {
        let first = WorkspaceRecord(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
            name: "Alpha",
            createdAt: now
        )
        let second = WorkspaceRecord(
            id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
            name: "Beta",
            createdAt: now
        )
        let project = ProjectRecord(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
            workspaceID: first.id,
            name: "Shared Name",
            createdAt: now
        )
        let archived = ProjectRecord(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
            workspaceID: first.id,
            name: "Shared Name",
            createdAt: now,
            archivedAt: now.addingTimeInterval(10)
        )
        let otherProject = ProjectRecord(
            id: UUID(uuidString: "20000000-0000-0000-0000-000000000003")!,
            workspaceID: second.id,
            name: "Shared Name",
            createdAt: now
        )
        let session = completedSession(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            project: project,
            startedAt: now.addingTimeInterval(-120)
        )
        let state = AppState(
            workspaces: [first, second],
            projects: [project, archived, otherProject],
            completedSessions: [session],
            settings: CodePulseSettings(
                defaultProjectBehavior: .specificProject,
                specificProjectID: project.id,
                selectedWorkspaceID: first.id
            )
        )
        let persistence = WorkspaceExperiencePersistence(state: state)
        let store = makeStore(persistence: persistence)

        let createdID = try XCTUnwrap(store.createWorkspace(name: "  Team  ", at: now.addingTimeInterval(20)))
        let duplicateID = try XCTUnwrap(store.createWorkspace(name: "Team", at: now.addingTimeInterval(21)))
        XCTAssertNotEqual(createdID, duplicateID)
        XCTAssertEqual(store.state.workspaces.first(where: { $0.id == createdID })?.name, "Team")
        XCTAssertEqual(store.selectedWorkspaceID, duplicateID)
        let duplicateNameScopes = store.workspaceScopeOptions.filter { $0.title == "Team" }
        XCTAssertEqual(duplicateNameScopes.count, 2)
        XCTAssertEqual(Set(duplicateNameScopes.map(\.scope)).count, 2)

        XCTAssertTrue(store.renameWorkspace(id: createdID, name: "  Renamed Team  ", at: now.addingTimeInterval(22)))
        XCTAssertEqual(store.state.workspaces.first(where: { $0.id == createdID })?.name, "Renamed Team")
        XCTAssertEqual(store.state.workspaces.first(where: { $0.id == createdID })?.updatedAt, now.addingTimeInterval(22))

        XCTAssertTrue(store.moveProject(id: archived.id, to: second.id))
        XCTAssertEqual(store.state.projects.first(where: { $0.id == archived.id })?.workspaceID, second.id)
        XCTAssertEqual(store.state.completedSessions.first?.projectID, project.id)

        XCTAssertTrue(store.selectWorkspace(id: second.id))
        XCTAssertNil(store.defaultProjectID(for: second.id), "A specific default in another workspace must not be reassigned")
        XCTAssertEqual(store.state.settings.specificProjectID, project.id)
        XCTAssertEqual(
            store.selectableProjectsSortedByRecentUse(in: second.id).map(\.id),
            [otherProject.id],
            "Duplicate project names remain distinguishable by ID"
        )
        XCTAssertEqual(
            Set(store.selectableProjectsSortedByRecentUse(in: first.id).map(\.id)),
            [project.id]
        )
    }

    func testWorkspaceMutationsRejectEmptyNamesActiveSessionMovesAndFailedCommits() {
        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let second = WorkspaceRecord(id: UUID(), name: "Second", createdAt: now)
        let project = ProjectRecord(workspaceID: first.id, name: "Active", createdAt: now)
        var state = AppState(
            workspaces: [first, second],
            projects: [project],
            settings: CodePulseSettings(selectedWorkspaceID: first.id)
        )
        let persistence = WorkspaceExperiencePersistence(state: state)
        let store = makeStore(persistence: persistence)

        XCTAssertNil(store.createWorkspace(name: " \t\n"))
        XCTAssertFalse(store.renameWorkspace(id: first.id, name: "  "))

        let renamePersistence = WorkspaceExperiencePersistence(state: state)
        renamePersistence.failSaves = true
        let renameStore = makeStore(persistence: renamePersistence)
        XCTAssertFalse(renameStore.renameWorkspace(id: first.id, name: "Renamed"))
        XCTAssertEqual(renameStore.state.workspaces.first?.name, first.name)

        let movePersistence = WorkspaceExperiencePersistence(state: state)
        movePersistence.failSaves = true
        let moveStore = makeStore(persistence: movePersistence)
        XCTAssertFalse(moveStore.moveProject(id: project.id, to: second.id))
        XCTAssertEqual(moveStore.state.projects.first?.workspaceID, first.id)

        let selectionPersistence = WorkspaceExperiencePersistence(state: state)
        selectionPersistence.failSaves = true
        let selectionStore = makeStore(persistence: selectionPersistence)
        XCTAssertFalse(selectionStore.selectWorkspace(id: second.id))
        XCTAssertEqual(selectionStore.selectedWorkspaceID, first.id)

        XCTAssertTrue(store.startSession(projectID: project.id, goal: nil, at: now))
        XCTAssertFalse(store.selectWorkspace(id: second.id))
        XCTAssertFalse(store.moveProject(id: project.id, to: second.id))
        XCTAssertEqual(store.state.projects.first?.workspaceID, first.id)

        state = store.state
        let failingPersistence = WorkspaceExperiencePersistence(state: state)
        failingPersistence.failSaves = true
        let failingStore = makeStore(persistence: failingPersistence)
        let original = failingStore.state
        XCTAssertNil(failingStore.createWorkspace(name: "Should Not Persist"))
        XCTAssertEqual(failingStore.state, original)
        XCTAssertTrue(failingStore.isInRecoveryMode)
    }

    func testCreateWorkspaceSelectsNewWorkspaceWhenIdle() throws {
        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let store = makeStore(state: AppState(
            workspaces: [first],
            settings: CodePulseSettings(selectedWorkspaceID: first.id)
        ))

        let createdID = try XCTUnwrap(store.createWorkspace(name: "Second", at: now.addingTimeInterval(1)))

        XCTAssertEqual(store.selectedWorkspaceID, createdID)
    }

    func testCreateWorkspacePreservesSelectionAndOwnershipDuringRunningSession() throws {
        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let project = ProjectRecord(workspaceID: first.id, name: "Active", createdAt: now)
        let store = makeStore(state: AppState(
            workspaces: [first],
            projects: [project],
            settings: CodePulseSettings(selectedWorkspaceID: first.id)
        ))

        XCTAssertTrue(store.startSession(projectID: project.id, goal: nil, at: now))
        let activeSessionBeforeCreate = try XCTUnwrap(store.activeSession)
        let projectsBeforeCreate = store.state.projects

        let createdID = try XCTUnwrap(store.createWorkspace(name: "Second", at: now.addingTimeInterval(1)))

        XCTAssertTrue(store.state.workspaces.contains(where: { $0.id == createdID }))
        XCTAssertEqual(store.selectedWorkspaceID, first.id)
        XCTAssertEqual(store.activeSession, activeSessionBeforeCreate)
        XCTAssertEqual(store.activeSession?.projectID, project.id)
        XCTAssertEqual(store.state.projects, projectsBeforeCreate)
        XCTAssertEqual(store.state.projects.first(where: { $0.id == project.id })?.workspaceID, first.id)
    }

    func testCreateWorkspacePreservesSelectionDuringPausedSession() throws {
        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let project = ProjectRecord(workspaceID: first.id, name: "Active", createdAt: now)
        let store = makeStore(state: AppState(
            workspaces: [first],
            projects: [project],
            settings: CodePulseSettings(selectedWorkspaceID: first.id)
        ))

        XCTAssertTrue(store.startSession(projectID: project.id, goal: nil, at: now))
        XCTAssertTrue(store.pause(at: now.addingTimeInterval(1)))
        let activeSessionBeforeCreate = try XCTUnwrap(store.activeSession)

        let createdID = try XCTUnwrap(store.createWorkspace(name: "Second", at: now.addingTimeInterval(2)))

        XCTAssertTrue(store.state.workspaces.contains(where: { $0.id == createdID }))
        XCTAssertEqual(store.phase, .paused)
        XCTAssertEqual(store.selectedWorkspaceID, first.id)
        XCTAssertEqual(store.activeSession, activeSessionBeforeCreate)
    }

    func testWorkspaceScopedHistoryTracksCurrentMembershipAndExcludesGlobalOrphanedSessions() {
        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let second = WorkspaceRecord(id: UUID(), name: "Second", createdAt: now)
        let firstProject = ProjectRecord(workspaceID: first.id, name: "First Project", createdAt: now)
        let secondProject = ProjectRecord(workspaceID: second.id, name: "Second Project", createdAt: now)
        let firstSession = completedSession(id: UUID(), project: firstProject, startedAt: now.addingTimeInterval(-500))
        let secondSession = completedSession(id: UUID(), project: secondProject, startedAt: now.addingTimeInterval(-400))
        let noProject = CompletedSession(
            id: UUID(), projectID: nil, projectName: nil, type: .coding, goal: nil, outcome: nil,
            startedAt: now.addingTimeInterval(-300), endedAt: now.addingTimeInterval(-240), pauseIntervals: []
        )
        let orphan = CompletedSession(
            id: UUID(), projectID: UUID(), projectName: "Deleted", type: .coding, goal: nil, outcome: nil,
            startedAt: now.addingTimeInterval(-200), endedAt: now.addingTimeInterval(-120), pauseIntervals: []
        )
        let state = AppState(
            workspaces: [first, second],
            projects: [firstProject, secondProject],
            completedSessions: [firstSession, secondSession, noProject, orphan],
            settings: CodePulseSettings(selectedWorkspaceID: first.id)
        )
        let store = makeStore(state: state)

        let firstQuery = HistoryQuery(workspace: .workspaceID(first.id))
        XCTAssertEqual(store.historySessions(for: firstQuery, referenceDate: now).map(\.id), [firstSession.id])
        XCTAssertEqual(
            Set(store.historySessions(for: HistoryQuery(), referenceDate: now).map(\.id)),
            [firstSession.id, secondSession.id, noProject.id, orphan.id]
        )

        XCTAssertTrue(store.moveProject(id: firstProject.id, to: second.id))
        XCTAssertEqual(store.historySessions(for: firstQuery, referenceDate: now).map(\.id), [])
        XCTAssertEqual(
            Set(store.historySessions(for: HistoryQuery(workspace: .workspaceID(second.id)), referenceDate: now).map(\.id)),
            [firstSession.id, secondSession.id]
        )
        XCTAssertEqual(store.state.completedSessions.first(where: { $0.id == firstSession.id })?.projectID, firstProject.id)
    }

    func testWorkspaceScopedInsightsUsesCurrentMembershipWithoutChangingCalculations() {
        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let second = WorkspaceRecord(id: UUID(), name: "Second", createdAt: now)
        let firstProject = ProjectRecord(workspaceID: first.id, name: "First Project", createdAt: now)
        let secondProject = ProjectRecord(workspaceID: second.id, name: "Second Project", createdAt: now)
        let firstSession = completedSession(id: UUID(), project: firstProject, startedAt: now.addingTimeInterval(-600), duration: 120)
        let secondSession = completedSession(id: UUID(), project: secondProject, startedAt: now.addingTimeInterval(-400), duration: 240)
        let noProject = CompletedSession(
            id: UUID(), projectID: nil, projectName: nil, type: .coding, goal: nil, outcome: nil,
            startedAt: now.addingTimeInterval(-300), endedAt: now.addingTimeInterval(-240), pauseIntervals: []
        )
        let orphan = CompletedSession(
            id: UUID(), projectID: UUID(), projectName: "Deleted", type: .coding, goal: nil, outcome: nil,
            startedAt: now.addingTimeInterval(-200), endedAt: now.addingTimeInterval(-120), pauseIntervals: []
        )
        let state = AppState(
            workspaces: [first, second],
            projects: [firstProject, secondProject],
            completedSessions: [firstSession, secondSession, noProject, orphan]
        )
        let all = InsightsCalculator.summary(
            state: state, calendar: calendar, referenceDate: now, timeframe: .allTime
        )
        let firstOnly = InsightsCalculator.summary(
            state: state, calendar: calendar, referenceDate: now, timeframe: .allTime,
            workspace: .workspaceID(first.id)
        )
        XCTAssertEqual(all.sessionCount, 4)
        XCTAssertEqual(firstOnly.sessionCount, 1)
        XCTAssertEqual(firstOnly.totalDuration, 120, accuracy: 0.001)
        XCTAssertEqual(firstOnly.projectBreakdown.map(\.label), [firstProject.name])

        let store = makeStore(state: state)
        XCTAssertTrue(store.moveProject(id: firstProject.id, to: second.id))
        let movedFirst = InsightsCalculator.summary(
            state: store.state, calendar: calendar, referenceDate: now, timeframe: .allTime,
            workspace: .workspaceID(first.id)
        )
        XCTAssertEqual(movedFirst.sessionCount, 0)
        XCTAssertEqual(movedFirst.totalDuration, 0, accuracy: 0.001)
    }

    func testWorkspaceSelectionDoesNotAffectDeveloperToolProjectResolution() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulseWorkspaceResolver-\(UUID().uuidString)")
        let firstURL = root.appendingPathComponent("First", isDirectory: true)
        let secondURL = root.appendingPathComponent("Second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let second = WorkspaceRecord(id: UUID(), name: "Second", createdAt: now)
        let firstProject = ProjectRecord(workspaceID: first.id, name: "First", folderPath: firstURL.path, createdAt: now)
        let secondProject = ProjectRecord(workspaceID: second.id, name: "Second", folderPath: secondURL.path, createdAt: now)
        let store = makeStore(state: AppState(
            workspaces: [first, second], projects: [firstProject, secondProject],
            settings: CodePulseSettings(selectedWorkspaceID: first.id)
        ))

        XCTAssertTrue(store.selectWorkspace(id: second.id))
        XCTAssertEqual(
            DeveloperToolProjectResolver.projectID(
                for: firstURL.appendingPathComponent("Sources").path,
                in: store.state.projects
            ),
            firstProject.id
        )
    }

    func testWorkspaceDashboardSnapshotIsDeterministicAndReadOnly() {
        let first = WorkspaceRecord(id: UUID(), name: "First", createdAt: now)
        let second = WorkspaceRecord(id: UUID(), name: "Second", createdAt: now)
        let active = ProjectRecord(workspaceID: first.id, name: "Active", createdAt: now.addingTimeInterval(-20))
        let archived = ProjectRecord(
            workspaceID: first.id, name: "Archived", createdAt: now.addingTimeInterval(-30),
            archivedAt: now.addingTimeInterval(-10)
        )
        let other = ProjectRecord(workspaceID: second.id, name: "Other", createdAt: now)
        let session = completedSession(id: UUID(), project: active, startedAt: now.addingTimeInterval(-120), duration: 60)
        let state = AppState(
            workspaces: [first, second], projects: [active, archived, other], completedSessions: [session]
        )
        let snapshot = WorkspaceDashboardCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: first.id, timeframe: .allTime
        )

        XCTAssertEqual(snapshot?.workspace.id, first.id)
        XCTAssertEqual(snapshot?.activeProjectCount, 1)
        XCTAssertEqual(snapshot?.archivedProjectCount, 1)
        XCTAssertEqual(snapshot?.recentProjects.map(\.id), [active.id, archived.id])
        XCTAssertEqual(snapshot?.recentSessions.map(\.id), [session.id])
        XCTAssertEqual(snapshot?.totalTrackedDuration ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(snapshot?.projectBreakdown.map(\.label), [active.name])
        XCTAssertEqual(snapshot?.intelligence.patterns.projectsTouched, 1)
        XCTAssertEqual(snapshot?.intelligence.resumeItems.map(\.projectID), [active.id])
    }

    private func makeStore(
        state: AppState,
        persistence: WorkspaceExperiencePersistence? = nil
    ) -> SessionStore {
        makeStore(
            persistence: persistence ?? WorkspaceExperiencePersistence(state: state)
        )
    }

    private func makeStore(persistence: WorkspaceExperiencePersistence) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: WorkspaceExperienceClock(now: now),
            calendar: calendar,
            automaticallyRefresh: false
        )
    }

    private func completedSession(
        id: UUID,
        project: ProjectRecord,
        startedAt: Date,
        duration: TimeInterval = 60
    ) -> CompletedSession {
        CompletedSession(
            id: id,
            projectID: project.id,
            projectName: project.name,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            pauseIntervals: []
        )
    }
}
