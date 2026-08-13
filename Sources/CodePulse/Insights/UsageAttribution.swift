import Foundation

/// A caller-selected calendar window for privacy-safe usage analytics. The
/// custom case keeps the boundary explicit instead of inferring a range from a
/// display label.
enum UsageAnalyticsWindow: Equatable {
    case day
    case week
    case month
    case custom(DateInterval)

    func interval(calendar: Calendar, referenceDate: Date) -> DateInterval {
        switch self {
        case .day:
            let start = calendar.startOfDay(for: referenceDate)
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? referenceDate
            return DateInterval(start: start, end: end)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: referenceDate)
                ?? DateInterval(start: calendar.startOfDay(for: referenceDate), duration: 7 * 86_400)
        case .month:
            return calendar.dateInterval(of: .month, for: referenceDate)
                ?? DateInterval(start: calendar.startOfDay(for: referenceDate), duration: 31 * 86_400)
        case .custom(let interval):
            return interval
        }
    }
}

enum UsageAttributionDimension: String, CaseIterable, Identifiable {
    case workspace
    case activity
    case workType
    case domain
    case integration
    case provider
    case model
    case effort
    case serviceMode

    var id: String { rawValue }
}

struct UsageAttributedSample: Identifiable, Equatable {
    let sample: UsageSample
    let workspace: Workspace?
    let activity: Activity?

    var id: UUID { sample.id }
    var isUnassigned: Bool { workspace == nil && activity == nil }

    /// Deliberately excludes source/session fingerprints. These values are safe
    /// to use as the reconciliation surface's local dimensions.
    func value(for dimension: UsageAttributionDimension) -> (id: String, label: String) {
        switch dimension {
        case .workspace:
            return workspace.map { ("workspace:\($0.id.uuidString)", $0.name) } ?? ("workspace:unassigned", "Unassigned")
        case .activity:
            return activity.map { ("activity:\($0.id.uuidString)", $0.title) } ?? ("activity:unassigned", "Unassigned")
        case .workType:
            return activity.map { ("work-type:\($0.workType.rawValue)", $0.workType.title) } ?? ("work-type:unknown", "Unknown")
        case .domain:
            return activity.map { ("domain:\($0.domain.rawValue)", $0.domain.analyticsTitle) } ?? ("domain:unknown", "Unknown")
        case .integration:
            return ("integration:\(sample.integration.rawValue)", sample.integration.title)
        case .provider:
            return value(sample.provider, prefix: "provider")
        case .model:
            return value(sample.model, prefix: "model")
        case .effort:
            return value(sample.effort, prefix: "effort")
        case .serviceMode:
            return value(sample.serviceMode, prefix: "service-mode")
        }
    }

    private func value(_ raw: String?, prefix: String) -> (id: String, label: String) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return ("\(prefix):unknown", "Unknown")
        }
        return ("\(prefix):\(raw)", raw)
    }
}

struct UsageTokenTotals: Equatable {
    var input = 0
    var output = 0
    var cachedInput = 0
    var cacheWriteInput = 0
    var reasoning = 0

    var total: Int { input + output + cachedInput + cacheWriteInput + reasoning }

    mutating func add(_ tokens: UsageTokenCounts) {
        input += tokens.input ?? 0
        output += tokens.output ?? 0
        cachedInput += tokens.cachedInput ?? 0
        cacheWriteInput += tokens.cacheWriteInput ?? 0
        reasoning += tokens.reasoning ?? 0
    }
}

struct UsageMoneyTotal: Identifiable, Equatable {
    let representation: UsageCostRepresentation
    let currency: String
    let amount: Decimal

    var id: String { "\(representation.rawValue):\(currency)" }
}

struct UsageTimingTotals: Equatable {
    let manualActive: TimeInterval
    let agentRuntime: TimeInterval
    let combinedWallActive: TimeInterval
    let agentWaiting: TimeInterval
}

struct UsageDimensionTotal: Identifiable, Equatable {
    let id: String
    let label: String
    let sampleCount: Int
    let tokens: UsageTokenTotals
    let costs: [UsageMoneyTotal]
}

