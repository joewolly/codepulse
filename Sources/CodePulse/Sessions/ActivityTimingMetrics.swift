import Foundation

struct ActivityTimingMetrics: Equatable {
    let manualActive: TimeInterval
    let agentRuntime: TimeInterval
    let agentWaiting: TimeInterval
    let elapsedSpan: TimeInterval
    let combinedWallActive: TimeInterval
}

enum ActivityTimingMetricsCalculator {
    static func calculate(activityID: UUID, in graph: ActivityGraph, at now: Date) -> ActivityTimingMetrics {
        let runs = graph.runs.filter { $0.activityID == activityID }
        let manualActive = duration(runs.filter { $0.kind == .manual }, states: [.active], at: now)
        let agentRuntime = duration(runs.filter { $0.kind == .agent }, states: [.active], at: now)
        let agentWaiting = duration(runs.filter { $0.kind == .agent }, states: [.waiting], at: now)
        let activeIntervals = runs.flatMap(\.intervals).filter { $0.state == .active }
        let start = runs.map(\.startedAt).min()
        let end = runs.map { $0.endedAt ?? now }.max()
        return ActivityTimingMetrics(
            manualActive: manualActive,
            agentRuntime: agentRuntime,
            agentWaiting: agentWaiting,
            elapsedSpan: (start.flatMap { start in end.map { max(0, $0.timeIntervalSince(start)) } }) ?? 0,
            combinedWallActive: unionDuration(activeIntervals, at: now)
        )
    }

    private static func duration(_ runs: [Run], states: [IntervalState], at now: Date) -> TimeInterval {
        runs.flatMap(\.intervals).filter { states.contains($0.state) }.reduce(0) { $0 + $1.duration(at: now) }
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
