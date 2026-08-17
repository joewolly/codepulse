import CodePulseIntegration
import Foundation

enum HistoryDateFilter: String, CaseIterable, Identifiable, Hashable {
    case allTime
    case today
    case last7Days
    case last30Days

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTime: return "All Time"
        case .today: return "Today"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        }
    }
}

enum HistoryTypeFilter: String, CaseIterable, Identifiable, Hashable {
    case allTypes
    case coding
    case debugging
    case planning
    case review
    case research

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allTypes: return "All Types"
        case .coding: return SessionType.coding.title
        case .debugging: return SessionType.debugging.title
        case .planning: return SessionType.planning.title
        case .review: return SessionType.review.title
        case .research: return SessionType.research.title
        }
    }

    var sessionType: SessionType? {
        switch self {
        case .allTypes: return nil
        case .coding: return .coding
        case .debugging: return .debugging
        case .planning: return .planning
        case .review: return .review
        case .research: return .research
        }
    }
}

enum HistoryGitFilter: String, CaseIterable, Identifiable, Hashable {
    case allSessions
    case gitSessions
    case nonGitSessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allSessions: return "All Sessions"
        case .gitSessions: return "Git Sessions"
        case .nonGitSessions: return "Non-Git Sessions"
        }
    }
}

enum HistoryDeveloperToolFilter: String, CaseIterable, Identifiable, Hashable {
    case anyTool
    case codex
    case openCode
    case noDeveloperTool

    var id: String { rawValue }

    var title: String {
        switch self {
        case .anyTool: return "Any Tool"
        case .codex: return "Codex"
        case .openCode: return "OpenCode"
        case .noDeveloperTool: return "No Developer Tool"
        }
    }

    var developerTool: DeveloperTool? {
        switch self {
        case .anyTool, .noDeveloperTool: return nil
        case .codex: return .codex
        case .openCode: return .opencode
        }
    }
}

enum HistoryGoalOutcomeFilter: String, CaseIterable, Identifiable, Hashable {
    case allSessions
    case needsFollowUp
    case closedLoop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allSessions: return "All Sessions"
        case .needsFollowUp: return "Needs Follow-Up"
        case .closedLoop: return "Closed Loop"
        }
    }
}

enum HistoryProjectFilter: Hashable {
    case allProjects
    case noProject
    case projectID(UUID)
    case historicalName(String)

    var title: String {
        switch self {
        case .allProjects: return "All Projects"
        case .noProject: return "No Project"
        case .projectID, .historicalName:
            return "Project"
        }
    }
}

struct HistoryProjectOption: Identifiable, Hashable {
    let id: String
    let title: String
    let filter: HistoryProjectFilter
}

struct HistoryQuery: Equatable {
    var searchText = ""
    var project: HistoryProjectFilter = .allProjects
    var date: HistoryDateFilter = .allTime
    var type: HistoryTypeFilter = .allTypes
    var git: HistoryGitFilter = .allSessions
    var developerTool: HistoryDeveloperToolFilter = .anyTool
    var goalOutcome: HistoryGoalOutcomeFilter = .allSessions

    var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasRestrictions: Bool {
        !normalizedSearchText.isEmpty ||
        project != .allProjects ||
        date != .allTime ||
        type != .allTypes ||
        git != .allSessions ||
        developerTool != .anyTool ||
        goalOutcome != .allSessions
    }

    func matches(
        _ session: CompletedSession,
        calendar: Calendar,
        referenceDate: Date
    ) -> Bool {
        guard matchesDate(session, calendar: calendar, referenceDate: referenceDate) else { return false }

        switch project {
        case .allProjects:
            break
        case .noProject:
            guard session.projectID == nil, session.projectName == nil else { return false }
        case .projectID(let projectID):
            guard session.projectID == projectID else { return false }
        case .historicalName(let name):
            guard session.projectName == name else { return false }
        }

        if let sessionType = type.sessionType, session.type != sessionType {
            return false
        }

        switch git {
        case .allSessions:
            break
        case .gitSessions where session.gitContext == nil:
            return false
        case .nonGitSessions where session.gitContext != nil:
            return false
        default:
            break
        }

        let tools = Set(session.developerToolContexts.map(\.tool))
        switch developerTool {
        case .anyTool:
            break
        case .codex, .openCode:
            guard let developerTool = developerTool.developerTool,
                  tools.contains(developerTool) else { return false }
        case .noDeveloperTool:
            guard tools.isEmpty else { return false }
        }

        let hasGoal = MeaningfulText.exists(session.goal)
        let hasOutcome = MeaningfulText.exists(session.outcome)
        switch goalOutcome {
        case .allSessions:
            break
        case .needsFollowUp:
            guard hasGoal, !hasOutcome else { return false }
        case .closedLoop:
            guard hasGoal, hasOutcome else { return false }
        }

        let query = normalizedSearchText
        guard !query.isEmpty else { return true }

        var searchableValues: [String] = [
            session.projectName,
            session.goal,
            session.outcome,
            session.type.title,
            session.gitContext?.branchAtStart,
            session.gitContext?.branchAtEnd,
            session.gitContext?.branchDisplay,
            session.gitContext?.repositoryRoot,
            session.githubContext?.repositoryNameWithOwner,
            session.githubContext?.pullRequest.map { "#\($0.number)" },
            session.githubContext?.pullRequest.map { "\($0.number)" },
            session.githubContext?.pullRequest?.title,
            session.githubContext?.pullRequest?.state.displayName,
            session.githubContext?.pullRequest?.branchDisplay
        ].compactMap { $0 }
        searchableValues.append(contentsOf: session.developerToolContexts.flatMap { context in
            [context.tool.title, context.model, context.profile].compactMap { $0 }
        })

        return searchableValues.contains { value in
            value.localizedCaseInsensitiveContains(query)
        }
    }

    private func matchesDate(
        _ session: CompletedSession,
        calendar: Calendar,
        referenceDate: Date
    ) -> Bool {
        guard let interval = dateInterval(calendar: calendar, referenceDate: referenceDate) else {
            return true
        }
        return interval.contains(session.startedAt)
    }

    private func dateInterval(calendar: Calendar, referenceDate: Date) -> DateInterval? {
        let today = calendar.startOfDay(for: referenceDate)
        switch date {
        case .allTime:
            return nil
        case .today:
            guard let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return DateInterval(start: today, end: end)
        case .last7Days:
            guard let start = calendar.date(byAdding: .day, value: -6, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return DateInterval(start: start, end: end)
        case .last30Days:
            guard let start = calendar.date(byAdding: .day, value: -29, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }
}
