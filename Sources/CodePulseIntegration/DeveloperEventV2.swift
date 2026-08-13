import CryptoKit
import Foundation

/// The content-safe event contract used by developer-tool adapters. It carries
/// lifecycle metadata only; prompts, transcripts, source files, commands, and
/// tool input/output are deliberately not representable by this type.
public enum DeveloperEventIntegration: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case codex
    case claudeCode = "claude-code"
    case openCode = "opencode"

    public var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claudeCode:
            return "Claude Code"
        case .openCode:
            return "OpenCode"
        }
    }
}

public enum DeveloperEventKindV2: String, Codable, CaseIterable, Equatable, Sendable {
    case sessionStarted = "session.started"
    case activityObserved = "activity.observed"
    case permissionRequested = "permission.requested"
    case sessionStopped = "session.stopped"
    case sessionIdle = "session.idle"
    case sessionEnded = "session.ended"
    case integrationError = "integration.error"
}

public enum DeveloperEventReceiptStatus: String, Codable, Equatable, Sendable {
    case accepted
    case duplicate
    case rejected
}

/// Closed, content-free categories that an adapter may attach to a lifecycle
/// event for local activity classification. They never contain a prompt,
/// command, file name, or tool payload.
public enum DeveloperEventActionCategory: String, Codable, CaseIterable, Equatable, Sendable {
    case codeChange
    case debugging
    case planning
    case review
    case research
    case fileOrganization
    case automation
    case administration
    case documentation
}

public enum DeveloperEventFileType: String, Codable, CaseIterable, Equatable, Sendable {
    case sourceCode
    case documentation
    case configuration
    case automation
}

/// A bounded, content-free handoff from the receiver to the app's durable
/// diagnostics journal. It intentionally has no event body, paths, or session
/// identifiers.
public struct DeveloperEventReceiptV2: Codable, Equatable, Sendable {
    public let receivedAt: Date
    public let status: DeveloperEventReceiptStatus
    public let integration: DeveloperEventIntegration?
    public let eventFingerprint: String?
    public let parserVersion: String?
    public let integrationVersion: String?
    public let rejectionCode: String?

    public init(
        receivedAt: Date,
        status: DeveloperEventReceiptStatus,
        integration: DeveloperEventIntegration? = nil,
        eventFingerprint: String? = nil,
        parserVersion: String? = nil,
        integrationVersion: String? = nil,
        rejectionCode: String? = nil
    ) {
        self.receivedAt = receivedAt
        self.status = status
        self.integration = integration
        self.eventFingerprint = eventFingerprint
        self.parserVersion = parserVersion
        self.integrationVersion = integrationVersion
        self.rejectionCode = rejectionCode
    }
}

/// Closed metadata fields that are useful for normalisation but cannot carry
/// arbitrary hook payloads.
public struct DeveloperEventMetadataV2: Codable, Equatable, Sendable {
    public let adapterVersion: String?
    public let eventSequence: Int?
    public let sourceKind: String?
    public let transcriptAvailable: Bool?
    public let actionCategory: DeveloperEventActionCategory?
    public let fileType: DeveloperEventFileType?

    public init(
        adapterVersion: String? = nil,
        eventSequence: Int? = nil,
        sourceKind: String? = nil,
        transcriptAvailable: Bool? = nil,
        actionCategory: DeveloperEventActionCategory? = nil,
        fileType: DeveloperEventFileType? = nil
    ) {
        self.adapterVersion = adapterVersion
        self.eventSequence = eventSequence
        self.sourceKind = sourceKind
        self.transcriptAvailable = transcriptAvailable
        self.actionCategory = actionCategory
        self.fileType = fileType
    }
}

public struct DeveloperEventV2: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let integration: DeveloperEventIntegration
    public let eventKind: DeveloperEventKindV2
    public let observedAt: Date
    public let idempotencyKey: String
    public let externalSessionKey: String
    public let parentSessionKey: String?
    public let workingDirectory: String
    public let model: String?
    public let effort: String?
    public let serviceMode: String?
    public let parserVersion: String
    public let integrationVersion: String
    public let metadata: DeveloperEventMetadataV2?

    public init(
        schemaVersion: Int = DeveloperEventV2.currentSchemaVersion,
        integration: DeveloperEventIntegration,
        eventKind: DeveloperEventKindV2,
        observedAt: Date,
        idempotencyKey: String,
        externalSessionKey: String,
        parentSessionKey: String? = nil,
        workingDirectory: String,
        model: String? = nil,
        effort: String? = nil,
        serviceMode: String? = nil,
        parserVersion: String,
        integrationVersion: String,
        metadata: DeveloperEventMetadataV2? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.integration = integration
        self.eventKind = eventKind
        self.observedAt = observedAt
        self.idempotencyKey = idempotencyKey
        self.externalSessionKey = externalSessionKey
        self.parentSessionKey = parentSessionKey
        self.workingDirectory = workingDirectory
        self.model = model
        self.effort = effort
        self.serviceMode = serviceMode
        self.parserVersion = parserVersion
        self.integrationVersion = integrationVersion
        self.metadata = metadata
    }
}

