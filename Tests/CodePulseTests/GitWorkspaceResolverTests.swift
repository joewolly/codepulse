import Foundation
import XCTest
@testable import CodePulse

private struct GitWorkspaceFixtureRunner: GitCommandRunning {
    let responses: [[String]: GitCommandResult]

    func run(arguments: [String], in directory: URL) -> GitCommandResult? { responses[arguments] }

    static func success(_ text: String) -> GitCommandResult {
        GitCommandResult(terminationStatus: 0, stdout: Data("\(text)\n".utf8), stderr: Data())
    }

    static let failure = GitCommandResult(terminationStatus: 1, stdout: Data(), stderr: Data())
}

final class GitWorkspaceResolverTests: XCTestCase {
    func testResolverCapturesNestedRepositoryIdentityWithoutRemoteURL() {
        let resolver = SystemGitWorkspaceResolver(runner: GitWorkspaceFixtureRunner(responses: [
            ["rev-parse", "--show-toplevel"]: GitWorkspaceFixtureRunner.success("/repos/demo"),
            ["rev-parse", "--path-format=absolute", "--git-common-dir"]: GitWorkspaceFixtureRunner.success("/repos/demo/.git"),
            ["rev-parse", "--path-format=absolute", "--git-dir"]: GitWorkspaceFixtureRunner.success("/repos/demo/.git"),
            ["config", "--get", "remote.origin.url"]: GitWorkspaceFixtureRunner.success("https://github.com/Owner/Demo.git"),
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: GitWorkspaceFixtureRunner.success("feature/discovery")
        ]))

        let identity = resolver.resolve(workingDirectory: "/repos/demo/Sources/Feature")
        XCTAssertEqual(identity?.worktreeRoot, "/repos/demo")
        XCTAssertEqual(identity?.commonDirectory, "/repos/demo/.git")
        XCTAssertEqual(identity?.repository, "owner/demo")
        XCTAssertEqual(identity?.branch, "feature/discovery")
        XCTAssertFalse(identity?.isLinkedWorktree ?? true)
    }

    func testResolverRepresentsDetachedRemoteLessWorktreeAndRejectsNonGit() {
        let detached = SystemGitWorkspaceResolver(runner: GitWorkspaceFixtureRunner(responses: [
            ["rev-parse", "--show-toplevel"]: GitWorkspaceFixtureRunner.success("/worktrees/review"),
            ["rev-parse", "--path-format=absolute", "--git-common-dir"]: GitWorkspaceFixtureRunner.success("/repos/demo/.git"),
            ["rev-parse", "--path-format=absolute", "--git-dir"]: GitWorkspaceFixtureRunner.success("/repos/demo/.git/worktrees/review"),
            ["config", "--get", "remote.origin.url"]: GitWorkspaceFixtureRunner.failure,
            ["symbolic-ref", "--quiet", "--short", "HEAD"]: GitWorkspaceFixtureRunner.failure
        ]))
        let nonGit = SystemGitWorkspaceResolver(runner: GitWorkspaceFixtureRunner(responses: [
            ["rev-parse", "--show-toplevel"]: GitWorkspaceFixtureRunner.failure
        ]))

        let identity = detached.resolve(workingDirectory: "/worktrees/review/Sources")
        XCTAssertEqual(identity?.worktreeRoot, "/worktrees/review")
        XCTAssertNil(identity?.repository)
        XCTAssertNil(identity?.branch)
        XCTAssertTrue(identity?.isLinkedWorktree ?? false)
        XCTAssertNil(nonGit.resolve(workingDirectory: "/not-a-repository"))
    }
}
