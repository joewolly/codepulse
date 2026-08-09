import XCTest
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
}
