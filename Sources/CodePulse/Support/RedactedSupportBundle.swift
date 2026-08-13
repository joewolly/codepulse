import CodePulseIntegration
import Foundation

/// A local troubleshooting artifact. Its schema is intentionally separate from
/// the full backup codec so it cannot accidentally include user-entered text,
/// paths, session fingerprints, or raw integration payloads.
struct RedactedSupportBundle: Codable, Equatable {
    static let format = "codepulse-redacted-support-bundle"
    static let currentVersion = 1

    struct IntegrationSummary: Codable, Equatable {
        let integration: String
        let agentRunCount: Int
        let usageSampleCount: Int
        let diagnosticCounts: [String: Int]
        let usageTrackingEnabled: Bool
        let adapterStatus: String?
    }

    let format: String
    let version: Int
    let createdAt: Date
    let stateSchemaVersion: Int
    let workspaceCount: Int
    let activityCount: Int
    let manualRunCount: Int
    let agentRunCount: Int
    let integrationSummaries: [IntegrationSummary]
    let persistenceRecoveryKind: String?
}

enum RedactedSupportBundleCodec {
    static func make(
        state: AppState,
        createdAt: Date,
        persistenceRecoveryIssue: PersistenceRecoveryIssue? = nil
    ) -> RedactedSupportBundle {
        let summaries = DeveloperTool.allCases.map { tool in
            let diagnosticCounts = Dictionary(grouping: state.developerEventDiagnostics?.entries.filter {
                $0.integration == tool.rawValue
            } ?? [], by: { $0.status.rawValue })
                .mapValues(\.count)
            let enabled: Bool
            let adapterStatus: String?
            switch tool {
            case .codex:
                enabled = state.settings.codexUsageTrackingEnabled
                adapterStatus = state.codexUsageProcessing == nil ? nil : "checkpointing"
            case .claudeCode:
                enabled = state.settings.claudeUsageTrackingEnabled
                adapterStatus = state.claudeUsageProcessing == nil ? nil : "checkpointing"
            case .opencode:
                enabled = state.settings.openCodeUsageTrackingEnabled
                adapterStatus = state.openCodeUsageProcessing?.status.rawValue
            }
            return RedactedSupportBundle.IntegrationSummary(
                integration: tool.rawValue,
                agentRunCount: state.activityGraph.runs.filter { $0.agentMetadata?.integration.rawValue == tool.rawValue }.count,
                usageSampleCount: state.usageSamples.filter { $0.integration == tool }.count,
                diagnosticCounts: diagnosticCounts,
                usageTrackingEnabled: enabled,
                adapterStatus: adapterStatus
            )
        }
        return RedactedSupportBundle(
            format: RedactedSupportBundle.format,
            version: RedactedSupportBundle.currentVersion,
            createdAt: createdAt,
            stateSchemaVersion: StatePersistenceEnvelope.currentSchemaVersion,
            workspaceCount: state.activityGraph.workspaces.count,
            activityCount: state.activityGraph.activities.count,
            manualRunCount: state.activityGraph.runs.filter { $0.kind == .manual }.count,
            agentRunCount: state.activityGraph.runs.filter { $0.kind == .agent }.count,
            integrationSummaries: summaries,
            persistenceRecoveryKind: persistenceRecoveryIssue.map { String(describing: $0.kind) }
        )
    }

    static func encode(
        state: AppState,
        createdAt: Date,
        persistenceRecoveryIssue: PersistenceRecoveryIssue? = nil
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(make(state: state, createdAt: createdAt, persistenceRecoveryIssue: persistenceRecoveryIssue))
    }
}
