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
        return min(1, max(0, sustainedFocusDuration / totalActiveDuration))
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

struct ProjectOutcomeEntry: Identifiable, Equatable {
    let sessionID: UUID
    let endedAt: Date
    let goal: String?
    let outcome: String?

    var id: UUID { sessionID }
}

struct ProjectOutcomeInsights: Identifiable, Equatable {
    let id: String
    let label: String
    let completedSessionCount: Int
    let completedActiveDuration: TimeInterval
    let sessionsWithGoal: Int
    let sessionsWithOutcome: Int
    let closedLoopCount: Int
    let needsFollowUpCount: Int
    let outcomeOnlyCount: Int
    let untrackedCount: Int
    let recentOutcomes: [ProjectOutcomeEntry]
    let followUps: [ProjectOutcomeEntry]

    var closedLoopRate: Double? {
        guard sessionsWithGoal > 0 else { return nil }
        return Double(closedLoopCount) / Double(sessionsWithGoal)
    }

    var recordedOutcomeCount: Int {
        closedLoopCount + outcomeOnlyCount
    }

    var followUpOverflowCount: Int {
        max(0, needsFollowUpCount - followUps.count)
    }

    var outcomeOverflowCount: Int {
        max(0, recordedOutcomeCount - recentOutcomes.count)
    }
}

struct InsightsSummary: Equatable {
    let timeframe: InsightsTimeframe
    let interval: DateInterval
    let comparisonInterval: DateInterval?
    let activeTime: TimeInterval
    let sessionActivity: TimeInterval
    let comparisonActiveTime: TimeInterval
    let comparisonSessionActivity: TimeInterval
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
    let projectOutcomeInsights: [ProjectOutcomeInsights]
    let focusInsights: FocusInsights
    let comparisonFocusInsights: FocusInsights?

