import Foundation
import XCTest
@testable import CodePulse

private final class GitTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class GitTestPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

@MainActor
final class GitServiceTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        try super.tearDownWithError()
    }

    func testNonGitDirectoryReturnsNoSnapshot() throws {
        let folder = try makeTemporaryDirectory()
        let service = SystemGitService()

        XCTAssertNil(service.captureStartSnapshot(at: folder))
    }

    func testRepositoryRootIsResolvedFromSubdirectory() throws {
        let repository = try makeRepository()
        let nestedFolder = repository.appendingPathComponent("Sources/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedFolder, withIntermediateDirectories: true)

        let snapshot = SystemGitService().captureStartSnapshot(at: nestedFolder)

        XCTAssertEqual(snapshot?.repositoryRoot.path, repository.standardizedFileURL.path)
    }

    func testNormalBranchAndHeadAreCaptured() throws {
        let repository = try makeRepository()

        let snapshot = SystemGitService().captureStartSnapshot(at: repository)

        XCTAssertEqual(snapshot?.branch, "main")
        XCTAssertEqual(snapshot?.isDetached, false)
        XCTAssertNotNil(snapshot?.headSHA)
    }

    func testDetachedHeadIsRepresentedWithoutManufacturingBranchName() throws {
        let repository = try makeRepository()
        try runGit(["checkout", "--detach", "HEAD"], at: repository)

        let snapshot = SystemGitService().captureStartSnapshot(at: repository)

        XCTAssertNil(snapshot?.branch)
        XCTAssertEqual(snapshot?.isDetached, true)
        XCTAssertNotNil(snapshot?.headSHA)

        let context = GitSessionContext(
            repositoryRoot: repository.path,
            startWasDetached: snapshot?.isDetached
        )
        XCTAssertEqual(context.branchDisplay, "Detached HEAD")
    }

    func testEmptyRepositoryIsSafeAndCanCaptureNewUntrackedWork() throws {
        let repository = try makeEmptyRepository()
        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))
        try write("first.swift", contents: "let value = 1\n", in: repository)

        let finish = try XCTUnwrap(service.captureFinishSnapshot(for: start))

        XCTAssertNil(start.headSHA)
        XCTAssertEqual(finish.commitCount, 0)
        XCTAssertEqual(finish.statistics?.filesChanged, 1)
        XCTAssertEqual(finish.statistics?.insertions, 1)
        XCTAssertEqual(finish.statistics?.deletions, 0)
    }

    func testZeroCommitsAndZeroChangesAreSafe() throws {
        let repository = try makeRepository()
        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))

        let finish = try XCTUnwrap(service.captureFinishSnapshot(for: start))

        XCTAssertEqual(finish.commitCount, 0)
        XCTAssertEqual(finish.statistics?.filesChanged, 0)
        XCTAssertEqual(finish.statistics?.insertions, 0)
        XCTAssertEqual(finish.statistics?.deletions, 0)
    }

    func testCommittedChangesProduceDeterministicCommitAndDiffStats() throws {
        let repository = try makeRepository()
        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))

        try write("Notes.md", contents: "one\ntwo\n", in: repository)
        try runGit(["add", "--", "Notes.md"], at: repository)
        try runGit(["commit", "-m", "Add notes"], at: repository)

        try write("README.md", contents: "one\nupdated\n", in: repository)
        try runGit(["add", "--", "README.md"], at: repository)
        try runGit(["commit", "-m", "Update README"], at: repository)

        let finish = try XCTUnwrap(service.captureFinishSnapshot(for: start))

        XCTAssertEqual(finish.commitCount, 2)
        XCTAssertEqual(finish.statistics?.filesChanged, 2)
        XCTAssertEqual(finish.statistics?.insertions, 3)
        XCTAssertEqual(finish.statistics?.deletions, 0)
    }

    func testUncommittedChangesAreCapturedWhenWorkingTreeWasCleanAtStart() throws {
        let repository = try makeRepository()
        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))

        try write("work file.swift", contents: "let first = 1\nlet second = 2\n", in: repository)

        let finish = try XCTUnwrap(service.captureFinishSnapshot(for: start))

        XCTAssertEqual(finish.commitCount, 0)
        XCTAssertEqual(finish.statistics?.filesChanged, 1)
        XCTAssertEqual(finish.statistics?.insertions, 2)
        XCTAssertEqual(finish.statistics?.deletions, 0)
    }

    func testPreExistingDirtyPathIsNotCountedAsNewUncommittedWork() throws {
        let repository = try makeRepository()
        try write("README.md", contents: "one\npre-existing\n", in: repository)

        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))
        try write("README.md", contents: "one\npre-existing\nsession-change\n", in: repository)

        let finish = try XCTUnwrap(service.captureFinishSnapshot(for: start))

        XCTAssertEqual(finish.statistics?.filesChanged, 0)
    }

    func testValidBranchSwitchRetainsAncestrySafeCommitAndDiffStats() throws {
        let repository = try makeRepository()
        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))
        try runGit(["checkout", "-b", "feature"], at: repository)
        try write("feature.swift", contents: "let feature = true\n", in: repository)
        try runGit(["add", "--", "feature.swift"], at: repository)
        try runGit(["commit", "-m", "Feature work"], at: repository)
        let finish = try XCTUnwrap(service.captureFinishSnapshot(for: start))

        var context = GitSessionContext(
            repositoryRoot: start.repositoryRoot.path,
            branchAtStart: start.branch,
            startHeadSHA: start.headSHA,
            startWasDetached: start.isDetached
        )
        context.branchAtEnd = finish.branch
        context.endHeadSHA = finish.headSHA
        context.endWasDetached = finish.isDetached

        XCTAssertEqual(context.branchDisplay, "main → feature")
        try runGit(
            ["merge-base", "--is-ancestor", try XCTUnwrap(start.headSHA), try XCTUnwrap(finish.headSHA)],
            at: repository
        )
        XCTAssertEqual(finish.commitCount, 1)
        XCTAssertEqual(finish.statistics?.filesChanged, 1)
        XCTAssertEqual(finish.statistics?.insertions, 1)
        XCTAssertEqual(finish.statistics?.deletions, 0)
    }

    func testDivergentBranchSwitchOmitsUntrustedCommittedStatistics() throws {
        let repository = try makeRepository()
        try runGit(["checkout", "-b", "feature-a"], at: repository)
        try write("feature-a.swift", contents: "let branch = \"a\"\n", in: repository)
        try runGit(["add", "--", "feature-a.swift"], at: repository)
        try runGit(["commit", "-m", "Feature A work"], at: repository)

        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))

        try runGit(["checkout", "main"], at: repository)
        try runGit(["checkout", "-b", "feature-b"], at: repository)
        try write("feature-b.swift", contents: "let branch = \"b\"\n", in: repository)
        try runGit(["add", "--", "feature-b.swift"], at: repository)
        try runGit(["commit", "-m", "Feature B work"], at: repository)
        try write("session.swift", contents: "let sessionWork = true\n", in: repository)

        let finish = try XCTUnwrap(service.captureFinishSnapshot(for: start))

        var context = GitSessionContext(
            repositoryRoot: start.repositoryRoot.path,
            branchAtStart: start.branch,
            startHeadSHA: start.headSHA,
            startWasDetached: start.isDetached
        )
        context.branchAtEnd = finish.branch
        context.endHeadSHA = finish.headSHA
        context.endWasDetached = finish.isDetached

        XCTAssertEqual(context.branchDisplay, "feature-a → feature-b")
        XCTAssertThrowsError(
            try runGit(
                ["merge-base", "--is-ancestor", try XCTUnwrap(start.headSHA), try XCTUnwrap(finish.headSHA)],
                at: repository
            )
        )
        XCTAssertNil(finish.commitCount)
        XCTAssertEqual(finish.statistics?.filesChanged, 1)
        XCTAssertEqual(finish.statistics?.insertions, 1)
        XCTAssertEqual(finish.statistics?.deletions, 0)
    }

    func testDiffStatParserHandlesSpacesAndBinaryFiles() {
        let data = Data("12\t3\tfile with spaces.swift\0-\t-\timage.png\0".utf8)

        let statistics = GitDiffStatsParser.parse(data)

        XCTAssertEqual(statistics.filesChanged, 2)
        XCTAssertNil(statistics.insertions)
        XCTAssertNil(statistics.deletions)
        XCTAssertEqual(
            GitDiffStatsParser.entries(from: data),
            [
                GitNumstatEntry(path: "file with spaces.swift", insertions: 12, deletions: 3),
                GitNumstatEntry(path: "image.png", insertions: nil, deletions: nil)
            ]
        )
    }

    func testGitFailureReturnsSafeOptionalContext() throws {
        let folder = try makeTemporaryDirectory()
        let missingGit = folder.appendingPathComponent("missing-git")

        let snapshot = SystemGitService(gitExecutableURL: missingGit).captureStartSnapshot(at: folder)

        XCTAssertNil(snapshot)
    }

    func testMissingRepositoryAtFinishReturnsNoFinalSnapshot() throws {
        let repository = try makeRepository()
        let service = SystemGitService()
        let start = try XCTUnwrap(service.captureStartSnapshot(at: repository))
        try FileManager.default.removeItem(at: repository.appendingPathComponent(".git"))

        XCTAssertNil(service.captureFinishSnapshot(for: start))
    }

    func testSessionStoreCapturesAndPersistsGitMetadata() async throws {
        let repository = try makeRepository()
        let clock = GitTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let persistence = GitTestPersistence()
        let service = SystemGitService()
        let store = SessionStore(
            persistence: persistence,
            clock: clock,
            gitService: service,
            automaticallyRefresh: false
        )
        let projectID = try XCTUnwrap(store.addProject(name: "Demo", folderURL: repository))

        XCTAssertTrue(store.startSession(projectID: projectID, goal: "Validate Git context"))
        try await waitForGitCapture(store)
        XCTAssertEqual(store.activeSession?.gitContext?.branchAtStart, "main")
        XCTAssertNotNil(store.activeSession?.gitContext?.startHeadSHA)

        try write("session.txt", contents: "session work\n", in: repository)
        try runGit(["add", "--", "session.txt"], at: repository)
        try runGit(["commit", "-m", "Session work"], at: repository)
        clock.now = clock.now.addingTimeInterval(120)

        XCTAssertTrue(store.finish())
        try await waitForGitCapture(store)
        XCTAssertEqual(store.activeSession?.gitContext?.commitCount, 1)
        XCTAssertEqual(store.activeSession?.gitContext?.filesChanged, 1)
        XCTAssertNotNil(store.activeSession?.gitContext?.endHeadSHA)
        XCTAssertEqual(store.activeSession?.gitContext?.branchAtEnd, "main")
        XCTAssertTrue(store.saveFinishedSession(outcome: "Saved"))

        let completed = try XCTUnwrap(persistence.state.completedSessions.first)
        XCTAssertEqual(completed.gitContext?.commitCount, 1)
        XCTAssertNil(completed.gitContext?.preExistingWorkingTreePaths)
        XCTAssertEqual(completed.gitContext?.branchDisplay, "main")
    }

    func testNonGitProjectSessionSavesWithoutGitMetadata() async throws {
        let folder = try makeTemporaryDirectory()
        let clock = GitTestClock(Date(timeIntervalSince1970: 1_700_000_000))
        let persistence = GitTestPersistence()
        let store = SessionStore(
            persistence: persistence,
            clock: clock,
            automaticallyRefresh: false
        )
        let projectID = try XCTUnwrap(store.addProject(name: "Plain Folder", folderURL: folder))

        XCTAssertTrue(store.startSession(projectID: projectID, goal: nil))
        try await waitForGitCapture(store)
        XCTAssertNil(store.activeSession?.gitContext)
        XCTAssertTrue(store.finish())
        try await waitForGitCapture(store)
        XCTAssertTrue(store.saveFinishedSession(outcome: nil))
        XCTAssertNil(persistence.state.completedSessions.first?.gitContext)
    }

    func testGitMetadataRoundTripsThroughJSONPersistence() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("state.json")
        let persistence = JSONFilePersistence(fileURL: fileURL)
        let context = GitSessionContext(
            repositoryRoot: "/tmp/demo",
            branchAtStart: "feature-a",
            startHeadSHA: String(repeating: "a", count: 40),
            startWasDetached: false,
            branchAtEnd: "feature-b",
            endHeadSHA: String(repeating: "b", count: 40),
            endWasDetached: false,
            commitCount: 3,
            filesChanged: 4,
            insertions: 81,
            deletions: 12
        )
        var state = AppState()
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Demo",
            goal: nil,
            outcome: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_120),
            pauseIntervals: [],
            gitContext: context
        )]

        persistence.save(state)

        XCTAssertEqual(persistence.load(), state)
    }

    func testOldSessionWithoutGitMetadataStillLoads() throws {
        let fileURL = try makeTemporaryDirectory().appendingPathComponent("state.json")
        let persistence = JSONFilePersistence(fileURL: fileURL)
        var state = AppState()
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Old Session",
            goal: "Before Git",
            outcome: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_060),
            pauseIntervals: []
        )]
        state.activeSession = ActiveSession(
            projectID: nil,
            projectName: "Old Active",
            goal: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any]
        )
        var sessions = try XCTUnwrap(object["completedSessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "gitContext")
        object["completedSessions"] = sessions
        var activeSession = try XCTUnwrap(object["activeSession"] as? [String: Any])
        activeSession.removeValue(forKey: "gitContext")
        object["activeSession"] = activeSession
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        let loaded = persistence.load()

        XCTAssertEqual(loaded.completedSessions.count, 1)
        XCTAssertEqual(loaded.completedSessions[0].projectName, "Old Session")
        XCTAssertNil(loaded.completedSessions[0].gitContext)
        XCTAssertEqual(loaded.activeSession?.projectName, "Old Active")
        XCTAssertNil(loaded.activeSession?.gitContext)
    }

    private func makeRepository() throws -> URL {
        let repository = try makeEmptyRepository()
        try write("README.md", contents: "one\n", in: repository)
        try runGit(["add", "--", "README.md"], at: repository)
        try runGit(["commit", "-m", "Initial commit"], at: repository)
        return repository
    }

    private func makeEmptyRepository() throws -> URL {
        let repository = try makeTemporaryDirectory()
        try runGit(["init", "-b", "main"], at: repository)
        try runGit(["config", "user.email", "codepulse-tests@example.com"], at: repository)
        try runGit(["config", "user.name", "CodePulse Tests"], at: repository)
        return repository
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseGitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func write(_ name: String, contents: String, in directory: URL) throws {
        try Data(contents.utf8).write(to: directory.appendingPathComponent(name))
    }

    private func waitForGitCapture(_ store: SessionStore) async throws {
        for _ in 0..<200 {
            if !store.gitCaptureInProgress { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for Git capture")
    }

    @discardableResult
    private func runGit(_ arguments: [String], at directory: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "GitServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output]
            )
        }
        return output
    }
}
