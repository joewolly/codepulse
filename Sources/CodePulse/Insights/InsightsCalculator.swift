import CodePulseIntegration
import Foundation

enum InsightsTimeframe: String, CaseIterable, Identifiable {
    case thisWeek
    case lastWeek
    case thisMonth
    case last30Days
    case last90Days
    case allTime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisWeek: return "This Week"
        case .lastWeek: return "Last Week"
        case .thisMonth: return "This Month"
        case .last30Days: return "Last 30 Days"
        case .last90Days: return "Last 90 Days"
        case .allTime: return "All Time"
        }
    }
}

enum InsightsProjectFilter: Hashable {
    case allProjects
    case noProject
    case projectID(UUID)
    case historicalName(String)
}

struct InsightsProjectOption: Identifiable, Hashable {
    let id: String
    let title: String
    let filter: InsightsProjectFilter
}

struct InsightsBreakdown: Identifiable, Equatable {
    let id: String
    let label: String
    let duration: TimeInterval
}

struct InsightsCountBreakdown: Identifiable, Equatable {
    let id: String
    let label: String
    let count: Int
}

struct DailyActivity: Identifiable, Equatable {
    let date: Date
    let duration: TimeInterval

    var id: Date { date }
}

/// Version-one analytical definitions for Focus Patterns. These are kept in
/// one place so the calculation, UI copy, and tests share the same contract.
enum FocusDefinition {
    static let interruptionGrace: TimeInterval = 15 * 60
    static let sustainedThreshold: TimeInterval = 30 * 60
}

struct HourlyFocusActivity: Identifiable, Equatable {
    let hour: Int
    let duration: TimeInterval

    var id: Int { hour }
}

struct FocusInsights: Equatable {
    let totalActiveDuration: TimeInterval
    let focusBlockCount: Int
    let longestFocusBlockDuration: TimeInterval
    let averageFocusBlockDuration: TimeInterval
    let sustainedFocusBlockCount: Int
    let sustainedFocusDuration: TimeInterval
    let projectSwitchCount: Int
    let hourlySustainedFocus: [HourlyFocusActivity]
    let bestFocusDay: DailyActivity?

    var sustainedFocusShare: Double? {
        guard totalActiveDuration > 0 else { return nil }
        return sustainedFocusDuration / totalActiveDuration
    }

    var peakFocusHour: Int? {
        guard let peak = hourlySustainedFocus.max(by: { lhs, rhs in
            if lhs.duration == rhs.duration { return lhs.hour > rhs.hour }
            return lhs.duration < rhs.duration
        }), peak.duration > 0 else {
            return nil
        }
        return peak.hour
    }

    static let empty = FocusInsights(
        totalActiveDuration: 0,
        focusBlockCount: 0,
        longestFocusBlockDuration: 0,
        averageFocusBlockDuration: 0,
        sustainedFocusBlockCount: 0,
        sustainedFocusDuration: 0,
        projectSwitchCount: 0,
        hourlySustainedFocus: (0..<24).map { HourlyFocusActivity(hour: $0, duration: 0) },
        bestFocusDay: nil
    )
}

struct DeveloperToolInsights: Equatable {
    let sessionsWithCodex: Int
    let sessionsWithOpenCode: Int
    let sessionsWithBoth: Int
    let sessionsWithAnyTool: Int
    let sessionsWithNoTool: Int
    let modelBreakdown: [InsightsCountBreakdown]
    let profileBreakdown: [InsightsCountBreakdown]

    var hasModelData: Bool { !modelBreakdown.isEmpty }
    var hasProfileData: Bool { !profileBreakdown.isEmpty }
}

struct GitInsights: Equatable {
    let sessionsWithGitContext: Int
    let totalCommits: Int?
    let totalFilesChanged: Int?
    let totalInsertions: Int?
    let totalDeletions: Int?

    var hasMetrics: Bool {
        totalCommits != nil || totalFilesChanged != nil ||
            totalInsertions != nil || totalDeletions != nil
    }
}

struct GitHubInsights: Equatable {
    let sessionsWithGitHubContext: Int
    let sessionsWithPullRequest: Int
    let uniqueRepositories: Int
    let uniquePullRequests: Int
    let repositoryBreakdown: [InsightsBreakdown]
}

