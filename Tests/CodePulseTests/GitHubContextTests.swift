import Foundation
import XCTest
@testable import CodePulse

private final class FakeGitHubCommandRunner: GitHubCommandRunning, @unchecked Sendable {
    let isAvailable: Bool
    private let responses: [String: GitHubCommandResult]
    private(set) var calls: [[String]] = []

    init(isAvailable: Bool = true, responses: [String: GitHubCommandResult] = [:]) {
        self.isAvailable = isAvailable
        self.responses = responses
    }

    func run(arguments: [String], in directory: URL?) -> GitHubCommandResult? {
        calls.append(arguments)
        return responses[Self.key(arguments)]
    }

    static func key(_ arguments: [String]) -> String {
        arguments.joined(separator: "\u{1F}")
    }
}

private final class SnapshotGitService: GitServicing, @unchecked Sendable {
    let startSnapshot: GitStartSnapshot
    let finishSnapshot: GitFinishSnapshot?

    init(startSnapshot: GitStartSnapshot, finishSnapshot: GitFinishSnapshot? = nil) {
        self.startSnapshot = startSnapshot
        self.finishSnapshot = finishSnapshot
    }

    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? {
        startSnapshot
    }

    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? {
        finishSnapshot
    }
}

private final class DeferredGitHubService: GitHubContextServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<GitHubSessionContext?, Never>] = []
    private var requestIndex = 0
    private let requestExpectations: [XCTestExpectation]

    init(requestExpectation: XCTestExpectation? = nil) {
        self.requestExpectations = requestExpectation.map { [$0] } ?? []
    }

    init(requestExpectations: [XCTestExpectation]) {
        self.requestExpectations = requestExpectations
    }

    func captureContext(
        repositoryRoot: URL,
        repository: GitHubRepositoryIdentity,
        branch: String?
    ) async -> GitHubSessionContext? {
        nextRequestExpectation()?.fulfill()
        return await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    private func nextRequestExpectation() -> XCTestExpectation? {
        lock.lock()
        defer { lock.unlock() }
        let expectation = requestIndex < requestExpectations.count ? requestExpectations[requestIndex] : nil
        requestIndex += 1
        return expectation
    }

    func resolveNext(with context: GitHubSessionContext?) {
        lock.lock()
        let continuation = continuations.isEmpty ? nil : continuations.removeFirst()
        lock.unlock()
        continuation?.resume(returning: context)
    }
}

@MainActor
final class GitHubContextTests: XCTestCase {
    private let startDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testGitHubRemoteParserSupportsHTTPSAndSSHForms() {
        let cases: [(String, String)] = [
            ("https://github.com/owner/repo.git", "owner/repo"),
            ("https://github.com/owner/repo", "owner/repo"),
            ("git@github.com:owner/repo.git", "owner/repo"),
            ("ssh://git@github.com/owner/repo.git", "owner/repo")
        ]

        for (remote, expectedName) in cases {
            let identity = GitHubRemoteParser.parse(remote)
            XCTAssertEqual(identity?.nameWithOwner, expectedName, remote)
            XCTAssertEqual(identity?.webURL.absoluteString, "https://github.com/owner/repo", remote)
        }
    }

    func testGitHubRemoteParserRejectsNonGitHubAndMalformedRemotes() {
        let rejected = [
            "https://gitlab.com/owner/repo.git",
            "git@gitlab.com:owner/repo.git",
            "invalid text",
            "github.com",
            "https://github.com/",
            "https://github.com/owner/repo/extra",
            "https://token:secret@github.com/owner/repo.git",
            "ssh://other@github.com/owner/repo.git"
        ]

        for remote in rejected {
            XCTAssertNil(GitHubRemoteParser.parse(remote), remote)
        }
    }

    func testGitHubRepositoryIdentityNormalizesOwnerAndName() {
        XCTAssertEqual(
            GitHubRepositoryIdentity(nameWithOwner: "joewolly/codepulse")?.webURL.absoluteString,
            "https://github.com/joewolly/codepulse"
        )
        XCTAssertNil(GitHubRepositoryIdentity(nameWithOwner: "owner"))
        XCTAssertNil(GitHubRepositoryIdentity(nameWithOwner: "owner/repo/extra"))
    }

