import Foundation

struct GitCommandResult {
    let terminationStatus: Int32
    let stdout: Data
    let stderr: Data

    var succeeded: Bool { terminationStatus == 0 }
}

protocol GitCommandRunning {
    func run(arguments: [String], in directory: URL) -> GitCommandResult?
}

private final class GitDataBox {
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

final class ProcessGitCommandRunner: GitCommandRunning {
    let executableURL: URL
    let timeout: TimeInterval

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: TimeInterval = 2
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
    }

    func run(arguments: [String], in directory: URL) -> GitCommandResult? {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directory.standardizedFileURL
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

        let stdoutBox = GitDataBox()
        let stderrBox = GitDataBox()
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
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            return nil
        }

        guard outputGroup.wait(timeout: .now() + 1) == .success else {
            stdoutPipe.fileHandleForReading.closeFile()
            stderrPipe.fileHandleForReading.closeFile()
            return nil
        }
        return GitCommandResult(
            terminationStatus: process.terminationStatus,
            stdout: stdoutBox.get(),
            stderr: stderrBox.get()
        )
    }
}

struct GitStartSnapshot: Equatable {
    let repositoryRoot: URL
    let branch: String?
    let headSHA: String?
    let isDetached: Bool?
    let preExistingWorkingTreePaths: Set<String>?
}

struct GitFinishSnapshot: Equatable {
    let branch: String?
    let headSHA: String?
    let isDetached: Bool?
    let commitCount: Int?
    let statistics: GitDiffStatistics?
}

protocol GitServicing: AnyObject, Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot?
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot?
}

struct GitNumstatEntry: Equatable {
    let path: String
    let insertions: Int?
    let deletions: Int?
}

struct GitDiffStatistics: Equatable {
    private(set) var paths: Set<String> = []
    private(set) var insertionTotal = 0
    private(set) var deletionTotal = 0
    private(set) var hasUnknownLineCounts = false

    var filesChanged: Int { paths.count }
    var insertions: Int? { hasUnknownLineCounts ? nil : insertionTotal }
    var deletions: Int? { hasUnknownLineCounts ? nil : deletionTotal }

    mutating func add(_ entry: GitNumstatEntry) {
        paths.insert(entry.path)
        guard let insertions = entry.insertions,
              let deletions = entry.deletions else {
            hasUnknownLineCounts = true
            return
        }
        insertionTotal += insertions
        deletionTotal += deletions
    }

    mutating func merge(_ other: GitDiffStatistics) {
        paths.formUnion(other.paths)
        insertionTotal += other.insertionTotal
        deletionTotal += other.deletionTotal
        hasUnknownLineCounts = hasUnknownLineCounts || other.hasUnknownLineCounts
    }
}

enum GitDiffStatsParser {
    static func entries(from data: Data) -> [GitNumstatEntry] {
        let separator: UInt8 = data.contains(0) ? 0 : 10
        let records = data.split(separator: separator, omittingEmptySubsequences: true)
        var entries: [GitNumstatEntry] = []
        var index = 0

        while index < records.count {
            guard let values = parseValues(records[index]) else {
                index += 1
                continue
            }

            if let path = values.path, !path.isEmpty {
                entries.append(GitNumstatEntry(
                    path: path,
                    insertions: values.insertions,
                    deletions: values.deletions
                ))
                index += 1
                continue
            }

            // git diff --no-index -z emits an empty path field followed by
            // the two compared paths. The second path is the useful new file.
            if index + 2 < records.count {
                let oldPath = String(decoding: records[index + 1], as: UTF8.self)
                let newPath = String(decoding: records[index + 2], as: UTF8.self)
                if oldPath == "/dev/null", !newPath.isEmpty {
                    entries.append(GitNumstatEntry(
                        path: newPath,
                        insertions: values.insertions,
                        deletions: values.deletions
                    ))
                    index += 3
                    continue
                }
            }
            index += 1
        }
        return entries
    }

