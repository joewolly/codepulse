import Foundation

/// Content-safe usage event emitted by the CodePulse-owned OpenCode plugin.
/// The plugin omits messages, prompts, tool payloads, and file content.
public struct OpenCodeUsageEvent: Codable, Equatable {
    public let sessionID: String
    public let workingDirectory: String
    public let messageID: String
    public let observedAt: Date
    public let model: String?
    public let provider: String?
    public let serviceMode: String?
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let reasoningTokens: Int?
    public let providerReportedCost: Decimal?
    public let pluginVersion: String

    public init(
        sessionID: String,
        workingDirectory: String,
        messageID: String,
        observedAt: Date,
        model: String? = nil,
        provider: String? = nil,
        serviceMode: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        providerReportedCost: Decimal? = nil,
        pluginVersion: String
    ) {
        self.sessionID = sessionID
        self.workingDirectory = workingDirectory
        self.messageID = messageID
        self.observedAt = observedAt
        self.model = model
        self.provider = provider
        self.serviceMode = serviceMode
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
        self.providerReportedCost = providerReportedCost
        self.pluginVersion = pluginVersion
    }
}

public enum OpenCodeUsageInboxError: Error, Equatable {
    case unsafePath
    case eventTooLarge
    case invalidEvent
    case cannotReadEvent
}

/// The usage handoff is independent from lifecycle events so malformed or
/// unsupported usage data never changes activity timing.
public final class OpenCodeUsageInbox {
    public let paths: DeveloperToolIntegrationPaths
    private let fileManager: FileManager
    private let maximumFiles: Int
    private let maximumBytes: Int

    public init(
        paths: DeveloperToolIntegrationPaths = .default(),
        fileManager: FileManager = .default,
        maximumFiles: Int = DeveloperToolIntegrationLimits.maximumInboxFiles,
        maximumBytes: Int = DeveloperToolIntegrationLimits.maximumInboxBytes
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.maximumFiles = max(1, maximumFiles)
        self.maximumBytes = max(DeveloperToolIntegrationLimits.maximumEventBytes, maximumBytes)
    }

    public func write(_ event: OpenCodeUsageEvent) throws {
        try validate(event)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        guard data.count <= DeveloperToolIntegrationLimits.maximumEventBytes else {
            throw OpenCodeUsageInboxError.eventTooLarge
        }
        guard !containsSymbolicLink(paths.openCodeUsageInboxURL) else { throw OpenCodeUsageInboxError.unsafePath }
        try fileManager.createDirectory(at: paths.openCodeUsageInboxURL, withIntermediateDirectories: true)
        try ensureCapacity(incomingBytes: data.count)
        let target = paths.openCodeUsageInboxURL.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        guard !isSymbolicLink(target) else { throw OpenCodeUsageInboxError.unsafePath }
        try data.write(to: target, options: .atomic)
    }

    public func pendingEventURLs() -> [URL] {
        guard !containsSymbolicLink(paths.openCodeUsageInboxURL),
              let urls = try? fileManager.contentsOfDirectory(
                at: paths.openCodeUsageInboxURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls.filter { url in
            guard url.pathExtension.lowercased() == "json",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(DeveloperToolIntegrationLimits.maximumPendingEventsPerScan)
        .map { $0 }
    }

    public func read(from url: URL) throws -> OpenCodeUsageEvent {
        guard !containsSymbolicLink(paths.openCodeUsageInboxURL), isInboxFile(url),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= DeveloperToolIntegrationLimits.maximumEventBytes,
              let data = try? Data(contentsOf: url) else {
            throw OpenCodeUsageInboxError.cannotReadEvent
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(OpenCodeUsageEvent.self, from: data)
        try validate(event)
        return event
    }

    @discardableResult
    public func remove(_ url: URL) -> Bool {
        guard !containsSymbolicLink(paths.openCodeUsageInboxURL), isInboxFile(url) else { return false }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch { return false }
    }

    private func validate(_ event: OpenCodeUsageEvent) throws {
        guard !event.sessionID.isEmpty,
              !event.messageID.isEmpty,
              DeveloperToolProjectPathMatcher.canonicalPath(for: event.workingDirectory) != nil,
              !event.pluginVersion.isEmpty else { throw OpenCodeUsageInboxError.invalidEvent }
        let counts = [event.inputTokens, event.outputTokens, event.cacheReadTokens, event.cacheWriteTokens, event.reasoningTokens]
        guard counts.contains(where: { ($0 ?? 0) > 0 }),
              counts.allSatisfy({ value in
                  guard let value else { return true }
                  return value >= 0 && value <= DeveloperToolIntegrationLimits.maximumUsageTokensPerField
              }),
              counts.reduce(into: 0, { total, value in total += value ?? 0 }) <= DeveloperToolIntegrationLimits.maximumUsageTokensPerSample,
              event.providerReportedCost.map({ $0 >= 0 && $0 <= DeveloperToolIntegrationLimits.maximumUsageReportedCostUSD }) ?? true else {
            throw OpenCodeUsageInboxError.invalidEvent
        }
    }

    private func ensureCapacity(incomingBytes: Int) throws {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: paths.openCodeUsageInboxURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ), urls.count < maximumFiles else {
            throw OpenCodeUsageInboxError.eventTooLarge
        }
        var total = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true else {
                throw OpenCodeUsageInboxError.unsafePath
            }
            if values.isRegularFile == true {
                total += values.fileSize ?? 0
                guard total <= maximumBytes else { throw OpenCodeUsageInboxError.eventTooLarge }
            }
        }
        guard incomingBytes <= maximumBytes - total else { throw OpenCodeUsageInboxError.eventTooLarge }
    }

    private func isInboxFile(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == paths.openCodeUsageInboxURL.standardizedFileURL && !isSymbolicLink(url)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    private func containsSymbolicLink(_ url: URL) -> Bool {
        var current = url
        let managedRoot = paths.rootURL.standardizedFileURL
        let managedParent = managedRoot.deletingLastPathComponent()
        while true {
            if isSymbolicLink(current) { return true }
            if current.standardizedFileURL == managedParent { return false }
            current.deleteLastPathComponent()
        }
    }
}
