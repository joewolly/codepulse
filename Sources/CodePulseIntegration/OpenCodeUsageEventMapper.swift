import Foundation

/// Decodes only the allowlisted record created by CodePulse's managed plugin.
/// It never accepts a raw OpenCode message object.
public enum OpenCodeUsageEventMapper {
    public static let parserVersion = "opencode-usage-plugin-v1"

    public static func map(_ data: Data, observedAt: Date = Date()) -> OpenCodeUsageEvent? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.eventType == "usage.recorded",
              let workingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(for: payload.cwd),
              !payload.sessionID.isEmpty,
              !payload.messageID.isEmpty,
              payload.tokens.hasTokens else { return nil }
        return OpenCodeUsageEvent(
            sessionID: payload.sessionID,
            workingDirectory: workingDirectory,
            messageID: payload.messageID,
            observedAt: payload.observedAt ?? observedAt,
            model: payload.model,
            provider: payload.provider,
            serviceMode: payload.serviceMode,
            inputTokens: payload.tokens.input,
            outputTokens: payload.tokens.output,
            cacheReadTokens: payload.tokens.cacheRead,
            cacheWriteTokens: payload.tokens.cacheWrite,
            reasoningTokens: payload.tokens.reasoning,
            providerReportedCost: payload.costUSD,
            pluginVersion: payload.pluginVersion
        )
    }

    private struct Payload: Decodable {
        let eventType: String
        let sessionID: String
        let cwd: String
        let messageID: String
        let observedAt: Date?
        let model: String?
        let provider: String?
        let serviceMode: String?
        let tokens: Tokens
        let costUSD: Decimal?
        let pluginVersion: String

        enum CodingKeys: String, CodingKey {
            case eventType = "event_type"
            case sessionID = "session_id"
            case cwd
            case messageID = "message_id"
            case observedAt = "observed_at"
            case model, provider
            case serviceMode = "service_mode"
            case tokens
            case costUSD = "cost_usd"
            case pluginVersion = "plugin_version"
        }
    }

    private struct Tokens: Decodable {
        let input: Int?
        let output: Int?
        let cacheRead: Int?
        let cacheWrite: Int?
        let reasoning: Int?

        enum CodingKeys: String, CodingKey {
            case input, output, reasoning
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }

        var hasTokens: Bool { [input, output, cacheRead, cacheWrite, reasoning].contains { ($0 ?? 0) > 0 } }
    }
}
