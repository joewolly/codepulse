import Foundation

public struct DeveloperToolIntegrationPaths: Equatable, Sendable {
    public let rootURL: URL
    public let inboxURL: URL

    public init(applicationSupportDirectory: URL = DeveloperToolIntegrationPaths.defaultApplicationSupportDirectory()) {
        let rootURL = applicationSupportDirectory
            .appendingPathComponent("CodePulse", isDirectory: true)
            .appendingPathComponent("Integrations", isDirectory: true)
        self.rootURL = rootURL
        self.inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
    }

    public static func `default`() -> DeveloperToolIntegrationPaths {
        DeveloperToolIntegrationPaths()
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

public enum DeveloperToolInboxError: Error, Equatable {
    case unsafePath
    case eventTooLarge
    case cannotReadEvent
}

public final class DeveloperToolInbox {
    public let paths: DeveloperToolIntegrationPaths
    private let fileManager: FileManager

    public init(
        paths: DeveloperToolIntegrationPaths = .default(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func write(_ event: DeveloperToolEvent) throws {
        let data = try DeveloperToolEventCodec.encode(event)
        guard data.count <= DeveloperToolIntegrationLimits.maximumEventBytes else {
            throw DeveloperToolInboxError.eventTooLarge
        }

        try ensureInboxDirectory()
        let filename = "\(event.id.uuidString.lowercased()).json"
        let target = paths.inboxURL.appendingPathComponent(filename, isDirectory: false)
        guard !isSymbolicLink(target) else {
            throw DeveloperToolInboxError.unsafePath
        }
        if fileManager.fileExists(atPath: target.path) {
            return
        }

        let temporary = paths.inboxURL.appendingPathComponent(
            ".\(event.id.uuidString.lowercased()).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .atomic)
            do {
                try fileManager.moveItem(at: temporary, to: target)
            } catch {
                if !fileManager.fileExists(atPath: target.path) {
                    throw error
                }
                try? fileManager.removeItem(at: temporary)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func pendingEventURLs() -> [URL] {
        guard !isSymbolicLink(paths.inboxURL) else { return [] }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: paths.inboxURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .filter { url in
                guard url.pathExtension.lowercased() == "json" else { return false }
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                return values?.isRegularFile == true && values?.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(DeveloperToolIntegrationLimits.maximumPendingEventsPerScan)
            .map { $0 }
    }

    public func readEvent(from url: URL, now: Date = Date()) throws -> DeveloperToolEvent {
        guard !isSymbolicLink(paths.inboxURL), isInboxFile(url) else {
            throw DeveloperToolInboxError.unsafePath
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= DeveloperToolIntegrationLimits.maximumEventBytes else {
            throw DeveloperToolInboxError.eventTooLarge
        }
        guard let data = try? Data(contentsOf: url) else {
            throw DeveloperToolInboxError.cannotReadEvent
        }
        return try DeveloperToolEventValidator.validateEncodedData(data, now: now)
    }

    public func remove(_ url: URL) {
        guard !isSymbolicLink(paths.inboxURL), isInboxFile(url) else { return }
        try? fileManager.removeItem(at: url)
    }

    private func ensureInboxDirectory() throws {
        guard !isSymbolicLink(paths.inboxURL) else {
            throw DeveloperToolInboxError.unsafePath
        }
        try fileManager.createDirectory(at: paths.inboxURL, withIntermediateDirectories: true)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private func isInboxFile(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        return url.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL == paths.inboxURL
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }
}
