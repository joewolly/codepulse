import Foundation
import Darwin

struct GitHubCommandResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data

    var succeeded: Bool { terminationStatus == 0 }
}

protocol GitHubCommandRunning: AnyObject, Sendable {
    var isAvailable: Bool { get }
    func run(arguments: [String], in directory: URL?) -> GitHubCommandResult?
}

private final class GitHubDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Data()

    func set(_ data: Data) {
        lock.lock()
        value = data
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

enum GitHubExecutableResolver {
    static let commonLocations = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "/usr/bin/gh"
    ]

    static func resolve(fileManager: FileManager = .default) -> URL? {
        let pathCandidates = commonLocations +
            (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map { "\($0)/gh" }

        var seen = Set<String>()
        for path in pathCandidates where seen.insert(path).inserted {
            guard fileManager.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

final class ProcessGitHubCommandRunner: GitHubCommandRunning, @unchecked Sendable {
    let executableURL: URL?
    let timeout: TimeInterval

    init(
        executableURL: URL? = GitHubExecutableResolver.resolve(),
        timeout: TimeInterval = 4
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    var isAvailable: Bool {
        guard let executableURL else { return false }
        return FileManager.default.isExecutableFile(atPath: executableURL.path)
    }

    func run(arguments: [String], in directory: URL?) -> GitHubCommandResult? {
        guard let executableURL, isAvailable else { return nil }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory?.standardizedFileURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let terminationSemaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            terminationSemaphore.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let stdoutBox = GitHubDataBox()
        let stderrBox = GitHubDataBox()
        let outputGroup = DispatchGroup()

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        outputGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            outputGroup.leave()
        }

        guard terminationSemaphore.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = terminationSemaphore.wait(timeout: .now() + 0.25)
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = terminationSemaphore.wait(timeout: .now() + 0.25)
            }
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            _ = outputGroup.wait(timeout: .now() + 0.25)
            return nil
        }

        guard outputGroup.wait(timeout: .now() + 1) == .success else {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            return nil
        }

        return GitHubCommandResult(
            terminationStatus: process.terminationStatus,
            stdout: stdoutBox.get(),
            stderr: stderrBox.get()
        )
    }
}

enum GitHubAvailability: Equatable, Sendable {
    case available
    case cliMissing
    case unauthenticated
    case unavailable
}

protocol GitHubContextServicing: AnyObject, Sendable {
    func captureContext(
        repositoryRoot: URL,
        repository: GitHubRepositoryIdentity,
        branch: String?
    ) async -> GitHubSessionContext?
}

final class SystemGitHubContextService: GitHubContextServicing, @unchecked Sendable {
    private let runner: GitHubCommandRunning

    init(runner: GitHubCommandRunning = ProcessGitHubCommandRunner()) {
        self.runner = runner
    }

    var availability: GitHubAvailability {
        runner.isAvailable ? .available : .cliMissing
    }

    func captureContext(
        repositoryRoot: URL,
        repository: GitHubRepositoryIdentity,
        branch: String?
    ) async -> GitHubSessionContext? {
        var repositoryIsPrivate: Bool?
        var pullRequest: GitHubPullRequestSnapshot?
        if runner.isAvailable {
            // GitHub Context is read-only enrichment. The CLI receives only the
            // normalized repository and, when available, the local branch;
            // CodePulse notes, timing, paths, and file contents never leave
            // the app's local state.
            if let result = runner.run(
                arguments: [
                    "repo", "view", repository.nameWithOwner,
                    "--json", "nameWithOwner,url,isPrivate"
                ],
                in: repositoryRoot
            ),
            result.succeeded,
            let response = try? JSONDecoder().decode(GHRepositoryResponse.self, from: result.stdout),
            let responseIdentity = GitHubRepositoryIdentity(nameWithOwner: response.nameWithOwner),
            responseIdentity == repository,
            GitHubURLValidator.trustedHTTPSURL(response.url) != nil {
                repositoryIsPrivate = response.isPrivate
            }

            if let branch, !branch.isEmpty {
                if let result = runner.run(
                    arguments: [
                        "pr", "view", branch,
                        "--repo", repository.nameWithOwner,
                        "--json", "number,title,state,url,isDraft,baseRefName,headRefName"
                    ],
                    in: repositoryRoot
                ),
                result.succeeded,
                let response = try? JSONDecoder().decode(GHPullRequestResponse.self, from: result.stdout),
                let url = GitHubURLValidator.trustedHTTPSURL(response.url) {
                    pullRequest = GitHubPullRequestSnapshot(
                        number: response.number,
                        title: response.title,
                        state: GitHubPullRequestState(gitHubValue: response.state),
                        isDraft: response.isDraft,
                        url: url.absoluteString,
                        baseBranch: response.baseRefName,
                        headBranch: response.headRefName
                    )
                }
            }
        }

        return GitHubSessionContext(
            repositoryNameWithOwner: repository.nameWithOwner,
            repositoryURL: repository.webURL.absoluteString,
            repositoryIsPrivate: repositoryIsPrivate,
            pullRequest: pullRequest
        )
    }
}

private struct GHRepositoryResponse: Decodable {
    let nameWithOwner: String
    let url: URL
    let isPrivate: Bool
}

private struct GHPullRequestResponse: Decodable {
    let number: Int
    let title: String
    let state: String
    let url: URL
    let isDraft: Bool
    let baseRefName: String?
    let headRefName: String?
}
