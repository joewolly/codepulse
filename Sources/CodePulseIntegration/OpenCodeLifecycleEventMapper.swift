import Foundation

/// Maps the content-free records emitted by CodePulse's OpenCode plugin into
/// the shared v2 lifecycle contract. The plugin never forwards raw OpenCode
/// event payloads to this mapper.
public enum OpenCodeLifecycleEventMapper {
    public static let parserVersion = "opencode-plugin-v1"

    public static func map(_ data: Data, observedAt: Date = Date()) -> DeveloperEventV2? {
        guard let payload = try? JSONDecoder().decode(PluginPayload.self, from: data),
              let eventKind = payload.eventKind,
              let workingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(for: payload.cwd) else {
            return nil
        }

        let idempotencyKey = DeveloperToolEventID.stable(
            tool: .opencode,
            externalSessionID: payload.sessionID,
            eventType: .activity,
            workingDirectory: workingDirectory,
            discriminator: "\(payload.eventType)\u{1F}\(payload.sequence)"
        ).uuidString.lowercased()

        return DeveloperEventV2(
            integration: .openCode,
            eventKind: eventKind,
            observedAt: observedAt,
            idempotencyKey: idempotencyKey,
            externalSessionKey: payload.sessionID,
            workingDirectory: workingDirectory,
            model: payload.model,
            serviceMode: payload.agent,
            parserVersion: parserVersion,
            integrationVersion: payload.pluginVersion,
            metadata: DeveloperEventMetadataV2(
                eventSequence: payload.sequence,
                sourceKind: payload.eventType,
                actionCategory: payload.eventType == "activity.observed" ? .codeChange : nil
            )
        )
    }

    private struct PluginPayload: Decodable {
        let eventType: String
        let sessionID: String
        let cwd: String
        let model: String?
        let agent: String?
        let sequence: Int
        let pluginVersion: String

        private enum CodingKeys: String, CodingKey {
            case eventType = "event_type"
            case sessionID = "session_id"
            case cwd, model, agent, sequence
            case pluginVersion = "plugin_version"
        }

        var eventKind: DeveloperEventKindV2? {
            switch eventType {
            case "session.started": return .sessionStarted
            case "activity.observed": return .activityObserved
            case "session.idle": return .sessionIdle
            case "session.ended": return .sessionEnded
            case "integration.error": return .integrationError
            default: return nil
            }
        }
    }
}
