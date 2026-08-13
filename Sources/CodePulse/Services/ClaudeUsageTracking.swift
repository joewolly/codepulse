import CodePulseIntegration
import Foundation

/// Persisted reader state keeps only salted source/event fingerprints and
/// offsets. It never stores a Claude transcript path, session ID, or content.
struct ClaudeUsageProcessingState: Codable, Equatable {
    static let maximumCheckpoints = 512
    static let maximumProcessedRecords = 4_096
    var checkpoints: [ClaudeUsageCheckpoint] = []
    var processedRecordFingerprints: [String] = []
}

struct ClaudeUsageCheckpoint: Codable, Equatable {
    let sourceFingerprint: String
    var byteOffset: UInt64
    var fileNode: UInt64?
    var updatedAt: Date
}

struct ClaudeUsageRecord: Equatable {
    let sessionFingerprint: String
    let observedAt: Date
    let model: String?
    let effort: String?
    let serviceMode: String?
    let tokens: UsageTokenCounts
    let providerReportedCost: Decimal?
    let includesSubagentUsage: Bool
}

protocol ClaudeUsageSessionSource {
    func sessionFiles() -> [URL]
}

struct SystemClaudeUsageSessionSource: ClaudeUsageSessionSource {
    let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func sessionFiles() -> [URL] {
        guard let rootValues = try? rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true,
              let enumerator = fileManager.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard url.pathExtension.lowercased() == "jsonl",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        .sorted { $0.path < $1.path }
    }
}

/// Reads only supported assistant usage metadata from local Claude JSONL
/// records. The parser discards message content and all unsupported fields.
final class ClaudeUsageReader {
    private let source: ClaudeUsageSessionSource
    private let fingerprint: (String) -> String
    private let fileManager: FileManager
    private let maximumBytesPerFilePerScan: Int

    init(
        source: ClaudeUsageSessionSource = SystemClaudeUsageSessionSource(),
        fingerprint: @escaping (String) -> String,
        fileManager: FileManager = .default,
        maximumBytesPerFilePerScan: Int = 2_000_000
    ) {
        self.source = source
        self.fingerprint = fingerprint
        self.fileManager = fileManager
        self.maximumBytesPerFilePerScan = max(4_096, maximumBytesPerFilePerScan)
    }

    func read(state: inout ClaudeUsageProcessingState, now: Date) -> [ClaudeUsageRecord] {
        var records: [ClaudeUsageRecord] = []
        for fileURL in source.sessionFiles().prefix(ClaudeUsageProcessingState.maximumCheckpoints) {
            let sourceFingerprint = fingerprint(fileURL.standardizedFileURL.path)
            var checkpoint = state.checkpoints.first(where: { $0.sourceFingerprint == sourceFingerprint })
                ?? ClaudeUsageCheckpoint(sourceFingerprint: sourceFingerprint, byteOffset: 0, fileNode: nil, updatedAt: now)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
                  let fileSize = (attributes[.size] as? NSNumber)?.uint64Value else { continue }
            let fileNode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            if fileSize < checkpoint.byteOffset ||
                (checkpoint.fileNode != nil && checkpoint.fileNode != fileNode) ||
                !isLineBoundary(in: fileURL, before: checkpoint.byteOffset) {
                checkpoint.byteOffset = 0
            }
            checkpoint.fileNode = fileNode
            guard let chunk = readChunk(from: fileURL, offset: checkpoint.byteOffset),
                  let completedLength = chunk.lastIndex(of: 0x0A).map({ chunk.distance(from: chunk.startIndex, to: $0) + 1 }),
                  completedLength > 0 else { continue }
            for line in chunk.prefix(completedLength).split(separator: 0x0A, omittingEmptySubsequences: true) where line.count <= 128_000 {
                process(line: Data(line), state: &state, records: &records, now: now)
            }
            checkpoint.byteOffset += UInt64(completedLength)
            checkpoint.updatedAt = now
            if let index = state.checkpoints.firstIndex(where: { $0.sourceFingerprint == sourceFingerprint }) {
                state.checkpoints[index] = checkpoint
            } else {
                state.checkpoints.append(checkpoint)
            }
        }
        state.checkpoints.sort { $0.updatedAt > $1.updatedAt }
        state.checkpoints = Array(state.checkpoints.prefix(ClaudeUsageProcessingState.maximumCheckpoints))
        if state.processedRecordFingerprints.count > ClaudeUsageProcessingState.maximumProcessedRecords {
            state.processedRecordFingerprints.removeFirst(state.processedRecordFingerprints.count - ClaudeUsageProcessingState.maximumProcessedRecords)
        }
        return records
    }

