import Foundation

/// Persisted reader state contains only salted source/session fingerprints,
/// offsets, token counters, and a model label. It never keeps a Codex path,
/// raw session identifier, or JSONL content.
struct CodexUsageProcessingState: Codable, Equatable {
    static let maximumCheckpoints = 512
    var checkpoints: [CodexUsageCheckpoint] = []
}

struct CodexUsageCheckpoint: Codable, Equatable {
    let sourceFingerprint: String
    var sessionFingerprint: String?
    var byteOffset: UInt64
    var fileNode: UInt64?
    var cumulativeTokens: UsageTokenCounts
    var model: String?
    var updatedAt: Date
}

struct CodexUsageRecord: Equatable {
    let sessionFingerprint: String
    let observedAt: Date
    let model: String?
    let tokens: UsageTokenCounts
}

protocol CodexUsageSessionSource {
    func sessionFiles() -> [URL]
}

struct SystemCodexUsageSessionSource: CodexUsageSessionSource {
    let rootURL: URL
    private let fileManager: FileManager

    init(
        rootURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions", isDirectory: true),
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

/// Incrementally reads the content-free `session_meta`, `turn_context`, and
/// `event_msg/token_count` records emitted by current local Codex session logs.
/// Every other JSONL record is skipped before it can affect state.
final class CodexUsageReader {
    private let source: CodexUsageSessionSource
    private let fingerprint: (String) -> String
    private let fileManager: FileManager
    private let maximumBytesPerFilePerScan: Int

    init(
        source: CodexUsageSessionSource = SystemCodexUsageSessionSource(),
        fingerprint: @escaping (String) -> String,
        fileManager: FileManager = .default,
        maximumBytesPerFilePerScan: Int = 2_000_000
    ) {
        self.source = source
        self.fingerprint = fingerprint
        self.fileManager = fileManager
        self.maximumBytesPerFilePerScan = max(4_096, maximumBytesPerFilePerScan)
    }

    func read(state: inout CodexUsageProcessingState, now: Date) -> [CodexUsageRecord] {
        var records: [CodexUsageRecord] = []
        for fileURL in source.sessionFiles().prefix(CodexUsageProcessingState.maximumCheckpoints) {
            let sourceFingerprint = fingerprint(fileURL.standardizedFileURL.path)
            var checkpoint = state.checkpoints.first(where: { $0.sourceFingerprint == sourceFingerprint })
                ?? CodexUsageCheckpoint(
                    sourceFingerprint: sourceFingerprint,
                    sessionFingerprint: nil,
                    byteOffset: 0,
                    fileNode: nil,
                    cumulativeTokens: UsageTokenCounts(),
                    model: nil,
                    updatedAt: now
                )
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
            let completedData = chunk.prefix(completedLength)
            for line in completedData.split(separator: 0x0A, omittingEmptySubsequences: true) where line.count <= 128_000 {
                process(
                    line: Data(line),
                    checkpoint: &checkpoint,
                    records: &records,
                    now: now
                )
            }
            checkpoint.byteOffset += UInt64(completedLength)
            checkpoint.updatedAt = now
            if let index = state.checkpoints.firstIndex(where: { $0.sourceFingerprint == sourceFingerprint }) {
                state.checkpoints[index] = checkpoint
            } else {
                state.checkpoints.append(checkpoint)
            }
        }
        if state.checkpoints.count > CodexUsageProcessingState.maximumCheckpoints {
            state.checkpoints.sort { $0.updatedAt > $1.updatedAt }
            state.checkpoints.removeLast(state.checkpoints.count - CodexUsageProcessingState.maximumCheckpoints)
        }
        return records
    }

    private func readChunk(from url: URL, offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: maximumBytesPerFilePerScan)
        } catch {
            return nil
        }
    }

    private func isLineBoundary(in url: URL, before offset: UInt64) -> Bool {
        guard offset > 0, let handle = try? FileHandle(forReadingFrom: url) else { return true }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset - 1)
            return try handle.read(upToCount: 1)?.first == 0x0A
        } catch {
            return false
        }
    }

    private func process(
        line: Data,
        checkpoint: inout CodexUsageCheckpoint,
        records: inout [CodexUsageRecord],
        now: Date
    ) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String,
              let payload = object["payload"] as? [String: Any] else { return }
        switch type {
        case "session_meta":
            if let sessionID = (payload["session_id"] ?? payload["id"]) as? String, !sessionID.isEmpty {
                checkpoint.sessionFingerprint = fingerprint("codex:\(sessionID)")
            }
        case "turn_context":
            checkpoint.model = payload["model"] as? String ?? checkpoint.model
        case "event_msg":
            guard payload["type"] as? String == "token_count",
                  let sessionFingerprint = checkpoint.sessionFingerprint,
                  let info = payload["info"] as? [String: Any],
                  let total = info["total_token_usage"] as? [String: Any] else { return }
            let totals = tokenCounts(from: total)
            let delta = totals.subtracting(checkpoint.cumulativeTokens)
            checkpoint.cumulativeTokens = totals
            guard delta.hasTokens else { return }
            records.append(CodexUsageRecord(
                sessionFingerprint: sessionFingerprint,
                observedAt: date(from: object["timestamp"]) ?? now,
                model: checkpoint.model,
                tokens: delta
            ))
        default:
            return
        }
    }

    private func tokenCounts(from object: [String: Any]) -> UsageTokenCounts {
        func token(_ key: String) -> Int? {
            guard let number = object[key] as? NSNumber else { return nil }
            return max(0, number.intValue)
        }
        return UsageTokenCounts(
            input: token("input_tokens"),
            output: token("output_tokens"),
            cachedInput: token("cached_input_tokens"),
            cacheWriteInput: token("cache_write_input_tokens"),
            reasoning: token("reasoning_output_tokens")
        )
    }

    private func date(from value: Any?) -> Date? {
        guard let value = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}

private extension UsageTokenCounts {
    func subtracting(_ previous: UsageTokenCounts) -> UsageTokenCounts {
        func difference(_ current: Int?, _ previous: Int?) -> Int? {
            guard let current else { return nil }
            return max(0, current - (previous ?? 0))
        }
        return UsageTokenCounts(
            input: difference(input, previous.input),
            output: difference(output, previous.output),
            cachedInput: difference(cachedInput, previous.cachedInput),
            cacheWriteInput: difference(cacheWriteInput, previous.cacheWriteInput),
            reasoning: difference(reasoning, previous.reasoning)
        )
    }

    var hasTokens: Bool {
        [input, output, cachedInput, cacheWriteInput, reasoning].contains { ($0 ?? 0) > 0 }
    }
}
