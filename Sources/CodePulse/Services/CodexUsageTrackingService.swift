import CodePulseIntegration
import Foundation

protocol CodexUsageTracking {
    func process(state: inout AppState, now: Date) -> Bool
}

/// Keeps Codex token reading separate from lifecycle timing. With consent off,
/// this service does not enumerate, open, or parse any Codex session files.
final class CodexUsageTrackingService: CodexUsageTracking {
    private let reader: CodexUsageReader
    private let catalogStore: PricingCatalogStore?

    init(reader: CodexUsageReader? = nil, catalogStore: PricingCatalogStore? = nil) {
        let fingerprinter = DeveloperEventV2Inbox()
        self.reader = reader ?? CodexUsageReader(fingerprint: fingerprinter.fingerprint)
        self.catalogStore = catalogStore ?? (try? PricingCatalogStore(cacheURL: Self.defaultCatalogCacheURL()))
    }

    func process(state: inout AppState, now: Date) -> Bool {
        guard state.settings.codexUsageTrackingEnabled else { return false }
        var processing = state.codexUsageProcessing ?? CodexUsageProcessingState()
        let records = reader.read(state: &processing, now: now)
        var changed = processing != state.codexUsageProcessing
        state.codexUsageProcessing = processing
        guard !records.isEmpty else { return changed }
        let catalog = try? catalogStore?.current(at: now)
        for record in records {
            let attribution = attribution(for: record, in: state.activityGraph)
            let base = UsageSample(
                integration: .codex,
                observedAt: record.observedAt,
                sessionFingerprint: record.sessionFingerprint,
                runID: attribution.runID,
                workspaceID: attribution.workspaceID,
                model: record.model,
                tokens: record.tokens
            )
            let costs = catalog.map { snapshot in
                [UsageCostRepresentation.apiEquivalentEstimate, .codexCreditEstimate]
                    .compactMap { UsageCostCalculator.calculate(representation: $0, sample: base, catalog: snapshot, calculatedAt: now) }
            } ?? []
            state.usageSamples.append(UsageSample(
                integration: base.integration,
                observedAt: base.observedAt,
                sessionFingerprint: base.sessionFingerprint,
                runID: base.runID,
                workspaceID: base.workspaceID,
                model: base.model,
                tokens: base.tokens,
                calculatedCosts: costs
            ))
            changed = true
        }
        return changed
    }

    private func attribution(for record: CodexUsageRecord, in graph: ActivityGraph) -> (runID: UUID?, workspaceID: UUID?) {
        let matches = graph.runs.filter { run in
            guard run.kind == .agent,
                  run.agentMetadata?.integration == .codex,
                  run.agentMetadata?.sessionFingerprint == record.sessionFingerprint,
                  run.startedAt <= record.observedAt else { return false }
            return run.endedAt.map { $0 >= record.observedAt } ?? true
        }
        guard matches.count == 1, let run = matches.first,
              let activity = graph.activities.first(where: { $0.id == run.activityID }) else {
            return (nil, nil)
        }
        return (run.id, activity.workspaceID)
    }

    private static func defaultCatalogCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodePulse", isDirectory: true)
            .appendingPathComponent("pricing-catalog.json", isDirectory: false)
    }
}