public enum DeveloperEventV2Codec {
    public enum Error: Swift.Error, Equatable {
        case invalidEnvelope
        case unexpectedField(String)
        case forbiddenField(String)
    }

    private static let allowedFields: Set<String> = [
        "schemaVersion", "integration", "eventKind", "observedAt", "idempotencyKey",
        "externalSessionKey", "parentSessionKey", "workingDirectory", "model", "effort",
        "serviceMode", "parserVersion", "integrationVersion", "metadata"
    ]
    private static let allowedMetadataFields: Set<String> = [
        "adapterVersion", "eventSequence", "sourceKind", "transcriptAvailable", "actionCategory", "fileType"
    ]
    private static let forbiddenFields: Set<String> = [
        "prompt", "transcript", "source", "sourceContent", "content", "message", "messages",
        "command", "arguments", "input", "output", "toolCall", "toolCalls", "fileContents"
    ]

    public static func encode(_ event: DeveloperEventV2) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }

    public static func decode(_ data: Data) throws -> DeveloperEventV2 {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw Error.invalidEnvelope
        }
        if let forbidden = dictionary.keys.first(where: { forbiddenFields.contains($0) }) {
            throw Error.forbiddenField(forbidden)
        }
        if let unexpected = dictionary.keys.first(where: { !allowedFields.contains($0) }) {
            throw Error.unexpectedField(unexpected)
        }
        if let rawMetadata = dictionary["metadata"] {
            guard let metadata = rawMetadata as? [String: Any] else { throw Error.invalidEnvelope }
            if let forbidden = metadata.keys.first(where: { forbiddenFields.contains($0) }) {
                throw Error.forbiddenField(forbidden)
            }
            if let unexpected = metadata.keys.first(where: { !allowedMetadataFields.contains($0) }) {
                throw Error.unexpectedField("metadata.\(unexpected)")
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeveloperEventV2.self, from: data)
    }
}

public enum DeveloperEventV2ValidationError: Swift.Error, Equatable {
    case eventTooLarge
    case unsupportedSchemaVersion(Int)
    case integrationNotAllowed(DeveloperEventIntegration)
    case invalidIdempotencyKey
    case emptyExternalSessionKey
    case externalSessionKeyTooLong
    case invalidParentSessionKey
    case invalidWorkingDirectory
    case metadataTooLong
    case invalidMetadata
    case invalidMetadataSequence
    case timestampTooOld
    case timestampInFuture
}

public enum DeveloperEventV2Validator {
    public static func sanitized(
        _ event: DeveloperEventV2,
        allowedIntegrations: Set<DeveloperEventIntegration> = Set(DeveloperEventIntegration.allCases),
        now: Date = Date()
    ) throws -> DeveloperEventV2 {
        guard event.schemaVersion == DeveloperEventV2.currentSchemaVersion else {
            throw DeveloperEventV2ValidationError.unsupportedSchemaVersion(event.schemaVersion)
        }
        guard allowedIntegrations.contains(event.integration) else {
            throw DeveloperEventV2ValidationError.integrationNotAllowed(event.integration)
        }
        guard isSafeIdempotencyKey(event.idempotencyKey) else {
            throw DeveloperEventV2ValidationError.invalidIdempotencyKey
        }
        let externalSessionKey = try sanitizeSessionKey(event.externalSessionKey, emptyError: .emptyExternalSessionKey)
        let parentSessionKey = try event.parentSessionKey.map { try sanitizeSessionKey($0, emptyError: .invalidParentSessionKey) }
        guard let workingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(for: event.workingDirectory),
              workingDirectory.count <= DeveloperToolIntegrationLimits.maximumPathLength else {
            throw DeveloperEventV2ValidationError.invalidWorkingDirectory
        }
        let model = try sanitizeMetadata(event.model)
        let effort = try sanitizeMetadata(event.effort)
        let serviceMode = try sanitizeMetadata(event.serviceMode)
        let parserVersion = try requiredMetadata(event.parserVersion)
        let integrationVersion = try requiredMetadata(event.integrationVersion)
        let metadata = try sanitize(event.metadata)
        let age = now.timeIntervalSince(event.observedAt)
        guard age <= DeveloperToolIntegrationLimits.maximumEventAge else {
            throw DeveloperEventV2ValidationError.timestampTooOld
        }
        guard age >= -DeveloperToolIntegrationLimits.maximumFutureSkew else {
            throw DeveloperEventV2ValidationError.timestampInFuture
        }
        return DeveloperEventV2(
            schemaVersion: event.schemaVersion,
            integration: event.integration,
            eventKind: event.eventKind,
            observedAt: event.observedAt,
            idempotencyKey: event.idempotencyKey,
            externalSessionKey: externalSessionKey,
            parentSessionKey: parentSessionKey,
            workingDirectory: workingDirectory,
            model: model,
            effort: effort,
            serviceMode: serviceMode,
            parserVersion: parserVersion,
            integrationVersion: integrationVersion,
            metadata: metadata
        )
    }

