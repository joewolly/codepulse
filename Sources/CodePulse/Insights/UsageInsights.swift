import Foundation

/// The state shown in Insights is deliberately derived from the selected
/// report. A missing usage reader never makes locally recorded timing look
/// unavailable.
enum UsageInsightsDataState: Equatable {
    case noData
    case timingOnly
    case partialUsage
    case pricedUsage

    static func resolve(report: UsageAnalyticsReport) -> UsageInsightsDataState {
        let hasTiming = report.timing.manualActive > 0 || report.timing.agentRuntime > 0 ||
            report.timing.combinedWallActive > 0 || report.timing.agentWaiting > 0
        guard !report.samples.isEmpty else { return hasTiming ? .timingOnly : .noData }
        return report.costs.isEmpty ? .partialUsage : .pricedUsage
    }

    var title: String {
        switch self {
        case .noData: return "No local activity in this period"
        case .timingOnly: return "Timing is available; no usage samples were recorded"
        case .partialUsage: return "Usage is available; cost data is incomplete"
        case .pricedUsage: return "Timing, usage, and available cost representations are shown"
        }
    }
}

struct UsageInsightsDataQuality: Equatable {
    let state: UsageInsightsDataState
    let messages: [String]

    static func resolve(state: AppState, report: UsageAnalyticsReport) -> UsageInsightsDataQuality {
        var messages: [String] = []
        let viewState = UsageInsightsDataState.resolve(report: report)
        if !state.settings.codexUsageTrackingEnabled && !state.settings.claudeUsageTrackingEnabled && !state.settings.openCodeUsageTrackingEnabled {
            messages.append("Token readers are off. Enable one in Settings → Integrations to add optional local usage metadata.")
        }
        if state.settings.openCodeUsageTrackingEnabled,
           let status = state.openCodeUsageProcessing?.status,
           status != .healthy {
            let explanation: String
            switch status {
            case .waitingForPlugin: explanation = "OpenCode usage is waiting for the managed local plugin."
            case .unsupportedPluginVersion: explanation = "OpenCode usage is unavailable because the installed plugin event version is unsupported."
            case .malformedEvent: explanation = "OpenCode usage is unavailable until its next valid local plugin event."
            case .healthy: explanation = ""
            }
            if !explanation.isEmpty { messages.append(explanation) }
        }
        if !report.samples.isEmpty && report.costs.isEmpty {
            messages.append("No reported or calculated prices are available for these samples; token totals remain valid.")
        }
        return UsageInsightsDataQuality(state: viewState, messages: messages)
    }
}

enum UsageExportFormat: String, CaseIterable, Identifiable {
    case json
    case csv

    var id: String { rawValue }
    var fileExtension: String { rawValue }
}

enum UsageExportField: String, CaseIterable, Hashable, Identifiable {
    case workspace
    case activity
    case provider
    case model
    case effort
    case serviceMode

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .activity: return "Activity"
        case .provider: return "Provider"
        case .model: return "Model"
        case .effort: return "Effort"
        case .serviceMode: return "Service mode"
        }
    }
}

struct UsageExportOptions: Equatable {
    /// Context labels are opt-in. Paths, UUIDs, fingerprints, and raw source
    /// identifiers are never exportable through this format.
    var includedFields: Set<UsageExportField> = [.provider, .model, .effort, .serviceMode]

    func includes(_ field: UsageExportField) -> Bool { includedFields.contains(field) }
}

struct UsageExportDocument: Codable, Equatable {
    static let format = "codepulse-usage-export"
    static let currentVersion = 1

    let format: String
    let version: Int
    let exportedAt: Date
    let selectedRangeStart: Date
    let selectedRangeEnd: Date
    let fields: [String]
    let samples: [UsageExportSample]
}

struct UsageExportSample: Codable, Equatable {
    struct Cost: Codable, Equatable {
        let representation: String
        let label: String
        let currency: String
        let amount: String
        let catalogVersion: Int?
        let catalogOrigin: String?
        let calculationMethod: String?
    }

    let observedAt: Date
    let integration: String
    let inputTokens: Int
    let outputTokens: Int
    let cachedInputTokens: Int
    let cacheWriteInputTokens: Int
    let reasoningTokens: Int
    let totalTokens: Int
    let workspace: String?
    let activity: String?
    let provider: String?
    let model: String?
    let effort: String?
    let serviceMode: String?
    let costs: [Cost]
}

enum UsageExportError: LocalizedError, Equatable {
    case unsupportedFormat
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "This file is not a CodePulse usage export."
        case .unsupportedVersion(let version): return "This usage export uses unsupported version \(version)."
        }
    }
}

enum UsageExportCodec {
    static func document(
        report: UsageAnalyticsReport,
        exportedAt: Date,
        options: UsageExportOptions = UsageExportOptions()
    ) -> UsageExportDocument {
        UsageExportDocument(
            format: UsageExportDocument.format,
            version: UsageExportDocument.currentVersion,
            exportedAt: exportedAt,
            selectedRangeStart: report.interval.start,
            selectedRangeEnd: report.interval.end,
            fields: options.includedFields.map(\.rawValue).sorted(),
            samples: report.samples.map { sample in exportSample(sample, options: options) }
        )
    }

