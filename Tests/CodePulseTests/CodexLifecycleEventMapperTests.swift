import CodePulseIntegration
import Foundation
import XCTest

final class CodexLifecycleEventMapperTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNormalizesSupportedMetadataWithoutContent() throws {
        let payload = Data(#"""
        {
          "session_id": "codex-session",
          "cwd": "/tmp/codepulse/Sources",
          "model": "gpt-5.6",
          "hook_event_name": "UserPromptSubmit",
          "turn_id": "turn-1",
          "prompt": "do not persist this prompt",
          "command": "do not persist this command",
          "transcript_path": "/private/transcript.jsonl"
        }
        """#.utf8)

        let event = try XCTUnwrap(CodexLifecycleEventMapper.map(payload, observedAt: now))
        XCTAssertEqual(event.integration, .codex)
        XCTAssertEqual(event.eventKind, .activityObserved)
        XCTAssertEqual(event.workingDirectory, "/tmp/codepulse/Sources")
        XCTAssertEqual(event.metadata?.sourceKind, "UserPromptSubmit")

        let encoded = try DeveloperEventV2Codec.encode(event)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.contains("do not persist this prompt"))
        XCTAssertFalse(text.contains("do not persist this command"))
        XCTAssertFalse(text.contains("transcript"))
    }
}
