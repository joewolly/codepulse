import Foundation

/// Maps the supported Codex hook contract into the content-safe v2 envelope.
/// Codex can include prompt, transcript, tool, and command fields in hook
/// input; this decoder intentionally has no properties for any of them.
public enum CodexLifecycleEventMapper {
    public static let parserVersion = "codex-hooks-v1"

    public static func map(_ data: Data, observedAt: Date = Date()) -> DeveloperEventV2? {
        guard let payload = try? JSONDecoder().decode(HookPayload.self, from: data),
              let eventKind = payload.eventKind,
              let workingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(for: payload.cwd) else {
            return nil
        }

        let idempotencyKey = DeveloperToolEventID.stable(
            tool: .codex,
            externalSessionID: payload.sessionID,
            eventType: .activity,
            workingDirectory: workingDirectory,
            discriminator: [
                payload.hookEventName,
                payload.source ?? "",
                payload.turnID ?? "",
                payload.agentID ?? ""
            ].joined(separator: "\u{1F}")
        ).uuidString.lowercased()

        return DeveloperEventV2(
            integration: .codex,
            eventKind: eventKind,
            observedAt: observedAt,
            idempotencyKey: idempotencyKey,
            externalSessionKey: payload.sessionID,
            workingDirectory: workingDirectory,
            model: payload.model,
            serviceMode: payload.permissionMode,
            parserVersion: parserVersion,
            integrationVersion: payload.codexVersion ?? "unknown",
            metadata: DeveloperEventMetadataV2(
                sourceKind: payload.hookEventName,
                actionCategory: payload.actionCategory
            )
        )
    }

    private struct HookPayload: Decodable {
        let sessionID: String
        let cwd: String
        let model: String?
        let hookEventName: String
        let source: String?
        let turnID: String?
        let agentID: String?
        let permissionMode: String?
        let codexVersion: String?

        private enum CodingKeys: String, CodingKey {
            case sessionID = "session_id"
            case cwd, model, source
            case hookEventName = "hook_event_name"
            case turnID = "turn_id"
            case agentID = "agent_id"
            case permissionMode = "permission_mode"
            case codexVersion = "codex_version"
        }

        var eventKind: DeveloperEventKindV2? {
            switch hookEventName {
            case "SessionStart": return .sessionStarted
            case "UserPromptSubmit", "PostToolUse": return .activityObserved
            case "PermissionRequest": return .permissionRequested
            case "Stop": return .sessionStopped
            case "SessionEnd": return .sessionEnded
            default: return nil
            }
        }

        var actionCategory: DeveloperEventActionCategory? {
            switch hookEventName {
            case "PostToolUse": return .codeChange
            default: return nil
            }
        }
    }
}