    private func readChunk(from url: URL, offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: maximumBytesPerFilePerScan)
        } catch { return nil }
    }

    private func isLineBoundary(in url: URL, before offset: UInt64) -> Bool {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset - 1)
            return try handle.read(upToCount: 1)?.first == 0x0A
        } catch { return false }
    }

    private func process(
        line: Data,
        state: inout ClaudeUsageProcessingState,
        records: inout [ClaudeUsageRecord],
        now: Date
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              object["type"] as? String == "assistant",
              let sessionID = (object["sessionId"] ?? object["session_id"]) as? String,
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }
        let tokens = tokenCounts(from: usage)
        guard tokens.hasTokens else { return }
        let recordFingerprint = fingerprint(recordIdentity(sessionID: sessionID, object: object, message: message, tokens: tokens))
        guard !state.processedRecordFingerprints.contains(recordFingerprint) else { return }
        state.processedRecordFingerprints.append(recordFingerprint)
        records.append(ClaudeUsageRecord(
            sessionFingerprint: fingerprint("claude-code:\(sessionID)"),
            observedAt: date(from: object["timestamp"]) ?? now,
            model: message["model"] as? String,
            effort: object["effort"] as? String,
            serviceMode: usage["service_tier"] as? String ?? usage["speed"] as? String,
            tokens: tokens,
            providerReportedCost: decimal(from: usage["cost_usd"] ?? usage["costUSD"] ?? usage["total_cost_usd"]),
            includesSubagentUsage: object["usage_scope"] as? String == "aggregate" || (usage["includes_subagent_usage"] as? Bool == true)
        ))
    }

    private func recordIdentity(sessionID: String, object: [String: Any], message: [String: Any], tokens: UsageTokenCounts) -> String {
        let recordID = object["uuid"] as? String ?? ""
        let timestamp = object["timestamp"] as? String ?? ""
        let model = message["model"] as? String ?? ""
        let input = tokens.input.map { String($0) } ?? ""
        let output = tokens.output.map { String($0) } ?? ""
        let cachedInput = tokens.cachedInput.map { String($0) } ?? ""
        let cacheWriteInput = tokens.cacheWriteInput.map { String($0) } ?? ""
        let parts = [sessionID, recordID, timestamp, model, input, output, cachedInput, cacheWriteInput]
        return "claude-usage:" + parts.joined(separator: "\u{1F}")
    }

    private func tokenCounts(from usage: [String: Any]) -> UsageTokenCounts {
        func token(_ key: String) -> Int? {
            guard let number = usage[key] as? NSNumber else { return nil }
            return max(0, number.intValue)
        }
        let nestedCacheCreation = (usage["cache_creation"] as? [String: Any])?.values.compactMap { ($0 as? NSNumber)?.intValue }.reduce(0, +)
        return UsageTokenCounts(
            input: token("input_tokens"),
            output: token("output_tokens"),
            cachedInput: token("cache_read_input_tokens"),
            cacheWriteInput: token("cache_creation_input_tokens") ?? nestedCacheCreation
        )
    }

    private func decimal(from value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return number.decimalValue }
        if let string = value as? String { return Decimal(string: string) }
        return nil
    }

    private func date(from value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

protocol ClaudeUsageTracking {
    func process(state: inout AppState, now: Date) -> Bool
}

final class ClaudeUsageTrackingService: ClaudeUsageTracking {
    private let reader: ClaudeUsageReader
    private let catalogStore: PricingCatalogStore?

    init(reader: ClaudeUsageReader? = nil, catalogStore: PricingCatalogStore? = nil) {
        let fingerprinter = DeveloperEventV2Inbox()
        self.reader = reader ?? ClaudeUsageReader(fingerprint: fingerprinter.fingerprint)
        self.catalogStore = catalogStore ?? (try? PricingCatalogStore(cacheURL: Self.defaultCatalogCacheURL()))
    }

    func process(state: inout AppState, now: Date) -> Bool {
        guard state.settings.claudeUsageTrackingEnabled else { return false }
        var processing = state.claudeUsageProcessing ?? ClaudeUsageProcessingState()
        let records = reader.read(state: &processing, now: now)
        var changed = processing != state.claudeUsageProcessing
        state.claudeUsageProcessing = processing
        guard !records.isEmpty else { return changed }
        let catalog = try? catalogStore?.current(at: now)
        for record in records {
            let attribution = attribution(for: record, in: state.activityGraph)
            let sample = UsageSample(
                integration: .claudeCode,
                observedAt: record.observedAt,
                sessionFingerprint: record.sessionFingerprint,
                runID: attribution.runID,
                workspaceID: attribution.workspaceID,
                model: record.model,
                effort: record.effort,
                serviceMode: record.serviceMode,
                tokens: record.tokens,
                providerReportedCost: record.providerReportedCost,
                providerReportedCurrency: record.providerReportedCost == nil ? nil : "USD",
                includesSubagentUsage: record.includesSubagentUsage,
                calculatedCosts: catalog.map { snapshot in
                    UsageCostCalculator.calculate(representation: .apiEquivalentEstimate, sample: UsageSample(
                        integration: .claudeCode,
                        observedAt: record.observedAt,
                        sessionFingerprint: record.sessionFingerprint,
                        runID: attribution.runID,
                        workspaceID: attribution.workspaceID,
                        model: record.model,
                        effort: record.effort,
                        serviceMode: record.serviceMode,
                        tokens: record.tokens
                    ), catalog: snapshot, calculatedAt: now).map { [$0] } ?? []
                } ?? []
            )
            state.usageSamples.append(sample)
            changed = true
        }
        return changed
    }

    private func attribution(for record: ClaudeUsageRecord, in graph: ActivityGraph) -> (runID: UUID?, workspaceID: UUID?) {
        let matches = graph.runs.filter { run in
            guard run.kind == .agent,
                  run.agentMetadata?.integration == .claudeCode,
                  run.agentMetadata?.sessionFingerprint == record.sessionFingerprint,
                  run.startedAt <= record.observedAt else { return false }
            return run.endedAt.map { $0 >= record.observedAt } ?? true
        }
        guard matches.count == 1, let run = matches.first,
              let activity = graph.activities.first(where: { $0.id == run.activityID }) else { return (nil, nil) }
        return (run.id, activity.workspaceID)
    }

    private static func defaultCatalogCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodePulse", isDirectory: true)
            .appendingPathComponent("pricing-catalog.json", isDirectory: false)
    }
}

