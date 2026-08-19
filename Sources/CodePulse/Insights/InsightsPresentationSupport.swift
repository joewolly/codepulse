import Foundation

/// Small, deterministic presentation derivations for the Insights surface.
///
/// `InsightsCalculator` remains the source of truth for all analytics. This
/// type only decides how already-calculated values are grouped or bounded for
/// the window UI.
struct InsightsActivityBucket: Identifiable, Equatable {
    let date: Date
    let duration: TimeInterval
    let label: String
    let isWeekly: Bool

    var id: Date { date }
}

enum InsightsPresentation {
    /// The readable canvas is intentionally capped so a wide window does not
    /// turn the charts into a full-width document. The two-column threshold is
    /// between the supported 740pt minimum and the 880pt default canvas.
    static let regularLayoutMinimumWidth: CGFloat = 780
    static let wideLayoutThreshold: CGFloat = 800
    static let projectBreakdownLimit = 8
    static let modelBreakdownLimit = 6
    static let profileBreakdownLimit = 6
    static let repositoryBreakdownLimit = 8
    static let allProjectsOutcomeLimit = 6
    static let singleProjectOutcomeLimit = 3
    static let allProjectsOutcomeEntryLimit = 1
    static let singleProjectOutcomeEntryLimit = 3

    static func summaryColumnCount(for contentWidth: CGFloat) -> Int {
        contentWidth >= wideLayoutThreshold ? 4 : 2
    }

    static func mainGridColumnCount(for contentWidth: CGFloat) -> Int {
        contentWidth >= wideLayoutThreshold ? 2 : 1
    }

    static func showsDeveloperToolParticipation(_ insights: DeveloperToolInsights) -> Bool {
        insights.sessionsWithAnyTool > 0
    }

    static func showsGitContext(_ insights: GitInsights) -> Bool {
        insights.sessionsWithGitContext > 0
    }

    static func showsGitHubContext(_ insights: GitHubInsights) -> Bool {
        insights.sessionsWithGitHubContext > 0
    }

    static func focusColumnCount(for contentWidth: CGFloat) -> Int {
        contentWidth >= wideLayoutThreshold ? 3 : 2
    }

    static func usesWeeklyActivityBuckets(
        timeframe: InsightsTimeframe,
        dailyBucketCount: Int
    ) -> Bool {
        timeframe == .last90Days || (timeframe == .allTime && dailyBucketCount > 45)
    }

    static func activityBuckets(
        activity: [DailyActivity],
        timeframe: InsightsTimeframe,
        calendar: Calendar
    ) -> [InsightsActivityBucket] {
        let usesWeekly = usesWeeklyActivityBuckets(
            timeframe: timeframe,
            dailyBucketCount: activity.count
        )

        guard usesWeekly else {
            return activity.map {
                InsightsActivityBucket(
                    date: $0.date,
                    duration: $0.duration,
                    label: CodePulseFormatting.fullDay($0.date, calendar: calendar),
                    isWeekly: false
                )
            }
        }

        var grouped: [Date: TimeInterval] = [:]
        for day in activity {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
            grouped[weekStart, default: 0] += day.duration
        }

        return grouped
            .map { date, duration in
                InsightsActivityBucket(
                    date: date,
                    duration: duration,
                    label: CodePulseFormatting.fullDay(date, calendar: calendar),
                    isWeekly: true
                )
            }
            .sorted { $0.date < $1.date }
    }

    static func comparisonLabel(for timeframe: InsightsTimeframe) -> String? {
        switch timeframe {
        case .thisWeek:
            return "vs last week"
        case .lastWeek:
            return "vs the week before"
        case .thisMonth:
            return "vs last month"
        case .last30Days:
            return "vs the previous 30 days"
        case .last90Days:
            return "vs the previous 90 days"
        case .allTime:
            return nil
        }
    }

    static func outcomeLimits(isAllProjects: Bool) -> (projects: Int, entries: Int) {
        if isAllProjects {
            return (allProjectsOutcomeLimit, allProjectsOutcomeEntryLimit)
        }
        return (singleProjectOutcomeLimit, singleProjectOutcomeEntryLimit)
    }

    static func boundedBreakdown(
        _ values: [InsightsBreakdown],
        limit: Int
    ) -> (visible: [InsightsBreakdown], overflow: Int) {
        let safeLimit = max(0, limit)
        return (
            Array(values.prefix(safeLimit)),
            max(0, values.count - safeLimit)
        )
    }

    static func boundedMetadata(
        _ values: [InsightsCountBreakdown],
        limit: Int
    ) -> (visible: [InsightsCountBreakdown], overflow: Int) {
        let safeLimit = max(0, limit)
        return (
            Array(values.prefix(safeLimit)),
            max(0, values.count - safeLimit)
        )
    }

    static func gitMetricText(_ value: Int?) -> String {
        value.map(String.init) ?? "Unavailable"
    }

    static let unavailableGitTotalsCopy =
        "Detailed Git totals unavailable for these session snapshots."
}
