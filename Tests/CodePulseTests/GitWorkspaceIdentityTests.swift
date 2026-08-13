import Foundation
import XCTest
@testable import CodePulse

final class GitWorkspaceIdentityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testIdentityPrecedenceKeepsWorktreesSeparateAndEquivalentClonesTogether() {
        let first = identity(repository: "owner/repo", common: "/repos/main/.git", root: "/repos/main")
        let siblingWorktree = identity(repository: "owner/repo", common: "/repos/main/.git", root: "/repos/review")
        let equivalentClone = identity(repository: "owner/repo", common: "/clones/repo/.git", root: "/clones/repo")
        var graph = ActivityGraph(workspaces: [workspace(root: first)])

        XCTAssertEqual(GitWorkspaceIdentityMatcher.workspaceIndex(for: first, in: graph), 0)
        XCTAssertNil(GitWorkspaceIdentityMatcher.workspaceIndex(for: siblingWorktree, in: graph))
        graph.workspaces.append(workspace(root: siblingWorktree))
        XCTAssertEqual(GitWorkspaceIdentityMatcher.workspaceIndex(for: equivalentClone, in: graph), 0)
    }

    private func workspace(root: GitWorkspaceIdentity) -> Workspace {
        Workspace(
            name: URL(fileURLWithPath: root.worktreeRoot).lastPathComponent,
            roots: [WorkspaceRoot(path: root.worktreeRoot, kind: .gitWorktree, addedAt: now, gitIdentity: root)],
            createdAt: now,
            source: .automatic
        )
    }

    private func identity(repository: String?, common: String, root: String) -> GitWorkspaceIdentity {
        GitWorkspaceIdentity(repository: repository, commonDirectory: common, worktreeRoot: root, isLinkedWorktree: common != "\(root)/.git", branch: "main")
    }
}