    func testSystemGitHubServiceParsesRepositoryAndOpenDraftPullRequest() async throws {
        let repository = try XCTUnwrap(GitHubRepositoryIdentity(nameWithOwner: "owner/repo"))
        let repoArguments = ["repo", "view", "owner/repo", "--json", "nameWithOwner,url,isPrivate"]
        let prArguments = [
            "pr", "view", "feature/github-context", "--repo", "owner/repo",
            "--json", "number,title,state,url,isDraft,baseRefName,headRefName"
        ]
        let runner = FakeGitHubCommandRunner(responses: [
            FakeGitHubCommandRunner.key(repoArguments): commandResult(
                "{\"nameWithOwner\":\"owner/repo\",\"url\":\"https://github.com/owner/repo\",\"isPrivate\":true}"
            ),
            FakeGitHubCommandRunner.key(prArguments): commandResult(
                "{\"number\":9,\"title\":\"Add GitHub session context\",\"state\":\"OPEN\",\"url\":\"https://github.com/owner/repo/pull/9\",\"isDraft\":true,\"baseRefName\":\"main\",\"headRefName\":\"feature/github-context\"}"
            )
        ])
        let service = SystemGitHubContextService(runner: runner)

        let optionalContext = await service.captureContext(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository", isDirectory: true),
            repository: repository,
            branch: "feature/github-context"
        )
        let context = try XCTUnwrap(optionalContext)

        XCTAssertEqual(context.repositoryNameWithOwner, "owner/repo")
        XCTAssertEqual(context.repositoryIsPrivate, true)
        XCTAssertEqual(context.repositoryWebURL?.absoluteString, "https://github.com/owner/repo")
        XCTAssertEqual(context.pullRequest?.number, 9)
        XCTAssertEqual(context.pullRequest?.state, .open)
        XCTAssertTrue(context.pullRequest?.isDraft == true)
        XCTAssertEqual(context.pullRequest?.statusDisplay, "Draft · Open")
        XCTAssertEqual(context.pullRequest?.branchDisplay, "feature/github-context → main")
        XCTAssertEqual(runner.calls, [repoArguments, prArguments])
    }

    func testSystemGitHubServiceNormalizesClosedAndMergedPullRequestStates() async throws {
        let repository = try XCTUnwrap(GitHubRepositoryIdentity(nameWithOwner: "owner/repo"))
        for (rawState, expectedState) in [("CLOSED", GitHubPullRequestState.closed), ("MERGED", .merged)] {
            let repoArguments = ["repo", "view", "owner/repo", "--json", "nameWithOwner,url,isPrivate"]
            let prArguments = [
                "pr", "view", "feature", "--repo", "owner/repo",
                "--json", "number,title,state,url,isDraft,baseRefName,headRefName"
            ]
            let runner = FakeGitHubCommandRunner(responses: [
                FakeGitHubCommandRunner.key(repoArguments): commandResult(
                    "{\"nameWithOwner\":\"owner/repo\",\"url\":\"https://github.com/owner/repo\",\"isPrivate\":false}"
                ),
                FakeGitHubCommandRunner.key(prArguments): commandResult(
                    "{\"number\":3,\"title\":\"Old work\",\"state\":\"\(rawState)\",\"url\":\"https://github.com/owner/repo/pull/3\",\"isDraft\":false,\"baseRefName\":\"main\",\"headRefName\":\"feature\"}"
                )
            ])

            let optionalContext = await SystemGitHubContextService(runner: runner).captureContext(
                repositoryRoot: URL(fileURLWithPath: "/tmp/repository", isDirectory: true),
                repository: repository,
                branch: "feature"
            )
            let context = try XCTUnwrap(optionalContext)

            XCTAssertEqual(context.pullRequest?.state, expectedState)
        }
    }