    static func parse(_ data: Data) -> GitDiffStatistics {
        var statistics = GitDiffStatistics()
        for entry in entries(from: data) {
            statistics.add(entry)
        }
        return statistics
    }

    private static func parseValues(_ record: Data.SubSequence) -> (insertions: Int?, deletions: Int?, path: String?)? {
        let fields = record.split(separator: 9, maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count == 3 else { return nil }

        let insertions = Int(String(decoding: fields[0], as: UTF8.self))
        let deletions = Int(String(decoding: fields[1], as: UTF8.self))
        let path = String(decoding: fields[2], as: UTF8.self)
        return (insertions, deletions, path.isEmpty ? nil : path)
    }
}

final class SystemGitService: GitServicing, @unchecked Sendable {
    private let runner: GitCommandRunning

    init(
        gitExecutableURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        timeout: TimeInterval = 2
    ) {
        self.runner = ProcessGitCommandRunner(executableURL: gitExecutableURL, timeout: timeout)
    }

    init(runner: GitCommandRunning) {
        self.runner = runner
    }

    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? {
        guard let repositoryRoot = resolveRepositoryRoot(at: folderURL) else { return nil }
        let reference = readReference(in: repositoryRoot)
        let preExistingPaths = readWorkingTreePaths(in: repositoryRoot)

        return GitStartSnapshot(
            repositoryRoot: repositoryRoot,
            branch: reference.branch,
            headSHA: reference.headSHA,
            isDetached: reference.isDetached,
            preExistingWorkingTreePaths: preExistingPaths
        )
    }

    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? {
        guard let repositoryRoot = resolveRepositoryRoot(at: startSnapshot.repositoryRoot) else {
            return nil
        }

        let reference = readReference(in: repositoryRoot)
        let commitCount = calculateCommitCount(
            from: startSnapshot.headSHA,
            to: reference.headSHA,
            in: repositoryRoot
        )
        let statistics = calculateStatistics(
            from: startSnapshot,
            to: reference.headSHA,
            in: repositoryRoot
        )

        return GitFinishSnapshot(
            branch: reference.branch,
            headSHA: reference.headSHA,
            isDetached: reference.isDetached,
            commitCount: commitCount,
            statistics: statistics
        )
    }

    private func resolveRepositoryRoot(at folderURL: URL) -> URL? {
        guard let result = runner.run(arguments: ["rev-parse", "--show-toplevel"], in: folderURL),
              result.succeeded,
              let path = outputString(result.stdout),
              !path.isEmpty else {
            return nil
        }

        return URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private func readReference(in repositoryRoot: URL) -> GitReference {
        let branchResult = runner.run(
            arguments: ["symbolic-ref", "--quiet", "--short", "HEAD"],
            in: repositoryRoot
        )
        let headResult = runner.run(arguments: ["rev-parse", "--verify", "HEAD"], in: repositoryRoot)

        let branch: String?
        let isDetached: Bool?
        if let branchResult, branchResult.succeeded, let branchName = outputString(branchResult.stdout), !branchName.isEmpty {
            branch = branchName
            isDetached = false
        } else if branchResult?.terminationStatus == 1 {
            branch = nil
            isDetached = true
        } else {
            branch = nil
            isDetached = nil
        }

        let headSHA = headResult.flatMap { result in
            result.succeeded ? outputString(result.stdout) : nil
        }
        return GitReference(branch: branch, headSHA: headSHA, isDetached: isDetached)
    }

    private func readWorkingTreePaths(in repositoryRoot: URL) -> Set<String>? {
        guard let result = runner.run(
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames"],
            in: repositoryRoot
        ), result.succeeded else {
            return nil
        }

        var paths = Set<String>()
        for record in result.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard record.count >= 4 else { continue }
            let path = String(decoding: record.dropFirst(3), as: UTF8.self)
            if !path.isEmpty {
                paths.insert(path)
            }
        }
        return paths
    }