struct UsageReconciliationRow: Identifiable, Equatable {
    /// This is an ordinal local display label, not a source/session identifier.
    let id: String
    let observedAt: Date
    let workspace: String
    let activity: String
    let integration: String
    let provider: String
    let model: String
    let tokens: UsageTokenTotals
    let costs: [UsageMoneyTotal]
}

struct UsageAnalyticsReport: Equatable {
    let interval: DateInterval
    let samples: [UsageAttributedSample]
    let tokens: UsageTokenTotals
    let costs: [UsageMoneyTotal]
    let timing: UsageTimingTotals
    let dimensions: [UsageAttributionDimension: [UsageDimensionTotal]]
    let reconciliation: [UsageReconciliationRow]
}

/// Builds an indexed, in-memory analytics view over normalized samples. It
/// never mutates or reattributes persisted source records; unknown and
/// ambiguous relationships remain explicit buckets.
enum UsageAttributionService {
    static func report(
        state: AppState,
        calendar: Calendar,
        referenceDate: Date,
        window: UsageAnalyticsWindow
    ) -> UsageAnalyticsReport {
        let interval = window.interval(calendar: calendar, referenceDate: referenceDate)
        let attributed = attribute(samples: state.usageSamples, graph: state.activityGraph)
            .filter { interval.contains($0.sample.observedAt) }
            .sorted { $0.sample.observedAt < $1.sample.observedAt }
        let tokens = tokenTotals(for: attributed)
        let costs = costTotals(for: attributed)
        let dimensions = Dictionary(uniqueKeysWithValues: UsageAttributionDimension.allCases.map { dimension in
            (dimension, dimensionTotals(for: attributed, dimension: dimension))
        })
        return UsageAnalyticsReport(
            interval: interval,
            samples: attributed,
            tokens: tokens,
            costs: costs,
            timing: timingTotals(graph: state.activityGraph, interval: interval, referenceDate: referenceDate),
            dimensions: dimensions,
            reconciliation: reconciliationRows(for: attributed)
        )
    }

    static func attribute(samples: [UsageSample], graph: ActivityGraph) -> [UsageAttributedSample] {
        let workspaces = Dictionary(uniqueKeysWithValues: graph.workspaces.map { ($0.id, $0) })
        let activities = Dictionary(uniqueKeysWithValues: graph.activities.map { ($0.id, $0) })
        let runs = Dictionary(uniqueKeysWithValues: graph.runs.map { ($0.id, $0) })
        return samples.map { sample in
            let run = sample.runID.flatMap { runs[$0] }
            let candidateActivity = run.flatMap { activities[$0.activityID] }
            // A conflicting direct workspace is not silently repaired by a run
            // association: retain the independently supplied workspace and
            // leave activity classification unknown.
            let activity = candidateActivity.flatMap { candidate in
                sample.workspaceID == nil || sample.workspaceID == candidate.workspaceID ? candidate : nil
            }
            let workspaceID = activity?.workspaceID ?? sample.workspaceID
            return UsageAttributedSample(sample: sample, workspace: workspaceID.flatMap { workspaces[$0] }, activity: activity)
        }
    }

    private static func tokenTotals(for samples: [UsageAttributedSample]) -> UsageTokenTotals {
        samples.reduce(into: UsageTokenTotals()) { totals, attributed in
            totals.add(attributed.sample.tokens)
        }
    }

    private static func costTotals(for samples: [UsageAttributedSample]) -> [UsageMoneyTotal] {
        var totals: [String: Decimal] = [:]
        func add(_ representation: UsageCostRepresentation, _ amount: Decimal, _ currency: String) {
            let key = "\(representation.rawValue):\(currency)"
            totals[key, default: 0] += amount
        }
        for attributed in samples {
            let sample = attributed.sample
            if let amount = sample.providerReportedCost {
                add(.providerReported, amount, sample.providerReportedCurrency ?? "USD")
            }
            for cost in sample.calculatedCosts where cost.representation == .apiEquivalentEstimate || cost.representation == .codexCreditEstimate {
                add(cost.representation, cost.amount, cost.currency)
            }
        }
        return totals.compactMap { key, amount in
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let representation = UsageCostRepresentation(rawValue: parts[0]) else { return nil }
            return UsageMoneyTotal(representation: representation, currency: parts[1], amount: amount)
        }
        .sorted { $0.id < $1.id }
    }

