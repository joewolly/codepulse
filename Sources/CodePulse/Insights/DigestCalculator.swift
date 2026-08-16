import Foundation

enum DigestPeriodCalculator {
    /// The completed calendar period for a digest kind, relative to a
    /// reference date. Daily periods run local midnight to local midnight;
    /// weekly periods use the same calendar `weekOfYear` boundaries as
    /// Insights, honoring the configured first weekday.
    static func completedPeriod(
        kind: DigestKind,
        referenceDate: Date,
        calendar: Calendar
    ) -> DigestPeriod {
        switch kind {
        case .daily:
            return dailyPeriod(referenceDate: referenceDate, calendar: calendar)
        case .weekly:
            return weeklyPeriod(referenceDate: referenceDate, calendar: calendar)
        }
    }

    /// The delivery time for the period that completes at `date`: for daily
    /// digests the configured time after the period's end; for weekly digests
    /// the configured weekday/time after the period's end.
    static func nextDeliveryDate(
        kind: DigestKind,
        after date: Date,
        settings: DigestSettings,
        calendar: Calendar
    ) -> Date? {
        let components: DateComponents
        switch kind {
        case .daily:
            components = DateComponents(
                hour: settings.dailyTime.hour,
                minute: settings.dailyTime.minute
            )
        case .weekly:
            components = DateComponents(
                hour: settings.weeklyTime.hour,
                minute: settings.weeklyTime.minute,
                weekday: settings.weeklyWeekday.rawValue
            )
        }
        return calendar.nextDate(
            after: date,
            matching: components,
            matchingPolicy: .nextTime
        )
    }

    private static func dailyPeriod(referenceDate: Date, calendar: Calendar) -> DigestPeriod {
        let todayStart = calendar.startOfDay(for: referenceDate)
        let yesterdayStart = calendar.date(byAdding: .day, value: -1, to: todayStart) ?? todayStart
        let beforeStart = calendar.date(byAdding: .day, value: -1, to: yesterdayStart) ?? yesterdayStart
        return DigestPeriod(
            kind: .daily,
            interval: DateInterval(start: yesterdayStart, end: todayStart),
            comparisonInterval: DateInterval(start: beforeStart, end: yesterdayStart)
        )
    }

    private static func weeklyPeriod(referenceDate: Date, calendar: Calendar) -> DigestPeriod {
        let week = InsightsCalculator.previousWeekInterval(calendar: calendar, referenceDate: referenceDate)
        let previousReference = calendar.date(byAdding: .day, value: -1, to: week.start) ?? week.start
        let comparison = InsightsCalculator.currentWeekInterval(
            calendar: calendar,
            referenceDate: previousReference
        )
        return DigestPeriod(
            kind: .weekly,
            interval: week,
            comparisonInterval: comparison
        )
    }
}

enum DigestCalculator {
    /// Computes the digest for the completed period relative to the reference
    /// date, delegating all metric math to the shared Insights calculator.
    static func summary(
        state: AppState,
        kind: DigestKind,
        referenceDate: Date,
        calendar: Calendar
    ) -> DigestSummary {
        let period = DigestPeriodCalculator.completedPeriod(
            kind: kind,
            referenceDate: referenceDate,
            calendar: calendar
        )
        return summary(state: state, period: period, referenceDate: referenceDate, calendar: calendar)
    }

    static func summary(
        state: AppState,
        period: DigestPeriod,
        referenceDate: Date,
        calendar: Calendar
    ) -> DigestSummary {
        let insights = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: referenceDate,
            interval: period.interval,
            comparisonInterval: period.comparisonInterval,
            // The timeframe label is display-only for the Insights UI; digest
            // summaries never render through InsightsView.
            timeframe: .allTime
        )
        return DigestSummary(
            period: period,
            totalActiveTime: insights.totalDuration,
            sessionCount: insights.sessionCount,
            topProject: insights.projectBreakdown
                .first { $0.id != "no-project" }
                .map { DigestTopItem(label: $0.label, duration: $0.duration) },
            topType: insights.typeBreakdown.first
                .map { DigestTopItem(label: $0.label, duration: $0.duration) },
            developerToolParticipation: DigestDeveloperToolParticipation(
                sessionsWithAnyTool: insights.developerToolInsights.sessionsWithAnyTool,
                sessionsWithCodex: insights.developerToolInsights.sessionsWithCodex,
                sessionsWithOpenCode: insights.developerToolInsights.sessionsWithOpenCode
            ),
            comparisonTotalActiveTime: insights.comparisonInterval.map { _ in insights.comparisonDuration },
            comparisonSessionCount: insights.comparisonSessionCount
        )
    }
}
