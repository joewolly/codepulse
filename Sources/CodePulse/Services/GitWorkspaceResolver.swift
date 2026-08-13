import CodePulseIntegration
import Foundation

protocol GitWorkspaceResolving {
    func resolve(workingDirectory: String) -> GitWorkspaceIdentity?
}

/// Resolves a single supplied directory with bounded `git rev-parse` calls.
/// It never scans parent directories itself or reads repository contents.
struct SystemGitWorkspaceResolver: GitWorkspaceResolving {
    private let runner: GitCommandRunning

    init(runner: GitCommandRunning = ProcessGitCommandRunner(timeout: 1)) {
        self.runner = runner
    }

    func resolve(workingDirectory: String) -> GitWorkspaceIdentity? {
        guard let directory = DeveloperToolProjectPathMatcher.canonicalPath(for: workingDirectory).map(URL.init(fileURLWithPath:)),
              let root = output(["rev-parse", "--show-toplevel"], in: directory),
              let rootPath = DeveloperToolProjectPathMatcher.canonicalPath(for: root),
              let common = output(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory),
              let commonPath = DeveloperToolProjectPathMatcher.canonicalPath(for: common),
              let gitDirectory = output(["rev-parse", "--path-format=absolute", "--git-dir"], in: directory),
              let gitPath = DeveloperToolProjectPathMatcher.canonicalPath(for: gitDirectory) else {
            return nil
        }

        let remote = output(["config", "--get", "remote.origin.url"], in: directory)
        let repository = remote.flatMap(GitHubRemoteParser.parse)?.nameWithOwner.lowercased()
        let branch = output(["symbolic-ref", "--quiet", "--short", "HEAD"], in: directory)
        return GitWorkspaceIdentity(
            repository: repository,
            commonDirectory: commonPath,
            worktreeRoot: rootPath,
            isLinkedWorktree: commonPath != gitPath,
            branch: branch
        )
    }

    private func output(_ arguments: [String], in directory: URL) -> String? {
        guard let result = runner.run(arguments: arguments, in: directory), result.succeeded else { return nil }
        let value = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
