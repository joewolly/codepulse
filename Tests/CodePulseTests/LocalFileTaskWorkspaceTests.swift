import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

private struct FileTaskNoGitResolver: GitWorkspaceResolving {
    func resolve(workingDirectory: String) -> GitWorkspaceIdentity? { nil }
}

private struct FixedFileTaskResolver: LocalTaskResolving {
    let identities: [String: LocalTaskIdentity]
    func resolve(workingDirectory: String) -> LocalTaskIdentity? { identities[workingDirectory] }
}

final class LocalFileTaskWorkspaceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testCreatesAndReusesAFileWorkspaceWithRedactedDiagnostics() throws {
        let path = "/Volumes/Archive/meeting-notes.md"
        let identity = LocalTaskIdentity(canonicalPath: path, displayName: "meeting-notes.md", isFile: true, isTransient: false)
        let coordinator = coordinator(identities: [path: identity])
        var state = AppState()

        XCTAssertTrue(coordinator.apply(event(path: path, session: "first"), sessionFingerprint: "first", parentSessionFingerprint: nil, to: &state))
        XCTAssertTrue(coordinator.apply(event(path: path, session: "second"), sessionFingerprint: "second", parentSessionFingerprint: nil, to: &state))
        XCTAssertEqual(state.activityGraph.workspaces.count, 1)
        let workspace = try XCTUnwrap(state.activityGraph.workspaces.first)
        XCTAssertEqual(workspace.roots.map(\.kind), [.localFile])
        XCTAssertEqual(workspace.localTaskIdentity, identity)

        let diagnostics = try JSONEncoder().encode(ActivityGraphDiagnostics(graph: state.activityGraph))
        XCTAssertFalse(try XCTUnwrap(String(data: diagnostics, encoding: .utf8)).contains(path))
    }

    func testMovedFileCreatesASeparateWorkspace() {
        let original = "/Volumes/Archive/meeting-notes.md"
        let moved = "/Volumes/Archive/2026/meeting-notes.md"
        let coordinator = coordinator(identities: [
            original: LocalTaskIdentity(canonicalPath: original, displayName: "meeting-notes.md", isFile: true, isTransient: false),
            moved: LocalTaskIdentity(canonicalPath: moved, displayName: "meeting-notes.md", isFile: true, isTransient: false)
        ])
        var state = AppState()

        XCTAssertTrue(coordinator.apply(event(path: original, session: "original"), sessionFingerprint: "original", parentSessionFingerprint: nil, to: &state))
        XCTAssertTrue(coordinator.apply(event(path: moved, session: "moved"), sessionFingerprint: "moved", parentSessionFingerprint: nil, to: &state))
        XCTAssertEqual(state.activityGraph.workspaces.count, 2)
    }

    private func coordinator(identities: [String: LocalTaskIdentity]) -> DeveloperToolLifecycleCoordinator {
        DeveloperToolLifecycleCoordinator(
            workspaceResolver: FileTaskNoGitResolver(),
            localTaskResolver: FixedFileTaskResolver(identities: identities)
        )
    }

    private func event(path: String, session: String) -> DeveloperEventV2 {
        DeveloperEventV2(
            integration: .codex,
            eventKind: .sessionStarted,
            observedAt: start,
            idempotencyKey: "local-file-\(session)-0123456789",
            externalSessionKey: session,
            workingDirectory: path,
            parserVersion: "test",
            integrationVersion: "test"
        )
    }
}
