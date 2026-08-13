import XCTest
import CodePulseIntegration
@testable import CodePulse

private final class TestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func advance(_ interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

private final class InMemoryPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

@MainActor
final class SessionStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testNewSessionStartsAtZeroActiveDuration() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        XCTAssertEqual(store.elapsedDuration, 0, accuracy: 0.001)
    }

    func testDeleteIntegrationDataRemovesOnlySelectedAgentMetadataAndUsage() throws {
        let clock = TestClock(start)
        let workspace = Workspace(name: "Automatic", createdAt: start, source: .automatic)
        let activity = Activity(workspaceID: workspace.id, title: "Agent", createdAt: start)
        let codexRun = Run(
            activityID: activity.id,
            kind: .agent,
            startedAt: start,
            agentMetadata: AgentRunMetadata(integration: .codex, sessionFingerprint: "codex", lastEventAt: start)
        )
        let claudeRun = Run(
            activityID: activity.id,
            kind: .agent,
            startedAt: start,
            agentMetadata: AgentRunMetadata(integration: .claudeCode, sessionFingerprint: "claude", lastEventAt: start)
        )
        let state = AppState(
            settings: CodePulseSettings(),
            developerEventDiagnostics: DeveloperEventDiagnosticsJournal(entries: [
                DeveloperEventDiagnostic(receivedAt: start, status: .accepted, integration: "codex"),
                DeveloperEventDiagnostic(receivedAt: start, status: .accepted, integration: "claude-code"),
                DeveloperEventDiagnostic(receivedAt: start, status: .rejected, rejectionCode: "invalid-event")
            ]),
            activityGraph: ActivityGraph(workspaces: [workspace], activities: [activity], runs: [codexRun, claudeRun]),
            usageSamples: [
                UsageSample(integration: .codex, observedAt: start, tokens: UsageTokenCounts(input: 1)),
                UsageSample(integration: .claudeCode, observedAt: start, tokens: UsageTokenCounts(input: 2))
            ],
            codexUsageProcessing: CodexUsageProcessingState(),
            claudeUsageProcessing: ClaudeUsageProcessingState()
        )
        let store = makeStore(clock: clock, persistence: InMemoryPersistence(state))

        store.deleteIntegrationData(for: DeveloperTool.codex)

        XCTAssertFalse(store.state.settings.codexUsageTrackingEnabled)
        XCTAssertFalse(store.state.settings.claudeUsageTrackingEnabled)
        XCTAssertNil(store.state.codexUsageProcessing)
        XCTAssertNotNil(store.state.claudeUsageProcessing)
        XCTAssertEqual(store.state.usageSamples.map { $0.integration }, [DeveloperTool.claudeCode])
        XCTAssertEqual(store.activityGraph.runs.map { $0.agentMetadata?.integration }, [DeveloperEventIntegration.claudeCode])
        XCTAssertEqual(store.state.developerEventDiagnostics?.entries.map { $0.integration }, ["claude-code", nil])
    }

    func testLegacySessionControlsMaintainCompatibleManualActivityRun() throws {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)

        XCTAssertTrue(store.startSession(projectID: nil, goal: "Ship", type: .review))
        let activity = try XCTUnwrap(store.activityGraph.activities.first)
        let run = try XCTUnwrap(store.activityGraph.runs.first)
        XCTAssertEqual(activity.workType, .review)
        XCTAssertEqual(run.kind, .manual)
        XCTAssertEqual(run.intervals.last?.state, .active)

        clock.advance(60)
        XCTAssertTrue(store.pause())
        XCTAssertEqual(store.activityGraph.runs.first?.intervals.map(\.state), [.active, .waiting])

        clock.advance(30)
        XCTAssertTrue(store.resume())
        XCTAssertEqual(store.activityGraph.runs.first?.intervals.map(\.state), [.active, .waiting, .active])

        clock.advance(60)
        XCTAssertTrue(store.finish())
        XCTAssertTrue(store.activityGraph.runs.first?.intervals.allSatisfy { !$0.isOpen } == true)
        XCTAssertNotNil(store.activity(forLegacySessionID: try XCTUnwrap(store.activeSession?.id)))
    }

    func testRunningDurationUsesTimestamps() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        clock.advance(75)
        store.refresh()

        XCTAssertEqual(store.elapsedDuration, 75, accuracy: 0.001)
    }

    func testPauseStopsActiveDurationAccumulation() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        clock.advance(30)
        XCTAssertTrue(store.pause())

        clock.advance(600)
        store.refresh()

        XCTAssertEqual(store.elapsedDuration, 30, accuracy: 0.001)
        XCTAssertEqual(store.phase, .paused)
    }

    func testResumeContinuesTheSameSession() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        clock.advance(30)
        XCTAssertTrue(store.pause())
        clock.advance(600)
        XCTAssertTrue(store.resume())
        clock.advance(20)
        store.refresh()

        XCTAssertEqual(store.elapsedDuration, 50, accuracy: 0.001)
    }

    func testMultiplePauseResumeCyclesAccumulateOnlyPausedTime() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        clock.advance(10)
        XCTAssertTrue(store.pause())
        clock.advance(5)
        XCTAssertTrue(store.resume())
        clock.advance(20)
        XCTAssertTrue(store.pause())
        clock.advance(7)
        XCTAssertTrue(store.resume())
        clock.advance(30)
        store.refresh()

        XCTAssertEqual(store.elapsedDuration, 60, accuracy: 0.001)
        XCTAssertEqual(store.activeSession?.accumulatedPausedDuration(at: clock.now) ?? 0, 12, accuracy: 0.001)
    }

    func testFinishFreezesAndSavesCorrectActiveDuration() {
        let clock = TestClock(start)
        let persistence = InMemoryPersistence()
        let store = makeStore(clock: clock, persistence: persistence)
        XCTAssertTrue(store.startSession(projectID: nil, goal: "Ship it"))

        clock.advance(30)
        XCTAssertTrue(store.pause())
        clock.advance(15)
        XCTAssertTrue(store.resume())
        clock.advance(45)
        XCTAssertTrue(store.finish())
        let frozen = store.elapsedDuration

        clock.advance(500)
        store.refresh()
        XCTAssertEqual(store.phase, .finishing)
        XCTAssertEqual(store.elapsedDuration, frozen, accuracy: 0.001)
        XCTAssertTrue(store.saveFinishedSession(outcome: "Done"))
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertEqual(persistence.state.completedSessions[0].activeDuration, 75, accuracy: 0.001)
    }

    func testFinishingPausedSessionClosesPauseAndFreezesDuration() {
        let clock = TestClock(start)
        let persistence = InMemoryPersistence()
        let store = makeStore(clock: clock, persistence: persistence)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        clock.advance(30)
        XCTAssertTrue(store.pause())
        clock.advance(600)
        XCTAssertTrue(store.finish())

        XCTAssertEqual(store.phase, .finishing)
        XCTAssertEqual(store.elapsedDuration, 30, accuracy: 0.001)
        XCTAssertEqual(store.activeSession?.pauseIntervals.last?.endedAt, clock.now)

        clock.advance(300)
        store.refresh()
        XCTAssertEqual(store.elapsedDuration, 30, accuracy: 0.001)
        XCTAssertTrue(store.saveFinishedSession(outcome: "  "))
        XCTAssertNil(persistence.state.completedSessions[0].outcome)
    }

    func testLifecycleRejectsDuplicateAndImpossibleActions() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        XCTAssertFalse(store.startSession(projectID: nil, goal: nil))
        XCTAssertFalse(store.resume())
        XCTAssertFalse(store.discardSession())

        clock.advance(30)
        XCTAssertTrue(store.pause())
        XCTAssertFalse(store.pause())
        XCTAssertFalse(store.discardSession())

        clock.advance(30)
        XCTAssertTrue(store.finish())
        XCTAssertFalse(store.pause())
        XCTAssertFalse(store.resume())
        XCTAssertFalse(store.finish())
        XCTAssertTrue(store.discardSession())
        XCTAssertEqual(store.phase, .idle)
    }

    func testTransitionDatesRemainMonotonic() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        let pauseDate = start.addingTimeInterval(100)
        XCTAssertTrue(store.pause(at: pauseDate))
        XCTAssertTrue(store.resume(at: start.addingTimeInterval(10)))
        XCTAssertEqual(store.activeSession?.pauseIntervals[0].endedAt, pauseDate)

        clock.now = pauseDate
        XCTAssertTrue(store.finish(at: start.addingTimeInterval(20)))
        XCTAssertEqual(store.activeSession?.endedAt, pauseDate)
        XCTAssertEqual(store.elapsedDuration, 100, accuracy: 0.001)
    }

    func testClockMovingBackwardsDoesNotCountFuturePauseTime() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        let pauseDate = start.addingTimeInterval(100)
        XCTAssertTrue(store.pause(at: pauseDate))
        XCTAssertTrue(store.resume(at: pauseDate))

        clock.now = start.addingTimeInterval(50)
        store.refresh()
        XCTAssertEqual(store.elapsedDuration, 50, accuracy: 0.001)
    }

    func testRestoredRunningSessionContinuesFromPersistedTimestamp() {
        let clock = TestClock(start)
        let persistence = InMemoryPersistence()
        let firstStore = makeStore(clock: clock, persistence: persistence)
        XCTAssertTrue(firstStore.startSession(projectID: nil, goal: nil))
        clock.advance(90)

        let restoredStore = makeStore(clock: clock, persistence: persistence)
        restoredStore.refresh()
        XCTAssertEqual(restoredStore.phase, .running)
        XCTAssertEqual(restoredStore.elapsedDuration, 90, accuracy: 0.001)
    }

    func testRestoredPausedSessionRemainsFrozen() {
        let clock = TestClock(start)
        let persistence = InMemoryPersistence()
        let firstStore = makeStore(clock: clock, persistence: persistence)
        XCTAssertTrue(firstStore.startSession(projectID: nil, goal: nil))
        clock.advance(30)
        XCTAssertTrue(firstStore.pause())
        let pausedDuration = firstStore.elapsedDuration
        clock.advance(900)

        let restoredStore = makeStore(clock: clock, persistence: persistence)
        restoredStore.refresh()
        XCTAssertEqual(restoredStore.phase, .paused)
        XCTAssertEqual(restoredStore.elapsedDuration, pausedDuration, accuracy: 0.001)
    }

    func testTodayTotalCombinesCompletedAndActiveSessions() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        clock.advance(3_600)
        XCTAssertTrue(store.finish())
        XCTAssertTrue(store.saveFinishedSession(outcome: nil))

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        clock.advance(1_800)
        store.refresh()

        XCTAssertEqual(store.todayTotal(), 5_400, accuracy: 0.001)
    }

    func testWallClockJumpUsesDatesInsteadOfTickCount() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        clock.advance(8 * 60 * 60)
        store.refresh()

        XCTAssertEqual(store.elapsedDuration, 8 * 60 * 60, accuracy: 0.001)
    }

    func testTodayTotalSplitsSessionAtLocalDayBoundaryAndExcludesPause() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let yesterday = calendar.date(from: DateComponents(year: 2023, month: 11, day: 13, hour: 23, minute: 50))!
        let today = calendar.date(from: DateComponents(year: 2023, month: 11, day: 14, hour: 0, minute: 15))!
        let clock = TestClock(yesterday)
        let persistence = InMemoryPersistence()
        let store = makeStore(clock: clock, persistence: persistence, calendar: calendar)

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        clock.advance(5 * 60)
        XCTAssertTrue(store.pause())
        clock.advance(10 * 60)
        XCTAssertTrue(store.resume())
        clock.advance(10 * 60)
        XCTAssertTrue(store.finish())
        XCTAssertTrue(store.saveFinishedSession(outcome: nil))

        XCTAssertEqual(store.todayTotal(at: today), 10 * 60, accuracy: 0.001)
        XCTAssertEqual(store.historyGroups.count, 1)
        XCTAssertEqual(store.historyGroups[0].totalDuration, 5 * 60, accuracy: 0.001)
    }

    func testJSONPersistenceRoundTripsProjectsSettingsAndSessions() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseTests-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let persistence = JSONFilePersistence(fileURL: url)
        let project = ProjectRecord(
            name: "CodePulse",
            folderPath: "/tmp/CodePulse",
            bookmarkData: Data([1, 2, 3]),
            createdAt: start,
            lastUsedAt: start.addingTimeInterval(1)
        )
        var state = AppState()
        state.projects = [project]
        state.settings.defaultProjectBehavior = .specificProject
        state.settings.specificProjectID = project.id
        state.settings.menuBarDisplay = .timerOnly
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: project.id,
            projectName: project.name,
            goal: "Ship it",
            outcome: "Done",
            startedAt: start,
            endedAt: start.addingTimeInterval(60),
            pauseIntervals: []
        )]

        persistence.save(state)
        XCTAssertEqual(persistence.load(), state)
    }

    func testFinishedSessionPersistsAcrossStoreReloadWithoutActiveRestoration() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseTests-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let clock = TestClock(start)
        let firstStore = SessionStore(
            persistence: JSONFilePersistence(fileURL: url),
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            automaticallyRefresh: false
        )
        XCTAssertTrue(firstStore.startSession(projectID: nil, goal: "Ship it"))
        clock.advance(90)
        XCTAssertTrue(firstStore.finish())
        XCTAssertTrue(firstStore.saveFinishedSession(outcome: "Done"))

        let restoredStore = SessionStore(
            persistence: JSONFilePersistence(fileURL: url),
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            automaticallyRefresh: false
        )
        XCTAssertEqual(restoredStore.phase, .idle)
        XCTAssertNil(restoredStore.activeSession)
        XCTAssertEqual(restoredStore.state.completedSessions.count, 1)
        XCTAssertEqual(restoredStore.state.completedSessions[0].goal, "Ship it")
        XCTAssertEqual(restoredStore.state.completedSessions[0].outcome, "Done")
        XCTAssertEqual(restoredStore.state.completedSessions[0].activeDuration, 90, accuracy: 0.001)
    }

    func testProjectAndSettingsMutationsPersistAcrossStoreReload() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseTests-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let clock = TestClock(start)
        let firstStore = SessionStore(
            persistence: JSONFilePersistence(fileURL: url),
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            automaticallyRefresh: false
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulse-project")
        let projectID = firstStore.addProject(name: "Demo", folderURL: folder, at: start)
        XCTAssertNotNil(projectID)
        firstStore.updateSettings {
            $0.menuBarDisplay = .timerOnly
            $0.idleAppearance = .iconOnly
            $0.defaultProjectBehavior = .specificProject
            $0.specificProjectID = projectID
        }

        let restoredStore = SessionStore(
            persistence: JSONFilePersistence(fileURL: url),
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            automaticallyRefresh: false
        )
        XCTAssertEqual(restoredStore.state.projects.first?.id, projectID)
        XCTAssertEqual(restoredStore.state.projects.first?.name, "Demo")
        XCTAssertEqual(restoredStore.state.projects.first?.folderPath, folder.path)
        XCTAssertEqual(restoredStore.state.settings.menuBarDisplay, .timerOnly)
        XCTAssertEqual(restoredStore.state.settings.idleAppearance, .iconOnly)
        XCTAssertEqual(restoredStore.defaultProjectID, projectID)
    }

    func testProjectMetadataAndDefaultSelectionAreOptional() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulse-project")

        let projectID = store.addProject(name: "  Demo  ", folderURL: folder, at: start)
        XCTAssertNotNil(projectID)
        XCTAssertEqual(store.state.projects.first?.name, "Demo")
        XCTAssertEqual(store.state.projects.first?.folderPath, folder.path)
        XCTAssertNil(store.defaultProjectID)

        store.updateSettings {
            $0.defaultProjectBehavior = .specificProject
            $0.specificProjectID = projectID
        }
        XCTAssertEqual(store.defaultProjectID, projectID)

        XCTAssertTrue(store.startSession(projectID: projectID, goal: "  "))
        XCTAssertEqual(store.activeSession?.projectID, projectID)
        XCTAssertEqual(store.activeSession?.projectName, "Demo")
        XCTAssertNil(store.activeSession?.goal)
    }

    func testTodayTotalExcludesPausedActiveTime() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        clock.advance(60)
        XCTAssertTrue(store.pause())
        clock.advance(600)
        store.refresh()

        XCTAssertEqual(store.todayTotal(), 60, accuracy: 0.001)
    }

    func testCodexLifecycleEventsCreateAndAdvanceAnAgentRunForMatchingWorkspace() throws {
        let clock = TestClock(start)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulse-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperEventV2Inbox(paths: paths, fingerprintSalt: Data(repeating: 9, count: 32))
        let store = SessionStore(
            persistence: InMemoryPersistence(),
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            developerEventV2Consumer: DeveloperEventV2Consumer(inbox: inbox),
            automaticallyRefresh: false
        )
        let workspacePath = "/tmp/codepulse-workspace"
        let workspaceID = try XCTUnwrap(store.addWorkspace(
            name: "CodePulse",
            roots: [WorkspaceRoot(path: workspacePath, addedAt: start)],
            at: start
        ))

        let started = codexEvent(kind: .sessionStarted, at: start, key: "codex-start-0123456789abcdef", path: workspacePath)
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(started), now: start), .accepted)
        clock.advance(5)
        store.refresh()

        let run = try XCTUnwrap(store.runs(workspaceID: workspaceID).first)
        XCTAssertEqual(run.agentMetadata?.integration, .codex)
        XCTAssertEqual(run.agentMetadata?.state, .active)
        XCTAssertEqual(run.intervals.map(\.state), [.active])
        let persistedText = try XCTUnwrap(String(data: JSONEncoder().encode(store.state), encoding: .utf8))
        XCTAssertFalse(persistedText.contains("codex-session"))

        let permission = codexEvent(
            kind: .permissionRequested,
            at: start.addingTimeInterval(10),
            key: "codex-permission-0123456789",
            path: workspacePath
        )
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(permission), now: start.addingTimeInterval(10)), .accepted)
        clock.advance(5)
        store.refresh()

        XCTAssertEqual(store.runs(workspaceID: workspaceID).first?.agentMetadata?.state, .awaitingPermission)
        XCTAssertEqual(store.runs(workspaceID: workspaceID).first?.intervals.map(\.state), [.active, .waiting])
    }

    func testCodexCorrelationKeepsConcurrentRunsSeparateAndResumesAfterStop() throws {
        let clock = TestClock(start)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulse-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperEventV2Inbox(paths: paths, fingerprintSalt: Data(repeating: 8, count: 32))
        let store = SessionStore(
            persistence: InMemoryPersistence(),
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            developerEventV2Consumer: DeveloperEventV2Consumer(inbox: inbox),
            automaticallyRefresh: false
        )
        let workspacePath = "/tmp/codepulse-concurrent"
        let workspaceID = try XCTUnwrap(store.addWorkspace(
            name: "CodePulse",
            roots: [WorkspaceRoot(path: workspacePath, addedAt: start)],
            at: start
        ))

        for (session, key) in [("codex-a", "codex-a-start-0123456789abcdef"), ("codex-b", "codex-b-start-0123456789abcdef")] {
            let event = codexEvent(kind: .sessionStarted, at: start, key: key, path: workspacePath, session: session)
            XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(event), now: start), .accepted)
        }
        clock.advance(5)
        store.refresh()
        XCTAssertEqual(store.runs(workspaceID: workspaceID).count, 2)
        XCTAssertEqual(store.runs(workspaceID: workspaceID).map { $0.agentMetadata?.state }, [.active, .active])

        let stoppedAt = start.addingTimeInterval(10)
        let stop = codexEvent(kind: .sessionStopped, at: stoppedAt, key: "codex-a-stop-0123456789abcdef", path: workspacePath, session: "codex-a")
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(stop), now: stoppedAt), .accepted)
        clock.advance(5)
        store.refresh()
        XCTAssertEqual(store.runs(workspaceID: workspaceID).filter { $0.agentMetadata?.state == .reviewGrace }.count, 1)

        let resumedAt = start.addingTimeInterval(20)
        let resumed = codexEvent(kind: .activityObserved, at: resumedAt, key: "codex-a-resume-0123456789abcdef", path: workspacePath, session: "codex-a")
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(resumed), now: resumedAt), .accepted)
        clock.advance(5)
        store.refresh()
        XCTAssertEqual(store.runs(workspaceID: workspaceID).filter { $0.agentMetadata?.state == .active }.count, 2)

        // Replaying a lifecycle event uses the same session fingerprint and
        // never creates a third run.
        try DeveloperEventV2Codec.encode(resumed).write(
            to: paths.eventV2InboxURL.appendingPathComponent("replayed-event.json"),
            options: .atomic
        )
        clock.advance(5)
        store.refresh()
        XCTAssertEqual(store.runs(workspaceID: workspaceID).count, 2)
    }

    func testClaudeParentAndOverlappingChildrenRemainSeparateWhenParentEndsFirst() throws {
        let clock = TestClock(start)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulse-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperEventV2Inbox(paths: paths, fingerprintSalt: Data(repeating: 6, count: 32))
        let store = SessionStore(
            persistence: InMemoryPersistence(),
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            developerEventV2Consumer: DeveloperEventV2Consumer(inbox: inbox),
            automaticallyRefresh: false
        )
        let workspacePath = "/tmp/codepulse-claude"
        let workspaceID = try XCTUnwrap(store.addWorkspace(
            name: "CodePulse",
            roots: [WorkspaceRoot(path: workspacePath, addedAt: start)],
            at: start
        ))
        let parent = developerEvent(
            integration: .claudeCode,
            kind: .sessionStarted,
            at: start,
            key: "claude-parent-start-0123456789",
            path: workspacePath,
            session: "parent"
        )
        let firstChild = developerEvent(
            integration: .claudeCode,
            kind: .sessionStarted,
            at: start.addingTimeInterval(1),
            key: "claude-first-child-start-0123456789",
            path: workspacePath,
            session: "first-child",
            parent: "parent"
        )
        let secondChild = developerEvent(
            integration: .claudeCode,
            kind: .sessionStarted,
            at: start.addingTimeInterval(2),
            key: "claude-second-child-start-012345678",
            path: workspacePath,
            session: "second-child",
            parent: "parent"
        )
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(parent), now: start), .accepted)
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(firstChild), now: start.addingTimeInterval(1)), .accepted)
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(secondChild), now: start.addingTimeInterval(2)), .accepted)
        clock.advance(5)
        store.refresh()

        let firstChildRun = try XCTUnwrap(store.runs(workspaceID: workspaceID).first(where: {
            $0.agentMetadata?.sessionFingerprint == inbox.fingerprint(for: "claude-code:first-child")
        }))
        let secondChildRun = try XCTUnwrap(store.runs(workspaceID: workspaceID).first(where: {
            $0.agentMetadata?.sessionFingerprint == inbox.fingerprint(for: "claude-code:second-child")
        }))
        XCTAssertEqual(firstChildRun.agentMetadata?.parentSessionFingerprint, inbox.fingerprint(for: "claude-code:parent"))
        XCTAssertEqual(secondChildRun.agentMetadata?.parentSessionFingerprint, inbox.fingerprint(for: "claude-code:parent"))

        let overlappingActivity = developerEvent(
            integration: .claudeCode,
            kind: .activityObserved,
            at: start.addingTimeInterval(10),
            key: "claude-second-child-activity-012345",
            path: workspacePath,
            session: "second-child",
            parent: "parent"
        )
        let parentEnd = developerEvent(
            integration: .claudeCode,
            kind: .sessionEnded,
            at: start.addingTimeInterval(11),
            key: "claude-parent-end-0123456789ab",
            path: workspacePath,
            session: "parent"
        )
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(overlappingActivity), now: start.addingTimeInterval(10)), .accepted)
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(parentEnd), now: start.addingTimeInterval(11)), .accepted)
        clock.advance(10)
        store.refresh()

        XCTAssertEqual(store.runs(workspaceID: workspaceID).count, 3)
        XCTAssertEqual(store.runs(workspaceID: workspaceID).first(where: { $0.id == firstChildRun.id })?.agentMetadata?.state, .active)
        XCTAssertEqual(store.runs(workspaceID: workspaceID).first(where: { $0.id == secondChildRun.id })?.agentMetadata?.state, .active)
        XCTAssertEqual(store.runs(workspaceID: workspaceID).first(where: {
            $0.agentMetadata?.sessionFingerprint == inbox.fingerprint(for: "claude-code:parent")
        })?.agentMetadata?.state, .ended)
    }

    func testOpenCodeConcurrentRunsAndRestartReconciliation() throws {
        let clock = TestClock(start)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulse-opencode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperEventV2Inbox(paths: paths, fingerprintSalt: Data(repeating: 7, count: 32))
        let workspacePath = "/tmp/codepulse-opencode"
        let persistence = InMemoryPersistence()
        var store: SessionStore? = SessionStore(
            persistence: persistence,
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            developerEventV2Consumer: DeveloperEventV2Consumer(inbox: inbox),
            automaticallyRefresh: false
        )
        let workspaceID = try XCTUnwrap(store?.addWorkspace(
            name: "CodePulse",
            roots: [WorkspaceRoot(path: workspacePath, addedAt: start)],
            at: start
        ))
        for (session, key) in [("open-1", "opencode-one-start-0123456789"), ("open-2", "opencode-two-start-0123456789")] {
            let event = developerEvent(
                integration: .openCode,
                kind: .sessionStarted,
                at: start,
                key: key,
                path: workspacePath,
                session: session
            )
            XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(event), now: start), .accepted)
        }
        clock.advance(5)
        store?.refresh()
        XCTAssertEqual(store?.runs(workspaceID: workspaceID).filter { $0.agentMetadata?.state == .active }.count, 2)

        store = nil
        clock.advance(16 * 60)
        let restored = SessionStore(
            persistence: persistence,
            clock: clock,
            calendar: Calendar(identifier: .gregorian),
            developerEventV2Consumer: DeveloperEventV2Consumer(inbox: inbox),
            automaticallyRefresh: false
        )
        restored.refresh()
        XCTAssertEqual(restored.activityGraph.runs.filter { $0.agentMetadata?.state == .orphaned }.count, 2)
    }

    private func makeStore(
        clock: TestClock,
        persistence: InMemoryPersistence = InMemoryPersistence(),
        calendar: Calendar? = nil
    ) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: clock,
            calendar: calendar ?? Calendar(identifier: .gregorian),
            automaticallyRefresh: false
        )
    }

    private func codexEvent(
        kind: DeveloperEventKindV2,
        at date: Date,
        key: String,
        path: String,
        session: String = "codex-session"
    ) -> DeveloperEventV2 {
        developerEvent(
            integration: .codex,
            kind: kind,
            at: date,
            key: key,
            path: path,
            session: session
        )
    }

    private func developerEvent(
        integration: DeveloperEventIntegration,
        kind: DeveloperEventKindV2,
        at date: Date,
        key: String,
        path: String,
        session: String,
        parent: String? = nil
    ) -> DeveloperEventV2 {
        DeveloperEventV2(
            integration: integration,
            eventKind: kind,
            observedAt: date,
            idempotencyKey: key,
            externalSessionKey: session,
            parentSessionKey: parent,
            workingDirectory: path,
            model: "gpt-5.6",
            parserVersion: "codex-hooks-v1",
            integrationVersion: "test"
        )
    }
}