struct GoalOutcomeInsights: Equatable {
    let completedSessionCount: Int
    let sessionsWithGoal: Int
    let sessionsWithOutcome: Int
    let closedLoopCount: Int
    let needsFollowUpCount: Int
    let outcomeOnlyCount: Int
    let untrackedCount: Int

    var closedLoopRate: Double? {
        guard sessionsWithGoal > 0 else { return nil }
        return Double(closedLoopCount) / Double(sessionsWithGoal)
    }

    static let empty = GoalOutcomeInsights(
        completedSessionCount: 0,
        sessionsWithGoal: 0,
        sessionsWithOutcome: 0,
        closedLoopCount: 0,
        needsFollowUpCount: 0,
        outcomeOnlyCount: 0,
        untrackedCount: 0
    )
}

struct InsightsSummary: Equatable {
    let timeframe: InsightsTimeframe
    let interval: DateInterval
    let comparisonInterval: DateInterval?
    let totalDuration: TimeInterval
    let comparisonDuration: TimeInterval
    let sessionCount: Int
    let comparisonSessionCount: Int?
    let averageSessionDuration: TimeInterval
    let longestSessionDuration: TimeInterval
    let projectBreakdown: [InsightsBreakdown]
    let typeBreakdown: [InsightsBreakdown]
    let dailyActivity: [DailyActivity]
    let developerToolInsights: DeveloperToolInsights
    let gitInsights: GitInsights
    let githubInsights: GitHubInsights
    let goalOutcomeInsights: GoalOutcomeInsights
    let focusInsights: FocusInsights
    let comparisonFocusInsights: FocusInsights?

    init(
        timeframe: InsightsTimeframe,
        interval: DateInterval,
        comparisonInterval: DateInterval?,
        totalDuration: TimeInterval,
        comparisonDuration: TimeInterval,
        sessionCount: Int,
        comparisonSessionCount: Int?,
        averageSessionDuration: TimeInterval,
        longestSessionDuration: TimeInterval,
        projectBreakdown: [InsightsBreakdown],
        typeBreakdown: [InsightsBreakdown],
        dailyActivity: [DailyActivity],
        developerToolInsights: DeveloperToolInsights,
        gitInsights: GitInsights,
        githubInsights: GitHubInsights,
        goalOutcomeInsights: GoalOutcomeInsights = .empty,
        focusInsights: FocusInsights = .empty,
        comparisonFocusInsights: FocusInsights? = nil
    ) {
        self.timeframe = timeframe
        self.interval = interval
        self.comparisonInterval = comparisonInterval
        self.totalDuration = totalDuration
        self.comparisonDuration = comparisonDuration
        self.sessionCount = sessionCount
        self.comparisonSessionCount = comparisonSessionCount
        self.averageSessionDuration = averageSessionDuration
        self.longestSessionDuration = longestSessionDuration
        self.projectBreakdown = projectBreakdown
        self.typeBreakdown = typeBreakdown
        self.dailyActivity = dailyActivity
        self.developerToolInsights = developerToolInsights
        self.gitInsights = gitInsights
        self.githubInsights = githubInsights
        self.goalOutcomeInsights = goalOutcomeInsights
        self.focusInsights = focusInsights
        self.comparisonFocusInsights = comparisonFocusInsights
    }

    var hasComparison: Bool { comparisonInterval != nil }

    /// Kept as a non-optional compatibility convenience. Callers should use
    /// `durationDifference` when they need to distinguish All Time.
    var difference: TimeInterval { durationDifference ?? 0 }

    var durationDifference: TimeInterval? {
        guard hasComparison else { return nil }
        return totalDuration - comparisonDuration
    }

    var hasActivity: Bool {
        totalDuration > 0
    }
}

enum InsightsCalculator {
    static func currentWeekInterval(calendar: Calendar, referenceDate: Date) -> DateInterval {
        calendar.dateInterval(of: .weekOfYear, for: referenceDate)
            ?? fallbackInterval(calendar: calendar, start: calendar.startOfDay(for: referenceDate), component: .day, value: 7)
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
        timeframe: InsightsTimeframe = .thisWeek,
        project: InsightsProjectFilter = .allProjects
    ) -> InsightsSummary {
        let interval = interval(
            for: timeframe,
            state: state,
            calendar: calendar,
            referenceDate: referenceDate
        )
        let comparisonInterval = comparisonInterval(
            for: timeframe,
            calendar: calendar,
            interval: interval
        )
        return summary(
            state: state,
            calendar: calendar,
            referenceDate: referenceDate,
            interval: interval,
            comparisonInterval: comparisonInterval,
            timeframe: timeframe,
            project: project
        )
    }

