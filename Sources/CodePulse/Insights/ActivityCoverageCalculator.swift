import Foundation

/// Shared wall-clock coverage math for Insights, Focus, Workspaces, digests,
/// and menu-bar totals. Pauses are normalized per Session before coverage from
/// different Sessions is unioned.
enum ActivityCoverageCalculator {
    static func activeIntervals(
        startedAt: Date,
        endedAt: Date?,
        pauseIntervals: [PauseInterval],
        in interval: DateInterval,
        referenceDate: Date
    ) -> [DateInterval] {
        let end = min(endedAt ?? referenceDate, referenceDate, interval.end)
        let start = max(startedAt, interval.start)
        guard end > start else { return [] }

        let effectiveRange = DateInterval(start: start, end: end)
        let pauses = union(pauseIntervals.compactMap { pause in
            let pauseStart = max(pause.startedAt, effectiveRange.start)
            let pauseEnd = min(pause.endedAt ?? effectiveRange.end, effectiveRange.end)
            guard pauseEnd > pauseStart else { return nil }
            return DateInterval(start: pauseStart, end: pauseEnd)
        })

        var intervals: [DateInterval] = []
        var cursor = effectiveRange.start
        for pause in pauses {
            if pause.start > cursor {
                intervals.append(DateInterval(start: cursor, end: pause.start))
            }
            cursor = max(cursor, pause.end)
        }
        if cursor < effectiveRange.end {
            intervals.append(DateInterval(start: cursor, end: effectiveRange.end))
        }
        return intervals
    }

    static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals
            .filter { $0.duration > 0 }
            .sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }
        guard var current = sorted.first else { return [] }
        var result: [DateInterval] = []
        for next in sorted.dropFirst() {
            if next.start <= current.end {
                current = DateInterval(start: current.start, end: max(current.end, next.end))
            } else {
                result.append(current)
                current = next
            }
        }
        result.append(current)
        return result
    }

    static func unionDuration(_ intervals: [DateInterval]) -> TimeInterval {
        union(intervals).reduce(0) { $0 + $1.duration }
    }
}
