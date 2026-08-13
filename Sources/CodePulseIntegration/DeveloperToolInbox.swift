import Foundation

public struct DeveloperToolIntegrationPaths: Equatable, Sendable {
    public let rootURL: URL
    public let inboxURL: URL
    public let eventV2InboxURL: URL
    public let eventV2ReceiptURL: URL
    public let openCodeUsageInboxURL: URL
    public let eventV2FingerprintSaltURL: URL

    public init(applicationSupportDirectory: URL = DeveloperToolIntegrationPaths.defaultApplicationSupportDirectory()) {
        let rootURL = applicationSupportDirectory
            .appendingPathComponent("CodePulse", isDirectory: true)
            .appendingPathComponent("Integrations", isDirectory: true)
        self.rootURL = rootURL
        self.inboxURL = rootURL.appendingPathComponent("Inbox", isDirectory: true)
        self.eventV2InboxURL = rootURL.appendingPathComponent("InboxV2", isDirectory: true)
        self.eventV2ReceiptURL = rootURL.appendingPathComponent("InboxV2Receipts", isDirectory: true)
        self.openCodeUsageInboxURL = rootURL.appendingPathComponent("OpenCodeUsageInbox", isDirectory: true)
        self.eventV2FingerprintSaltURL = rootURL.appendingPathComponent("event-v2-fingerprint-salt", isDirectory: false)
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

public enum DeveloperEventV2InboxError: Error, Equatable {
    case unsafePath
    case eventTooLarge
    case inboxFull
    case cannotReadEvent
}

public enum DeveloperEventV2Receipt: Equatable {
    case accepted
    case duplicate
}

/// Local receiver boundary for v2. Validation happens before a file enters
/// CodePulse-owned storage, and the idempotency key becomes a non-reversible
/// filename fingerprint rather than stored event content.
public final class DeveloperEventV2Inbox {
    public let paths: DeveloperToolIntegrationPaths
    private let fileManager: FileManager
    private let fingerprintSalt: Data

    public init(
        paths: DeveloperToolIntegrationPaths = .default(),
        fileManager: FileManager = .default,
        fingerprintSalt: Data? = nil
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.fingerprintSalt = fingerprintSalt ?? Self.loadOrCreateFingerprintSalt(
            at: paths.eventV2FingerprintSaltURL,
            fileManager: fileManager
        ) ?? Data(UUID().uuidString.utf8)
    }

    @discardableResult
    public func receive(
        _ data: Data,
        allowedIntegrations: Set<DeveloperEventIntegration> = Set(DeveloperEventIntegration.allCases),
        now: Date = Date()
    ) throws -> DeveloperEventV2Receipt {
        do {
            let event = try DeveloperEventV2Validator.validateEncodedData(
                data,
                allowedIntegrations: allowedIntegrations,
                now: now
            )
            let receipt = try writeValidated(event)
            try writeReceipt(DeveloperEventReceiptV2(
                receivedAt: now,
                status: receipt == .accepted ? .accepted : .duplicate,
                integration: event.integration,
                eventFingerprint: fingerprint(for: event.idempotencyKey),
                parserVersion: event.parserVersion,
                integrationVersion: event.integrationVersion
            ))
            return receipt
        } catch {
            // The input is never copied into diagnostics. Persist only a fixed
            // rejection category so every receiver outcome is auditable.
            try? writeReceipt(DeveloperEventReceiptV2(
                receivedAt: now,
                status: .rejected,
                rejectionCode: Self.redactedRejectionCode(for: error)
            ))
            throw error
        }
    }

    /// Records a receiver failure that occurred before a complete v2 envelope
    /// could be formed (for example a malformed legacy compatibility input).
    /// The caller supplies only a fixed, content-free category.
    public func recordRejected(now: Date = Date(), code: String = "invalid-event") {
        try? writeReceipt(DeveloperEventReceiptV2(
            receivedAt: now,
            status: .rejected,
            rejectionCode: code
        ))
    }

    @discardableResult
    private func writeValidated(_ event: DeveloperEventV2) throws -> DeveloperEventV2Receipt {
        let data = try DeveloperEventV2Codec.encode(event)
        guard data.count <= DeveloperToolIntegrationLimits.maximumEventBytes else {
            throw DeveloperEventV2InboxError.eventTooLarge
        }
        try ensureInboxDirectory()
        let target = paths.eventV2InboxURL.appendingPathComponent(
            "\(fingerprint(for: event.idempotencyKey)).json",
            isDirectory: false
        )
        guard !isSymbolicLink(target) else { throw DeveloperEventV2InboxError.unsafePath }
        guard !fileManager.fileExists(atPath: target.path) else { return .duplicate }
        try ensureInboxCapacity(incomingBytes: data.count)

        let temporary = paths.eventV2InboxURL.appendingPathComponent(
            ".\(UUID().uuidString).tmp", isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .atomic)
            do {
                try fileManager.moveItem(at: temporary, to: target)
                return .accepted
            } catch {
                if fileManager.fileExists(atPath: target.path) {
                    try? fileManager.removeItem(at: temporary)
                    return .duplicate
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    public func pendingEventURLs() -> [URL] {
        guard !managedPathContainsSymbolicLink(),
              let urls = try? fileManager.contentsOfDirectory(
                at: paths.eventV2InboxURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls.filter { url in
            guard url.pathExtension.lowercased() == "json" else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(DeveloperToolIntegrationLimits.maximumPendingEventsPerScan)
        .map { $0 }
    }

    public func pendingReceiptURLs() -> [URL] {
        managedJSONFiles(in: paths.eventV2ReceiptURL)
    }

    public func readEvent(from url: URL, now: Date = Date()) throws -> DeveloperEventV2 {
        guard !managedPathContainsSymbolicLink(), isInboxFile(url) else {
            throw DeveloperEventV2InboxError.unsafePath
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= DeveloperToolIntegrationLimits.maximumEventBytes else {
            throw DeveloperEventV2InboxError.eventTooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw DeveloperEventV2InboxError.cannotReadEvent }
        return try DeveloperEventV2Validator.validateEncodedData(data, now: now)
    }

    public func readReceipt(from url: URL) throws -> DeveloperEventReceiptV2 {
        guard !managedPathContainsSymbolicLink(paths.eventV2ReceiptURL), isReceiptFile(url) else {
            throw DeveloperEventV2InboxError.unsafePath
        }
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= DeveloperToolIntegrationLimits.maximumMetadataLength * 8,
              let data = try? Data(contentsOf: url) else {
            throw DeveloperEventV2InboxError.cannotReadEvent
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeveloperEventReceiptV2.self, from: data)
    }

    @discardableResult
    public func remove(_ url: URL) -> Bool {
        guard !managedPathContainsSymbolicLink(), (isInboxFile(url) || isReceiptFile(url)) else { return false }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func ensureInboxDirectory() throws {
        guard !managedPathContainsSymbolicLink() else { throw DeveloperEventV2InboxError.unsafePath }
        try fileManager.createDirectory(at: paths.eventV2InboxURL, withIntermediateDirectories: true)
    }

    private func writeReceipt(_ receipt: DeveloperEventReceiptV2) throws {
        guard !managedPathContainsSymbolicLink(paths.eventV2ReceiptURL) else { throw DeveloperEventV2InboxError.unsafePath }
        try fileManager.createDirectory(at: paths.eventV2ReceiptURL, withIntermediateDirectories: true)
        let existing = managedJSONFiles(in: paths.eventV2ReceiptURL)
        if existing.count >= DeveloperToolIntegrationLimits.maximumInboxFiles {
            for url in existing.prefix(existing.count - DeveloperToolIntegrationLimits.maximumInboxFiles + 1) {
                try? fileManager.removeItem(at: url)
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(receipt)
        let target = paths.eventV2ReceiptURL.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
        try data.write(to: target, options: .atomic)
    }

    private func ensureInboxCapacity(incomingBytes: Int) throws {
        guard !managedPathContainsSymbolicLink() else { throw DeveloperEventV2InboxError.unsafePath }
        guard let urls = try? fileManager.contentsOfDirectory(
            at: paths.eventV2InboxURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ), urls.count < DeveloperToolIntegrationLimits.maximumInboxFiles else {
            throw DeveloperEventV2InboxError.inboxFull
        }
        var total = 0
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  values.isSymbolicLink != true else { throw DeveloperEventV2InboxError.unsafePath }
            if values.isRegularFile == true {
                total += values.fileSize ?? 0
                guard total <= DeveloperToolIntegrationLimits.maximumInboxBytes else {
                    throw DeveloperEventV2InboxError.inboxFull
                }
            }
        }
        guard incomingBytes <= DeveloperToolIntegrationLimits.maximumInboxBytes - total else {
            throw DeveloperEventV2InboxError.inboxFull
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    public func fingerprint(for idempotencyKey: String) -> String {
        DeveloperEventV2Fingerprint.make(for: idempotencyKey, salt: fingerprintSalt)
    }

    private func managedJSONFiles(in directory: URL) -> [URL] {
        guard !managedPathContainsSymbolicLink(directory),
              let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls.filter { url in
            guard url.pathExtension.lowercased() == "json" else { return false }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            return values?.isRegularFile == true && values?.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .prefix(DeveloperToolIntegrationLimits.maximumPendingEventsPerScan)
        .map { $0 }
    }

    private func managedPathContainsSymbolicLink(_ target: URL? = nil) -> Bool {
        let managedBase = paths.rootURL.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL
        var current = (target ?? paths.eventV2InboxURL).standardizedFileURL
        while true {
            if isSymbolicLink(current) { return true }
            if current == managedBase { return false }
            let parent = current.deletingLastPathComponent()
            if parent == current { return false }
            current = parent
        }
    }

    private func isInboxFile(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            == paths.eventV2InboxURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func isReceiptFile(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        return url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
            == paths.eventV2ReceiptURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func redactedRejectionCode(for error: Error) -> String {
        switch error {
        case is DeveloperEventV2ValidationError: return "validation-rejected"
        case is DeveloperEventV2Codec.Error: return "schema-rejected"
        case is DeveloperEventV2InboxError: return "inbox-rejected"
        default: return "invalid-event"
        }
    }

    private static func loadOrCreateFingerprintSalt(at url: URL, fileManager: FileManager) -> Data? {
        if let data = try? Data(contentsOf: url), data.count >= 32 { return data }
        let directory = url.deletingLastPathComponent()
        guard !((try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true) else { return nil }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let salt = Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            try salt.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return salt
        } catch {
            return nil
        }
    }
}

public enum DeveloperToolInboxError: Error, Equatable {
    case unsafePath
    case eventTooLarge
    case inboxFull
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
        try ensureInboxCapacity(incomingBytes: data.count)

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
        guard !managedPathContainsSymbolicLink() else { return [] }
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
        guard !managedPathContainsSymbolicLink(), isInboxFile(url) else {
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

    @discardableResult
    public func remove(_ url: URL) -> Bool {
        guard !managedPathContainsSymbolicLink(), isInboxFile(url) else { return false }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func ensureInboxDirectory() throws {
        guard !managedPathContainsSymbolicLink() else {
            throw DeveloperToolInboxError.unsafePath
        }
        try fileManager.createDirectory(at: paths.inboxURL, withIntermediateDirectories: true)
    }

    private func ensureInboxCapacity(incomingBytes: Int) throws {
        guard !managedPathContainsSymbolicLink() else {
            throw DeveloperToolInboxError.unsafePath
        }

        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: paths.inboxURL,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: []
            )
        } catch {
            throw DeveloperToolInboxError.inboxFull
        }

        guard urls.count < DeveloperToolIntegrationLimits.maximumInboxFiles else {
            throw DeveloperToolInboxError.inboxFull
        }

        var totalBytes = 0
        for url in urls {
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            ) else {
                throw DeveloperToolInboxError.inboxFull
            }
            guard values.isSymbolicLink != true else {
                throw DeveloperToolInboxError.unsafePath
            }
            if values.isRegularFile == true {
                guard let fileSize = values.fileSize, fileSize <= DeveloperToolIntegrationLimits.maximumInboxBytes else {
                    throw DeveloperToolInboxError.inboxFull
                }
                totalBytes += fileSize
                guard totalBytes <= DeveloperToolIntegrationLimits.maximumInboxBytes else {
                    throw DeveloperToolInboxError.inboxFull
                }
            }
        }

        guard incomingBytes <= DeveloperToolIntegrationLimits.maximumInboxBytes - totalBytes else {
            throw DeveloperToolInboxError.inboxFull
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private func managedPathContainsSymbolicLink() -> Bool {
        let managedBase = paths.rootURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL
        var current = paths.inboxURL.standardizedFileURL

        while true {
            if isSymbolicLink(current) {
                return true
            }
            if current == managedBase {
                return false
            }
            let parent = current.deletingLastPathComponent()
            if parent == current {
                return false
            }
            current = parent
        }
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
