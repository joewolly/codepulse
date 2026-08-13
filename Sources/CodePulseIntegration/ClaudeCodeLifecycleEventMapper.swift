import Foundation

/// Maps documented Claude Code hooks into the content-safe v2 contract. The
/// hook payload can include prompt text, transcript paths, tool input, and tool
/// responses; none are modeled or forwarded by this decoder.
public enum ClaudeCodeLifecycleEventMapper {
    public static let parserVersion = "claude-code-hooks-v1"

    public static func map(_ data: Data, observedAt: Date = Date()) -> DeveloperEventV2? {
        guard let payload = try? JSONDecoder().decode(HookPayload.self, from: data),
              let eventKind = payload.eventKind,
              let workingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(for: payload.cwd) else {
            return nil
        }

        let externalSessionKey = payload.agentID ?? payload.sessionID
        let idempotencyKey = DeveloperToolEventID.stable(
            tool: .claudeCode,
            externalSessionID: externalSessionKey,
            eventType: .activity,
            workingDirectory: workingDirectory,
            discriminator: [payload.hookEventName, payload.turnID ?? "", payload.agentID ?? ""].joined(separator: "\u{1F}")
        ).uuidString.lowercased()

        return DeveloperEventV2(
            integration: .claudeCode,
            eventKind: eventKind,
            observedAt: observedAt,
            idempotencyKey: idempotencyKey,
            externalSessionKey: externalSessionKey,
            parentSessionKey: payload.agentID == nil ? nil : payload.sessionID,
            workingDirectory: workingDirectory,
            model: payload.model,
            effort: payload.effort?.level,
            serviceMode: payload.permissionMode,
            parserVersion: parserVersion,
            integrationVersion: payload.claudeCodeVersion ?? "unknown",
            metadata: DeveloperEventMetadataV2(
                sourceKind: payload.hookEventName,
                transcriptAvailable: payload.transcriptPath != nil
            )
        )
    }

    private struct HookPayload: Decodable {
        let sessionID: String
        let cwd: String
        let hookEventName: String
        let model: String?
        let permissionMode: String?
        let turnID: String?
        let agentID: String?
        let claudeCodeVersion: String?
        let effort: Effort?
        let transcriptPath: String?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd, model, effort
            case hookEventName = "hook_event_name"
            case permissionMode = "permission_mode"
            case turnID = "turn_id"
            case agentID = "agent_id"
            case claudeCodeVersion = "claude_code_version"
            case transcriptPath = "transcript_path"
        }

        struct Effort: Decodable { let level: String? }

        var eventKind: DeveloperEventKindV2? {
            switch hookEventName {
            case "SessionStart", "SubagentStart": return .sessionStarted
            case "UserPromptSubmit", "PostToolUse": return .activityObserved
            case "PermissionRequest": return .permissionRequested
            case "Stop", "SubagentStop": return .sessionStopped
            case "SessionEnd": return .sessionEnded
            default: return nil
            }
        }
    }
}