    /// Computes a summary for an explicit interval. This is the single shared
    /// analytics path: the timeframe-based entry point above and the local
    /// digest calculator both flow through here so they cannot drift apart.
    static func summary(
        state: AppState,
        calendar: Calendar,
        referenceDate: Date,
        interval: DateInterval,
        comparisonInterval: DateInterval?,
        timeframe: InsightsTimeframe,
        project: InsightsProjectFilter = .allProjects
    ) -> InsightsSummary {
        let sources = sources(
            state: state,
            project: project,
            referenceDate: referenceDate
        )
        let primaryRecords = records(
            from: sources,
            in: interval,
            referenceDate: referenceDate
        )
        let comparisonRecords = comparisonInterval.map {
            records(from: sources, in: $0, referenceDate: referenceDate)
        }
        let metrics = sessionMetrics(primaryRecords)
        let comparisonMetrics = comparisonRecords.map(sessionMetrics)

        return InsightsSummary(
            timeframe: timeframe,
            interval: interval,
            comparisonInterval: comparisonInterval,
            totalDuration: metrics.totalDuration,
            comparisonDuration: comparisonMetrics?.totalDuration ?? 0,
            sessionCount: metrics.sessionCount,
            comparisonSessionCount: comparisonMetrics?.sessionCount,
            averageSessionDuration: metrics.averageDuration,
            longestSessionDuration: metrics.longestDuration,
            projectBreakdown: breakdownByProject(primaryRecords),
            typeBreakdown: breakdownByType(primaryRecords),
            dailyActivity: dailyActivity(
                from: sources,
                in: interval,
                calendar: calendar,
                referenceDate: referenceDate
            ),
            developerToolInsights: developerToolInsights(primaryRecords),
            gitInsights: gitInsights(primaryRecords),
            githubInsights: githubInsights(primaryRecords),
            goalOutcomeInsights: goalOutcomeInsights(primaryRecords),
            focusInsights: focusInsights(
                from: sources,
                in: interval,
                referenceDate: referenceDate,
                calendar: calendar
            ),
            comparisonFocusInsights: comparisonInterval.map {
                focusInsights(
                    from: sources,
                    in: $0,
                    referenceDate: referenceDate,
                    calendar: calendar
                )
            }
        )
    }

    static func totalDuration(
        state: AppState,
        in interval: DateInterval,
        referenceDate: Date,
        project: InsightsProjectFilter = .allProjects
    ) -> TimeInterval {
        let sources = sources(state: state, project: project, referenceDate: referenceDate)
        return records(from: sources, in: interval, referenceDate: referenceDate)
            .reduce(into: 0) { total, record in total += record.duration }
    }

    static func interval(
        for timeframe: InsightsTimeframe,
        state: AppState,
        calendar: Calendar,
        referenceDate: Date
    ) -> DateInterval {
        switch timeframe {
        case .thisWeek:
            return currentWeekInterval(calendar: calendar, referenceDate: referenceDate)
        case .lastWeek:
            return previousWeekInterval(calendar: calendar, referenceDate: referenceDate)
        case .thisMonth:
            return calendar.dateInterval(of: .month, for: referenceDate)
                ?? fallbackInterval(calendar: calendar, start: calendar.startOfDay(for: referenceDate), component: .day, value: 31)
        case .last30Days:
            return rollingDayInterval(days: 30, calendar: calendar, referenceDate: referenceDate)
        case .last90Days:
            return rollingDayInterval(days: 90, calendar: calendar, referenceDate: referenceDate)
        case .allTime:
            return allTimeInterval(state: state, calendar: calendar, referenceDate: referenceDate)
        }
    }

    private static func comparisonInterval(
        for timeframe: InsightsTimeframe,
        calendar: Calendar,
        interval: DateInterval
    ) -> DateInterval? {
        switch timeframe {
        case .thisWeek, .lastWeek:
            let previousReference = calendar.date(byAdding: .day, value: -1, to: interval.start) ?? interval.start
            return currentWeekInterval(calendar: calendar, referenceDate: previousReference)
        case .thisMonth:
            let previousReference = calendar.date(byAdding: .day, value: -1, to: interval.start) ?? interval.start
            return calendar.dateInterval(of: .month, for: previousReference)
        case .last30Days:
            return precedingRollingInterval(days: 30, calendar: calendar, interval: interval)
        case .last90Days:
            return precedingRollingInterval(days: 90, calendar: calendar, interval: interval)
        case .allTime:
            return nil
        }
    }

