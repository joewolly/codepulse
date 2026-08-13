import CodePulseIntegration
import Foundation

enum SessionAutomationTrigger: Codable, Equatable, Sendable {
    case developerTool(DeveloperTool)

    private enum CodingKeys: String, CodingKey {
        case kind
        case developerTool
    }

    private enum Kind: String, Codable {
        case developerTool
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .developerTool:
            self = .developerTool(try container.decode(DeveloperTool.self, forKey: .developerTool))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .developerTool(let tool):
            try container.encode(Kind.developerTool, forKey: .kind)
            try container.encode(tool, forKey: .developerTool)
        }
    }

    var developerTool: DeveloperTool? {
        if case .developerTool(let tool) = self { return tool }
        return nil
    }
}

struct SessionAutomationRule: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var trigger: SessionAutomationTrigger
    var projectID: UUID
    var sessionType: SessionType
    var goal: String?
    var pauseDelay: TimeInterval
    var finishDelay: TimeInterval
    var minimumSavedDuration: TimeInterval

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: SessionAutomationTrigger,
        projectID: UUID,
        sessionType: SessionType = .coding,
        goal: String? = nil,
        pauseDelay: TimeInterval = 60,
        finishDelay: TimeInterval = 300,
        minimumSavedDuration: TimeInterval = 60
    ) {
        self.id = id
        self.name = Self.cleanName(name)
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.projectID = projectID
        self.sessionType = sessionType
        self.goal = Self.cleanOptionalText(goal)
        self.pauseDelay = max(0, pauseDelay)
        self.finishDelay = max(self.pauseDelay, finishDelay)
        self.minimumSavedDuration = max(0, minimumSavedDuration)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, trigger, projectID, sessionType, goal
        case pauseDelay, finishDelay, minimumSavedDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Automation Rule",
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            trigger: try container.decode(SessionAutomationTrigger.self, forKey: .trigger),
            projectID: try container.decode(UUID.self, forKey: .projectID),
            sessionType: try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .coding,
            goal: try container.decodeIfPresent(String.self, forKey: .goal),
            pauseDelay: try container.decodeIfPresent(TimeInterval.self, forKey: .pauseDelay) ?? 60,
            finishDelay: try container.decodeIfPresent(TimeInterval.self, forKey: .finishDelay) ?? 300,
            minimumSavedDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .minimumSavedDuration) ?? 60
        )
    }

    var developerTool: DeveloperTool? { trigger.developerTool }

    private static func cleanName(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Automation Rule" }
        return String(cleaned.prefix(200))
    }

    private static func cleanOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(4_096))
    }
}

struct SessionAutomationClaim: Codable, Equatable, Identifiable, Sendable {
    let tool: DeveloperTool
    let externalSessionID: String
    var isActive: Bool
    var lastSignalAt: Date

    var id: String {
        tool.rawValue + ":" + externalSessionID
    }
}

struct SessionAutomationMetadata: Codable, Equatable, Sendable {
    let startedByRuleID: UUID
    let startedByRuleName: String?
    let startedByTool: DeveloperTool
    var controlEnabled: Bool
    var lastMatchingSignalAt: Date
    var pauseEligibleAt: Date?
    var finishEligibleAt: Date?
    var pendingAutomaticSave: Bool
    var pauseDelay: TimeInterval
    var finishDelay: TimeInterval
    var minimumSavedDuration: TimeInterval
    var claims: [SessionAutomationClaim]

    init(
        startedByRuleID: UUID,
        startedByRuleName: String?,
        startedByTool: DeveloperTool,
        controlEnabled: Bool = true,
        lastMatchingSignalAt: Date,
        pauseEligibleAt: Date? = nil,
        finishEligibleAt: Date? = nil,
        pendingAutomaticSave: Bool = false,
        pauseDelay: TimeInterval,
        finishDelay: TimeInterval,
        minimumSavedDuration: TimeInterval,
        claims: [SessionAutomationClaim] = []
    ) {
        self.startedByRuleID = startedByRuleID
        self.startedByRuleName = startedByRuleName
        self.startedByTool = startedByTool
        self.controlEnabled = controlEnabled
        self.lastMatchingSignalAt = lastMatchingSignalAt
        self.pauseEligibleAt = pauseEligibleAt
        self.finishEligibleAt = finishEligibleAt
        self.pendingAutomaticSave = pendingAutomaticSave
        self.pauseDelay = max(0, pauseDelay)
        self.finishDelay = max(self.pauseDelay, finishDelay)
        self.minimumSavedDuration = max(0, minimumSavedDuration)
        self.claims = Array(claims.prefix(64))
    }

    var statusToolCount: Int {
        Set(claims.map { $0.tool }).count
    }

    func statusLabel(contexts: [DeveloperToolSessionContext]) -> String {
        let tools = Set(contexts.map { $0.tool })
        if tools.count == 1, let tool = tools.first {
            return "Automatic · " + tool.title
        }
        if tools.isEmpty, statusToolCount <= 1 {
            return "Automatic · " + startedByTool.title
        }
        return "Automatic"
    }
}