struct ClaudeUsageRollup: Equatable {
    let parentRunID: UUID
    let childRunIDs: [UUID]
    let tokens: UsageTokenCounts
    let usesParentAggregate: Bool
}

enum ClaudeUsageRollupCalculator {
    static func rollups(samples: [UsageSample], graph: ActivityGraph) -> [ClaudeUsageRollup] {
        graph.runs.compactMap { parent in
            guard parent.agentMetadata?.integration == .claudeCode,
                  parent.agentMetadata?.parentSessionFingerprint == nil,
                  let fingerprint = parent.agentMetadata?.sessionFingerprint else { return nil }
            let children = graph.runs.filter {
                $0.agentMetadata?.integration == .claudeCode &&
                    $0.agentMetadata?.parentSessionFingerprint == fingerprint
            }
            let direct = samples.filter { $0.integration == .claudeCode && $0.runID == parent.id }
            let childSamples = samples.filter { sample in children.contains(where: { $0.id == sample.runID }) }
            let aggregate = direct.filter(\.includesSubagentUsage).max { $0.observedAt < $1.observedAt }
            let included = aggregate.map { [$0] } ?? (direct + childSamples)
            guard let tokens = included.map(\.tokens).reduce(nil, { partial, next in
                partial.map { $0.adding(next) } ?? next
            }) else { return nil }
            return ClaudeUsageRollup(
                parentRunID: parent.id,
                childRunIDs: children.map(\.id).sorted { $0.uuidString < $1.uuidString },
                tokens: tokens,
                usesParentAggregate: aggregate != nil
            )
        }
    }
}

private extension UsageTokenCounts {
    var hasTokens: Bool {
        [input, output, cachedInput, cacheWriteInput, reasoning].contains { ($0 ?? 0) > 0 }
    }

    func adding(_ other: UsageTokenCounts) -> UsageTokenCounts {
        func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
            guard lhs != nil || rhs != nil else { return nil }
            return (lhs ?? 0) + (rhs ?? 0)
        }
        return UsageTokenCounts(
            input: sum(input, other.input),
            output: sum(output, other.output),
            cachedInput: sum(cachedInput, other.cachedInput),
            cacheWriteInput: sum(cacheWriteInput, other.cacheWriteInput),
            reasoning: sum(reasoning, other.reasoning)
        )
    }
}
