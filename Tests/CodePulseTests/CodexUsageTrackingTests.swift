import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class CodexUsageTrackingTests: XCTestCase {
    func testCodexUsageConsentDefaultsOffAndRoundTrips() throws {
        let legacySettings = try JSONDecoder().decode(CodePulseSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(legacySettings.codexUsageTrackingEnabled)

        let encoded = try JSONEncoder().encode(CodePulseSettings(codexUsageTrackingEnabled: true))
        XCTAssertTrue(try JSONDecoder().decode(CodePulseSettings.self, from: encoded).codexUsageTrackingEnabled)
    }

    func testDisabledTrackingNeverEnumeratesOrOpensUsageSources() {
        let source = TestSource([])
        let reader = CodexUsageReader(source: source, fingerprint: { $0 })
        let service = CodexUsageTrackingService(reader: reader, catalogStore: nil)
        var state = AppState()

        XCTAssertFalse(service.process(state: &state, now: Date()))
        XCTAssertEqual(source.calls, 0)
        XCTAssertNil(state.codexUsageProcessing)
    }

    func testReaderUsesCumulativeDeltasAndIgnoresRepeatedOrMalformedRecords() throws {
        let file = try makeFile(contents: sessionLog([
            token(total: ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 20, "reasoning_output_tokens": 4]),
            "not json",
            token(total: ["input_tokens": 100, "output_tokens": 10, "cached_input_tokens": 20, "reasoning_output_tokens": 4]),
            token(total: ["input_tokens": 130, "output_tokens": 15, "cached_input_tokens": 20, "reasoning_output_tokens": 6])
        ]))
        let reader = CodexUsageReader(source: TestSource([file]), fingerprint: testFingerprint)
        var processing = CodexUsageProcessingState()

        let records = reader.read(state: &processing, now: date("2026-08-13T00:01:00Z"))

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].tokens, UsageTokenCounts(input: 100, output: 10, cachedInput: 20, reasoning: 4))
        XCTAssertEqual(records[1].tokens, UsageTokenCounts(input: 30, output: 5, cachedInput: 0, reasoning: 2))
        XCTAssertEqual(records[0].sessionFingerprint, "session-digest")
        XCTAssertEqual(processing.checkpoints.count, 1)
        XCTAssertFalse(String(describing: processing).contains("session-a"))
    }

    func testReaderHandlesTruncationAndRotationWithoutRecountingPriorTotals() throws {
        let first = try makeFile(contents: sessionLog([
            token(total: ["input_tokens": 100, "output_tokens": 10])
        ]), name: "first.jsonl")
        let source = TestSource([first])
        let reader = CodexUsageReader(source: source, fingerprint: testFingerprint)
        var processing = CodexUsageProcessingState()
        XCTAssertEqual(reader.read(state: &processing, now: Date()).count, 1)

        try sessionLog([token(total: ["input_tokens": 100, "output_tokens": 10])]).write(to: first, atomically: true, encoding: .utf8)
        XCTAssertTrue(reader.read(state: &processing, now: Date()).isEmpty)
        try sessionLog([token(total: ["input_tokens": 125, "output_tokens": 15])]).write(to: first, atomically: true, encoding: .utf8)
        let afterTruncation = reader.read(state: &processing, now: Date())
        XCTAssertEqual(afterTruncation.map(\.tokens.output), [5])

        let second = try makeFile(contents: sessionLog([token(total: ["input_tokens": 12, "output_tokens": 3])], session: "session-b"), name: "second.jsonl")
        source.files = [first, second]
        let afterRotation = reader.read(state: &processing, now: Date())
        XCTAssertEqual(afterRotation.count, 1)
        XCTAssertEqual(afterRotation.first?.sessionFingerprint, "session-digest-b")
    }

    func testTrackingCorrelatesOnlyOneMatchingRunAndCalculatesClearlyLabeledEstimates() throws {
        let file = try makeFile(contents: sessionLog([token(total: ["input_tokens": 1_000_000, "output_tokens": 1_000_000, "cached_input_tokens": 1_000_000])]))
        let reader = CodexUsageReader(source: TestSource([file]), fingerprint: testFingerprint)
        let catalog = try PricingCatalogStore(cacheURL: try temporaryDirectory().appendingPathComponent("catalog.json"))
        let service = CodexUsageTrackingService(reader: reader, catalogStore: catalog)
        let workspace = Workspace(name: "Example", createdAt: date("2026-08-13T00:00:00Z"), source: .manual)
        let activity = Activity(workspaceID: workspace.id, title: "Codex", createdAt: date("2026-08-13T00:00:00Z"))
        let run = Run(
            activityID: activity.id,
            kind: .agent,
            startedAt: date("2026-08-13T00:00:00Z"),
            agentMetadata: AgentRunMetadata(integration: .codex, sessionFingerprint: "session-digest", model: "gpt-5.3-codex", lastEventAt: date("2026-08-13T00:00:00Z"))
        )
        var state = AppState(
            settings: CodePulseSettings(codexUsageTrackingEnabled: true),
            activityGraph: ActivityGraph(workspaces: [workspace], activities: [activity], runs: [run])
        )

        XCTAssertTrue(service.process(state: &state, now: date("2026-08-13T00:01:00Z")))
        let sample = try XCTUnwrap(state.usageSamples.first)
        XCTAssertEqual(sample.runID, run.id)
        XCTAssertEqual(sample.workspaceID, workspace.id)
        XCTAssertEqual(sample.model, "gpt-5.3-codex")
        XCTAssertEqual(Set(sample.calculatedCosts.map(\.representation)), [.apiEquivalentEstimate, .codexCreditEstimate])
        XCTAssertEqual(Set(sample.calculatedCosts.map(\.amount)), [Decimal(string: "15.925")])
        XCTAssertTrue(sample.calculatedCosts.allSatisfy { $0.provenance.catalogVersion == 2 && $0.provenance.priceSourceURL.contains("gpt-5.3-codex") })
    }

    func testAmbiguousRunsRemainUnassigned() throws {
        let file = try makeFile(contents: sessionLog([token(total: ["input_tokens": 4])]))
        let reader = CodexUsageReader(source: TestSource([file]), fingerprint: testFingerprint)
        let service = CodexUsageTrackingService(reader: reader, catalogStore: nil)
        let workspace = Workspace(name: "Example", createdAt: Date(), source: .manual)
        let activity = Activity(workspaceID: workspace.id, title: "Codex", createdAt: Date())
        let sameFingerprint = "session-digest"
        let first = Run(activityID: activity.id, kind: .agent, startedAt: date("2026-08-13T00:00:00Z"), agentMetadata: AgentRunMetadata(integration: .codex, sessionFingerprint: sameFingerprint, lastEventAt: date("2026-08-13T00:00:00Z")))
        let second = Run(activityID: activity.id, kind: .agent, startedAt: date("2026-08-13T00:00:00Z"), agentMetadata: AgentRunMetadata(integration: .codex, sessionFingerprint: sameFingerprint, lastEventAt: date("2026-08-13T00:00:00Z")))
        var state = AppState(settings: CodePulseSettings(codexUsageTrackingEnabled: true), activityGraph: ActivityGraph(workspaces: [workspace], activities: [activity], runs: [first, second]))

        XCTAssertTrue(service.process(state: &state, now: date("2026-08-13T00:01:00Z")))
        XCTAssertNil(state.usageSamples.first?.runID)
        XCTAssertNil(state.usageSamples.first?.workspaceID)
    }

    func testDelayedRunRemainsUnassigned() throws {
        let file = try makeFile(contents: sessionLog([token(total: ["input_tokens": 4])]))
        let reader = CodexUsageReader(source: TestSource([file]), fingerprint: testFingerprint)
        let service = CodexUsageTrackingService(reader: reader, catalogStore: nil)
        let workspace = Workspace(name: "Example", createdAt: Date(), source: .manual)
        let activity = Activity(workspaceID: workspace.id, title: "Codex", createdAt: Date())
        let delayedRun = Run(
            activityID: activity.id,
            kind: .agent,
            startedAt: date("2026-08-13T00:10:00Z"),
            agentMetadata: AgentRunMetadata(
                integration: .codex,
                sessionFingerprint: "session-digest",
                lastEventAt: date("2026-08-13T00:10:00Z")
            )
        )
        var state = AppState(
            settings: CodePulseSettings(codexUsageTrackingEnabled: true),
            activityGraph: ActivityGraph(workspaces: [workspace], activities: [activity], runs: [delayedRun])
        )

        XCTAssertTrue(service.process(state: &state, now: date("2026-08-13T00:11:00Z")))
        XCTAssertNil(state.usageSamples.first?.runID)
        XCTAssertNil(state.usageSamples.first?.workspaceID)
    }

    private func sessionLog(_ tokenEvents: [String], session: String = "session-a") -> String {
        (["{\"timestamp\":\"2026-08-13T00:00:00Z\",\"type\":\"session_meta\",\"payload\":{\"session_id\":\"\(session)\",\"cwd\":\"/example\"}}", "{\"timestamp\":\"2026-08-13T00:00:01Z\",\"type\":\"turn_context\",\"payload\":{\"model\":\"gpt-5.3-codex\"}}"] + tokenEvents).joined(separator: "\n") + "\n"
    }

    private func token(total: [String: Int]) -> String {
        let values = total.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",")
        return "{\"timestamp\":\"2026-08-13T00:00:02Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\(values)}}}}"
    }

    private func makeFile(contents: String, name: String = "session.jsonl") throws -> URL {
        let url = try temporaryDirectory().appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulseCodexUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func testFingerprint(_ value: String) -> String {
        if value == "codex:session-a" { return "session-digest" }
        if value == "codex:session-b" { return "session-digest-b" }
        return "file-digest:\(value.hashValue)"
    }
}

private final class TestSource: CodexUsageSessionSource {
    var files: [URL]
    private(set) var calls = 0

    init(_ files: [URL]) { self.files = files }

    func sessionFiles() -> [URL] {
        calls += 1
        return files
    }
}