    private static func rollingDayInterval(
        days: Int,
        calendar: Calendar,
        referenceDate: Date
    ) -> DateInterval {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: referenceDate))
            ?? referenceDate
        let start = calendar.date(byAdding: .day, value: -days + 1, to: calendar.startOfDay(for: referenceDate))
            ?? end
        return DateInterval(start: start, end: end)
    }

    private static func precedingRollingInterval(
        days: Int,
        calendar: Calendar,
        interval: DateInterval
    ) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -days, to: interval.start) ?? interval.start
        return DateInterval(start: start, end: interval.start)
    }

    private static func allTimeInterval(
        state: AppState,
        calendar: Calendar,
        referenceDate: Date
    ) -> DateInterval {
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let earliestSessionDate = (state.completedSessions.map(\.startedAt) + [state.activeSession?.startedAt].compactMap { $0 })
            .min()
        let start = min(referenceDay, calendar.startOfDay(for: earliestSessionDate ?? referenceDate))
        let end = calendar.date(byAdding: .day, value: 1, to: referenceDay) ?? referenceDate
        return DateInterval(start: start, end: end)
    }

    private static func fallbackInterval(
        calendar: Calendar,
        start: Date,
        component: Calendar.Component,
        value: Int
    ) -> DateInterval {
        let end = calendar.date(byAdding: component, value: value, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    private struct SessionSource {
        let id: UUID
        let projectID: UUID?
        let projectName: String?
        let type: SessionType
        let goal: String?
        let outcome: String?
        let isCompleted: Bool
        let startedAt: Date
        let endedAt: Date?
        let pauseIntervals: [PauseInterval]
        let gitContext: GitSessionContext?
        let githubContext: GitHubSessionContext?
        let developerToolContexts: [DeveloperToolSessionContext]

        func matches(_ project: InsightsProjectFilter) -> Bool {
            switch project {
            case .allProjects:
                return true
            case .noProject:
                return projectID == nil && projectName == nil
            case .projectID(let projectID):
                return self.projectID == projectID
            case .historicalName(let name):
                return projectID == nil && projectName == name
            }
        }

        var focusContext: FocusContext {
            if let projectID {
                return .projectID(projectID)
            }
            if let projectName, !projectName.isEmpty {
                return .historicalName(projectName)
            }
            return .noProject(id)
        }

        func activeSegments(
            in range: DateInterval,
            referenceDate: Date
        ) -> [DateInterval] {
            guard let normalized = normalizedPauseIntervals(in: range, referenceDate: referenceDate) else {
                return []
            }

            var segments: [DateInterval] = []
            var cursor = normalized.effectiveRange.start
            for pause in normalized.pauses {
                if pause.start > cursor {
                    segments.append(DateInterval(start: cursor, end: pause.start))
                }
                cursor = max(cursor, pause.end)
            }
            if cursor < normalized.effectiveRange.end {
                segments.append(DateInterval(start: cursor, end: normalized.effectiveRange.end))
            }
            return segments.filter { $0.duration > 0 }
        }

        func activeDuration(in range: DateInterval, referenceDate: Date) -> TimeInterval {
            guard let normalized = normalizedPauseIntervals(in: range, referenceDate: referenceDate) else {
                return 0
            }
            let paused = normalized.pauses.reduce(into: 0) { total, pause in
                total += pause.duration
            }
            return max(0, normalized.effectiveRange.duration - paused)
        }

        private func normalizedPauseIntervals(
            in range: DateInterval,
            referenceDate: Date
        ) -> (effectiveRange: DateInterval, pauses: [DateInterval])? {
            let sessionEnd = endedAt ?? referenceDate
            let end = min(sessionEnd, referenceDate, range.end)
            let start = max(startedAt, range.start)
            guard end > start else { return nil }

            let effectiveRange = DateInterval(start: start, end: end)
            let clippedPauses = pauseIntervals.compactMap { pause -> DateInterval? in
                let pauseStart = max(pause.startedAt, effectiveRange.start)
                let pauseEnd = min(pause.endedAt ?? effectiveRange.end, effectiveRange.end)
                guard pauseEnd > pauseStart else { return nil }
                return DateInterval(start: pauseStart, end: pauseEnd)
            }.sorted { lhs, rhs in
                if lhs.start != rhs.start { return lhs.start < rhs.start }
                return lhs.end < rhs.end
            }

            var normalizedPauses: [DateInterval] = []
            for pause in clippedPauses {
                guard let last = normalizedPauses.last else {
                    normalizedPauses.append(pause)
                    continue
                }
                if pause.start <= last.end {
                    normalizedPauses[normalizedPauses.count - 1] = DateInterval(
                        start: last.start,
                        end: max(last.end, pause.end)
                    )
                } else {
                    normalizedPauses.append(pause)
                }
            }

            return (effectiveRange: effectiveRange, pauses: normalizedPauses)
        }
    }

    private struct SessionRecord {
        let source: SessionSource
        let duration: TimeInterval
    }

    private enum FocusContext: Hashable {
        case projectID(UUID)
        case historicalName(String)
        case noProject(UUID)

        var projectIdentity: ProjectIdentity? {
            switch self {
            case .projectID(let id): return .projectID(id)
            case .historicalName(let name): return .historicalName(name)
            case .noProject: return nil
            }
        }
    }

    private enum ProjectIdentity: Hashable {
        case projectID(UUID)
        case historicalName(String)
    }

    private struct ActiveSegment {
        let sourceID: UUID
        let context: FocusContext
        let start: Date
        let end: Date

        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    private struct FocusBlock {
        let context: FocusContext
        var end: Date
        var segments: [ActiveSegment]

        var activeDuration: TimeInterval {
            segments.reduce(into: 0) { total, segment in
                total += segment.duration
            }
        }
    }

    private struct SessionMetrics {
        let totalDuration: TimeInterval
        let sessionCount: Int
        let averageDuration: TimeInterval
        let longestDuration: TimeInterval
    }

    private static func sources(
        state: AppState,
        project: InsightsProjectFilter,
        referenceDate: Date
    ) -> [SessionSource] {
        let completed = state.completedSessions.map { session in
            SessionSource(
                id: session.id,
                projectID: session.projectID,
                projectName: session.projectName,
                type: session.type,
                goal: session.goal,
                outcome: session.outcome,
                isCompleted: true,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                pauseIntervals: session.pauseIntervals,
                gitContext: session.gitContext,
                githubContext: session.githubContext,
                developerToolContexts: session.developerToolContexts
            )
        }
        let active = state.activeSession.map { session in
            SessionSource(
                id: session.id,
                projectID: session.projectID,
                projectName: session.projectName,
                type: session.type,
                goal: session.goal,
                outcome: session.outcome,
                isCompleted: false,
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                pauseIntervals: session.pauseIntervals,
                gitContext: session.gitContext,
                githubContext: session.githubContext,
                developerToolContexts: session.developerToolContexts
            )
        }
        return (completed + [active].compactMap { $0 }).filter { $0.matches(project) }
    }

    private static func records(
        from sources: [SessionSource],
        in interval: DateInterval,
        referenceDate: Date
    ) -> [SessionRecord] {
        sources.compactMap { source in
            let duration = source.activeDuration(in: interval, referenceDate: referenceDate)
            guard duration > 0 else { return nil }
            return SessionRecord(source: source, duration: duration)
        }
    }

    private static func focusInsights(
        from sources: [SessionSource],
        in interval: DateInterval,
        referenceDate: Date,
        calendar: Calendar
    ) -> FocusInsights {
        let segments = activeSegments(
            from: sources,
            in: interval,
            referenceDate: referenceDate
        )
        guard !segments.isEmpty else { return .empty }

        let blocks = focusBlocks(from: segments)
        let totalActiveDuration = segments.reduce(into: 0) { total, segment in
            total += segment.duration
        }
        let sustainedBlocks = blocks.filter {
            $0.activeDuration >= FocusDefinition.sustainedThreshold
        }
        var hourlyTotals = Array(repeating: 0.0, count: 24)
        var dailyTotals: [Date: TimeInterval] = [:]

        for block in sustainedBlocks {
            for segment in block.segments {
                bucketSustainedSegment(
                    segment,
                    calendar: calendar,
                    hourlyTotals: &hourlyTotals,
                    dailyTotals: &dailyTotals
                )
            }
        }

        let hourly = hourlyTotals.enumerated().map { hour, duration in
            HourlyFocusActivity(hour: hour, duration: duration)
        }
        let bestDay = dailyTotals
            .map { DailyActivity(date: $0.key, duration: $0.value) }
            .filter { $0.duration > 0 }
            .sorted { lhs, rhs in
                if lhs.duration == rhs.duration { return lhs.date < rhs.date }
                return lhs.duration > rhs.duration
            }
            .first

        return FocusInsights(
            totalActiveDuration: totalActiveDuration,
            focusBlockCount: blocks.count,
            longestFocusBlockDuration: blocks.map(\.activeDuration).max() ?? 0,
            averageFocusBlockDuration: blocks.isEmpty
                ? 0
                : blocks.reduce(0) { $0 + $1.activeDuration } / Double(blocks.count),
            sustainedFocusBlockCount: sustainedBlocks.count,
            sustainedFocusDuration: sustainedBlocks.reduce(0) { $0 + $1.activeDuration },
            projectSwitchCount: projectSwitchCount(
                from: segments,
                grace: FocusDefinition.interruptionGrace
            ),
            hourlySustainedFocus: hourly,
            bestFocusDay: bestDay
        )
    }

    private static func activeSegments(
        from sources: [SessionSource],
        in interval: DateInterval,
        referenceDate: Date
    ) -> [ActiveSegment] {
        sources.flatMap { source in
            source.activeSegments(in: interval, referenceDate: referenceDate).map { range in
                ActiveSegment(
                    sourceID: source.id,
                    context: source.focusContext,
                    start: range.start,
                    end: range.end
                )
            }
        }.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end < rhs.end }
            return lhs.sourceID.uuidString < rhs.sourceID.uuidString
        }
    }

    private static func focusBlocks(from segments: [ActiveSegment]) -> [FocusBlock] {
        var blocks: [FocusBlock] = []
        for segment in segments {
            guard var last = blocks.last else {
                blocks.append(FocusBlock(context: segment.context, end: segment.end, segments: [segment]))
                continue
            }

            let gap = segment.start.timeIntervalSince(last.end)
            if last.context == segment.context, gap <= FocusDefinition.interruptionGrace {
                last.segments.append(segment)
                last.end = max(last.end, segment.end)
                blocks[blocks.count - 1] = last
            } else {
                blocks.append(FocusBlock(context: segment.context, end: segment.end, segments: [segment]))
            }
        }
        return blocks
    }

    private static func projectSwitchCount(
        from segments: [ActiveSegment],
        grace: TimeInterval
    ) -> Int {
        struct SourceActivity {
            let firstStart: Date
            let lastEnd: Date
            let identity: ProjectIdentity?
            let id: UUID
        }

        var bySource: [UUID: SourceActivity] = [:]
        for segment in segments {
            if let existing = bySource[segment.sourceID] {
                bySource[segment.sourceID] = SourceActivity(
                    firstStart: min(existing.firstStart, segment.start),
                    lastEnd: max(existing.lastEnd, segment.end),
                    identity: existing.identity,
                    id: existing.id
                )
            } else {
                bySource[segment.sourceID] = SourceActivity(
                    firstStart: segment.start,
                    lastEnd: segment.end,
                    identity: segment.context.projectIdentity,
                    id: segment.sourceID
                )
            }
        }

        let activities = bySource.values.sorted { lhs, rhs in
            if lhs.firstStart != rhs.firstStart { return lhs.firstStart < rhs.firstStart }
            if lhs.lastEnd != rhs.lastEnd { return lhs.lastEnd < rhs.lastEnd }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        return zip(activities, activities.dropFirst()).reduce(into: 0) { count, pair in
            let (previous, next) = pair
            guard let previousIdentity = previous.identity,
                  let nextIdentity = next.identity,
                  previousIdentity != nextIdentity,
                  next.firstStart.timeIntervalSince(previous.lastEnd) <= grace else {
                return
            }
            count += 1
        }
    }

    private static func bucketSustainedSegment(
        _ segment: ActiveSegment,
        calendar: Calendar,
        hourlyTotals: inout [TimeInterval],
        dailyTotals: inout [Date: TimeInterval]
    ) {
        var cursor = segment.start
        while cursor < segment.end {
            let hour = calendar.component(.hour, from: cursor)
            let nextHour = nextLocalHourBoundary(after: cursor, calendar: calendar)
            let sliceEnd = min(segment.end, nextHour)
            guard sliceEnd > cursor else { break }
            let duration = sliceEnd.timeIntervalSince(cursor)
            hourlyTotals[hour] += duration

            let day = calendar.startOfDay(for: cursor)
            dailyTotals[day, default: 0] += duration
            cursor = sliceEnd
        }
    }

    private static func nextLocalHourBoundary(after date: Date, calendar: Calendar) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        var next = components
        next.hour = (components.hour ?? 0) + 1
        next.minute = 0
        next.second = 0
        return calendar.date(from: next) ?? date.addingTimeInterval(3_600)
    }

    private static func sessionMetrics(_ records: [SessionRecord]) -> SessionMetrics {
        let total = records.reduce(into: 0) { total, record in total += record.duration }
        let longest = records.map(\.duration).max() ?? 0
        return SessionMetrics(
            totalDuration: total,
            sessionCount: records.count,
            averageDuration: records.isEmpty ? 0 : total / Double(records.count),
            longestDuration: longest
        )
    }

    private static func goalOutcomeInsights(_ records: [SessionRecord]) -> GoalOutcomeInsights {
        let completed = records.filter { $0.source.isCompleted }
        var sessionsWithGoal = 0
        var sessionsWithOutcome = 0
        var closedLoop = 0
        var needsFollowUp = 0
        var outcomeOnly = 0
        var untracked = 0

        for record in completed {
            let hasGoal = MeaningfulText.exists(record.source.goal)
            let hasOutcome = MeaningfulText.exists(record.source.outcome)

            if hasGoal { sessionsWithGoal += 1 }
            if hasOutcome { sessionsWithOutcome += 1 }

            switch (hasGoal, hasOutcome) {
            case (true, true): closedLoop += 1
            case (true, false): needsFollowUp += 1
            case (false, true): outcomeOnly += 1
            case (false, false): untracked += 1
            }
        }

        return GoalOutcomeInsights(
            completedSessionCount: completed.count,
            sessionsWithGoal: sessionsWithGoal,
            sessionsWithOutcome: sessionsWithOutcome,
            closedLoopCount: closedLoop,
            needsFollowUpCount: needsFollowUp,
            outcomeOnlyCount: outcomeOnly,
            untrackedCount: untracked
        )
    }

    private static func breakdownByProject(_ records: [SessionRecord]) -> [InsightsBreakdown] {
        var totals: [String: (label: String, duration: TimeInterval)] = [:]
        for record in records {
            let key = record.source.projectID.map { "id:\($0.uuidString)" }
                ?? record.source.projectName.map { "name:\($0)" }
                ?? "no-project"
            let label = record.source.projectName ?? "No Project"
            totals[key, default: (label: label, duration: 0)].duration += record.duration
        }
        return sortedDurationBreakdown(totals.map { key, value in
            InsightsBreakdown(id: key, label: value.label, duration: value.duration)
        })
    }

    private static func breakdownByType(_ records: [SessionRecord]) -> [InsightsBreakdown] {
        var totals: [SessionType: TimeInterval] = [:]
        for record in records {
            totals[record.source.type, default: 0] += record.duration
        }
        return sortedDurationBreakdown(totals.map { type, duration in
            InsightsBreakdown(id: type.rawValue, label: type.title, duration: duration)
        })
    }

    private static func dailyActivity(
        from sources: [SessionSource],
        in interval: DateInterval,
        calendar: Calendar,
        referenceDate: Date
    ) -> [DailyActivity] {
        let firstDay = calendar.startOfDay(for: interval.start)
        var dayStarts: [Date] = []
        var dayStart = firstDay
        while dayStart < interval.end {
            dayStarts.append(dayStart)
            guard let next = calendar.date(byAdding: .day, value: 1, to: dayStart) else { break }
            dayStart = next
        }

        var totals: [Date: TimeInterval] = [:]
        for source in sources {
            let sessionEnd = min(source.endedAt ?? referenceDate, referenceDate, interval.end)
            let sessionStart = max(source.startedAt, interval.start)
            guard sessionEnd > sessionStart else { continue }

            var bucketStart = calendar.startOfDay(for: sessionStart)
            while bucketStart < sessionEnd, bucketStart < interval.end {
                guard let bucketEnd = calendar.date(byAdding: .day, value: 1, to: bucketStart) else { break }
                let dayInterval = DateInterval(
                    start: max(bucketStart, interval.start),
                    end: min(bucketEnd, interval.end)
                )
                let duration = source.activeDuration(in: dayInterval, referenceDate: referenceDate)
                if duration > 0 {
                    totals[bucketStart, default: 0] += duration
                }
                bucketStart = bucketEnd
            }
        }

        return dayStarts.map { day in
            DailyActivity(date: day, duration: totals[day] ?? 0)
        }
    }

    private static func developerToolInsights(_ records: [SessionRecord]) -> DeveloperToolInsights {
        var modelSessions: [String: Set<UUID>] = [:]
        var profileSessions: [String: Set<UUID>] = [:]
        var codex = 0
        var openCode = 0
        var both = 0
        var any = 0

        for record in records {
            let tools = Set(record.source.developerToolContexts.map(\.tool))
            if tools.contains(.codex) { codex += 1 }
            if tools.contains(.opencode) { openCode += 1 }
            if tools.contains(.codex), tools.contains(.opencode) { both += 1 }
            if !tools.isEmpty { any += 1 }

            for context in record.source.developerToolContexts {
                if let model = normalizedMetadata(context.model) {
                    modelSessions[model, default: []].insert(record.source.id)
                }
                if let profile = normalizedMetadata(context.profile) {
                    profileSessions[profile, default: []].insert(record.source.id)
                }
            }
        }

        return DeveloperToolInsights(
            sessionsWithCodex: codex,
            sessionsWithOpenCode: openCode,
            sessionsWithBoth: both,
            sessionsWithAnyTool: any,
            sessionsWithNoTool: records.count - any,
            modelBreakdown: sortedCountBreakdown(modelSessions),
            profileBreakdown: sortedCountBreakdown(profileSessions)
        )
    }

    private static func gitInsights(_ records: [SessionRecord]) -> GitInsights {
        let contexts = records.compactMap(\.source.gitContext)
        return GitInsights(
            sessionsWithGitContext: contexts.count,
            totalCommits: completeMetric(contexts.map(\.commitCount)),
            totalFilesChanged: completeMetric(contexts.map(\.filesChanged)),
            totalInsertions: completeMetric(contexts.map(\.insertions)),
            totalDeletions: completeMetric(contexts.map(\.deletions))
        )
    }

    private static func githubInsights(_ records: [SessionRecord]) -> GitHubInsights {
        var repositories: [String: (label: String, duration: TimeInterval)] = [:]
        var repositoryKeys = Set<String>()
        var pullRequestKeys = Set<String>()
        var sessionsWithContext = 0
        var sessionsWithPullRequest = 0

        for record in records {
            guard let context = record.source.githubContext else { continue }
            sessionsWithContext += 1
            let repositoryKey = normalizedIdentity(context.repositoryNameWithOwner)
            repositoryKeys.insert(repositoryKey)
            repositories[repositoryKey, default: (
                label: context.repositoryNameWithOwner,
                duration: 0
            )].duration += record.duration

            if let pullRequest = context.pullRequest {
                sessionsWithPullRequest += 1
                pullRequestKeys.insert("\(repositoryKey)#\(pullRequest.number)")
            }
        }

        return GitHubInsights(
            sessionsWithGitHubContext: sessionsWithContext,
            sessionsWithPullRequest: sessionsWithPullRequest,
            uniqueRepositories: repositoryKeys.count,
            uniquePullRequests: pullRequestKeys.count,
            repositoryBreakdown: sortedDurationBreakdown(repositories.map { key, value in
                InsightsBreakdown(id: "github:\(key)", label: value.label, duration: value.duration)
            })
        )
    }

    private static func completeMetric(_ values: [Int?]) -> Int? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

    private static func normalizedMetadata(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func normalizedIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sortedDurationBreakdown(_ values: [InsightsBreakdown]) -> [InsightsBreakdown] {
        values.sorted { lhs, rhs in
            if lhs.duration == rhs.duration {
                let labelOrder = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
            return lhs.duration > rhs.duration
        }
    }

    private static func sortedCountBreakdown(_ values: [String: Set<UUID>]) -> [InsightsCountBreakdown] {
        values.map { key, sessionIDs in
            InsightsCountBreakdown(id: "metadata:\(key)", label: key, count: sessionIDs.count)
        }.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                let labelOrder = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
            return lhs.count > rhs.count
        }
    }
}
