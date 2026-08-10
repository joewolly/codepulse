import Foundation

enum InsightsTimeframe: String, CaseIterable, Identifiable {
    case thisWeek
    case lastWeek
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case .last30Days: return "Last 30 Days"
        }
    }
}

struct InsightsBreakdown: Identifiable, Equatable {
    let id: String
    let label: String
    let duration: TimeInterval
}

struct DailyActivity: Identifiable, Equatable {
    let date: Date
    let duration: TimeInterval

    var id: Date { date }
}

struct InsightsSummary: Equatable {
    let timeframe: InsightsTimeframe
    let interval: DateInterval
    let comparisonInterval: DateInterval
    let totalDuration: TimeInterval
    let comparisonDuration: TimeInterval
    let projectBreakdown: [InsightsBreakdown]
    let typeBreakdown: [InsightsBreakdown]
    let dailyActivity: [DailyActivity]

    var difference: TimeInterval {
        totalDuration - comparisonDuration
    }

    var hasActivity: Bool {
        totalDuration > 0
    }
}

enum InsightsCalculator {
    static func currentWeekInterval(calendar: Calendar, referenceDate: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: referenceDate)
            ?? DateInterval(start: calendar.startOfDay(for: referenceDate), duration: 7 * 24 * 60 * 60)
    }

    static func previousWeekInterval(calendar: Calendar, referenceDate: Date) -> DateInterval {
        let current = currentWeekInterval(calendar: calendar, referenceDate: referenceDate)
        let previousReference = calendar.date(byAdding: .day, value: -1, to: current.start) ?? current.start
        return currentWeekInterval(calendar: calendar, referenceDate: previousReference)
    }

    static func summary(
        state: AppState,
        calendar: Calendar,
        referenceDate: Date,
        timeframe: InsightsTimeframe = .thisWeek
    ) -> InsightsSummary {
        let interval = interval(for: timeframe, calendar: calendar, referenceDate: referenceDate)
        let comparisonInterval = comparisonInterval(for: timeframe, calendar: calendar, interval: interval)
        let total = totalDuration(state: state, in: interval, referenceDate: referenceDate)
        let comparisonDuration = totalDuration(state: state, in: comparisonInterval, referenceDate: referenceDate)

        return InsightsSummary(
            timeframe: timeframe,
            interval: interval,
            comparisonInterval: comparisonInterval,
            totalDuration: total,
            comparisonDuration: comparisonDuration,
            projectBreakdown: breakdownByProject(state: state, in: interval, referenceDate: referenceDate),
            typeBreakdown: breakdownByType(state: state, in: interval, referenceDate: referenceDate),
            dailyActivity: dailyActivity(state: state, in: interval, calendar: calendar, referenceDate: referenceDate)
        )
    }

    static func totalDuration(
        state: AppState,
        in interval: DateInterval,
        referenceDate: Date
    ) -> TimeInterval {
        let completed = state.completedSessions.reduce(into: 0) { total, session in
            total += session.activeDuration(in: interval)
        }
        let active = state.activeSession?.activeDuration(in: interval, referenceDate: referenceDate) ?? 0
        return max(0, completed + active)
    }

    private static func breakdownByProject(
        state: AppState,
        in interval: DateInterval,
        referenceDate: Date
    ) -> [InsightsBreakdown] {
        var totals: [String: TimeInterval] = [:]
        for session in state.completedSessions {
            let duration = session.activeDuration(in: interval)
            guard duration > 0 else { continue }
            totals[session.projectName ?? "No Project", default: 0] += duration
        }
        if let activeSession = state.activeSession {
            let duration = activeSession.activeDuration(in: interval, referenceDate: referenceDate)
            if duration > 0 {
                totals[activeSession.projectName ?? "No Project", default: 0] += duration
            }
        }
        return totals
            .map { InsightsBreakdown(id: $0.key, label: $0.key, duration: $0.value) }
            .sorted { lhs, rhs in
                if lhs.duration == rhs.duration { return lhs.label < rhs.label }
                return lhs.duration > rhs.duration
            }
    }

    private static func breakdownByType(
        state: AppState,
        in interval: DateInterval,
        referenceDate: Date
    ) -> [InsightsBreakdown] {
        var totals: [SessionType: TimeInterval] = [:]
        for session in state.completedSessions {
            let duration = session.activeDuration(in: interval)
            guard duration > 0 else { continue }
            totals[session.type, default: 0] += duration
        }
        if let activeSession = state.activeSession {
            let duration = activeSession.activeDuration(in: interval, referenceDate: referenceDate)
            if duration > 0 {
                totals[activeSession.type, default: 0] += duration
            }
        }
        return totals
            .map { InsightsBreakdown(id: $0.key.rawValue, label: $0.key.title, duration: $0.value) }
            .sorted { lhs, rhs in
                if lhs.duration == rhs.duration { return lhs.label < rhs.label }
                return lhs.duration > rhs.duration
            }
    }

    private static func dailyActivity(
        state: AppState,
        in interval: DateInterval,
        calendar: Calendar,
        referenceDate: Date
    ) -> [DailyActivity] {
        var result: [DailyActivity] = []
        var dayStart = interval.start
        while dayStart < interval.end {
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            let dayInterval = DateInterval(start: dayStart, end: min(dayEnd, interval.end))
            result.append(DailyActivity(
                date: dayStart,
                duration: totalDuration(state: state, in: dayInterval, referenceDate: referenceDate)
            ))
            dayStart = dayEnd
        }
        return result
    }

    private static func interval(
        for timeframe: InsightsTimeframe,
        calendar: Calendar,
        referenceDate: Date
    ) -> DateInterval {
        switch timeframe {
        case .thisWeek:
            return currentWeekInterval(calendar: calendar, referenceDate: referenceDate)
        case .lastWeek:
            return previousWeekInterval(calendar: calendar, referenceDate: referenceDate)
        case .last30Days:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate))
                ?? referenceDate
            let start = calendar.date(byAdding: .day, value: -30, to: end) ?? end
            return DateInterval(start: start, end: end)
        }
    }

    private static func comparisonInterval(
        for timeframe: InsightsTimeframe,
        calendar: Calendar,
        interval: DateInterval
    ) -> DateInterval {
        switch timeframe {
        case .thisWeek, .lastWeek:
            let previousReference = calendar.date(byAdding: .day, value: -1, to: interval.start) ?? interval.start
            return currentWeekInterval(calendar: calendar, referenceDate: previousReference)
        case .last30Days:
            let end = interval.start
            let start = calendar.date(byAdding: .day, value: -30, to: end) ?? end
            return DateInterval(start: start, end: end)
        }
    }
}
