import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class ClaudeUsageTrackingTests: XCTestCase {
    func testConsentDefaultsOffAndDisabledReaderNeverEnumeratesSources() throws {
        let settings = try JSONDecoder().decode(CodePulseSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.claudeUsageTrackingEnabled)
        let enabled = try JSONDecoder().decode(
            CodePulseSettings.self,
            from: JSONEncoder().encode(CodePulseSettings(claudeUsageTrackingEnabled: true))
        )
        XCTAssertTrue(enabled.claudeUsageTrackingEnabled)
        let source = ClaudeTestSource([])
        let service = ClaudeUsageTrackingService(reader: ClaudeUsageReader(source: source, fingerprint: fingerprint), catalogStore: nil)
        var state = AppState()

        XCTAssertFalse(service.process(state: &state, now: Date()))
        XCTAssertEqual(source.calls, 0)
        XCTAssertNil(state.claudeUsageProcessing)
    }

    func testReaderParsesSupportedMetadataAndNeverNeedsTranscriptContent() throws {
        let file = try makeFile(contents: log([
            assistant(session: "parent", uuid: "one", usage: ["input_tokens": 100, "output_tokens": 20, "cache_read_input_tokens": 30, "cache_creation_input_tokens": 40], effort: "high", service: "standard", cost: "0.125"),
            assistant(session: "child", uuid: "two", usage: ["input_tokens": 9, "output_tokens": 3, "cache_creation": ["ephemeral_5m_input_tokens": 4]], service: "fast"),
            "{not json}",
            "{\"type\":\"user\",\"message\":{\"content\":\"not parsed\"}}"
        ]))
        let reader = ClaudeUsageReader(source: ClaudeTestSource([file]), fingerprint: fingerprint)
        var state = ClaudeUsageProcessingState()

        let records = reader.read(state: &state, now: date("2026-08-13T00:01:00Z"))

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].sessionFingerprint, "digest-parent")
        XCTAssertEqual(records[0].model, "claude-sonnet")
        XCTAssertEqual(records[0].effort, "high")
        XCTAssertEqual(records[0].serviceMode, "standard")
        XCTAssertEqual(records[0].tokens, UsageTokenCounts(input: 100, output: 20, cachedInput: 30, cacheWriteInput: 40))
        XCTAssertEqual(records[0].providerReportedCost, Decimal(string: "0.125"))
        XCTAssertEqual(records[1].serviceMode, "fast")
        XCTAssertEqual(records[1].tokens.cacheWriteInput, 4)
        XCTAssertTrue(reader.read(state: &state, now: Date()).isEmpty)
        XCTAssertFalse(String(describing: state).contains("claude-code:parent"))
    }

    func testReaderHandlesReplacementWithoutRepeatingProcessedAssistantRecord() throws {
        let file = try makeFile(contents: log([assistant(session: "parent", uuid: "one", usage: ["input_tokens": 10])]))
        let reader = ClaudeUsageReader(source: ClaudeTestSource([file]), fingerprint: fingerprint)
        var state = ClaudeUsageProcessingState()
        XCTAssertEqual(reader.read(state: &state, now: Date()).count, 1)

        try log([assistant(session: "parent", uuid: "one", usage: ["input_tokens": 10])]).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(reader.read(state: &state, now: Date()).isEmpty)
        try log([
            assistant(session: "parent", uuid: "one", usage: ["input_tokens": 10]),
            assistant(session: "parent", uuid: "two", usage: ["input_tokens": 5])
        ]).write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(reader.read(state: &state, now: Date()).map(\.tokens.input), [5])
    }

    func testServiceCorrelatesParentAndChildSamplesSeparately() throws {
        let file = try makeFile(contents: log([
            assistant(session: "parent", uuid: "one", usage: ["input_tokens": 10]),
            assistant(session: "child", uuid: "two", usage: ["input_tokens": 4])
        ]))
        let parent = makeRun(session: "digest-parent", startedAt: date("2026-08-13T00:00:00Z"))
        let child = makeRun(session: "digest-child", parent: "digest-parent", startedAt: date("2026-08-13T00:00:00Z"))
        let service = ClaudeUsageTrackingService(reader: ClaudeUsageReader(source: ClaudeTestSource([file]), fingerprint: fingerprint), catalogStore: nil)
        var state = state(parent: parent, children: [child])

        XCTAssertTrue(service.process(state: &state, now: date("2026-08-13T00:01:00Z")))
        XCTAssertEqual(Set(state.usageSamples.compactMap(\.runID)), Set([parent.id, child.id]))
        XCTAssertEqual(ClaudeUsageRollupCalculator.rollups(samples: state.usageSamples, graph: state.activityGraph).first?.tokens.input, 14)
    }

    func testParentOnlyAndChildrenOnlyRollupsCountEachSampleOnce() {
        let parent = makeRun(session: "digest-parent", startedAt: Date())
        let child = makeRun(session: "digest-child", parent: "digest-parent", startedAt: Date())
        let graph = state(parent: parent, children: [child]).activityGraph
        let parentOnly = [sample(runID: parent.id, input: 8)]
        let childrenOnly = [sample(runID: child.id, input: 5)]

        XCTAssertEqual(ClaudeUsageRollupCalculator.rollups(samples: parentOnly, graph: graph).first?.tokens.input, 8)
        XCTAssertEqual(ClaudeUsageRollupCalculator.rollups(samples: childrenOnly, graph: graph).first?.tokens.input, 5)
    }

    func testAggregateParentUsagePreventsDuplicateChildRollup() {
        let parent = makeRun(session: "digest-parent", startedAt: Date())
        let child = makeRun(session: "digest-child", parent: "digest-parent", startedAt: Date())
        let graph = state(parent: parent, children: [child]).activityGraph
        let aggregate = sample(runID: parent.id, input: 30, aggregate: true)
        let childSample = sample(runID: child.id, input: 10)

        let rollup = ClaudeUsageRollupCalculator.rollups(samples: [aggregate, childSample], graph: graph).first
        XCTAssertEqual(rollup?.tokens.input, 30)
        XCTAssertTrue(rollup?.usesParentAggregate == true)
    }

    func testOverlappingChildrenBothContributeExactlyOnce() {
        let parent = makeRun(session: "digest-parent", startedAt: Date())
        let first = makeRun(session: "digest-child", parent: "digest-parent", startedAt: Date())
        let second = makeRun(session: "digest-child-two", parent: "digest-parent", startedAt: Date())
        let graph = state(parent: parent, children: [first, second]).activityGraph

        let rollup = ClaudeUsageRollupCalculator.rollups(samples: [sample(runID: first.id, input: 3), sample(runID: second.id, input: 7)], graph: graph).first
        XCTAssertEqual(rollup?.tokens.input, 10)
        XCTAssertEqual(Set(rollup?.childRunIDs ?? []), Set([first.id, second.id]))
    }

    func testRollupQuarantinesCumulativeTokenLimitOverflow() {
        let parent = makeRun(session: "digest-parent", startedAt: Date())
        let child = makeRun(session: "digest-child", parent: "digest-parent", startedAt: Date())
        let graph = state(parent: parent, children: [child]).activityGraph

        let rollups = ClaudeUsageRollupCalculator.rollups(
            samples: [sample(runID: parent.id, input: 60_000_000), sample(runID: child.id, input: 60_000_000)],
            graph: graph
        )

        XCTAssertTrue(rollups.isEmpty)
    }

    func testCostPresentationKeepsReportedSubscriptionAndEstimateStatesDistinct() {
        let reported = sample(runID: nil, input: 1, cost: Decimal(string: "0.50"))
        XCTAssertEqual(UsageCostPresentation.resolve(sample: reported, preferred: .providerReported), .providerReported(amount: Decimal(string: "0.50")!, currency: "USD"))
        XCTAssertEqual(UsageCostPresentation.resolve(sample: reported, preferred: .subscription), .subscription)
        XCTAssertEqual(UsageCostPresentation.resolve(sample: reported, preferred: .apiEquivalentEstimate), .unpriced)
    }

    private func state(parent: Run, children: [Run]) -> AppState {
        let workspace = Workspace(name: "Example", createdAt: date("2026-08-13T00:00:00Z"), source: .manual)
        let runs = [parent] + children
        let activities = runs.map { run in
            Activity(id: run.activityID, workspaceID: workspace.id, title: "Claude", createdAt: date("2026-08-13T00:00:00Z"))
        }
        return AppState(
            settings: CodePulseSettings(claudeUsageTrackingEnabled: true),
            activityGraph: ActivityGraph(workspaces: [workspace], activities: activities, runs: runs)
        )
    }

    private func makeRun(session: String, parent: String? = nil, startedAt: Date) -> Run {
        Run(
            activityID: UUID(),
            kind: .agent,
            startedAt: startedAt,
            agentMetadata: AgentRunMetadata(integration: .claudeCode, sessionFingerprint: session, parentSessionFingerprint: parent, lastEventAt: startedAt)
        )
    }

    private func sample(runID: UUID?, input: Int, aggregate: Bool = false, cost: Decimal? = nil) -> UsageSample {
        UsageSample(
            integration: .claudeCode,
            observedAt: Date(),
            runID: runID,
            tokens: UsageTokenCounts(input: input),
            providerReportedCost: cost,
            providerReportedCurrency: cost == nil ? nil : "USD",
            includesSubagentUsage: aggregate
        )
    }

    private func log(_ records: [String]) -> String { records.joined(separator: "\n") + "\n" }

    private func assistant(session: String, uuid: String, usage: [String: Any], effort: String? = nil, service: String? = nil, cost: String? = nil) -> String {
        var usage = usage
        if let service { usage["service_tier"] = service }
        if let cost { usage["cost_usd"] = cost }
        var record: [String: Any] = [
            "type": "assistant",
            "sessionId": session,
            "uuid": uuid,
            "timestamp": "2026-08-13T00:00:02Z",
            "message": ["model": "claude-sonnet", "usage": usage]
        ]
        if let effort { record["effort"] = effort }
        let data = try! JSONSerialization.data(withJSONObject: record)
        return String(data: data, encoding: .utf8)!
    }

    private func makeFile(contents: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulseClaudeUsageTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func fingerprint(_ value: String) -> String {
        if value == "claude-code:parent" { return "digest-parent" }
        if value == "claude-code:child" { return "digest-child" }
        if value == "claude-code:child-two" { return "digest-child-two" }
        return "digest:\(value.hashValue)"
    }
}

private final class ClaudeTestSource: ClaudeUsageSessionSource {
    let files: [URL]
    private(set) var calls = 0

    init(_ files: [URL]) { self.files = files }

    func sessionFiles() -> [URL] {
        calls += 1
        return files
    }
}
