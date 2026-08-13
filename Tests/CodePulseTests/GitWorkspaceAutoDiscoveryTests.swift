import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

private struct FixedGitWorkspaceResolver: GitWorkspaceResolving {
    let identities: [String: GitWorkspaceIdentity]
    func resolve(workingDirectory: String) -> GitWorkspaceIdentity? { identities[workingDirectory] }
}

@MainActor
final class GitWorkspaceAutoDiscoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testAutoCreationIsIdempotentRetainsUserNameAndHonorsGlobalOptOut() {
        let identity = self.identity(repository: "owner/repo", common: "/repos/demo/.git", root: "/repos/demo")
        let coordinator = DeveloperToolLifecycleCoordinator(workspaceResolver: FixedGitWorkspaceResolver(identities: ["/repos/demo": identity]))
        var state = AppState()

        XCTAssertTrue(coordinator.apply(event(path: "/repos/demo", session: "one"), sessionFingerprint: "one", parentSessionFingerprint: nil, to: &state))
        XCTAssertEqual(state.activityGraph.workspaces.count, 1)
        state.activityGraph.workspaces[0].name = "My renamed workspace"
        XCTAssertTrue(coordinator.apply(event(path: "/repos/demo", session: "two"), sessionFingerprint: "two", parentSessionFingerprint: nil, to: &state))
        XCTAssertEqual(state.activityGraph.workspaces.count, 1)
        XCTAssertEqual(state.activityGraph.workspaces[0].name, "My renamed workspace")

        var optedOut = AppState(settings: CodePulseSettings(automaticGitWorkspaceDiscoveryEnabled: false))
        XCTAssertFalse(coordinator.apply(event(path: "/repos/demo", session: "three"), sessionFingerprint: "three", parentSessionFingerprint: nil, to: &optedOut))
        XCTAssertTrue(optedOut.activityGraph.workspaces.isEmpty)
    }

    private func identity(repository: String?, common: String, root: String) -> GitWorkspaceIdentity {
        GitWorkspaceIdentity(repository: repository, commonDirectory: common, worktreeRoot: root, isLinkedWorktree: false, branch: "main")
    }

    private func event(path: String, session: String) -> DeveloperEventV2 {
        DeveloperEventV2(integration: .codex, eventKind: .sessionStarted, observedAt: now, idempotencyKey: "workspace-discovery-\(session)-0123456789", externalSessionKey: session, workingDirectory: path, parserVersion: "test", integrationVersion: "test")
    }
}