    func testSystemGitHubServiceKeepsRepositoryWhenPullRequestIsUnavailable() async throws {
        let repository = try XCTUnwrap(GitHubRepositoryIdentity(nameWithOwner: "owner/repo"))
        let repoArguments = ["repo", "view", "owner/repo", "--json", "nameWithOwner,url,isPrivate"]
        let prArguments = [
            "pr", "view", "main", "--repo", "owner/repo",
            "--json", "number,title,state,url,isDraft,baseRefName,headRefName"
        ]
        let runner = FakeGitHubCommandRunner(responses: [
            FakeGitHubCommandRunner.key(repoArguments): commandResult(
                "{\"nameWithOwner\":\"owner/repo\",\"url\":\"https://github.com/owner/repo\",\"isPrivate\":false}"
            ),
            FakeGitHubCommandRunner.key(prArguments): commandResult("no pull request", status: 1)
        ])

        let optionalContext = await SystemGitHubContextService(runner: runner).captureContext(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository", isDirectory: true),
            repository: repository,
            branch: "main"
        )
        let context = try XCTUnwrap(optionalContext)

        XCTAssertEqual(context.repositoryNameWithOwner, "owner/repo")
        XCTAssertNil(context.pullRequest)
        XCTAssertEqual(runner.calls, [repoArguments, prArguments])
    }

    func testSystemGitHubServiceSkipsPullRequestForDetachedHead() async throws {
        let repository = try XCTUnwrap(GitHubRepositoryIdentity(nameWithOwner: "owner/repo"))
        let repoArguments = ["repo", "view", "owner/repo", "--json", "nameWithOwner,url,isPrivate"]
        let runner = FakeGitHubCommandRunner(responses: [
            FakeGitHubCommandRunner.key(repoArguments): commandResult(
                "{\"nameWithOwner\":\"owner/repo\",\"url\":\"https://github.com/owner/repo\",\"isPrivate\":false}"
            )
        ])

        let optionalContext = await SystemGitHubContextService(runner: runner).captureContext(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository", isDirectory: true),
            repository: repository,
            branch: nil
        )
        let context = try XCTUnwrap(optionalContext)

        XCTAssertEqual(context.repositoryNameWithOwner, "owner/repo")
        XCTAssertEqual(runner.calls, [repoArguments])
    }

    func testSystemGitHubServiceHandlesMalformedJSONAndMissingCLIWithoutFailure() async throws {
        let repository = try XCTUnwrap(GitHubRepositoryIdentity(nameWithOwner: "owner/repo"))
        let malformedRunner = FakeGitHubCommandRunner(responses: [
            FakeGitHubCommandRunner.key(["repo", "view", "owner/repo", "--json", "nameWithOwner,url,isPrivate"]): commandResult("not json"),
            FakeGitHubCommandRunner.key(["pr", "view", "main", "--repo", "owner/repo", "--json", "number,title,state,url,isDraft,baseRefName,headRefName"]): commandResult("{", status: 1)
        ])
        let optionalMalformedContext = await SystemGitHubContextService(runner: malformedRunner).captureContext(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository", isDirectory: true),
            repository: repository,
            branch: "main"
        )
        let malformedContext = try XCTUnwrap(optionalMalformedContext)
        XCTAssertEqual(malformedContext.repositoryNameWithOwner, "owner/repo")
        XCTAssertNil(malformedContext.repositoryIsPrivate)
        XCTAssertNil(malformedContext.pullRequest)

        let missingRunner = FakeGitHubCommandRunner(isAvailable: false)
        let service = SystemGitHubContextService(runner: missingRunner)
        let optionalMissingContext = await service.captureContext(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository", isDirectory: true),
            repository: repository,
            branch: "main"
        )
        let missingContext = try XCTUnwrap(optionalMissingContext)
        XCTAssertEqual(service.availability, .cliMissing)
        XCTAssertEqual(missingContext.repositoryNameWithOwner, "owner/repo")
        XCTAssertTrue(missingRunner.calls.isEmpty)
    }

    func testSystemGitHubServiceTreatsEmptyOutputAsUnavailableEnrichment() async throws {
        let repository = try XCTUnwrap(GitHubRepositoryIdentity(nameWithOwner: "owner/repo"))
        let repoArguments = ["repo", "view", "owner/repo", "--json", "nameWithOwner,url,isPrivate"]
        let prArguments = [
            "pr", "view", "main", "--repo", "owner/repo",
            "--json", "number,title,state,url,isDraft,baseRefName,headRefName"
        ]
        let runner = FakeGitHubCommandRunner(responses: [
            FakeGitHubCommandRunner.key(repoArguments): commandResult(""),
            FakeGitHubCommandRunner.key(prArguments): commandResult("")
        ])

        let optionalContext = await SystemGitHubContextService(runner: runner).captureContext(
            repositoryRoot: URL(fileURLWithPath: "/tmp/repository", isDirectory: true),
            repository: repository,
            branch: "main"
        )
        let context = try XCTUnwrap(optionalContext)

        XCTAssertEqual(context.repositoryNameWithOwner, "owner/repo")
        XCTAssertNil(context.repositoryIsPrivate)
        XCTAssertNil(context.pullRequest)
    }