    init(
        timeframe: InsightsTimeframe,
        interval: DateInterval,
        comparisonInterval: DateInterval?,
        activeTime: TimeInterval,
        sessionActivity: TimeInterval,
        comparisonActiveTime: TimeInterval,
        comparisonSessionActivity: TimeInterval,
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
        projectOutcomeInsights: [ProjectOutcomeInsights] = [],
        focusInsights: FocusInsights = .empty,
        comparisonFocusInsights: FocusInsights? = nil
    ) {
        self.timeframe = timeframe
        self.interval = interval
        self.comparisonInterval = comparisonInterval
        self.activeTime = activeTime
        self.sessionActivity = sessionActivity
        self.comparisonActiveTime = comparisonActiveTime
        self.comparisonSessionActivity = comparisonSessionActivity
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
        self.projectOutcomeInsights = projectOutcomeInsights
        self.focusInsights = focusInsights
        self.comparisonFocusInsights = comparisonFocusInsights
    }

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
        projectOutcomeInsights: [ProjectOutcomeInsights] = [],
        focusInsights: FocusInsights = .empty,
        comparisonFocusInsights: FocusInsights? = nil
    ) {
        self.init(
            timeframe: timeframe,
            interval: interval,
            comparisonInterval: comparisonInterval,
            activeTime: totalDuration,
            sessionActivity: totalDuration,
            comparisonActiveTime: comparisonDuration,
            comparisonSessionActivity: comparisonDuration,
            sessionCount: sessionCount,
            comparisonSessionCount: comparisonSessionCount,
            averageSessionDuration: averageSessionDuration,
            longestSessionDuration: longestSessionDuration,
            projectBreakdown: projectBreakdown,
            typeBreakdown: typeBreakdown,
            dailyActivity: dailyActivity,
            developerToolInsights: developerToolInsights,
            gitInsights: gitInsights,
            githubInsights: githubInsights,
            goalOutcomeInsights: goalOutcomeInsights,
            projectOutcomeInsights: projectOutcomeInsights,
            focusInsights: focusInsights,
            comparisonFocusInsights: comparisonFocusInsights
        )
    }

    var hasComparison: Bool { comparisonInterval != nil }

    /// Source-compatible aliases for tests and non-concurrent legacy callers.
    /// Phase 5 production surfaces use the explicit metrics above.
    var totalDuration: TimeInterval { sessionActivity }
    var comparisonDuration: TimeInterval { comparisonSessionActivity }
    var difference: TimeInterval { sessionActivityDifference ?? 0 }

    var activeTimeDifference: TimeInterval? {
        guard hasComparison else { return nil }
        return activeTime - comparisonActiveTime
    }

    var sessionActivityDifference: TimeInterval? {
        guard hasComparison else { return nil }
        return sessionActivity - comparisonSessionActivity
    }

    var durationDifference: TimeInterval? { sessionActivityDifference }

    var hasActivity: Bool {
        activeTime > 0 || sessionActivity > 0
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
        project: InsightsProjectFilter = .allProjects,
        workspace: WorkspaceScope = .allWorkspaces
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
            project: project,
            workspace: workspace
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
        project: InsightsProjectFilter = .allProjects,
        workspace: WorkspaceScope = .allWorkspaces
    ) -> InsightsSummary {
        let sources = sources(
            state: state,
            project: project,
            referenceDate: referenceDate,
            workspace: workspace
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
        let projectOutcomes = projectOutcomeInsights(primaryRecords)

        return InsightsSummary(
            timeframe: timeframe,
            interval: interval,
            comparisonInterval: comparisonInterval,
            activeTime: activeTime(from: sources, in: interval, referenceDate: referenceDate),
            sessionActivity: metrics.totalDuration,
            comparisonActiveTime: comparisonInterval.map {
                activeTime(from: sources, in: $0, referenceDate: referenceDate)
            } ?? 0,
            comparisonSessionActivity: comparisonMetrics?.totalDuration ?? 0,
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
            goalOutcomeInsights: aggregateGoalOutcomeInsights(from: projectOutcomes),
            projectOutcomeInsights: projectOutcomes,
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
        project: InsightsProjectFilter = .allProjects,
        workspace: WorkspaceScope = .allWorkspaces
    ) -> TimeInterval {
        let sources = sources(
            state: state,
            project: project,
            referenceDate: referenceDate,
            workspace: workspace
        )
        return activeTime(from: sources, in: interval, referenceDate: referenceDate)
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
        let earliestSessionDate = (state.completedSessions.map(\.startedAt) + state.activeSessions.map(\.startedAt))
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
            ActivityCoverageCalculator.activeIntervals(
                startedAt: startedAt,
                endedAt: endedAt,
                pauseIntervals: pauseIntervals,
                in: range,
                referenceDate: referenceDate
            )
        }

        func activeDuration(in range: DateInterval, referenceDate: Date) -> TimeInterval {
            activeSegments(in: range, referenceDate: referenceDate).reduce(0) { $0 + $1.duration }
        }
    }

    private struct SessionRecord {
        let source: SessionSource
        let duration: TimeInterval
    }

    private struct ProjectBucket: Hashable {
        let id: String
        let label: String

        static func == (lhs: ProjectBucket, rhs: ProjectBucket) -> Bool {
            lhs.id == rhs.id
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }

        init(source: SessionSource) {
            if let projectID = source.projectID {
                id = "id:\(projectID.uuidString)"
            } else if let projectName = source.projectName {
                id = "name:\(projectName)"
            } else {
                id = "no-project"
            }
            label = source.projectName ?? "No Project"
        }
    }

    private enum GoalOutcomeState {
        case closedLoop
        case needsFollowUp
        case outcomeOnly
        case untracked
    }

    private struct ClassifiedGoalOutcome {
        let state: GoalOutcomeState
        let goal: String?
        let outcome: String?
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
            ActivityCoverageCalculator.unionDuration(
                segments.map { DateInterval(start: $0.start, end: $0.end) }
            )
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
        referenceDate: Date,
        workspace: WorkspaceScope
    ) -> [SessionSource] {
        let workspaceProjectIDs: Set<UUID>?
        switch workspace {
        case .allWorkspaces:
            workspaceProjectIDs = nil
        case .workspaceID(let workspaceID):
            workspaceProjectIDs = Set(
                state.projects
                    .filter { $0.workspaceID == workspaceID }
                    .map(\.id)
            )
        }

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
        let active: [SessionSource] = state.activeSessions.map { session in
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
        return (completed + active).filter { source in
            guard source.matches(project) else { return false }
            guard let workspaceProjectIDs else { return true }
            guard let projectID = source.projectID else { return false }
            return workspaceProjectIDs.contains(projectID)
        }
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

    private static func activeTime(
        from sources: [SessionSource],
        in interval: DateInterval,
        referenceDate: Date
    ) -> TimeInterval {
        ActivityCoverageCalculator.unionDuration(sources.flatMap {
            $0.activeSegments(in: interval, referenceDate: referenceDate)
        })
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
        let totalActiveDuration = ActivityCoverageCalculator.unionDuration(
            segments.map { DateInterval(start: $0.start, end: $0.end) }
        )
        let sustainedBlocks = blocks.filter {
            $0.activeDuration >= FocusDefinition.sustainedThreshold
        }
        var hourlyTotals = Array(repeating: 0.0, count: 24)
        var dailyTotals: [Date: TimeInterval] = [:]

        let sustainedCoverage = ActivityCoverageCalculator.union(
            sustainedBlocks.flatMap(\.segments).map {
                DateInterval(start: $0.start, end: $0.end)
            }
        )
        for interval in sustainedCoverage {
            bucketSustainedInterval(
                interval,
                calendar: calendar,
                hourlyTotals: &hourlyTotals,
                dailyTotals: &dailyTotals
            )
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
            sustainedFocusDuration: ActivityCoverageCalculator.unionDuration(sustainedCoverage),
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
        for (context, contextSegments) in Dictionary(grouping: segments, by: \.context) {
            let normalized = ActivityCoverageCalculator.union(contextSegments.map {
                DateInterval(start: $0.start, end: $0.end)
            })
            var contextBlocks: [FocusBlock] = []
            for interval in normalized {
                let segment = ActiveSegment(
                    sourceID: contextSegments[0].sourceID,
                    context: context,
                    start: interval.start,
                    end: interval.end
                )
                if var last = contextBlocks.last,
                   interval.start.timeIntervalSince(last.end) <= FocusDefinition.interruptionGrace {
                    last.segments.append(segment)
                    last.end = max(last.end, interval.end)
                    contextBlocks[contextBlocks.count - 1] = last
                } else {
                    contextBlocks.append(FocusBlock(context: context, end: interval.end, segments: [segment]))
                }
            }
            blocks.append(contentsOf: contextBlocks)
        }
        return blocks.sorted { lhs, rhs in
            let lhsStart = lhs.segments[0].start
            let rhsStart = rhs.segments[0].start
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            return lhs.end < rhs.end
        }
    }

    private static func projectSwitchCount(
        from segments: [ActiveSegment],
        grace: TimeInterval
    ) -> Int {
        struct ProjectBoundary {
            var starting: [ProjectIdentity] = []
            var ending: [ProjectIdentity] = []
        }

        var boundaries: [Date: ProjectBoundary] = [:]
        for (context, values) in Dictionary(grouping: segments, by: \.context) {
            guard let identity = context.projectIdentity else { continue }
            for interval in ActivityCoverageCalculator.union(values.map {
                DateInterval(start: $0.start, end: $0.end)
            }) {
                boundaries[interval.start, default: ProjectBoundary()].starting.append(identity)
                boundaries[interval.end, default: ProjectBoundary()].ending.append(identity)
            }
        }

        var activeCounts: [ProjectIdentity: Int] = [:]
        var pendingGap: (identity: ProjectIdentity, startedAt: Date)?
        var switchCount = 0

        for timestamp in boundaries.keys.sorted() {
            guard let boundary = boundaries[timestamp] else { continue }
            let before = Set(activeCounts.keys)

            // Equal timestamps are one atomic coverage transition. Applying
            // all ends and starts before inspecting the new set prevents
            // source, UUID, or dictionary ordering from choosing an owner.
            for identity in boundary.ending {
                guard let count = activeCounts[identity] else { continue }
                if count == 1 {
                    activeCounts.removeValue(forKey: identity)
                } else {
                    activeCounts[identity] = count - 1
                }
            }
            for identity in boundary.starting {
                activeCounts[identity, default: 0] += 1
            }

            let after = Set(activeCounts.keys)
            if before.count == 1, after.isEmpty, let identity = before.first {
                pendingGap = (identity, timestamp)
            } else if before.isEmpty, after.count == 1, let identity = after.first {
                if let pendingGap,
                   timestamp.timeIntervalSince(pendingGap.startedAt) <= grace,
                   pendingGap.identity != identity {
                    switchCount += 1
                }
                pendingGap = nil
            } else if before.count == 1,
                      after.count == 1,
                      let previous = before.first,
                      let next = after.first,
                      previous != next {
                // A direct touching transition has no materialized empty
                // interval, but remains an unambiguous zero-gap switch.
                switchCount += 1
                pendingGap = nil
            } else if !after.isEmpty {
                pendingGap = nil
            }
        }

        return switchCount
    }

    private static func bucketSustainedInterval(
        _ interval: DateInterval,
        calendar: Calendar,
        hourlyTotals: inout [TimeInterval],
        dailyTotals: inout [Date: TimeInterval]
    ) {
        var cursor = interval.start
        while cursor < interval.end {
            let hour = calendar.component(.hour, from: cursor)
            let nextHour = nextLocalHourBoundary(after: cursor, calendar: calendar)
            let sliceEnd = min(interval.end, nextHour)
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

    private static func classifyGoalOutcome(
        goal: String?,
        outcome: String?
    ) -> ClassifiedGoalOutcome {
        let normalizedGoal = MeaningfulText.normalized(goal)
        let normalizedOutcome = MeaningfulText.normalized(outcome)
        let state: GoalOutcomeState
        switch (normalizedGoal != nil, normalizedOutcome != nil) {
        case (true, true): state = .closedLoop
        case (true, false): state = .needsFollowUp
        case (false, true): state = .outcomeOnly
        case (false, false): state = .untracked
        }
        return ClassifiedGoalOutcome(
            state: state,
            goal: normalizedGoal,
            outcome: normalizedOutcome
        )
    }

    private static func aggregateGoalOutcomeInsights(
        from projects: [ProjectOutcomeInsights]
    ) -> GoalOutcomeInsights {
        projects.reduce(into: GoalOutcomeInsights.empty) { result, project in
            result = GoalOutcomeInsights(
                completedSessionCount: result.completedSessionCount + project.completedSessionCount,
                sessionsWithGoal: result.sessionsWithGoal + project.sessionsWithGoal,
                sessionsWithOutcome: result.sessionsWithOutcome + project.sessionsWithOutcome,
                closedLoopCount: result.closedLoopCount + project.closedLoopCount,
                needsFollowUpCount: result.needsFollowUpCount + project.needsFollowUpCount,
                outcomeOnlyCount: result.outcomeOnlyCount + project.outcomeOnlyCount,
                untrackedCount: result.untrackedCount + project.untrackedCount
            )
        }
    }

    private static func projectOutcomeInsights(
        _ records: [SessionRecord]
    ) -> [ProjectOutcomeInsights] {
        struct Accumulator {
            let bucket: ProjectBucket
            var completedSessionCount = 0
            var completedActiveDuration: TimeInterval = 0
            var sessionsWithGoal = 0
            var sessionsWithOutcome = 0
            var closedLoopCount = 0
            var needsFollowUpCount = 0
            var outcomeOnlyCount = 0
            var untrackedCount = 0
            var outcomeCandidates: [(record: SessionRecord, classified: ClassifiedGoalOutcome)] = []
            var followUpCandidates: [(record: SessionRecord, classified: ClassifiedGoalOutcome)] = []
        }

        var accumulators: [ProjectBucket: Accumulator] = [:]
        for record in records where record.source.isCompleted {
            let bucket = ProjectBucket(source: record.source)
            let classified = classifyGoalOutcome(
                goal: record.source.goal,
                outcome: record.source.outcome
            )
            var accumulator = accumulators[bucket] ?? Accumulator(bucket: bucket)
            accumulator.completedSessionCount += 1
            accumulator.completedActiveDuration += record.duration
            if classified.goal != nil { accumulator.sessionsWithGoal += 1 }
            if classified.outcome != nil { accumulator.sessionsWithOutcome += 1 }

            switch classified.state {
            case .closedLoop:
                accumulator.closedLoopCount += 1
                accumulator.outcomeCandidates.append((record, classified))
            case .needsFollowUp:
                accumulator.needsFollowUpCount += 1
                accumulator.followUpCandidates.append((record, classified))
            case .outcomeOnly:
                accumulator.outcomeOnlyCount += 1
                accumulator.outcomeCandidates.append((record, classified))
            case .untracked:
                accumulator.untrackedCount += 1
            }
            accumulators[bucket] = accumulator
        }

        return accumulators.values.map { accumulator in
            let outcomes = boundedEntries(from: accumulator.outcomeCandidates)
            let followUps = boundedEntries(from: accumulator.followUpCandidates)
            return ProjectOutcomeInsights(
                id: accumulator.bucket.id,
                label: accumulator.bucket.label,
                completedSessionCount: accumulator.completedSessionCount,
                completedActiveDuration: accumulator.completedActiveDuration,
                sessionsWithGoal: accumulator.sessionsWithGoal,
                sessionsWithOutcome: accumulator.sessionsWithOutcome,
                closedLoopCount: accumulator.closedLoopCount,
                needsFollowUpCount: accumulator.needsFollowUpCount,
                outcomeOnlyCount: accumulator.outcomeOnlyCount,
                untrackedCount: accumulator.untrackedCount,
                recentOutcomes: outcomes,
                followUps: followUps
            )
        }.sorted(by: projectOutcomePrecedes)
    }

    private static func boundedEntries(
        from candidates: [(record: SessionRecord, classified: ClassifiedGoalOutcome)]
    ) -> [ProjectOutcomeEntry] {
        candidates
            .sorted { lhs, rhs in
                let left = lhs.record.source
                let right = rhs.record.source
                let leftEndedAt = left.endedAt ?? .distantPast
                let rightEndedAt = right.endedAt ?? .distantPast
                if leftEndedAt != rightEndedAt { return leftEndedAt > rightEndedAt }
                if left.startedAt != right.startedAt { return left.startedAt > right.startedAt }
                return left.id.uuidString < right.id.uuidString
            }
            .prefix(3)
            .map { candidate in
                ProjectOutcomeEntry(
                    sessionID: candidate.record.source.id,
                    endedAt: candidate.record.source.endedAt ?? candidate.record.source.startedAt,
                    goal: candidate.classified.goal,
                    outcome: candidate.classified.outcome
                )
            }
    }

    private static func projectOutcomePrecedes(
        _ lhs: ProjectOutcomeInsights,
        _ rhs: ProjectOutcomeInsights
    ) -> Bool {
        if lhs.needsFollowUpCount != rhs.needsFollowUpCount {
            return lhs.needsFollowUpCount > rhs.needsFollowUpCount
        }
        if lhs.completedActiveDuration != rhs.completedActiveDuration {
            return lhs.completedActiveDuration > rhs.completedActiveDuration
        }
        let labelOrder = lhs.label.localizedCaseInsensitiveCompare(rhs.label)
        if labelOrder != .orderedSame { return labelOrder == .orderedAscending }
        return lhs.id < rhs.id
    }

    private static func breakdownByProject(_ records: [SessionRecord]) -> [InsightsBreakdown] {
        var totals: [ProjectBucket: TimeInterval] = [:]
        for record in records {
            let bucket = ProjectBucket(source: record.source)
            totals[bucket, default: 0] += record.duration
        }
        return sortedDurationBreakdown(totals.map { bucket, duration in
            InsightsBreakdown(id: bucket.id, label: bucket.label, duration: duration)
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

        return dayStarts.map { day in
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                return DailyActivity(date: day, duration: 0)
            }
            let dayInterval = DateInterval(
                start: max(day, interval.start),
                end: min(nextDay, interval.end)
            )
            return DailyActivity(
                date: day,
                duration: activeTime(from: sources, in: dayInterval, referenceDate: referenceDate)
            )
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
