import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class OpenCodeUsageTrackingTests: XCTestCase {
    func testConsentDefaultsOffRoundTripsAndDisabledServiceNeverReadsPluginHandoffs() throws {
        XCTAssertFalse(try JSONDecoder().decode(CodePulseSettings.self, from: Data("{}".utf8)).openCodeUsageTrackingEnabled)
        let enabled = try JSONDecoder().decode(
            CodePulseSettings.self,
            from: JSONEncoder().encode(CodePulseSettings(openCodeUsageTrackingEnabled: true))
        )
        XCTAssertTrue(enabled.openCodeUsageTrackingEnabled)
        let receiver = TestReceiver([])
        let service = OpenCodeUsageTrackingService(receiver: receiver, catalogStore: nil, fingerprint: fingerprint)
        var state = AppState()

        XCTAssertFalse(service.process(state: &state, now: Date()))
        XCTAssertEqual(receiver.calls, 0)
        XCTAssertNil(state.openCodeUsageProcessing)
    }

    func testPluginMapperAcceptsOnlyAllowlistedUsageRecord() throws {
        let data = Data("""
        {"event_type":"usage.recorded","session_id":"session-a","cwd":"/example","message_id":"message-a","observed_at":"2026-08-13T00:00:02Z","model":"gpt-5","provider":"openai","service_mode":"build","tokens":{"input":100,"output":20,"cache_read":10,"cache_write":5,"reasoning":2},"cost_usd":0.5,"plugin_version":"opencode-usage-plugin-v1"}
        """.utf8)
        let event = try XCTUnwrap(OpenCodeUsageEventMapper.map(data))
        XCTAssertEqual(event.model, "gpt-5")
        XCTAssertEqual(event.provider, "openai")
        XCTAssertEqual(event.inputTokens, 100)
        XCTAssertEqual(event.cacheReadTokens, 10)
        XCTAssertEqual(event.providerReportedCost, Decimal(string: "0.5"))
        XCTAssertNil(OpenCodeUsageEventMapper.map(Data("{\"event_type\":\"usage.recorded\",\"session_id\":\"a\",\"cwd\":\"/example\",\"message_id\":\"b\",\"tokens\":{},\"plugin_version\":\"v1\"}".utf8)))
        XCTAssertNil(OpenCodeUsageEventMapper.map(Data("{\"event_type\":\"message.updated\",\"content\":\"never accepted\"}".utf8)))
    }

    func testServiceNormalizesPluginUsageCorrelatesRunAndPreservesReportedCost() throws {
        let event = usageEvent(model: "gpt-5", provider: "openai", input: 1_000_000, output: 500_000, cost: Decimal(string: "2.25"))
        let receiver = TestReceiver([event])
        let catalog = try PricingCatalogStore(cacheURL: temporaryDirectory().appendingPathComponent("catalog.json"))
        let run = makeRun()
        let service = OpenCodeUsageTrackingService(receiver: receiver, catalogStore: catalog, fingerprint: fingerprint)
        var state = state(run: run)

        XCTAssertTrue(service.process(state: &state, now: date("2026-08-13T00:03:00Z")))
        let sample = try XCTUnwrap(state.usageSamples.first)
        XCTAssertEqual(sample.integration, .opencode)
        XCTAssertEqual(sample.runID, run.id)
        XCTAssertEqual(sample.workspaceID, state.activityGraph.activities.first?.workspaceID)
        XCTAssertEqual(sample.model, "gpt-5")
        XCTAssertEqual(sample.provider, "openai")
        XCTAssertEqual(sample.providerReportedCost, Decimal(string: "2.25"))
        XCTAssertEqual(sample.calculatedCosts.first?.representation, .apiEquivalentEstimate)
        XCTAssertEqual(sample.calculatedCosts.first?.amount, Decimal(string: "6.25"))
        XCTAssertEqual(state.openCodeUsageProcessing?.status, .healthy)
        XCTAssertEqual(receiver.removed.count, 1)
    }

    func testUnknownProviderModelAndUnmatchedSessionRemainUnassignedAndUnpriced() {
        let event = usageEvent(session: "unmatched", model: "unknown", provider: "example", input: 8, output: 2)
        let receiver = TestReceiver([event])
        let service = OpenCodeUsageTrackingService(receiver: receiver, catalogStore: nil, fingerprint: fingerprint)
        var state = AppState(settings: CodePulseSettings(openCodeUsageTrackingEnabled: true))

        XCTAssertTrue(service.process(state: &state, now: Date()))
        XCTAssertNil(state.usageSamples.first?.runID)
        XCTAssertNil(state.usageSamples.first?.workspaceID)
        XCTAssertTrue(state.usageSamples.first?.calculatedCosts.isEmpty == true)
    }

    func testRepeatedMessageHandoffIsRemovedWithoutDoubleCountingUsage() {
        let event = usageEvent(input: 8, output: 2)
        let receiver = TestReceiver([event, event])
        let service = OpenCodeUsageTrackingService(receiver: receiver, catalogStore: nil, fingerprint: fingerprint)
        var state = AppState(settings: CodePulseSettings(openCodeUsageTrackingEnabled: true))

        XCTAssertTrue(service.process(state: &state, now: Date()))
        XCTAssertEqual(state.usageSamples.count, 1)
        XCTAssertEqual(receiver.removed.count, 2)
        XCTAssertEqual(state.openCodeUsageProcessing?.acceptedEventCount, 1)
    }

    func testUnsupportedPluginVersionIsIsolatedAsAdapterHealth() {
        var event = usageEvent(input: 1)
        event = OpenCodeUsageEvent(
            sessionID: event.sessionID,
            workingDirectory: event.workingDirectory,
            messageID: event.messageID,
            observedAt: event.observedAt,
            inputTokens: event.inputTokens,
            pluginVersion: "future-plugin-v2"
        )
        let receiver = TestReceiver([event])
        let service = OpenCodeUsageTrackingService(receiver: receiver, catalogStore: nil, fingerprint: fingerprint)
        var state = AppState(settings: CodePulseSettings(openCodeUsageTrackingEnabled: true))

        XCTAssertTrue(service.process(state: &state, now: Date()))
        XCTAssertEqual(state.openCodeUsageProcessing?.status, .unsupportedPluginVersion)
        XCTAssertTrue(state.usageSamples.isEmpty)
        XCTAssertEqual(receiver.removed.count, 1)
    }

    private func usageEvent(
        session: String = "session-a",
        model: String = "gpt-5",
        provider: String? = nil,
        input: Int,
        output: Int = 0,
        cost: Decimal? = nil
    ) -> OpenCodeUsageEvent {
        OpenCodeUsageEvent(
            sessionID: session,
            workingDirectory: "/example",
            messageID: "message-\(UUID().uuidString)",
            observedAt: date("2026-08-13T00:02:00Z"),
            model: model,
            provider: provider,
            serviceMode: "build",
            inputTokens: input,
            outputTokens: output,
            providerReportedCost: cost,
            pluginVersion: OpenCodeUsageEventMapper.parserVersion
        )
    }

    private func makeRun() -> Run {
        Run(
            activityID: UUID(),
            kind: .agent,
            startedAt: date("2026-08-13T00:00:00Z"),
            agentMetadata: AgentRunMetadata(
                integration: .openCode,
                sessionFingerprint: "session-digest",
                lastEventAt: date("2026-08-13T00:00:00Z")
            )
        )
    }

    private func state(run: Run) -> AppState {
        let workspace = Workspace(name: "Example", createdAt: date("2026-08-13T00:00:00Z"), source: .manual)
        let activity = Activity(id: run.activityID, workspaceID: workspace.id, title: "OpenCode", createdAt: date("2026-08-13T00:00:00Z"))
        return AppState(
            settings: CodePulseSettings(openCodeUsageTrackingEnabled: true),
            activityGraph: ActivityGraph(workspaces: [workspace], activities: [activity], runs: [run])
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulseOpenCodeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func fingerprint(_ value: String) -> String {
        value == "opencode:session-a" ? "session-digest" : "digest:\(value.hashValue)"
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}

private final class TestReceiver: OpenCodeUsageReceiving {
    let events: [OpenCodeUsageEvent?]
    private(set) var calls = 0
    private(set) var removed: [URL] = []

    init(_ events: [OpenCodeUsageEvent?]) { self.events = events }

    func pendingEvents() -> [(URL, OpenCodeUsageEvent?)] {
        calls += 1
        return events.enumerated().map { index, event in
            (URL(fileURLWithPath: "/tmp/opencode-usage-\(index).json"), event)
        }
    }

    func remove(_ url: URL) { removed.append(url) }
}
