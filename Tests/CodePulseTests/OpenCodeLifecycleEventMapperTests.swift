import CodePulseIntegration
import Foundation
import XCTest

final class OpenCodeLifecycleEventMapperTests: XCTestCase {
    func testMapsContentFreePluginLifecycleRecord() throws {
        let payload = Data(#"""
        {
          "event_type": "activity.observed",
          "session_id": "ses-123",
          "cwd": "/tmp/codepulse",
          "model": "openai/gpt-5.6",
          "agent": "build",
          "sequence": 4,
          "plugin_version": "opencode-plugin-v1",
          "prompt": "must not be decoded"
        }
        """#.utf8)

        let event = try XCTUnwrap(OpenCodeLifecycleEventMapper.map(payload))
        XCTAssertEqual(event.integration, .openCode)
        XCTAssertEqual(event.eventKind, .activityObserved)
        XCTAssertEqual(event.externalSessionKey, "ses-123")
        XCTAssertEqual(event.model, "openai/gpt-5.6")
        XCTAssertEqual(event.metadata?.eventSequence, 4)
        XCTAssertEqual(event.metadata?.sourceKind, "activity.observed")
    }
}
