import CryptoKit
import Foundation

public enum DeveloperToolIntegrationLimits {
    public static let maximumEventBytes = 64 * 1024
    public static let maximumExternalSessionIDLength = 512
    public static let maximumPathLength = 4 * 1024
    public static let maximumMetadataLength = 256
    public static let maximumEventAge: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumFutureSkew: TimeInterval = 5 * 60
    public static let maximumContextsPerSession = 64
    public static let maximumEventsPerContext = 100_000
}

public enum DeveloperToolEventValidationError: Error, Equatable {
    case eventTooLarge
    case unsupportedSchemaVersion(Int)
    case emptyExternalSessionID
    case externalSessionIDTooLong
    case invalidWorkingDirectory
    case metadataTooLong
    case invalidMetadata
    case timestampTooOld
    case timestampInFuture
    case unknownEventType
}

public enum DeveloperToolEventValidator {
    public static func sanitized(
        _ event: DeveloperToolEvent,
        now: Date = Date()
    ) throws -> DeveloperToolEvent {
        guard event.schemaVersion == DeveloperToolEvent.currentSchemaVersion else {
            throw DeveloperToolEventValidationError.unsupportedSchemaVersion(event.schemaVersion)
        }

        let externalSessionID = event.externalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !externalSessionID.isEmpty else {
            throw DeveloperToolEventValidationError.emptyExternalSessionID
        }
        guard externalSessionID.count <= DeveloperToolIntegrationLimits.maximumExternalSessionIDLength else {
            throw DeveloperToolEventValidationError.externalSessionIDTooLong
        }
        guard isSafeString(externalSessionID) else {
            throw DeveloperToolEventValidationError.invalidMetadata
        }

        guard let workingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(
            for: event.workingDirectory
        ), workingDirectory.count <= DeveloperToolIntegrationLimits.maximumPathLength else {
            throw DeveloperToolEventValidationError.invalidWorkingDirectory
        }

        let model = try sanitizeMetadata(event.model)
        let profile = try sanitizeMetadata(event.profile)

        let age = now.timeIntervalSince(event.timestamp)
        guard age <= DeveloperToolIntegrationLimits.maximumEventAge else {
            throw DeveloperToolEventValidationError.timestampTooOld
        }
        guard age >= -DeveloperToolIntegrationLimits.maximumFutureSkew else {
            throw DeveloperToolEventValidationError.timestampInFuture
        }

        guard event.eventType != .unknown else {
            throw DeveloperToolEventValidationError.unknownEventType
        }

        return DeveloperToolEvent(
            schemaVersion: event.schemaVersion,
            id: event.id,
            tool: event.tool,
            externalSessionID: externalSessionID,
            eventType: event.eventType,
            timestamp: event.timestamp,
            workingDirectory: workingDirectory,
            model: model,
            profile: profile
        )
    }

    public static func validateEncodedData(_ data: Data, now: Date = Date()) throws -> DeveloperToolEvent {
        guard data.count <= DeveloperToolIntegrationLimits.maximumEventBytes else {
            throw DeveloperToolEventValidationError.eventTooLarge
        }
        let event = try DeveloperToolEventCodec.decode(data)
        return try sanitized(event, now: now)
    }

    private static func sanitizeMetadata(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count <= DeveloperToolIntegrationLimits.maximumMetadataLength else {
            throw DeveloperToolEventValidationError.metadataTooLong
        }
        guard isSafeString(trimmed) else {
            throw DeveloperToolEventValidationError.invalidMetadata
        }
        return trimmed
    }

    private static func isSafeString(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

public enum DeveloperToolEventID {
    public static func stable(
        tool: DeveloperTool,
        externalSessionID: String,
        eventType: DeveloperToolEventType,
        workingDirectory: String,
        discriminator: String
    ) -> UUID {
        let seed = [
            tool.rawValue,
            externalSessionID,
            eventType.rawValue,
            workingDirectory,
            discriminator
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