    func testProcessGitHubCommandRunnerTimesOutWithoutWaitingIndefinitely() {
        let runner = ProcessGitHubCommandRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            timeout: 0.05
        )

        let start = Date()
        let result = runner.run(arguments: ["2"], in: nil)

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testGitHubSessionContextRoundTripsRepositoryOnlyAndPullRequestSnapshots() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseGitHubTests-\(UUID().uuidString)")
            .appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let pullRequest = GitHubPullRequestSnapshot(
            number: 9,
            title: "Add GitHub session context",
            state: .open,
            isDraft: false,
            url: "https://github.com/owner/repo/pull/9",
            baseBranch: "main",
            headBranch: "feature/github-context"
        )
        let repositoryOnly = GitHubSessionContext(
            repositoryNameWithOwner: "owner/repo",
            repositoryURL: "https://github.com/owner/repo",
            repositoryIsPrivate: nil
        )
        let withPullRequest = GitHubSessionContext(
            repositoryNameWithOwner: "owner/repo",
            repositoryURL: "https://github.com/owner/repo",
            repositoryIsPrivate: true,
            pullRequest: pullRequest
        )
        var state = AppState()
        state.activeSession = ActiveSession(
            projectName: "Active",
            startedAt: startDate,
            githubContext: repositoryOnly
        )
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Completed",
            goal: nil,
            outcome: nil,
            startedAt: startDate,
            endedAt: startDate.addingTimeInterval(60),
            pauseIntervals: [],
            githubContext: withPullRequest
        )]

        let persistence = JSONFilePersistence(fileURL: fileURL)
        persistence.save(state)

        XCTAssertEqual(persistence.load(), state)
        XCTAssertEqual(persistence.load().activeSession?.githubContext, repositoryOnly)
        XCTAssertEqual(persistence.load().completedSessions.first?.githubContext, withPullRequest)
    }

    func testOldSessionJSONWithoutGitHubContextStillDecodes() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let oldSession = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "Legacy",
            goal: nil,
            outcome: nil,
            startedAt: startDate,
            endedAt: startDate.addingTimeInterval(60),
            pauseIntervals: []
        )

        let data = try encoder.encode(oldSession)
        let decoded = try JSONDecoder.withISO8601.decode(CompletedSession.self, from: data)

        XCTAssertNil(decoded.githubContext)
    }

    func testSessionStartRemainsRunningWhileGitHubCaptureIsDelayed() async throws {
        let repository = try makeTemporaryDirectory()
        let gitService = makeGitService(repository: repository)
        let requestExpectation = expectation(description: "GitHub capture requested")
        let githubService = DeferredGitHubService(requestExpectation: requestExpectation)
        let store = makeStore(repository: repository, gitService: gitService, githubService: githubService)
        let projectID = try XCTUnwrap(store.addProject(name: "Demo", folderURL: repository))

        XCTAssertTrue(store.startSession(projectID: projectID, goal: "Start immediately"))
        XCTAssertEqual(store.phase, .running)
        await fulfillment(of: [requestExpectation], timeout: 1)
    }

    func testGitHubResultAppliesToTheSameActiveSession() async throws {
        let repository = try makeTemporaryDirectory()
        let requestExpectation = expectation(description: "GitHub capture requested")
        let githubService = DeferredGitHubService(requestExpectation: requestExpectation)
        let store = makeStore(
            repository: repository,
            gitService: makeGitService(repository: repository),
            githubService: githubService
        )
        let projectID = try XCTUnwrap(store.addProject(name: "Demo", folderURL: repository))
        XCTAssertTrue(store.startSession(projectID: projectID, goal: nil))
        await fulfillment(of: [requestExpectation], timeout: 1)

        let context = makeContext()
        githubService.resolveNext(with: context)
        await waitFor { store.activeSession?.githubContext == context }

        XCTAssertEqual(store.activeSession?.githubContext, context)
    }

    func testLateGitHubResultCannotCorruptNextSession() async throws {
        let repository = try makeTemporaryDirectory()
        let firstRequest = expectation(description: "First GitHub capture requested")
        let secondRequest = expectation(description: "Second GitHub capture requested")
        let githubService = DeferredGitHubService(requestExpectations: [firstRequest, secondRequest])
        let store = makeStore(
            repository: repository,
            gitService: makeGitService(repository: repository),
            githubService: githubService
        )
        let projectID = try XCTUnwrap(store.addProject(name: "Demo", folderURL: repository))

        XCTAssertTrue(store.startSession(projectID: projectID, goal: "Session A"))
        await fulfillment(of: [firstRequest], timeout: 1)
        let firstID = try XCTUnwrap(store.activeSession?.id)
        XCTAssertTrue(store.finish())
        await waitFor { !store.gitCaptureInProgress }
        XCTAssertTrue(store.discardSession())

        XCTAssertTrue(store.startSession(projectID: projectID, goal: "Session B"))
        await waitFor { store.activeSession?.id != firstID }
        await fulfillment(of: [secondRequest], timeout: 1)
        githubService.resolveNext(with: makeContext())
        await Task.yield()

        XCTAssertEqual(store.activeSession?.goal, "Session B")
        XCTAssertNil(store.activeSession?.githubContext)
    }

    func testGitHubFailureLeavesLocalGitContextAndDoesNotBlockSaving() async throws {
        let repository = try makeTemporaryDirectory()
        let requestExpectation = expectation(description: "GitHub capture requested")
        let githubService = DeferredGitHubService(requestExpectation: requestExpectation)
        let persistence = TestGitHubPersistence()
        let store = makeStore(
            repository: repository,
            persistence: persistence,
            gitService: makeGitService(repository: repository),
            githubService: githubService
        )
        let projectID = try XCTUnwrap(store.addProject(name: "Demo", folderURL: repository))

        XCTAssertTrue(store.startSession(projectID: projectID, goal: nil))
        await fulfillment(of: [requestExpectation], timeout: 1)
        await waitFor { store.activeSession?.gitContext != nil && !store.gitCaptureInProgress }

        XCTAssertTrue(store.finish())
        await waitFor { !store.gitCaptureInProgress }
        XCTAssertTrue(store.saveFinishedSession(outcome: "Saved"))
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertNotNil(persistence.state.completedSessions.first?.gitContext)
        XCTAssertNil(persistence.state.completedSessions.first?.githubContext)

        githubService.resolveNext(with: nil)
        await Task.yield()
        XCTAssertNotNil(persistence.state.completedSessions.first?.gitContext)
    }

    private func makeStore(
        repository: URL,
        persistence: TestGitHubPersistence = TestGitHubPersistence(),
        gitService: GitServicing,
        githubService: GitHubContextServicing
    ) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: TestGitHubClock(startDate),
            calendar: Calendar(identifier: .gregorian),
            gitService: gitService,
            githubContextService: githubService,
            automaticallyRefresh: false
        )
    }

    private func makeGitService(repository: URL) -> GitServicing {
        SnapshotGitService(startSnapshot: GitStartSnapshot(
            repositoryRoot: repository,
            branch: "feature/github-context",
            headSHA: String(repeating: "a", count: 40),
            isDetached: false,
            preExistingWorkingTreePaths: [],
            remotes: [GitRemote(name: "origin", url: "https://github.com/owner/repo.git")]
        ))
    }

    private func makeContext() -> GitHubSessionContext {
        GitHubSessionContext(
            repositoryNameWithOwner: "owner/repo",
            repositoryURL: "https://github.com/owner/repo",
            repositoryIsPrivate: false,
            pullRequest: GitHubPullRequestSnapshot(
                number: 9,
                title: "Add GitHub session context",
                state: .open,
                isDraft: false,
                url: "https://github.com/owner/repo/pull/9",
                baseBranch: "main",
                headBranch: "feature/github-context"
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseGitHubTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func waitFor(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func commandResult(_ output: String, status: Int32 = 0) -> GitHubCommandResult {
        GitHubCommandResult(
            terminationStatus: status,
            stdout: Data(output.utf8),
            stderr: Data()
        )
    }
}

private final class TestGitHubClock: SessionClock {
    let now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class TestGitHubPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private extension JSONDecoder {
    static var withISO8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
