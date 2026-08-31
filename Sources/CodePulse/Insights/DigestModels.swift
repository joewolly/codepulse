import Foundation

enum DigestKind: String, Codable, CaseIterable, Identifiable, Equatable {
    case daily
    case weekly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        }
    }

    var periodLabel: String {
        switch self {
        case .daily: return "day"
        case .weekly: return "week"
        }
    }
}

/// The completed calendar period a digest describes, plus the immediately
/// preceding equivalent period used for comparison.
struct DigestPeriod: Equatable {
    let kind: DigestKind
    let interval: DateInterval
    let comparisonInterval: DateInterval?

    var hasComparison: Bool { comparisonInterval != nil }
}

struct DigestTopItem: Equatable {
    let label: String
    let duration: TimeInterval
}

struct DigestDeveloperToolParticipation: Equatable {
    let sessionsWithAnyTool: Int
    let sessionsWithCodex: Int
    let sessionsWithOpenCode: Int

    var hasParticipation: Bool { sessionsWithAnyTool > 0 }
}

/// Structured, deterministic metrics for one completed digest period. Derived
/// exclusively from the shared Insights analytics so the digest can never
/// disagree with the Insights UI or the Markdown report.
struct DigestSummary: Equatable {
    let period: DigestPeriod
    let totalActiveTime: TimeInterval
    let sessionActivity: TimeInterval
    let sessionCount: Int
    let topProject: DigestTopItem?
    let topType: DigestTopItem?
    let developerToolParticipation: DigestDeveloperToolParticipation
    let comparisonTotalActiveTime: TimeInterval?
    let comparisonSessionActivity: TimeInterval?
    let comparisonSessionCount: Int?
    let goalOutcomeInsights: GoalOutcomeInsights

    init(
        period: DigestPeriod,
        totalActiveTime: TimeInterval,
        sessionActivity: TimeInterval? = nil,
        sessionCount: Int,
        topProject: DigestTopItem?,
        topType: DigestTopItem?,
        developerToolParticipation: DigestDeveloperToolParticipation,
        comparisonTotalActiveTime: TimeInterval?,
        comparisonSessionActivity: TimeInterval? = nil,
        comparisonSessionCount: Int?,
        goalOutcomeInsights: GoalOutcomeInsights = .empty
    ) {
        self.period = period
        self.totalActiveTime = totalActiveTime
        self.sessionActivity = sessionActivity ?? totalActiveTime
        self.sessionCount = sessionCount
        self.topProject = topProject
        self.topType = topType
        self.developerToolParticipation = developerToolParticipation
        self.comparisonTotalActiveTime = comparisonTotalActiveTime
        self.comparisonSessionActivity = comparisonSessionActivity ?? comparisonTotalActiveTime
        self.comparisonSessionCount = comparisonSessionCount
        self.goalOutcomeInsights = goalOutcomeInsights
    }

    var hasActivity: Bool { totalActiveTime > 0 }

    var activeTimeDelta: TimeInterval? {
        guard let comparisonTotalActiveTime else { return nil }
        return totalActiveTime - comparisonTotalActiveTime
    }

    var sessionCountDelta: Int? {
        guard let comparisonSessionCount else { return nil }
        return sessionCount - comparisonSessionCount
    }
}