    private static func dimensionTotals(
        for samples: [UsageAttributedSample],
        dimension: UsageAttributionDimension
    ) -> [UsageDimensionTotal] {
        var grouped: [String: (label: String, samples: [UsageAttributedSample])] = [:]
        for attributed in samples {
            let value = attributed.value(for: dimension)
            grouped[value.id, default: (label: value.label, samples: [])].samples.append(attributed)
        }
        return grouped.map { id, group in
            UsageDimensionTotal(
                id: id,
                label: group.label,
                sampleCount: group.samples.count,
                tokens: tokenTotals(for: group.samples),
                costs: costTotals(for: group.samples)
            )
        }
        .sorted { lhs, rhs in
            lhs.tokens.total == rhs.tokens.total ? lhs.label < rhs.label : lhs.tokens.total > rhs.tokens.total
        }
    }

    private static func reconciliationRows(for samples: [UsageAttributedSample]) -> [UsageReconciliationRow] {
        samples.enumerated().map { index, attributed in
            let workspace = attributed.value(for: .workspace).label
            let activity = attributed.value(for: .activity).label
            let provider = attributed.value(for: .provider).label
            let model = attributed.value(for: .model).label
            return UsageReconciliationRow(
                id: "sample-\(index + 1)",
                observedAt: attributed.sample.observedAt,
                workspace: workspace,
                activity: activity,
                integration: attributed.sample.integration.title,
                provider: provider,
                model: model,
                tokens: tokenTotals(for: [attributed]),
                costs: costTotals(for: [attributed])
            )
        }
    }

    private static func timingTotals(graph: ActivityGraph, interval: DateInterval, referenceDate: Date) -> UsageTimingTotals {
        let manualActive = clippedIntervals(graph.runs.filter { $0.kind == .manual }, states: [.active], interval: interval, referenceDate: referenceDate)
        let agentActive = clippedIntervals(graph.runs.filter { $0.kind == .agent }, states: [.active], interval: interval, referenceDate: referenceDate)
        let agentWaiting = clippedIntervals(graph.runs.filter { $0.kind == .agent }, states: [.waiting], interval: interval, referenceDate: referenceDate)
        let combined = clippedIntervals(graph.runs, states: [.active], interval: interval, referenceDate: referenceDate)
            + clippedIntervals(graph.runs.filter { $0.kind == .agent }, states: [.reviewGrace], interval: interval, referenceDate: referenceDate)
        return UsageTimingTotals(
            manualActive: summedDuration(manualActive),
            agentRuntime: summedDuration(agentActive),
            combinedWallActive: unionDuration(combined),
            agentWaiting: summedDuration(agentWaiting)
        )
    }

    private static func clippedIntervals(
        _ runs: [Run],
        states: [IntervalState],
        interval: DateInterval,
        referenceDate: Date
    ) -> [DateInterval] {
        runs.flatMap(\.intervals).compactMap { item in
            guard states.contains(item.state) else { return nil }
            let start = max(item.startedAt, interval.start)
            let end = min(item.endedAt ?? referenceDate, referenceDate, interval.end)
            return end > start ? DateInterval(start: start, end: end) : nil
        }
    }

    private static func summedDuration(_ intervals: [DateInterval]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.duration }
    }

    private static func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        var total: TimeInterval = 0
        var current: DateInterval?
        for interval in sorted {
            guard let existing = current else { current = interval; continue }
            if interval.start <= existing.end {
                current = DateInterval(start: existing.start, end: max(existing.end, interval.end))
            } else {
                total += existing.duration
                current = interval
            }
        }
        return total + (current?.duration ?? 0)
    }
}

private extension ActivityDomain {
    var analyticsTitle: String {
        switch self {
        case .development: return "Development"
        case .fileOrganization: return "File Organization"
        case .automation: return "Automation"
        case .administration: return "Administration"
        case .documentation: return "Documentation"
        case .localTask: return "Local Task"
        case .unknown: return "Unknown"
        }
    }
}
