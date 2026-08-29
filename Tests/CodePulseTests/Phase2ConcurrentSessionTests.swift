import Foundation
import XCTest
@testable import CodePulse

private final class Phase2TestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class Phase2TestPersistence: StatePersisting {
    var state: AppState
    var failCriticalSaves = false

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }

    func saveCritical(_ state: AppState) throws {
        guard !failCriticalSaves else { throw Phase2CriticalSaveFailure() }
        self.state = state
    }
}

private struct Phase2CriticalSaveFailure: Error {}

private final class Phase2ControlledGitService: GitServicing, @unchecked Sendable {
    struct Plan {
        let snapshot: GitStartSnapshot?
        let entered: XCTestExpectation
        let release: DispatchSemaphore
    }

    struct FinishPlan {
        let snapshot: GitFinishSnapshot?
        let entered: XCTestExpectation
        let release: DispatchSemaphore
    }

    private let lock = NSLock()
    private var startPlans: [String: Plan]
    private var finishPlans: [String: FinishPlan]

    init(startPlans: [String: Plan] = [:], finishPlans: [String: FinishPlan] = [:]) {
        self.startPlans = startPlans
        self.finishPlans = finishPlans
    }

    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? {
        let plan: Plan?
        lock.lock()
        plan = startPlans[normalizedPath(folderURL)]
        lock.unlock()
        guard let plan else { return nil }
        plan.entered.fulfill()
        _ = plan.release.wait(timeout: .distantFuture)
        return plan.snapshot
    }

    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? {
        let plan: FinishPlan?
        lock.lock()
        plan = finishPlans[normalizedPath(startSnapshot.repositoryRoot)]
        lock.unlock()
        guard let plan else { return nil }
        plan.entered.fulfill()
        _ = plan.release.wait(timeout: .distantFuture)
        return plan.snapshot
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

@MainActor
final class Phase2ConcurrentSessionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    func testIDReturningManualCreationUsesDistinctUUIDsAndEnforcesSixteenSessionBound() {
        let persistence = Phase2TestPersistence()
        let store = makeStore(persistence: persistence)

        let ids = (0..<ConcurrentSessionLimits.maximumActiveSessions).compactMap { index in
            store.createManualSession(projectID: nil, goal: "Session \(index)")
        }

        XCTAssertEqual(ids.count, ConcurrentSessionLimits.maximumActiveSessions)
        XCTAssertEqual(Set(ids).count, ids.count)
        let beforeRejectedStart = store.state
        XCTAssertNil(store.createManualSession(projectID: nil, goal: "Rejected"))
        XCTAssertEqual(store.state, beforeRejectedStart)
        XCTAssertEqual(persistence.state, beforeRejectedStart)
    }

    func testIDTargetedLifecycleAndNoIDAmbiguityPreserveUnrelatedSession() throws {
        let store = makeStore()
        let idA = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "A"))
        let idB = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B"))

        XCTAssertFalse(store.pause())
        XCTAssertTrue(store.pause(sessionID: idA))
        XCTAssertEqual(store.state.activeSession(id: idA)?.phase, .paused)
        XCTAssertEqual(store.state.activeSession(id: idB)?.phase, .running)

        XCTAssertTrue(store.resume())
        XCTAssertEqual(store.state.activeSession(id: idA)?.phase, .running)
        XCTAssertEqual(store.state.activeSession(id: idB)?.phase, .running)

        XCTAssertFalse(store.finish())
        XCTAssertTrue(store.finish(sessionID: idA))
        XCTAssertEqual(store.state.activeSession(id: idA)?.phase, .finishing)
        XCTAssertEqual(store.state.activeSession(id: idB)?.phase, .running)
        XCTAssertTrue(store.updateFinishingOutcome(sessionID: idA, outcome: "Done"))
        XCTAssertEqual(store.state.activeSession(id: idA)?.outcome, "Done")
        XCTAssertNil(store.state.activeSession(id: idB)?.outcome)