    private func readUntrackedPaths(in repositoryRoot: URL) -> Set<String>? {
        guard let result = runner.run(
            arguments: ["ls-files", "--others", "--exclude-standard", "-z"],
            in: repositoryRoot
        ), result.succeeded else {
            return nil
        }

        return Set(result.stdout
            .split(separator: 0, omittingEmptySubsequences: true)
            .map { String(decoding: $0, as: UTF8.self) })
    }

    private func calculateCommitCount(from startSHA: String?, to endSHA: String?, in repositoryRoot: URL) -> Int? {
        guard let endSHA else {
            return startSHA == nil ? 0 : nil
        }
        guard let startSHA else {
            return countCommits(reachableFrom: endSHA, in: repositoryRoot)
        }
        guard startSHA != endSHA else { return 0 }

        guard let ancestry = runner.run(
            arguments: ["merge-base", "--is-ancestor", startSHA, endSHA],
            in: repositoryRoot
        ), ancestry.succeeded else {
            return nil
        }

        return countCommits(in: "\(startSHA)..\(endSHA)", repositoryRoot: repositoryRoot)
    }

    private func countCommits(reachableFrom sha: String, in repositoryRoot: URL) -> Int? {
        countCommits(in: sha, repositoryRoot: repositoryRoot)
    }

    private func countCommits(in revisionRange: String, repositoryRoot: URL) -> Int? {
        guard let result = runner.run(arguments: ["rev-list", "--count", revisionRange], in: repositoryRoot),
              result.succeeded,
              let count = outputString(result.stdout) else {
            return nil
        }
        return Int(count)
    }

    private func calculateStatistics(
        from startSnapshot: GitStartSnapshot,
        to endSHA: String?,
        in repositoryRoot: URL
    ) -> GitDiffStatistics? {
        var statistics = GitDiffStatistics()
        var capturedAnyStatistics = false

        if let endSHA {
            if let startSHA = startSnapshot.headSHA {
                if let result = runner.run(
                    arguments: ["diff", "--numstat", "--no-renames", "-z", startSHA, endSHA],
                    in: repositoryRoot
                ), result.succeeded {
                    statistics.merge(GitDiffStatsParser.parse(result.stdout))
                    capturedAnyStatistics = true
                }
            } else if let emptyTreeSHA = emptyTreeSHA(in: repositoryRoot),
                      let result = runner.run(
                          arguments: ["diff", "--numstat", "--no-renames", "-z", emptyTreeSHA, endSHA],
                          in: repositoryRoot
                      ), result.succeeded {
                statistics.merge(GitDiffStatsParser.parse(result.stdout))
                capturedAnyStatistics = true
            }
        }

        if let baseline = startSnapshot.preExistingWorkingTreePaths {
            if let endSHA,
               let result = runner.run(
                   arguments: ["diff", "--numstat", "--no-renames", "-z", endSHA],
                   in: repositoryRoot
               ), result.succeeded {
                for entry in GitDiffStatsParser.entries(from: result.stdout) where !baseline.contains(entry.path) {
                    statistics.add(entry)
                }
                capturedAnyStatistics = true
            }

            if let untrackedPaths = readUntrackedPaths(in: repositoryRoot) {
                for path in untrackedPaths where !baseline.contains(path) {
                    guard let result = runner.run(
                        arguments: ["diff", "--no-index", "--numstat", "-z", "--", "/dev/null", path],
                        in: repositoryRoot
                    ) else { continue }

                    statistics.merge(GitDiffStatsParser.parse(result.stdout))
                    capturedAnyStatistics = true
                }
            }
        }

        return capturedAnyStatistics ? statistics : nil
    }

    private func emptyTreeSHA(in repositoryRoot: URL) -> String? {
        guard let result = runner.run(arguments: ["hash-object", "-t", "tree", "/dev/null"], in: repositoryRoot),
              result.succeeded else {
            return nil
        }
        return outputString(result.stdout)
    }

    private func outputString(_ data: Data) -> String? {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct GitReference {
    let branch: String?
    let headSHA: String?
    let isDetached: Bool?
}
