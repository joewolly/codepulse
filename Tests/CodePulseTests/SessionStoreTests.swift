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

private struct CriticalSaveFailure: Error {}

private final class FailureInjectingPersistence: StatePersisting {
    var state: AppState
    var failCriticalSaves = false

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }

    func save(_ state: AppState) {
        self.state = state
    }

    func saveCritical(_ state: AppState) throws {
        if failCriticalSaves {
            throw CriticalSaveFailure()
        }
        self.state = state
    }
}

private final class RecoveryReportingPersistence: StatePersisting {
    var state: AppState
    private(set) var loadStatus: StateLoadStatus = .loaded
    var failCriticalSaves = false
    var failNonCriticalSaves = false

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }

    func save(_ state: AppState) {
        if failNonCriticalSaves {
            loadStatus = .unreadable
            return
        }
        self.state = state
    }

    func saveCritical(_ state: AppState) throws {
        if failCriticalSaves {
            loadStatus = .unreadable
            throw CriticalSaveFailure()
        }
        self.state = state
    }
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

    func testStateRevisionChangesForStateMutationsButNotClockRefreshes() {
        let clock = TestClock(start)
        let store = makeStore(clock: clock)
        let initialRevision = store.stateRevision

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        XCTAssertGreaterThan(store.stateRevision, initialRevision)
        let runningRevision = store.stateRevision

        clock.advance(60)
        store.refresh()
        XCTAssertEqual(store.stateRevision, runningRevision)

        XCTAssertTrue(store.pause())
        XCTAssertGreaterThan(store.stateRevision, runningRevision)
    }

    func testCriticalCommitFailureThatMakesPersistenceUnreadableEntersRecovery() {
        let persistence = RecoveryReportingPersistence()
        persistence.failCriticalSaves = true
        let store = SessionStore(
            persistence: persistence,
            clock: TestClock(start),
            automaticallyRefresh: false
        )
        let originalState = store.state
        let originalRevision = store.stateRevision

        XCTAssertFalse(store.startSession(projectID: nil, goal: "Release validation"))
        XCTAssertTrue(store.isInRecoveryMode)
        XCTAssertFalse(store.shouldPresentOnboarding)
        XCTAssertEqual(store.state, originalState)
        XCTAssertEqual(store.stateRevision, originalRevision)
    }

    func testNonCriticalCommitFailureThatMakesPersistenceUnreadableDoesNotPublishState() {
        let persistence = RecoveryReportingPersistence()
        let store = SessionStore(
            persistence: persistence,
            clock: TestClock(start),
            automaticallyRefresh: false
        )
        let originalState = store.state
        let originalRevision = store.stateRevision
        persistence.failNonCriticalSaves = true

        store.updateSettings { settings in
            settings.menuBarDisplay = .timerOnly
        }

        XCTAssertTrue(store.isInRecoveryMode)
        XCTAssertEqual(store.state, originalState)
        XCTAssertEqual(store.stateRevision, originalRevision)
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

    func testManualLifecycleCommitFailureKeepsPriorStateAndRelaunchesThatState() {
        let clock = TestClock(start)
        let persistence = FailureInjectingPersistence()
        let store = makeStore(clock: clock, persistence: persistence)

        persistence.failCriticalSaves = true
        XCTAssertFalse(store.startSession(projectID: nil, goal: nil))
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(persistence.state.activeSession)
        XCTAssertEqual(
            store.lifecycleErrorMessage,
            "CodePulse couldn't save this lifecycle change. Your previous session state is unchanged. Try again or dismiss this message."
        )
        store.dismissLifecycleError()
        XCTAssertNil(store.lifecycleErrorMessage)

        persistence.failCriticalSaves = false
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))

        persistence.failCriticalSaves = true
        XCTAssertFalse(store.pause())
        XCTAssertEqual(store.phase, .running)

        persistence.failCriticalSaves = false
        XCTAssertTrue(store.pause())
        persistence.failCriticalSaves = true
        XCTAssertFalse(store.resume())
        XCTAssertEqual(store.phase, .paused)

        persistence.failCriticalSaves = false
        XCTAssertTrue(store.resume())
        persistence.failCriticalSaves = true
        XCTAssertFalse(store.finish())
        XCTAssertEqual(store.phase, .running)

        let relaunched = makeStore(clock: clock, persistence: persistence)
        XCTAssertEqual(relaunched.phase, .running)
        XCTAssertEqual(relaunched.activeSession?.id, store.activeSession?.id)
    }

    func testSaveFailureKeepsFinishingSessionAndRetryCreatesOneCompletedRecord() {
        let clock = TestClock(start)
        let persistence = FailureInjectingPersistence()
        let store = makeStore(clock: clock, persistence: persistence)

        XCTAssertTrue(store.startSession(projectID: nil, goal: "Recover"))
        clock.advance(60)
        XCTAssertTrue(store.finish())
        let sessionID = store.activeSession?.id

        persistence.failCriticalSaves = true
        XCTAssertFalse(store.saveFinishedSession(outcome: "Done"))
        XCTAssertEqual(store.phase, .finishing)
        XCTAssertEqual(store.activeSession?.id, sessionID)
        XCTAssertTrue(persistence.state.activeSession?.id == sessionID)
        XCTAssertTrue(persistence.state.completedSessions.isEmpty)

        let relaunched = makeStore(clock: clock, persistence: persistence)
        XCTAssertEqual(relaunched.phase, .finishing)
        persistence.failCriticalSaves = false
        XCTAssertTrue(relaunched.saveFinishedSession(outcome: "Done"))
        XCTAssertEqual(relaunched.state.completedSessions.count, 1)
        XCTAssertEqual(relaunched.state.completedSessions[0].id, sessionID)
        XCTAssertFalse(relaunched.saveFinishedSession(outcome: "Done"))

        let savedAgain = makeStore(clock: clock, persistence: persistence)
        XCTAssertEqual(savedAgain.state.completedSessions.count, 1)
        XCTAssertEqual(savedAgain.state.completedSessions.first?.id, sessionID)
        XCTAssertNil(savedAgain.activeSession)
    }

    func testPersistedFinishingOutcomeSurvivesRelaunchBeforeSave() {
        let clock = TestClock(start)
        let persistence = FailureInjectingPersistence()
        let store = makeStore(clock: clock, persistence: persistence)

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        clock.advance(60)
        XCTAssertTrue(store.finish())
        XCTAssertTrue(store.updateFinishingOutcome("  Done  "))

        let relaunched = makeStore(clock: clock, persistence: persistence)
        XCTAssertEqual(relaunched.activeSession?.outcome, "Done")
        XCTAssertTrue(relaunched.saveFinishedSession(outcome: nil))
        XCTAssertEqual(relaunched.state.completedSessions.first?.outcome, "Done")
    }

    func testDiscardFailureLeavesFinishingSessionRecoverable() {
        let clock = TestClock(start)
        let persistence = FailureInjectingPersistence()
        let store = makeStore(clock: clock, persistence: persistence)

        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        XCTAssertTrue(store.finish())
        let sessionID = store.activeSession?.id

        persistence.failCriticalSaves = true
        XCTAssertFalse(store.discardSession())
        XCTAssertEqual(store.phase, .finishing)
        XCTAssertEqual(store.activeSession?.id, sessionID)

        let relaunched = makeStore(clock: clock, persistence: persistence)
        XCTAssertEqual(relaunched.phase, .finishing)
        persistence.failCriticalSaves = false
        XCTAssertTrue(relaunched.discardSession())
        XCTAssertNil(relaunched.activeSession)
        XCTAssertTrue(relaunched.state.completedSessions.isEmpty)
    }

    func testJSONCriticalCommitFailureRollsBackTheLiveStateFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseCriticalCommit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        var shouldFail = true
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if shouldFail {
                    if case .afterLiveReplacement = point {
                        throw CriticalSaveFailure()
                    }
                }
            }
        )
        persistence.save(AppState())
        let before = try Data(contentsOf: stateURL)
        let store = SessionStore(
            persistence: persistence,
            clock: TestClock(start),
            automaticallyRefresh: false
        )

        XCTAssertFalse(store.startSession(projectID: nil, goal: nil))
        XCTAssertNil(store.activeSession)
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
        XCTAssertEqual(JSONFilePersistence(fileURL: stateURL).load(), AppState())

        shouldFail = false
        XCTAssertTrue(store.startSession(projectID: nil, goal: nil))
        XCTAssertNotNil(JSONFilePersistence(fileURL: stateURL).load().activeSession)
    }

    func testJSONCriticalCommitFailuresBeforeReplacementLeaveLiveBytesUnchanged() throws {
        let points: [StateRestoreFailurePoint] = [
            .candidateEncoding,
            .candidateWrite,
            .candidateVerification,
            .liveReplacement
        ]
        for point in points {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulseCriticalBoundary-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }

            let stateURL = root.appendingPathComponent("CodePulse/state.json")
            let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
            let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
            let base = JSONFilePersistence(fileURL: stateURL)
            base.save(stateA)
            let persistence = JSONFilePersistence(
                fileURL: stateURL,
                failureInjector: { injected in
                    if Self.sameFailurePoint(injected, point) {
                        throw CriticalSaveFailure()
                    }
                }
            )
            XCTAssertEqual(persistence.load(), stateA)
            let before = try Data(contentsOf: stateURL)

            XCTAssertThrowsError(try persistence.saveCritical(stateB)) { error in
                guard case .criticalCommitFailed = (error as? StatePersistenceError) else {
                    return XCTFail("Expected critical commit failure")
                }
            }
            XCTAssertEqual(try Data(contentsOf: stateURL), before)
            let leftovers = try FileManager.default.contentsOfDirectory(
                at: stateURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".state.critical-") }
            XCTAssertTrue(leftovers.isEmpty)
        }
    }

    func testJSONCriticalCommitDetectsTruncatedLiveStateAndRollsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseCriticalVerification-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if case .liveVerification = point {
                    try Data().write(to: stateURL, options: .atomic)
                }
            }
        )
        persistence.save(stateA)
        let before = try Data(contentsOf: stateURL)

        XCTAssertThrowsError(try persistence.saveCritical(stateB)) { error in
            guard case .criticalCommitFailed = (error as? StatePersistenceError) else {
                return XCTFail("Expected live verification failure")
            }
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
        XCTAssertEqual(persistence.loadStatus, .loaded)
        XCTAssertEqual(persistence.load(), stateA)
    }

    func testJSONCriticalCommitDurabilityFailureRollsBack() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseCriticalDurability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if Self.sameFailurePoint(point, .liveDurability) {
                    throw CriticalSaveFailure()
                }
            }
        )
        persistence.save(stateA)
        let before = try Data(contentsOf: stateURL)

        XCTAssertThrowsError(try persistence.saveCritical(stateB)) { error in
            guard case .criticalCommitFailed = (error as? StatePersistenceError) else {
                return XCTFail("Expected durability failure")
            }
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), before)
        XCTAssertEqual(persistence.loadStatus, .loaded)
    }

    func testJSONCriticalCommitRollbackFailureEntersRecoveryModeAndBlocksWrites() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseCriticalRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let stateC = AppState(settings: CodePulseSettings(idleAppearance: .iconOnly))
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if Self.sameFailurePoint(point, .afterLiveReplacement) ||
                    Self.sameFailurePoint(point, .rollbackWrite) {
                    throw CriticalSaveFailure()
                }
            }
        )
        persistence.save(stateA)
        let before = try Data(contentsOf: stateURL)

        XCTAssertThrowsError(try persistence.saveCritical(stateB)) { error in
            guard case .criticalCommitRollbackFailed = (error as? StatePersistenceError) else {
                return XCTFail("Expected severe rollback failure")
            }
        }
        XCTAssertEqual(persistence.loadStatus, .unreadable)
        let afterFailure = try Data(contentsOf: stateURL)
        XCTAssertNotEqual(afterFailure, before)

        persistence.save(stateC)
        XCTAssertEqual(try Data(contentsOf: stateURL), afterFailure)
        XCTAssertThrowsError(try persistence.saveCritical(stateC)) { error in
            guard case .unreadablePrimaryState = (error as? StatePersistenceError) else {
                return XCTFail("Expected unreadable-primary-state rejection")
            }
        }
    }

    func testJSONCriticalCommitRejectsUnsafeStoragePathWithoutWrapping() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseCriticalUnsafePath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
        let stateURL = managed.appendingPathComponent("state.json")
        let persistence = JSONFilePersistence(fileURL: stateURL)

        XCTAssertThrowsError(try persistence.saveCritical(AppState())) { error in
            guard case .unsafeStoragePath = (error as? StatePersistenceError) else {
                return XCTFail("Expected unsafe storage path")
            }
        }
        XCTAssertEqual(persistence.loadStatus, .notLoaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("state.json").path))
    }

    func testUnsafeStatePathEntersRecoveryWithoutFreshInstallOnboarding() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseLoadUnsafePath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
        let stateURL = managed.appendingPathComponent("state.json")
        let persistence = JSONFilePersistence(fileURL: stateURL)
        let store = SessionStore(
            persistence: persistence,
            clock: TestClock(start),
            automaticallyRefresh: false
        )

        XCTAssertEqual(persistence.loadStatus, .unsafePath)
        XCTAssertTrue(store.isInRecoveryMode)
        XCTAssertFalse(store.shouldPresentOnboarding)
        XCTAssertNil(store.addProject(name: "Blocked", folderURL: nil))
        XCTAssertThrowsError(try persistence.saveCritical(AppState())) { error in
            guard case .unsafeStoragePath = (error as? StatePersistenceError) else {
                return XCTFail("Expected unsafe storage path")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("state.json").path))
    }

    func testMissingStateIsFreshButUnreadableStateIsReadOnlyUntilExplicitRestore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missingURL = root.appendingPathComponent("missing/CodePulse/state.json")
        let missingPersistence = JSONFilePersistence(fileURL: missingURL)
        let missingStore = SessionStore(
            persistence: missingPersistence,
            clock: TestClock(start),
            automaticallyRefresh: false
        )
        XCTAssertEqual(missingPersistence.loadStatus, .missing)
        XCTAssertFalse(missingStore.isInRecoveryMode)
        XCTAssertTrue(missingStore.shouldPresentOnboarding)

        let stateURL = root.appendingPathComponent("broken/CodePulse/state.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptData = Data("{ not valid CodePulse state".utf8)
        try corruptData.write(to: stateURL, options: .atomic)
        let persistence = JSONFilePersistence(fileURL: stateURL)
        let store = SessionStore(
            persistence: persistence,
            clock: TestClock(start),
            automaticallyRefresh: false
        )
        XCTAssertEqual(persistence.loadStatus, .unreadable)
        XCTAssertTrue(store.isInRecoveryMode)
        XCTAssertFalse(store.shouldPresentOnboarding)
        XCTAssertNil(store.addProject(name: "Blocked", folderURL: nil))
        XCTAssertFalse(store.startSession(projectID: nil, goal: nil))
        store.markOnboardingCompleted()
        XCTAssertEqual(try Data(contentsOf: stateURL), corruptData)

        let backupURL = root.appendingPathComponent("valid-backup.json")
        try CodePulseBackupCodec.encode(
            state: AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly)),
            exportedAt: start
        ).write(to: backupURL, options: .atomic)
        let candidate = try store.inspectBackup(at: backupURL)
        let result = try store.restoreBackup(candidate)

        XCTAssertFalse(store.isInRecoveryMode)
        XCTAssertNil(store.lifecycleErrorMessage)
        XCTAssertEqual(try Data(contentsOf: result.recoveryBackupURL), corruptData)
        let restoredData = try Data(contentsOf: stateURL)
        XCTAssertNotEqual(restoredData, corruptData)
        XCTAssertEqual(JSONFilePersistence(fileURL: stateURL).load(), store.state)
    }

    func testUnreadableRestoreFailureRollsBackOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseRecoveryRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptData = Data("{ truncated CodePulse state".utf8)
        try corruptData.write(to: stateURL, options: .atomic)

        var shouldFail = true
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if shouldFail, case .afterLiveReplacement = point {
                    throw CriticalSaveFailure()
                }
            }
        )
        let store = SessionStore(
            persistence: persistence,
            clock: TestClock(start),
            automaticallyRefresh: false
        )
        let backupURL = root.appendingPathComponent("valid-backup.json")
        try CodePulseBackupCodec.encode(
            state: AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly)),
            exportedAt: start
        ).write(to: backupURL, options: .atomic)
        let candidate = try store.inspectBackup(at: backupURL)

        XCTAssertThrowsError(try store.restoreBackup(candidate))
        XCTAssertTrue(store.isInRecoveryMode)
        XCTAssertEqual(try Data(contentsOf: stateURL), corruptData)

        let recoveryDirectory = stateURL.deletingLastPathComponent().appendingPathComponent("Backups")
        let preservedCopies = try FileManager.default.contentsOfDirectory(
            at: recoveryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Unreadable State ") }
        XCTAssertEqual(preservedCopies.count, 1)
        XCTAssertEqual(try Data(contentsOf: preservedCopies[0]), corruptData)

        shouldFail = false
        let result = try store.restoreBackup(candidate)
        XCTAssertFalse(store.isInRecoveryMode)
        XCTAssertEqual(try Data(contentsOf: result.recoveryBackupURL), corruptData)
    }

    func testUnreadableRestorePreservesSubsecondAcceptanceBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseRecoveryFractional-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let corruptData = Data("{ truncated CodePulse state".utf8)
        try corruptData.write(to: stateURL, options: .atomic)

        let restoreDate = start.addingTimeInterval(0.375123)
        let persistence = JSONFilePersistence(fileURL: stateURL)
        let store = SessionStore(
            persistence: persistence,
            clock: TestClock(restoreDate),
            automaticallyRefresh: false
        )
        let backupURL = root.appendingPathComponent("valid-backup.json")
        try CodePulseBackupCodec.encode(
            state: AppState(),
            exportedAt: start
        ).write(to: backupURL, options: .atomic)

        let candidate = try store.inspectBackup(at: backupURL)
        let result = try store.restoreBackup(candidate)

        XCTAssertFalse(store.isInRecoveryMode)
        XCTAssertEqual(store.state.localInputAcceptanceDate, restoreDate)
        XCTAssertEqual(
            JSONFilePersistence(fileURL: stateURL).load().localInputAcceptanceDate,
            start
        )
        XCTAssertEqual(try Data(contentsOf: result.recoveryBackupURL), corruptData)
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

    func testAddProjectUsesTheSelectedWorkspace() {
        let firstID = UUID(uuidString: "B1000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "B2000000-0000-0000-0000-000000000002")!
        let persistence = InMemoryPersistence(AppState(
            workspaces: [
                WorkspaceRecord(id: firstID, name: "First", createdAt: start),
                WorkspaceRecord(id: secondID, name: "Second", createdAt: start)
            ],
            settings: CodePulseSettings(selectedWorkspaceID: secondID)
        ))
        let store = makeStore(clock: TestClock(start), persistence: persistence)

        let projectID = store.addProject(name: "Selected Workspace Project", folderURL: nil, at: start)

        let project = store.state.projects.first(where: { $0.id == projectID })
        XCTAssertNotNil(projectID)
        XCTAssertEqual(project?.workspaceID, secondID)
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

    private static func sameFailurePoint(_ lhs: StateRestoreFailurePoint, _ rhs: StateRestoreFailurePoint) -> Bool {
        switch (lhs, rhs) {
        case (.recoveryWrite, .recoveryWrite),
             (.recoveryVerification, .recoveryVerification),
             (.candidateEncoding, .candidateEncoding),
             (.candidateWrite, .candidateWrite),
             (.candidateVerification, .candidateVerification),
             (.liveReplacement, .liveReplacement),
             (.liveDurability, .liveDurability),
             (.afterLiveReplacement, .afterLiveReplacement),
             (.liveVerification, .liveVerification),
             (.rollbackWrite, .rollbackWrite),
             (.rollbackVerification, .rollbackVerification):
            return true
        default:
            return false
        }
    }

    private func makeStore(
        clock: TestClock,
        persistence: StatePersisting = InMemoryPersistence(),
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
