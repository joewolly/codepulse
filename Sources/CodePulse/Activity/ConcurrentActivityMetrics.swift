import Foundation

struct ConcurrentActivityMetrics: Equatable {
    /// The union of manual active intervals only. Agent concurrency is never
    /// presented as additional personal time.
    let personalWallActive: TimeInterval
    /// Summed agent active intervals; concurrent agents intentionally overlap.
    let agentRuntime: TimeInterval
    let agentWaiting: TimeInterval
    /// Union of manual active and eligible agent intervals, useful for an
    /// activity span without inflating simultaneous work.
    let combinedWallActive: TimeInterval
}

enum ConcurrentActivityMetricsCalculator {
    static func calculate(in graph: ActivityGraph, at now: Date) -> ConcurrentActivityMetrics {
        let manualIntervals = graph.runs
            .filter { $0.kind == .manual }
            .flatMap(\.intervals)
            .filter { $0.state == .active }
        let agentIntervals = graph.runs
            .filter { $0.kind == .agent }
            .flatMap(\.intervals)
        let agentActive = agentIntervals.filter { $0.state == .active }
        let agentWaiting = agentIntervals.filter { $0.state == .waiting }
        let eligibleAgent = agentIntervals.filter { $0.state == .active || $0.state == .reviewGrace }

        return ConcurrentActivityMetrics(
            personalWallActive: unionDuration(manualIntervals, at: now),
            agentRuntime: duration(agentActive, at: now),
            agentWaiting: duration(agentWaiting, at: now),
            combinedWallActive: unionDuration(manualIntervals + eligibleAgent, at: now)
        )
    }

    private static func duration(_ intervals: [Interval], at now: Date) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.duration(at: now) }
    }

    private static func unionDuration(_ intervals: [Interval], at now: Date) -> TimeInterval {
        let sorted = intervals.map { ($0.startedAt, $0.endedAt ?? now) }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var current: (Date, Date)?
        for interval in sorted where interval.1 > interval.0 {
            guard let active = current else { current = interval; continue }
            if interval.0 <= active.1 {
                current = (active.0, max(active.1, interval.1))
            } else {
                total += active.1.timeIntervalSince(active.0)
                current = interval
            }
        }
        if let current { total += current.1.timeIntervalSince(current.0) }
        return total
    }
}
