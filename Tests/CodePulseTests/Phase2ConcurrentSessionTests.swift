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

    func testLoneLegacyGitMetricsSurviveReconciliation() {
        let legacy = completed(id: UUID(), root: "/repo-a", start: nil, end: nil,
                               commitCount: 3, filesChanged: 5, insertions: 8, deletions: 2)
        var state = AppState(completedSessions: [legacy])

        state.reconcileGitObservationAttribution()

        XCTAssertEqual(state.completedSessions, [legacy])
    }

    func testLegacyGitMetricsRemainIndependentAcrossCanonicalRoots() {
        let legacy = completed(id: UUID(), root: "/repo-a", start: nil, end: nil,
                               commitCount: 3, filesChanged: 5, insertions: 8, deletions: 2)
        let observed = completed(id: UUID(), root: "/repo-b", start: 10, end: 20,
                                 commitCount: 1, filesChanged: 2, insertions: 3, deletions: 0)
        var state = AppState(completedSessions: [legacy, observed])

        state.reconcileGitObservationAttribution()

        XCTAssertEqual(state.completedSessions[0], legacy)
        XCTAssertEqual(state.completedSessions[1].id, observed.id)
        XCTAssertEqual(state.completedSessions[1].gitContext?.deltaAttribution, .attributable)
    }

    func testLegacySameRootMetricsAreSuppressedOnlyWhenComparisonIsUnsafe() {
        let legacy = completed(id: UUID(), root: "/repo-a", start: nil, end: nil,
                               commitCount: 3, filesChanged: 5, insertions: 8, deletions: 2)
        let observed = completed(id: UUID(), root: "/repo-a", start: 10, end: 20,
                                 commitCount: 1, filesChanged: 2, insertions: 3, deletions: 0)
        var state = AppState(completedSessions: [legacy, observed])

        state.reconcileGitObservationAttribution()

        XCTAssertEqual(state.completedSessions.map(\.id), [legacy.id, observed.id])
        for session in state.completedSessions {
            XCTAssertNil(session.gitContext?.commitCount)
            XCTAssertNil(session.gitContext?.filesChanged)
            XCTAssertEqual(session.gitContext?.deltaAttribution, .ambiguous)
        }
    }

    func testPartialWindowsUseKnownBoundariesToProveStrictSeparation() {
        assertAttribution(startA: 10, endA: 20, startB: 21, endB: nil, expected: .attributable)
        assertAttribution(startA: nil, endA: 20, startB: 21, endB: 30, expected: .attributable)
    }

    func testPartialWindowsRemainAmbiguousWithoutASeparationProof() {
        assertAttribution(startA: 10, endA: 20, startB: 20, endB: nil, expected: .ambiguous)
        assertAttribution(startA: 10, endA: nil, startB: 21, endB: 30, expected: .ambiguous)
        assertAttribution(startA: 10, endA: 30, startB: 20, endB: nil, expected: .ambiguous)
    }

    func testCompleteWindowsRetainClosedBoundarySafety() {
        assertAttribution(startA: 10, endA: 20, startB: 21, endB: 30, expected: .attributable)
        assertAttribution(startA: 10, endA: 20, startB: 20, endB: 30, expected: .ambiguous)
        assertAttribution(startA: 10, endA: 30, startB: 20, endB: 40, expected: .ambiguous)
    }

    func testPriorAmbiguityIsRecomputedFromCurrentEvidenceWithoutInventingMetrics() {
        let first = completed(id: UUID(), root: "/repo-a", start: 10, end: 20,
                              commitCount: nil, filesChanged: nil, insertions: nil, deletions: nil,
                              attribution: .ambiguous)
        let second = completed(id: UUID(), root: "/repo-a", start: 21, end: 30,
                               commitCount: 2, filesChanged: 3, insertions: 4, deletions: 1,
                               attribution: .ambiguous)
        var state = AppState(completedSessions: [first, second])

        state.reconcileGitObservationAttribution()

        XCTAssertEqual(state.completedSessions.map(\.id), [first.id, second.id])
        XCTAssertEqual(state.completedSessions.map { $0.gitContext?.deltaAttribution }, [.attributable, .attributable])
        XCTAssertNil(state.completedSessions[0].gitContext?.commitCount)
        XCTAssertEqual(state.completedSessions[1].gitContext?.commitCount, 2)
    }

    func testProvenAmbiguitySurvivesPeerRemovalAndCompletedHistoryDeletion() {
        let first = completed(id: UUID(), root: "/repo-a", start: 10, end: 30,
                              commitCount: 2, filesChanged: 3, insertions: 4, deletions: 1)
        let second = completed(id: UUID(), root: "/repo-a", start: 20, end: 40,
                               commitCount: 5, filesChanged: 6, insertions: 7, deletions: 2)
        let unrelated = completed(id: UUID(), root: "/repo-b", start: 10, end: 20,
                                  commitCount: 8, filesChanged: 9, insertions: 10, deletions: 3)
        var state = AppState(completedSessions: [first, second, unrelated])
        state.reconcileGitObservationAttribution()

        XCTAssertEqual(state.completedSessions[0].gitContext?.deltaAttribution, .ambiguous)
        XCTAssertEqual(state.completedSessions[1].gitContext?.deltaAttribution, .ambiguous)
        XCTAssertNil(state.completedSessions[1].gitContext?.commitCount)
        let unrelatedAfterConflict = state.completedSessions[2]

        state.completedSessions.removeAll { $0.id == first.id }
        state.reconcileGitObservationAttribution()

        let survivor = state.completedSessions.first { $0.id == second.id }
        XCTAssertEqual(survivor?.gitContext?.deltaAttribution, .ambiguous)
        XCTAssertNil(survivor?.gitContext?.commitCount)
        XCTAssertNil(survivor?.gitContext?.filesChanged)
        XCTAssertNil(survivor?.gitContext?.insertions)
        XCTAssertNil(survivor?.gitContext?.deletions)
        XCTAssertEqual(state.completedSessions.first { $0.id == unrelated.id }, unrelatedAfterConflict)
    }

    func testFinalCaptureCannotResurrectAmbiguousNumbersAfterPeerDiscard() async throws {
        let root = try makeTemporaryDirectory(named: "preserved-ambiguity")
        defer { try? FileManager.default.removeItem(at: root) }
        let project = ProjectRecord(name: "Shared", folderPath: root.path, createdAt: start)
        var sessionA = ActiveSession(id: UUID(), projectID: project.id, projectName: project.name,
                                     startedAt: start, phase: .finishing)
        sessionA.endedAt = start.addingTimeInterval(25)
        sessionA.gitContext = gitContext(root: root.path, start: 10, end: 25, attribution: .ambiguous)
        var sessionB = ActiveSession(id: UUID(), projectID: project.id, projectName: project.name,
                                     startedAt: start.addingTimeInterval(5))
        sessionB.gitContext = gitContext(root: root.path, start: 15, end: nil, attribution: .ambiguous)
        let unrelated = completed(id: UUID(), root: "/repo-b", start: 1, end: 2,
                                  commitCount: 9, filesChanged: 8, insertions: 7, deletions: 6,
                                  attribution: .attributable)
        let persistence = Phase2TestPersistence(AppState(
            projects: [project],
            completedSessions: [unrelated],
            activeSessions: [sessionA, sessionB]
        ))
        let finalEntered = expectation(description: "B final entered")
        let finalRelease = DispatchSemaphore(value: 0)
        var statistics = GitDiffStatistics()
        statistics.add(GitNumstatEntry(path: "Sources/A.swift", insertions: 11, deletions: 3))
        let finalSnapshot = GitFinishSnapshot(
            branch: "main",
            headSHA: "final-b",
            isDetached: false,
            commitCount: 4,
            statistics: statistics,
            observationEndedAt: start.addingTimeInterval(40)
        )
        let service = Phase2ControlledGitService(finishPlans: [root.path: .init(
            snapshot: finalSnapshot, entered: finalEntered, release: finalRelease
        )])
        let store = makeStore(persistence: persistence, gitService: service)

        XCTAssertTrue(store.discardSession(sessionID: sessionA.id))
        XCTAssertNil(store.state.activeSession(id: sessionA.id))
        XCTAssertEqual(store.state.activeSession(id: sessionB.id)?.gitContext?.deltaAttribution, .ambiguous)
        let unrelatedAfterDiscard = try XCTUnwrap(store.state.completedSessions.first { $0.id == unrelated.id })
        XCTAssertTrue(store.finish(sessionID: sessionB.id, at: start.addingTimeInterval(30)))
        await fulfillment(of: [finalEntered], timeout: 2)
        finalRelease.signal()
        try await waitFor { !store.isGitCaptureInProgress(for: sessionB.id) }

        let survivingContext = try XCTUnwrap(store.state.activeSession(id: sessionB.id)?.gitContext)
        XCTAssertEqual(survivingContext.deltaAttribution, .ambiguous)
        XCTAssertNil(survivingContext.commitCount)
        XCTAssertNil(survivingContext.filesChanged)
        XCTAssertNil(survivingContext.insertions)
        XCTAssertNil(survivingContext.deletions)
        XCTAssertEqual(store.state.completedSessions, [unrelatedAfterDiscard])
    }

    func testProvisionalAmbiguityClearsWhenSurvivingPeersProveSeparation() {
        let first = completed(id: UUID(), root: "/repo-a", start: 10, end: 20,
                              commitCount: nil, filesChanged: nil, insertions: nil, deletions: nil,
                              attribution: .ambiguous)
        let second = completed(id: UUID(), root: "/repo-a", start: 21, end: 30,
                               commitCount: 3, filesChanged: 4, insertions: 5, deletions: 1,
                               attribution: .ambiguous)
        var state = AppState(completedSessions: [first, second])

        state.reconcileGitObservationAttribution()

        XCTAssertEqual(state.completedSessions.map { $0.gitContext?.deltaAttribution }, [.attributable, .attributable])
        XCTAssertNil(state.completedSessions[0].gitContext?.commitCount)
        XCTAssertEqual(state.completedSessions[1].gitContext?.commitCount, 3)
        XCTAssertEqual(state.completedSessions[1].gitContext?.filesChanged, 4)
    }

    func testStaleGitCallbackAfterDiscardIsIgnored() async throws {
        let root = try makeTemporaryDirectory(named: "discard")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "start entered")
        let release = DispatchSemaphore(value: 0)
        let service = Phase2ControlledGitService(startPlans: [root.path: .init(
            snapshot: startSnapshot(root: root, sha: "discard"), entered: entered, release: release
        )])
        let store = makeStore(gitService: service)
        let project = try XCTUnwrap(store.addProject(name: "Discard", folderURL: root))
        let id = try XCTUnwrap(store.createManualSession(projectID: project, goal: "Discard"))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(store.finish(sessionID: id))
        XCTAssertTrue(store.discardSession(sessionID: id))

        release.signal()
        try await waitFor { !store.isGitCaptureInProgress(for: id) }

        XCTAssertNil(store.state.activeSession(id: id))
        XCTAssertFalse(store.state.completedSessions.contains(where: { $0.id == id }))
    }

    func testTwoFinishingSessionsRemainIndependentlySaveableAndDiscardable() throws {
        let store = makeStore()
        let idA = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "A"))
        let idB = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B"))
        XCTAssertTrue(store.finish(sessionID: idA))
        XCTAssertTrue(store.finish(sessionID: idB))
        let untouchedB = try XCTUnwrap(store.state.activeSession(id: idB))

        XCTAssertTrue(store.saveFinishedSession(sessionID: idA, outcome: "Saved A"))
        XCTAssertEqual(store.state.activeSession(id: idB), untouchedB)
        XCTAssertEqual(store.state.completedSessions.map(\.id), [idA])
        XCTAssertTrue(store.discardSession(sessionID: idB))
        XCTAssertEqual(store.state.completedSessions.map(\.id), [idA])
    }

    func testSessionBCanSaveWhileSessionAGitCaptureIsInProgress() async throws {
        let root = try makeTemporaryDirectory(named: "independent-save")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "A start entered")
        let release = DispatchSemaphore(value: 0)
        let service = Phase2ControlledGitService(startPlans: [root.path: .init(
            snapshot: startSnapshot(root: root, sha: "a"), entered: entered, release: release
        )])
        let store = makeStore(gitService: service)
        let project = try XCTUnwrap(store.addProject(name: "A", folderURL: root))
        let idA = try XCTUnwrap(store.createManualSession(projectID: project, goal: "A"))
        let idB = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B"))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(store.finish(sessionID: idB))

        XCTAssertTrue(store.saveFinishedSession(sessionID: idB, outcome: "Saved B"))
        XCTAssertTrue(store.isGitCaptureInProgress(for: idA))
        XCTAssertEqual(store.state.completedSessions.map(\.id), [idB])
        XCTAssertEqual(store.state.activeSession(id: idA)?.goal, "A")
        release.signal()
    }

    func testFinishingDuringStartCaptureQueuesFinalCapture() async throws {
        let root = try makeTemporaryDirectory(named: "serialized")
        defer { try? FileManager.default.removeItem(at: root) }
        let startEntered = expectation(description: "start entered")
        let finalEntered = expectation(description: "final entered")
        let startRelease = DispatchSemaphore(value: 0)
        let finalRelease = DispatchSemaphore(value: 0)
        let startSnapshot = startSnapshot(root: root, sha: "start")
        let finishSnapshot = GitFinishSnapshot(branch: "main", headSHA: "end",
                                               isDetached: false, commitCount: 1, statistics: nil,
                                               observationEndedAt: start.addingTimeInterval(20))
        let service = Phase2ControlledGitService(
            startPlans: [root.path: .init(snapshot: startSnapshot, entered: startEntered, release: startRelease)],
            finishPlans: [root.path: .init(snapshot: finishSnapshot, entered: finalEntered, release: finalRelease)]
        )
        let store = makeStore(gitService: service)
        let project = try XCTUnwrap(store.addProject(name: "Serialized", folderURL: root))
        let id = try XCTUnwrap(store.createManualSession(projectID: project, goal: nil))
        await fulfillment(of: [startEntered], timeout: 2)

        XCTAssertTrue(store.finish(sessionID: id))
        XCTAssertEqual(store.gitCaptureStatus(for: id), .running)
        startRelease.signal()
        await fulfillment(of: [finalEntered], timeout: 2)
        XCTAssertTrue(store.isGitCaptureInProgress(for: id))
        finalRelease.signal()
        try await waitFor { !store.isGitCaptureInProgress(for: id) }
        XCTAssertEqual(store.state.activeSession(id: id)?.gitContext?.endHeadSHA, "end")
    }

    func testGitFailureForSessionADoesNotMutateSessionB() async throws {
        let root = try makeTemporaryDirectory(named: "failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "failed start entered")
        let release = DispatchSemaphore(value: 0)
        let service = Phase2ControlledGitService(startPlans: [root.path: .init(
            snapshot: nil, entered: entered, release: release
        )])
        let store = makeStore(gitService: service)
        let project = try XCTUnwrap(store.addProject(name: "A", folderURL: root))
        let idA = try XCTUnwrap(store.createManualSession(projectID: project, goal: "A"))
        let idB = try XCTUnwrap(store.createManualSession(projectID: nil, goal: "B"))
        let beforeB = try XCTUnwrap(store.state.activeSession(id: idB))
        await fulfillment(of: [entered], timeout: 2)
        release.signal()
        try await waitFor { store.gitCaptureStatus(for: idA) == .failed }

        XCTAssertEqual(store.state.activeSession(id: idB), beforeB)
        XCTAssertNil(store.state.activeSession(id: idA)?.gitContext)
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

    private func startSnapshot(root: URL, sha: String) -> GitStartSnapshot {
        GitStartSnapshot(repositoryRoot: root, branch: "main", headSHA: sha, isDetached: false,
                         preExistingWorkingTreePaths: [], observationStartedAt: start.addingTimeInterval(10))
    }

    private func gitContext(
        root: String,
        start: TimeInterval?,
        end: TimeInterval?,
        attribution: GitDeltaAttribution?
    ) -> GitSessionContext {
        GitSessionContext(
            repositoryRoot: root,
            branchAtStart: "main",
            startHeadSHA: "start",
            startWasDetached: false,
            observationStartedAt: start.map { self.start.addingTimeInterval($0) },
            observationEndedAt: end.map { self.start.addingTimeInterval($0) },
            deltaAttribution: attribution
        )
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
        githubContext: GitHubSessionContext? = nil,
        attribution: GitDeltaAttribution? = nil
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
                observationEndedAt: end.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) },
                deltaAttribution: attribution
            ),
            githubContext: githubContext
        )
    }

    private func assertAttribution(
        startA: TimeInterval?,
        endA: TimeInterval?,
        startB: TimeInterval?,
        endB: TimeInterval?,
        expected: GitDeltaAttribution,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let first = completed(id: UUID(), root: "/repo-a", start: startA, end: endA,
                              commitCount: 1, filesChanged: 2, insertions: 3, deletions: 0)
        let second = completed(id: UUID(), root: "/repo-a", start: startB, end: endB,
                               commitCount: 4, filesChanged: 5, insertions: 6, deletions: 1)
        var state = AppState(completedSessions: [first, second])

        state.reconcileGitObservationAttribution()

        XCTAssertEqual(state.completedSessions.map(\.id), [first.id, second.id], file: file, line: line)
        if expected == .ambiguous {
            XCTAssertEqual(state.completedSessions.map { $0.gitContext?.deltaAttribution }, [expected, expected], file: file, line: line)
            XCTAssertTrue(state.completedSessions.allSatisfy { $0.gitContext?.commitCount == nil }, file: file, line: line)
        } else {
            let expectedAttributions: [GitDeltaAttribution?] = [
                startA != nil && endA != nil ? .attributable : nil,
                startB != nil && endB != nil ? .attributable : nil
            ]
            XCTAssertEqual(state.completedSessions.map { $0.gitContext?.deltaAttribution }, expectedAttributions, file: file, line: line)
            XCTAssertEqual(state.completedSessions[0].gitContext?.commitCount, 1, file: file, line: line)
            XCTAssertEqual(state.completedSessions[1].gitContext?.commitCount, 4, file: file, line: line)
        }
    }
}

private final class Phase2NoopGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}
