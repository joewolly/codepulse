import CodePulseIntegration

enum IntegrationsSectionKind: String, CaseIterable {
    case lifecycle
    case tokenUsage = "token-usage"
    case costDisplay = "cost-display"

    var rowIdentifierPrefix: String {
        switch self {
        case .lifecycle:
            return "lifecycle"
        case .tokenUsage:
            return "token-usage"
        case .costDisplay:
            return "cost-display"
        }
    }
}

struct IntegrationsToolRow: Identifiable, Equatable {
    let section: IntegrationsSectionKind
    let tool: DeveloperTool

    var id: String { "\(section.rawValue):\(tool.rawValue)" }

    var accessibilityIdentifier: String {
        "\(section.rowIdentifierPrefix)-\(tool.rawValue)"
    }
}

enum IntegrationsSettingsConfiguration {
    static let toolRowsBySection: [IntegrationsSectionKind: [IntegrationsToolRow]] = Dictionary(
        uniqueKeysWithValues: IntegrationsSectionKind.allCases.map { section in
            (section, DeveloperTool.allCases.map { IntegrationsToolRow(section: section, tool: $0) })
        }
    )

    static var lifecycleRows: [IntegrationsToolRow] {
        toolRowsBySection[.lifecycle] ?? []
    }

    static var tokenUsageRows: [IntegrationsToolRow] {
        toolRowsBySection[.tokenUsage] ?? []
    }

    static var costDisplayRows: [IntegrationsToolRow] {
        toolRowsBySection[.costDisplay] ?? []
    }
}