        XCTAssertTrue(store.saveFinishedSession(sessionID: idA, outcome: nil))
        XCTAssertNil(store.state.activeSession(id: idA))
        XCTAssertEqual(store.state.completedSessions.first?.id, idA)
        XCTAssertEqual(store.state.completedSessions.first?.outcome, "Done")
        XCTAssertEqual(store.state.activeSession(id: idB)?.phase, .running)
    }

    func testCriticalFailureForTargetedMutationPublishesNeitherTargetNorUnrelatedState() throws {
        let persistence = Phase2TestPersistence()
        let store = makeStore(persistence: persistence)
        let idA = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "A"))
        let idB = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B"))
        let before = store.state

        persistence.failCriticalSaves = true
        XCTAssertFalse(store.pause(sessionID: idA))
        XCTAssertEqual(store.state, before)
        XCTAssertEqual(persistence.state, before)
        XCTAssertEqual(store.state.activeSession(id: idA)?.phase, .running)
        XCTAssertEqual(store.state.activeSession(id: idB)?.phase, .running)
    }

    func testDifferentSessionGitStartsRunConcurrentlyAndCompleteIndependently() async throws {
        let rootA = try makeTemporaryDirectory(named: "a")
        let rootB = try makeTemporaryDirectory(named: "b")
        defer {
            try? FileManager.default.removeItem(at: rootA)
            try? FileManager.default.removeItem(at: rootB)
        }
        let enteredA = expectation(description: "Git start capture A enters")
        let enteredB = expectation(description: "Git start capture B enters")
        let releaseA = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        let snapshotA = GitStartSnapshot(
            repositoryRoot: rootA,
            branch: "main",
            headSHA: "a-start",
            isDetached: false,
            preExistingWorkingTreePaths: [],
            observationStartedAt: start.addingTimeInterval(5)
        )
        let snapshotB = GitStartSnapshot(
            repositoryRoot: rootB,
            branch: "main",
            headSHA: "b-start",
            isDetached: false,
            preExistingWorkingTreePaths: [],
            observationStartedAt: start.addingTimeInterval(6)
        )
        let gitService = Phase2ControlledGitService(startPlans: [
            rootA.standardizedFileURL.resolvingSymlinksInPath().path: .init(snapshot: snapshotA, entered: enteredA, release: releaseA),
            rootB.standardizedFileURL.resolvingSymlinksInPath().path: .init(snapshot: snapshotB, entered: enteredB, release: releaseB)
        ])
        let store = makeStore(gitService: gitService)
        let projectA = try XCTUnwrap(store.addProject(name: "A", folderURL: rootA))
        let projectB = try XCTUnwrap(store.addProject(name: "B", folderURL: rootB))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rootA.path))
        XCTAssertEqual(store.state.projects.first(where: { $0.id == projectA })?.folderPath, rootA.path)
        let idA = try XCTUnwrap(store.createManualSession(projectID: projectA, goal: "A"))
        let idB = try XCTUnwrap(store.createManualSession(projectID: projectB, goal: "B"))

        XCTAssertEqual(store.gitCaptureStatus(for: idA), .scheduled)
        XCTAssertEqual(store.gitCaptureStatus(for: idB), .scheduled)
        await fulfillment(of: [enteredA, enteredB], timeout: 2)
        XCTAssertTrue(store.isGitCaptureInProgress(for: idA))
        XCTAssertTrue(store.isGitCaptureInProgress(for: idB))

        releaseA.signal()
        try await waitFor { store.state.activeSession(id: idA)?.gitContext != nil }
        XCTAssertNil(store.state.activeSession(id: idB)?.gitContext)
        XCTAssertTrue(store.isGitCaptureInProgress(for: idB))

        releaseB.signal()
        try await waitFor {
            store.state.activeSession(id: idA)?.gitContext != nil &&
                store.state.activeSession(id: idB)?.gitContext != nil
        }
        XCTAssertEqual(store.state.activeSession(id: idA)?.gitContext?.observationStartedAt, start.addingTimeInterval(5))
        XCTAssertEqual(store.state.activeSession(id: idB)?.gitContext?.observationStartedAt, start.addingTimeInterval(6))
    }

    func testObservationAttributionSuppressesOnlySameRootOverlapsAndPreservesMetadata() {
        let repository = "/tmp/codepulse-phase2"
        let github = GitHubSessionContext(
            repositoryNameWithOwner: "owner/repo",
            repositoryURL: "https://github.com/owner/repo",
            repositoryIsPrivate: false
        )
        let first = completed(
            id: UUID(),
            root: repository,
            start: 10,
            end: 20,
            commitCount: 2,
            filesChanged: 3,
            insertions: 4,
            deletions: 1,
            githubContext: github
        )
        let second = completed(
            id: UUID(),
            root: repository,
            start: 21,
            end: 30,
            commitCount: 1,
            filesChanged: 2,
            insertions: 3,
            deletions: 0
        )
        var nonOverlapping = AppState(completedSessions: [first, second])
        nonOverlapping.reconcileGitObservationAttribution()

        XCTAssertEqual(nonOverlapping.completedSessions[0].gitContext?.commitCount, 2)
        XCTAssertEqual(nonOverlapping.completedSessions[1].gitContext?.filesChanged, 2)
        XCTAssertEqual(nonOverlapping.completedSessions[0].gitContext?.deltaAttribution, .attributable)

        let overlappingSecond = completed(
            id: second.id,
            root: repository,
            start: 19,
            end: 30,
            commitCount: 1,
            filesChanged: 2,
            insertions: 3,
            deletions: 0
        )
        var overlapping = AppState(completedSessions: [first, overlappingSecond])
        overlapping.reconcileGitObservationAttribution()

        for session in overlapping.completedSessions {
            XCTAssertNil(session.gitContext?.commitCount)
            XCTAssertNil(session.gitContext?.filesChanged)
            XCTAssertNil(session.gitContext?.insertions)
            XCTAssertNil(session.gitContext?.deletions)
            XCTAssertEqual(session.gitContext?.deltaAttribution, .ambiguous)
        }
        XCTAssertEqual(overlapping.completedSessions[0].gitContext?.repositoryRoot, repository)
        XCTAssertEqual(overlapping.completedSessions[0].gitContext?.branchAtStart, "main")
        XCTAssertEqual(overlapping.completedSessions[0].githubContext, github)
    }

    func testDelayedFinalAndMissingBoundaryRemainConservativeAndDistinctRootsRemainIndependent() {
        let delayed = completed(
            id: UUID(),
            root: "/tmp/shared-worktree",
            start: 0,
            end: 120,
            commitCount: 2,
            filesChanged: 2,
            insertions: 2,
            deletions: 0
        )
        let activeWithDelayedStart = completed(
            id: UUID(),
            root: "/tmp/shared-worktree",
            start: 60,
            end: nil,
            commitCount: nil,
            filesChanged: nil,
            insertions: nil,
            deletions: nil
        )
        var delayedState = AppState(completedSessions: [delayed, activeWithDelayedStart])
        delayedState.reconcileGitObservationAttribution()
        XCTAssertNil(delayedState.completedSessions[0].gitContext?.commitCount)
        XCTAssertEqual(delayedState.completedSessions[0].gitContext?.deltaAttribution, .ambiguous)

        let missingStart = completed(
            id: UUID(),
            root: "/tmp/shared-worktree",
            start: nil,
            end: 40,
            commitCount: 4,
            filesChanged: 4,
            insertions: 4,
            deletions: 0
        )
        var missingState = AppState(completedSessions: [delayed, missingStart])
        missingState.reconcileGitObservationAttribution()
        XCTAssertNil(missingState.completedSessions[0].gitContext?.commitCount)
        XCTAssertNil(missingState.completedSessions[1].gitContext?.filesChanged)

        let differentRoot = completed(
            id: UUID(),
            root: "/tmp/different-worktree",
            start: 10,
            end: 20,
            commitCount: 7,
            filesChanged: 8,
            insertions: 9,
            deletions: 1
        )
        var distinctState = AppState(completedSessions: [delayed, differentRoot])
        distinctState.reconcileGitObservationAttribution()
        XCTAssertEqual(distinctState.completedSessions[0].gitContext?.commitCount, 2)
        XCTAssertEqual(distinctState.completedSessions[1].gitContext?.filesChanged, 8)
    }

    private func makeStore(
        persistence: Phase2TestPersistence = Phase2TestPersistence(),
        gitService: GitServicing = Phase2NoopGitService()
    ) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: Phase2TestClock(start),
            gitService: gitService,
            automaticallyRefresh: false
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulsePhase2-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func waitFor(
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !predicate() {
            if Date() >= deadline {
                throw NSError(domain: "Phase2ConcurrentSessionTests", code: 2)
            }
            await Task.yield()
        }
    }

    private func completed(
        id: UUID,
        root: String,
        start: TimeInterval?,
        end: TimeInterval?,
        commitCount: Int?,
        filesChanged: Int?,
        insertions: Int?,
        deletions: Int?,
        githubContext: GitHubSessionContext? = nil
    ) -> CompletedSession {
        let sessionStart = Date(timeIntervalSince1970: 1_800_000_000 + (start ?? 0))
        let sessionEnd = Date(timeIntervalSince1970: 1_800_000_000 + (end ?? 60))
        return CompletedSession(
            id: id,
            projectID: nil,
            projectName: "Phase 2",
            goal: nil,
            outcome: nil,
            startedAt: sessionStart,
            endedAt: sessionEnd,
            pauseIntervals: [],
            gitContext: GitSessionContext(
                repositoryRoot: root,
                branchAtStart: "main",
                startHeadSHA: "start",
                startWasDetached: false,
                branchAtEnd: "main",
                endHeadSHA: "end",
                endWasDetached: false,
                commitCount: commitCount,
                filesChanged: filesChanged,
                insertions: insertions,
                deletions: deletions,
                observationStartedAt: start.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) },
                observationEndedAt: end.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) }
            ),
            githubContext: githubContext
        )
    }
}

private final class Phase2NoopGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}