    public static func validateEncodedData(
        _ data: Data,
        allowedIntegrations: Set<DeveloperEventIntegration> = Set(DeveloperEventIntegration.allCases),
        now: Date = Date()
    ) throws -> DeveloperEventV2 {
        guard data.count <= DeveloperToolIntegrationLimits.maximumEventBytes else {
            throw DeveloperEventV2ValidationError.eventTooLarge
        }
        return try sanitized(DeveloperEventV2Codec.decode(data), allowedIntegrations: allowedIntegrations, now: now)
    }

    private static func sanitizeSessionKey(_ value: String, emptyError: DeveloperEventV2ValidationError) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw emptyError }
        guard value.count <= DeveloperToolIntegrationLimits.maximumExternalSessionIDLength else {
            throw DeveloperEventV2ValidationError.externalSessionKeyTooLong
        }
        guard isSafeString(value) else { throw DeveloperEventV2ValidationError.invalidMetadata }
        return value
    }

    private static func requiredMetadata(_ value: String) throws -> String {
        guard let sanitized = try sanitizeMetadata(value) else {
            throw DeveloperEventV2ValidationError.invalidMetadata
        }
        return sanitized
    }

    private static func sanitize(_ metadata: DeveloperEventMetadataV2?) throws -> DeveloperEventMetadataV2? {
        guard let metadata else { return nil }
        guard metadata.eventSequence.map({ $0 >= 0 }) ?? true else {
            throw DeveloperEventV2ValidationError.invalidMetadataSequence
        }
        return DeveloperEventMetadataV2(
            adapterVersion: try sanitizeMetadata(metadata.adapterVersion),
            eventSequence: metadata.eventSequence,
            sourceKind: try sanitizeMetadata(metadata.sourceKind),
            transcriptAvailable: metadata.transcriptAvailable,
            actionCategory: metadata.actionCategory,
            fileType: metadata.fileType
        )
    }

    private static func sanitizeMetadata(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= DeveloperToolIntegrationLimits.maximumMetadataLength else {
            throw DeveloperEventV2ValidationError.metadataTooLong
        }
        guard isSafeString(trimmed) else { throw DeveloperEventV2ValidationError.invalidMetadata }
        return trimmed
    }

    private static func isSafeIdempotencyKey(_ value: String) -> Bool {
        guard (16...256).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || "-_.:".unicodeScalars.contains(scalar)
        }
    }

    private static func isSafeString(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

public enum DeveloperEventV2Fingerprint {
    /// A diagnostics-safe identifier. An installation-specific secret prevents
    /// cross-installation correlation of a copied external idempotency key.
    public static func make(for idempotencyKey: String, salt: Data) -> String {
        let key = SymmetricKey(data: salt)
        let digest = HMAC<SHA256>.authenticationCode(for: Data(idempotencyKey.utf8), using: key)
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

public extension DeveloperEventV2 {
    /// Compatibility normalizer for the pre-roadmap hook contract. Existing
    /// installed Codex/OpenCode integrations enter the v2 pipeline here; new,
    /// richer per-tool mapping remains the responsibility of Features 05–07.
    init(legacy event: DeveloperToolEvent, parserVersion: String = "legacy-v1", integrationVersion: String = "legacy-v1") {
        self.init(
            integration: event.tool == .codex ? .codex : .openCode,
            eventKind: Self.eventKind(for: event.eventType),
            observedAt: event.timestamp,
            idempotencyKey: event.id.uuidString.lowercased(),
            externalSessionKey: event.externalSessionID,
            workingDirectory: event.workingDirectory,
            model: event.model,
            serviceMode: event.profile,
            parserVersion: parserVersion,
            integrationVersion: integrationVersion,
            metadata: DeveloperEventMetadataV2(sourceKind: "legacy-hook")
        )
    }

    private static func eventKind(for type: DeveloperToolEventType) -> DeveloperEventKindV2 {
        switch type {
        case .sessionStarted: return .sessionStarted
        case .activity: return .activityObserved
        case .sessionIdle: return .sessionIdle
        case .sessionEnded: return .sessionEnded
        case .error, .unknown: return .integrationError
        }
    }
}