    static func jsonData(report: UsageAnalyticsReport, exportedAt: Date, options: UsageExportOptions = UsageExportOptions()) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document(report: report, exportedAt: exportedAt, options: options))
    }

    static func decodeJSON(_ data: Data) throws -> UsageExportDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(UsageExportDocument.self, from: data)
        guard document.format == UsageExportDocument.format else { throw UsageExportError.unsupportedFormat }
        guard document.version == UsageExportDocument.currentVersion else { throw UsageExportError.unsupportedVersion(document.version) }
        return document
    }

    static func csvData(report: UsageAnalyticsReport, exportedAt: Date, options: UsageExportOptions = UsageExportOptions()) -> Data {
        let document = document(report: report, exportedAt: exportedAt, options: options)
        let header = [
            "observed_at", "integration", "input_tokens", "output_tokens", "cached_input_tokens", "cache_write_input_tokens", "reasoning_tokens", "total_tokens",
            "cost_representation", "cost_label", "currency", "amount", "catalog_version", "catalog_origin", "calculation_method",
            "workspace", "activity", "provider", "model", "effort", "service_mode"
        ]
        var rows = [header.joined(separator: ",")]
        let formatter = ISO8601DateFormatter()
        for sample in document.samples {
            let costs = sample.costs.isEmpty ? [UsageExportSample.Cost(representation: "", label: "", currency: "", amount: "", catalogVersion: nil, catalogOrigin: nil, calculationMethod: nil)] : sample.costs
            for cost in costs {
                rows.append(csvRow([
                    formatter.string(from: sample.observedAt), sample.integration,
                    "\(sample.inputTokens)", "\(sample.outputTokens)", "\(sample.cachedInputTokens)", "\(sample.cacheWriteInputTokens)", "\(sample.reasoningTokens)", "\(sample.totalTokens)",
                    cost.representation, cost.label, cost.currency, cost.amount,
                    cost.catalogVersion.map(String.init) ?? "", cost.catalogOrigin ?? "", cost.calculationMethod ?? "",
                    sample.workspace ?? "", sample.activity ?? "", sample.provider ?? "", sample.model ?? "", sample.effort ?? "", sample.serviceMode ?? ""
                ]))
            }
        }
        return Data(rows.joined(separator: "\n").appending("\n").utf8)
    }

    private static func exportSample(_ attributed: UsageAttributedSample, options: UsageExportOptions) -> UsageExportSample {
        let sample = attributed.sample
        let tokens = sample.tokens
        let calculated = sample.calculatedCosts.map { cost in
            UsageExportSample.Cost(
                representation: cost.representation.rawValue,
                label: cost.representation.displayLabel,
                currency: cost.currency,
                amount: decimalString(cost.amount),
                catalogVersion: cost.provenance.catalogVersion,
                catalogOrigin: cost.provenance.catalogOrigin.rawValue,
                calculationMethod: cost.provenance.calculationMethod
            )
        }
        let reported = sample.providerReportedCost.map {
            UsageExportSample.Cost(
                representation: UsageCostRepresentation.providerReported.rawValue,
                label: UsageCostRepresentation.providerReported.displayLabel,
                currency: sample.providerReportedCurrency ?? "USD",
                amount: decimalString($0),
                catalogVersion: nil,
                catalogOrigin: nil,
                calculationMethod: "provider-reported"
            )
        }
        return UsageExportSample(
            observedAt: sample.observedAt,
            integration: sample.integration.rawValue,
            inputTokens: tokens.input ?? 0,
            outputTokens: tokens.output ?? 0,
            cachedInputTokens: tokens.cachedInput ?? 0,
            cacheWriteInputTokens: tokens.cacheWriteInput ?? 0,
            reasoningTokens: tokens.reasoning ?? 0,
            totalTokens: UsageTokenTotals(input: tokens.input ?? 0, output: tokens.output ?? 0, cachedInput: tokens.cachedInput ?? 0, cacheWriteInput: tokens.cacheWriteInput ?? 0, reasoning: tokens.reasoning ?? 0).total,
            workspace: options.includes(.workspace) ? attributed.workspace?.name : nil,
            activity: options.includes(.activity) ? attributed.activity?.title : nil,
            provider: options.includes(.provider) ? sample.provider : nil,
            model: options.includes(.model) ? sample.model : nil,
            effort: options.includes(.effort) ? sample.effort : nil,
            serviceMode: options.includes(.serviceMode) ? sample.serviceMode : nil,
            costs: ([reported].compactMap { $0 } + calculated)
        )
    }

    private static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func csvRow(_ values: [String]) -> String {
        values.map { value in
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }.joined(separator: ",")
    }
}
