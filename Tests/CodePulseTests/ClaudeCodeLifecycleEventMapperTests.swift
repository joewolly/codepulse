import CodePulseIntegration
import Foundation
import XCTest

final class ClaudeCodeLifecycleEventMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMapsSubagentLifecycleWithoutPersistingContentFields() throws {
        let payload = Data(#"""
        {
          "session_id": "parent-session",
          "agent_id": "child-agent",
          "cwd": "/tmp/codepulse/Sources",
          "hook_event_name": "SubagentStart",
          "model": "claude-opus",
          "permission_mode": "acceptEdits",
          "effort": { "level": "high" },
          "prompt": "do not retain",
          "transcript_path": "/private/transcript.jsonl",
          "tool_input": { "command": "do not retain" }
        }
        """#.utf8)

        let event = try XCTUnwrap(ClaudeCodeLifecycleEventMapper.map(payload, observedAt: now))
        XCTAssertEqual(event.integration, .claudeCode)
        XCTAssertEqual(event.eventKind, .sessionStarted)
        XCTAssertEqual(event.externalSessionKey, "child-agent")
        XCTAssertEqual(event.parentSessionKey, "parent-session")
        XCTAssertEqual(event.effort, "high")
        XCTAssertEqual(event.metadata?.transcriptAvailable, true)

        let text = try XCTUnwrap(String(data: DeveloperEventV2Codec.encode(event), encoding: .utf8))
        XCTAssertFalse(text.contains("do not retain"))
        XCTAssertFalse(text.contains("/private/transcript.jsonl"))
        XCTAssertFalse(text.contains("tool_input"))

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulse-claude-mapper-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = DeveloperEventV2Inbox(
            paths: DeveloperToolIntegrationPaths(applicationSupportDirectory: root),
            fingerprintSalt: Data(repeating: 1, count: 32)
        )
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(event), now: now), .accepted)
        let stored = try XCTUnwrap(inbox.pendingEventURLs().first)
        XCTAssertEqual(try inbox.readEvent(from: stored, now: now).metadata?.transcriptAvailable, true)
    }
}
