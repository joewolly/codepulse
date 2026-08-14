import CodePulseIntegration
import Foundation

enum OpenCodeUsageAdapterStatus: String, Codable, Equatable {
    case waitingForPlugin
    case healthy
    case unsupportedPluginVersion
    case malformedEvent
}

struct OpenCodeUsageProcessingState: Codable, Equatable {
    var status: OpenCodeUsageAdapterStatus
    var updatedAt: Date
    var acceptedEventCount: Int
    /// Salted message fingerprints prevent repeated `message.updated` delivery
    /// from counting a completed usage record more than once.
    var processedMessageFingerprints: [String]

    init(
        status: OpenCodeUsageAdapterStatus = .waitingForPlugin,
        updatedAt: Date = Date(),
        acceptedEventCount: Int = 0,
        processedMessageFingerprints: [String] = []
    ) {
        self.status = status
        self.updatedAt = updatedAt
        self.acceptedEventCount = acceptedEventCount
        self.processedMessageFingerprints = processedMessageFingerprints
    }

    private enum CodingKeys: String, CodingKey {
        case status, updatedAt, acceptedEventCount, processedMessageFingerprints
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decodeIfPresent(OpenCodeUsageAdapterStatus.self, forKey: .status) ?? .waitingForPlugin
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        acceptedEventCount = try container.decodeIfPresent(Int.self, forKey: .acceptedEventCount) ?? 0
        processedMessageFingerprints = try container.decodeIfPresent([String].self, forKey: .processedMessageFingerprints) ?? []
    }
}

protocol OpenCodeUsageReceiving {
    func pendingEvents() -> [(URL, OpenCodeUsageEvent?)]
    func remove(_ url: URL)
}

final class OpenCodeUsageInboxReceiver: OpenCodeUsageReceiving {
    private let inbox: OpenCodeUsageInbox

    init(inbox: OpenCodeUsageInbox = OpenCodeUsageInbox()) { self.inbox = inbox }

    func pendingEvents() -> [(URL, OpenCodeUsageEvent?)] {
        inbox.pendingEventURLs().map { ($0, try? inbox.read(from: $0)) }
    }

    func remove(_ url: URL) { _ = inbox.remove(url) }
}

protocol OpenCodeUsageTracking {
    func process(state: inout AppState, now: Date) -> Bool
}

/// Consumes only content-safe, plugin-provided usage events. There is no
/// database fallback: a changed or absent plugin affects usage only, never
/// lifecycle timing.
final class OpenCodeUsageTrackingService: OpenCodeUsageTracking {
    private let receiver: OpenCodeUsageReceiving
    private let catalogStore: PricingCatalogStore?
    private let fingerprint: (String) -> String

    init(
        receiver: OpenCodeUsageReceiving = OpenCodeUsageInboxReceiver(),
        catalogStore: PricingCatalogStore? = nil,
        fingerprint: ((String) -> String)? = nil
    ) {
        self.receiver = receiver
        self.catalogStore = catalogStore ?? (try? PricingCatalogStore(cacheURL: Self.defaultCatalogCacheURL()))
        let fingerprinter = DeveloperEventV2Inbox()
        self.fingerprint = fingerprint ?? fingerprinter.fingerprint
    }

    func process(state: inout AppState, now: Date) -> Bool {
        guard state.settings.openCodeUsageTrackingEnabled else { return false }
        var processing = state.openCodeUsageProcessing ?? OpenCodeUsageProcessingState(updatedAt: now)
        var changed = state.openCodeUsageProcessing == nil
        let catalog = try? catalogStore?.current(at: now)
        for (url, event) in receiver.pendingEvents() {
            defer { receiver.remove(url) }
            guard let event else {
                processing.status = .malformedEvent
                processing.updatedAt = now
                changed = true
                continue
            }
            guard event.pluginVersion == OpenCodeUsageEventMapper.parserVersion else {
                processing.status = .unsupportedPluginVersion
                processing.updatedAt = now
                changed = true
                continue
            }
            let messageFingerprint = fingerprint("opencode-usage:\(event.sessionID):\(event.messageID)")
            guard !processing.processedMessageFingerprints.contains(messageFingerprint) else { continue }
            let attribution = attribution(for: event, in: state.activityGraph)
            let base = UsageSample(
                integration: .opencode,
                observedAt: event.observedAt,
                sessionFingerprint: fingerprint("opencode:\(event.sessionID)"),
                runID: attribution.runID,
                workspaceID: attribution.workspaceID,
                model: event.model,
                provider: event.provider,
                serviceMode: event.serviceMode,
                tokens: UsageTokenCounts(
                    input: event.inputTokens,
                    output: event.outputTokens,
                    cachedInput: event.cacheReadTokens,
                    cacheWriteInput: event.cacheWriteTokens,
                    reasoning: event.reasoningTokens
                ),
                providerReportedCost: event.providerReportedCost,
                providerReportedCurrency: event.providerReportedCost == nil ? nil : "USD"
            )
            guard base.isWithinResourceLimits else {
                processing.status = .malformedEvent
                processing.updatedAt = now
                changed = true
                continue
            }
            let estimates = catalog.flatMap {
                UsageCostCalculator.calculate(representation: .apiEquivalentEstimate, sample: base, catalog: $0, calculatedAt: now)
            }.map { [$0] } ?? []
            state.usageSamples.append(UsageSample(
                integration: base.integration,
                observedAt: base.observedAt,
                sessionFingerprint: base.sessionFingerprint,
                runID: base.runID,
                workspaceID: base.workspaceID,
                model: base.model,
                provider: base.provider,
                serviceMode: base.serviceMode,
                tokens: base.tokens,
                providerReportedCost: base.providerReportedCost,
                providerReportedCurrency: base.providerReportedCurrency,
                calculatedCosts: estimates
            ))
            processing.status = .healthy
            processing.updatedAt = now
            processing.acceptedEventCount += 1
            processing.processedMessageFingerprints = Array(
                (processing.processedMessageFingerprints + [messageFingerprint]).suffix(2_048)
            )
            changed = true
        }
        if state.openCodeUsageProcessing != processing {
            state.openCodeUsageProcessing = processing
            changed = true
        }
        return changed
    }

    private func attribution(for event: OpenCodeUsageEvent, in graph: ActivityGraph) -> (runID: UUID?, workspaceID: UUID?) {
        let fingerprint = fingerprint("opencode:\(event.sessionID)")
        let matches = graph.runs.filter { run in
            guard run.kind == .agent,
                  run.agentMetadata?.integration == .openCode,
                  run.agentMetadata?.sessionFingerprint == fingerprint,
                  run.startedAt <= event.observedAt else { return false }
            return run.endedAt.map { $0 >= event.observedAt } ?? true
        }
        guard matches.count == 1, let run = matches.first,
              let activity = graph.activities.first(where: { $0.id == run.activityID }) else { return (nil, nil) }
        return (run.id, activity.workspaceID)
    }

    private static func defaultCatalogCacheURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodePulse", isDirectory: true)
            .appendingPathComponent("pricing-catalog.json", isDirectory: false)
    }
}
