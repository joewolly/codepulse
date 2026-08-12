import Foundation

public enum DeveloperTool: String, Codable, CaseIterable, Equatable, Hashable, Identifiable, Sendable {
    case codex
    case opencode

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .opencode:
            return "OpenCode"
        }
    }

    public var systemImage: String {
        switch self {
        case .codex:
            return "sparkles"
        case .opencode:
            return "terminal"
        }
    }
}

public enum DeveloperToolEventType: String, Codable, Equatable, Sendable {
    case sessionStarted
    case activity
    case sessionIdle
    case sessionEnded
    case error
    case unknown

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: rawValue) ?? .unknown
    }
}

public struct DeveloperToolEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let tool: DeveloperTool
    public let externalSessionID: String
    public let eventType: DeveloperToolEventType
    public let timestamp: Date
    public let workingDirectory: String
    public let model: String?
    public let profile: String?

    public init(
        schemaVersion: Int = DeveloperToolEvent.currentSchemaVersion,
        id: UUID = UUID(),
        tool: DeveloperTool,
        externalSessionID: String,
        eventType: DeveloperToolEventType,
        timestamp: Date,
        workingDirectory: String,
        model: String? = nil,
        profile: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.tool = tool
        self.externalSessionID = externalSessionID
        self.eventType = eventType
        self.timestamp = timestamp
        self.workingDirectory = workingDirectory
        self.model = model
        self.profile = profile
    }
}

public struct DeveloperToolSessionContext: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let tool: DeveloperTool
    public let externalSessionID: String
    public let workingDirectory: String

    public var firstActivityAt: Date
    public var lastActivityAt: Date
    public var model: String?
    public var profile: String?
    public var eventCount: Int
    public var endedAt: Date?

    public init(
        id: UUID = UUID(),
        tool: DeveloperTool,
        externalSessionID: String,
        workingDirectory: String,
        firstActivityAt: Date,
        lastActivityAt: Date,
        model: String? = nil,
        profile: String? = nil,
        eventCount: Int = 0,
        endedAt: Date? = nil
    ) {
        self.id = id
        self.tool = tool
        self.externalSessionID = externalSessionID
        self.workingDirectory = workingDirectory
        self.firstActivityAt = firstActivityAt
        self.lastActivityAt = lastActivityAt
        self.model = model
        self.profile = profile
        self.eventCount = eventCount
        self.endedAt = endedAt
    }

    public var displayName: String {
        var values = [tool.title]
        if let model, !model.isEmpty {
            values.append(model)
        }
        if let profile, !profile.isEmpty {
            values.append(profile)
        }
        return values.joined(separator: " · ")
    }
}

public enum DeveloperToolEventCodec {
    public static func encode(_ event: DeveloperToolEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }

    public static func decode(_ data: Data) throws -> DeveloperToolEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DeveloperToolEvent.self, from: data)
    }
}
