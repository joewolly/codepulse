import Foundation
import CodePulseIntegration

enum SessionPhase: String, Codable, CaseIterable {
    case idle
    case running
    case paused
    case finishing
}

enum SessionType: String, Codable, CaseIterable, Identifiable {
    case coding
    case debugging
    case planning
    case review
    case research

    var id: String { rawValue }

    var title: String {
        switch self {
        case .coding: return "Coding"
        case .debugging: return "Debugging"
        case .planning: return "Planning"
        case .review: return "Review"
        case .research: return "Research"
        }
    }

    var systemImage: String {
        switch self {
        case .coding: return "chevron.left.forwardslash.chevron.right"
        case .debugging: return "ladybug"
        case .planning: return "list.bullet.clipboard"
        case .review: return "checkmark.seal"
        case .research: return "book"
        }
    }
}

struct GitSessionContext: Codable, Equatable {
    let repositoryRoot: String
    let branchAtStart: String?
    let startHeadSHA: String?
    let startWasDetached: Bool?
    var preExistingWorkingTreePaths: [String]?
    var branchAtEnd: String?
    var endHeadSHA: String?
    var endWasDetached: Bool?
    var commitCount: Int?
    var filesChanged: Int?
    var insertions: Int?
    var deletions: Int?

    init(
        repositoryRoot: String,
        branchAtStart: String? = nil,
        startHeadSHA: String? = nil,
        startWasDetached: Bool? = nil,
        preExistingWorkingTreePaths: [String]? = nil,
        branchAtEnd: String? = nil,
        endHeadSHA: String? = nil,
        endWasDetached: Bool? = nil,
        commitCount: Int? = nil,
        filesChanged: Int? = nil,
        insertions: Int? = nil,
        deletions: Int? = nil
    ) {
        self.repositoryRoot = repositoryRoot
        self.branchAtStart = branchAtStart
        self.startHeadSHA = startHeadSHA
        self.startWasDetached = startWasDetached
        self.preExistingWorkingTreePaths = preExistingWorkingTreePaths
        self.branchAtEnd = branchAtEnd
        self.endHeadSHA = endHeadSHA
        self.endWasDetached = endWasDetached
        self.commitCount = commitCount
        self.filesChanged = filesChanged
        self.insertions = insertions
        self.deletions = deletions
    }

    var branchDisplay: String? {
        let start = Self.branchLabel(name: branchAtStart, detached: startWasDetached)
        guard let endWasDetached else { return start }
        let end = Self.branchLabel(name: branchAtEnd, detached: endWasDetached)

        guard let start else { return end }
        guard let end else { return start }
        return start == end ? start : "\(start) → \(end)"
    }

    var headDisplay: String? {
        guard let startHeadSHA else {
            return endHeadSHA.map(Self.shortSHA)
        }
        guard let endHeadSHA, endHeadSHA != startHeadSHA else {
            return Self.shortSHA(startHeadSHA)
        }
        return "\(Self.shortSHA(startHeadSHA)) → \(Self.shortSHA(endHeadSHA))"
    }

    var changesDisplay: String? {
        guard let filesChanged, filesChanged > 0 else { return nil }

        let fileLabel = filesChanged == 1 ? "file" : "files"
        var result = "\(filesChanged) \(fileLabel)"
        if let insertions, let deletions {
            result += " · +\(insertions) / -\(deletions)"
        }
        return result
    }

    var historicalSnapshot: GitSessionContext {
        var snapshot = self
        snapshot.preExistingWorkingTreePaths = nil
        return snapshot
    }

    private static func branchLabel(name: String?, detached: Bool?) -> String? {
        if detached == true { return "Detached HEAD" }
        return name
    }

    private static func shortSHA(_ sha: String) -> String {
        String(sha.prefix(7))
    }
}

enum GitHubPullRequestState: String, Codable, Equatable, Sendable {
    case open
    case closed
    case merged
    case unknown

    init(gitHubValue: String) {
        switch gitHubValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "OPEN": self = .open
        case "CLOSED": self = .closed
        case "MERGED": self = .merged
        default: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .open: return "Open"
        case .closed: return "Closed"
        case .merged: return "Merged"
        case .unknown: return "Unknown"
        }
    }
}

struct GitHubPullRequestSnapshot: Codable, Equatable, Sendable {
    let number: Int
    let title: String
    let state: GitHubPullRequestState
    let isDraft: Bool
    let url: String
    let baseBranch: String?
    let headBranch: String?

    init(
        number: Int,
        title: String,
        state: GitHubPullRequestState,
        isDraft: Bool,
        url: String,
        baseBranch: String? = nil,
        headBranch: String? = nil
    ) {
        self.number = number
        self.title = title
        self.state = state
        self.isDraft = isDraft
        self.url = url
        self.baseBranch = baseBranch
        self.headBranch = headBranch
    }

    var statusDisplay: String {
        isDraft ? "Draft · \(state.displayName)" : state.displayName
    }

    var branchDisplay: String? {
        guard let headBranch, !headBranch.isEmpty else { return nil }
        guard let baseBranch, !baseBranch.isEmpty else { return headBranch }
        return "\(headBranch) → \(baseBranch)"
    }

    var webURL: URL? {
        GitHubURLValidator.trustedHTTPSURL(url)
    }
}

struct GitHubSessionContext: Codable, Equatable, Sendable {
    let repositoryNameWithOwner: String
    let repositoryURL: String
    let repositoryIsPrivate: Bool?
    let pullRequest: GitHubPullRequestSnapshot?

    init(
        repositoryNameWithOwner: String,
        repositoryURL: String,
        repositoryIsPrivate: Bool? = nil,
        pullRequest: GitHubPullRequestSnapshot? = nil
    ) {
        self.repositoryNameWithOwner = repositoryNameWithOwner
        self.repositoryURL = repositoryURL
        self.repositoryIsPrivate = repositoryIsPrivate
        self.pullRequest = pullRequest
    }

    var repositoryWebURL: URL? {
        GitHubURLValidator.trustedHTTPSURL(repositoryURL)
    }
}

struct PauseInterval: Codable, Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    var endedAt: Date?

    init(id: UUID = UUID(), startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    func duration(at referenceDate: Date) -> TimeInterval {
        let end = min(endedAt ?? referenceDate, referenceDate)
        return max(0, end.timeIntervalSince(startedAt))
    }

    func overlap(with range: DateInterval, referenceDate: Date) -> TimeInterval {
        let effectiveEnd = endedAt ?? referenceDate
        let start = max(startedAt, range.start)
        let end = min(effectiveEnd, range.end)
        return max(0, end.timeIntervalSince(start))
    }
}

struct ActiveSession: Codable, Equatable, Identifiable {
    let id: UUID
    let projectID: UUID?
    let projectName: String?
    var type: SessionType
    let goal: String?
    let startedAt: Date
    var endedAt: Date?
    var phase: SessionPhase
    var pauseIntervals: [PauseInterval]
    var outcome: String?
    var gitContext: GitSessionContext?
    var githubContext: GitHubSessionContext?
    var developerToolContexts: [DeveloperToolSessionContext]
    var automationMetadata: SessionAutomationMetadata?

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        projectName: String? = nil,
        type: SessionType = .coding,
        goal: String? = nil,
        startedAt: Date,
        phase: SessionPhase = .running,
        githubContext: GitHubSessionContext? = nil,
        developerToolContexts: [DeveloperToolSessionContext] = [],
        automationMetadata: SessionAutomationMetadata? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.type = type
        self.goal = goal
        self.startedAt = startedAt
        self.endedAt = nil
        self.phase = phase
        self.pauseIntervals = []
        self.outcome = nil
        self.gitContext = nil
        self.githubContext = githubContext
        self.developerToolContexts = developerToolContexts
        self.automationMetadata = automationMetadata
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, projectName, type, goal, startedAt, endedAt, phase
        case pauseIntervals, outcome, gitContext, githubContext, developerToolContexts, automationMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        type = try container.decodeIfPresent(SessionType.self, forKey: .type) ?? .coding
        goal = try container.decodeIfPresent(String.self, forKey: .goal)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        phase = try container.decodeIfPresent(SessionPhase.self, forKey: .phase) ?? .running
        pauseIntervals = try container.decodeIfPresent([PauseInterval].self, forKey: .pauseIntervals) ?? []
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        gitContext = try container.decodeIfPresent(GitSessionContext.self, forKey: .gitContext)
        githubContext = try container.decodeIfPresent(GitHubSessionContext.self, forKey: .githubContext)
        developerToolContexts = try container.decodeIfPresent(
            [DeveloperToolSessionContext].self,
            forKey: .developerToolContexts
        ) ?? []
        automationMetadata = try container.decodeIfPresent(SessionAutomationMetadata.self, forKey: .automationMetadata)
    }

    var pausedAt: Date? {
        pauseIntervals.last(where: { $0.endedAt == nil })?.startedAt
    }

    func accumulatedPausedDuration(at referenceDate: Date) -> TimeInterval {
        pauseIntervals.reduce(into: 0) { total, interval in
            total += interval.duration(at: referenceDate)
        }
    }

    func pausedDuration(at referenceDate: Date) -> TimeInterval {
        accumulatedPausedDuration(at: referenceDate)
    }

    func activeDuration(at referenceDate: Date) -> TimeInterval {
        let end = min(endedAt ?? referenceDate, referenceDate)
        guard end > startedAt else { return 0 }

        let rawDuration = end.timeIntervalSince(startedAt)
        return max(0, rawDuration - pausedDuration(at: end))
    }

    func activeDuration(in range: DateInterval, referenceDate: Date) -> TimeInterval {
        let end = min(endedAt ?? referenceDate, min(referenceDate, range.end))
        let start = max(startedAt, range.start)
        guard end > start else { return 0 }

        let effectiveRange = DateInterval(start: start, end: end)
        let paused = pauseIntervals.reduce(into: 0) { total, interval in
            total += interval.overlap(with: effectiveRange, referenceDate: referenceDate)
        }
        return max(0, effectiveRange.duration - paused)
    }

    @discardableResult
    mutating func pause(at date: Date) -> Bool {
        guard phase == .running, endedAt == nil else { return false }
        let pauseStart = max(startedAt, latestEventDate, date)
        pauseIntervals.append(PauseInterval(startedAt: pauseStart))
        phase = .paused
        return true
    }

    @discardableResult
    mutating func resume(at date: Date) -> Bool {
        guard phase == .paused,
              endedAt == nil,
              pauseIntervals.filter({ $0.endedAt == nil }).count == 1,
              let index = pauseIntervals.lastIndex(where: { $0.endedAt == nil }) else {
            return false
        }

        let resumeDate = max(pauseIntervals[index].startedAt, latestEventDate, date)
        pauseIntervals[index].endedAt = resumeDate
        phase = .running
        return true
    }

    @discardableResult
    mutating func finish(at date: Date) -> Bool {
        guard (phase == .running || phase == .paused), endedAt == nil else { return false }

        let end = max(startedAt, latestEventDate, date)
        for index in pauseIntervals.indices where pauseIntervals[index].endedAt == nil {
            pauseIntervals[index].endedAt = end
        }
        endedAt = end
        phase = .finishing
        return true
    }

    func completedSnapshot(outcome: String?) -> CompletedSession? {
        guard phase == .finishing, let endedAt else { return nil }

        return CompletedSession(
            id: id,
            projectID: projectID,
            projectName: projectName,
            type: type,
            goal: goal,
            outcome: Self.cleanOptionalText(outcome),
            startedAt: startedAt,
            endedAt: endedAt,
            pauseIntervals: pauseIntervals,
            gitContext: gitContext?.historicalSnapshot,
            githubContext: githubContext,
            developerToolContexts: developerToolContexts
        )
    }

    static func cleanOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private var latestEventDate: Date {
        pauseIntervals.reduce(startedAt) { latest, interval in
            max(latest, interval.endedAt ?? interval.startedAt)
        }
    }
}

struct CompletedSession: Codable, Equatable, Identifiable {
    let id: UUID
    let projectID: UUID?
    let projectName: String?
    let type: SessionType
    let goal: String?
    let outcome: String?
    let startedAt: Date
    let endedAt: Date
    let pauseIntervals: [PauseInterval]
    let gitContext: GitSessionContext?
    let githubContext: GitHubSessionContext?
    let developerToolContexts: [DeveloperToolSessionContext]

    init(
        id: UUID,
        projectID: UUID?,
        projectName: String?,
        type: SessionType = .coding,
        goal: String?,
        outcome: String?,
        startedAt: Date,
        endedAt: Date,
        pauseIntervals: [PauseInterval],
        gitContext: GitSessionContext? = nil,
        githubContext: GitHubSessionContext? = nil,
        developerToolContexts: [DeveloperToolSessionContext] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.type = type
        self.goal = goal
        self.outcome = outcome
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pauseIntervals = pauseIntervals
        self.gitContext = gitContext
        self.githubContext = githubContext
        self.developerToolContexts = developerToolContexts
    }

    private enum CodingKeys: String, CodingKey {
        case id, projectID, projectName, type, goal, outcome
        case startedAt, endedAt, pauseIntervals, gitContext, githubContext, developerToolContexts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        type = try container.decodeIfPresent(SessionType.self, forKey: .type) ?? .coding
        goal = try container.decodeIfPresent(String.self, forKey: .goal)
        outcome = try container.decodeIfPresent(String.self, forKey: .outcome)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        pauseIntervals = try container.decodeIfPresent([PauseInterval].self, forKey: .pauseIntervals) ?? []
        gitContext = try container.decodeIfPresent(GitSessionContext.self, forKey: .gitContext)
        githubContext = try container.decodeIfPresent(GitHubSessionContext.self, forKey: .githubContext)
        developerToolContexts = try container.decodeIfPresent(
            [DeveloperToolSessionContext].self,
            forKey: .developerToolContexts
        ) ?? []
    }

    var activeDuration: TimeInterval {
        activeDuration(in: DateInterval(start: startedAt, end: endedAt))
    }

    func activeDuration(in range: DateInterval) -> TimeInterval {
        let start = max(startedAt, range.start)
        let end = min(endedAt, range.end)
        guard end > start else { return 0 }

        let effectiveRange = DateInterval(start: start, end: end)
        let paused = pauseIntervals.reduce(into: 0) { total, interval in
            total += interval.overlap(with: effectiveRange, referenceDate: endedAt)
        }
        return max(0, effectiveRange.duration - paused)
    }

    /// Moves the complete session timeline while preserving the span and the
    /// relative position of every pause interval.
    func shifted(to newStart: Date) -> CompletedSession? {
        let offset = newStart.timeIntervalSince(startedAt)
        let newEnd = endedAt.addingTimeInterval(offset)
        guard newEnd > newStart else { return nil }

        let shiftedIntervals = pauseIntervals.map { interval in
            PauseInterval(
                id: interval.id,
                startedAt: interval.startedAt.addingTimeInterval(offset),
                endedAt: interval.endedAt?.addingTimeInterval(offset)
            )
        }

        guard shiftedIntervals.allSatisfy({ interval in
            interval.startedAt >= newStart && interval.startedAt <= newEnd &&
            (interval.endedAt == nil ||
                (interval.endedAt! >= interval.startedAt && interval.endedAt! <= newEnd))
        }) else {
            return nil
        }

        return CompletedSession(
            id: id,
            projectID: projectID,
            projectName: projectName,
            type: type,
            goal: goal,
            outcome: outcome,
            startedAt: newStart,
            endedAt: newEnd,
            pauseIntervals: shiftedIntervals,
            gitContext: gitContext,
            githubContext: githubContext,
            developerToolContexts: developerToolContexts
        )
    }
}

struct ProjectRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var folderPath: String?
    var bookmarkData: Data?
    let createdAt: Date
    var lastUsedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        folderPath: String? = nil,
        bookmarkData: Data? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

enum DefaultProjectBehavior: String, Codable, CaseIterable, Identifiable {
    case lastUsed
    case noProject
    case specificProject

    var id: String { rawValue }
}

enum MenuBarDisplay: String, Codable, CaseIterable, Identifiable {
    case projectAndTimer
    case timerOnly
    case iconOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .projectAndTimer: return "Project + Timer"
        case .timerOnly: return "Timer Only"
        case .iconOnly: return "Icon Only"
        }
    }
}

enum IdleAppearance: String, Codable, CaseIterable, Identifiable {
    case code
    case iconOnly

    var id: String { rawValue }
}

struct CodePulseSettings: Codable, Equatable {
    var launchAtLogin: Bool
    var menuBarDisplay: MenuBarDisplay
    var idleAppearance: IdleAppearance
    var defaultProjectBehavior: DefaultProjectBehavior
    var specificProjectID: UUID?
    var globalShortcutEnabled: Bool
    var automationEnabled: Bool

    init(
        launchAtLogin: Bool = false,
        menuBarDisplay: MenuBarDisplay = .projectAndTimer,
        idleAppearance: IdleAppearance = .code,
        defaultProjectBehavior: DefaultProjectBehavior = .lastUsed,
        specificProjectID: UUID? = nil,
        globalShortcutEnabled: Bool = true,
        automationEnabled: Bool = false
    ) {
        self.launchAtLogin = launchAtLogin
        self.menuBarDisplay = menuBarDisplay
        self.idleAppearance = idleAppearance
        self.defaultProjectBehavior = defaultProjectBehavior
        self.specificProjectID = specificProjectID
        self.globalShortcutEnabled = globalShortcutEnabled
        self.automationEnabled = automationEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case launchAtLogin, menuBarDisplay, idleAppearance
        case defaultProjectBehavior, specificProjectID, globalShortcutEnabled, automationEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        menuBarDisplay = try container.decodeIfPresent(MenuBarDisplay.self, forKey: .menuBarDisplay) ?? .projectAndTimer
        idleAppearance = try container.decodeIfPresent(IdleAppearance.self, forKey: .idleAppearance) ?? .code
        defaultProjectBehavior = try container.decodeIfPresent(DefaultProjectBehavior.self, forKey: .defaultProjectBehavior) ?? .lastUsed
        specificProjectID = try container.decodeIfPresent(UUID.self, forKey: .specificProjectID)
        globalShortcutEnabled = try container.decodeIfPresent(Bool.self, forKey: .globalShortcutEnabled) ?? true
        automationEnabled = try container.decodeIfPresent(Bool.self, forKey: .automationEnabled) ?? false
    }
}

struct AppState: Codable, Equatable {
    var projects: [ProjectRecord]
    var completedSessions: [CompletedSession]
    var activeSession: ActiveSession?
    var settings: CodePulseSettings
    var sessionPresets: [SessionPreset]
    var developerToolIntegration: DeveloperToolIntegrationProcessingState?
    var automationRules: [SessionAutomationRule]
    var controlProcessing: CodePulseControlProcessingState?

    init(
        projects: [ProjectRecord] = [],
        completedSessions: [CompletedSession] = [],
        activeSession: ActiveSession? = nil,
        settings: CodePulseSettings = CodePulseSettings(),
        sessionPresets: [SessionPreset] = [],
        developerToolIntegration: DeveloperToolIntegrationProcessingState? = nil,
        automationRules: [SessionAutomationRule] = [],
        controlProcessing: CodePulseControlProcessingState? = nil
    ) {
        self.projects = projects
        self.completedSessions = completedSessions
        self.activeSession = activeSession
        self.settings = settings
        self.sessionPresets = Self.normalizedPresets(sessionPresets, rules: automationRules)
        self.developerToolIntegration = developerToolIntegration
        self.automationRules = automationRules.map { $0.canonicalized() }
        self.controlProcessing = Self.normalizedControlProcessing(controlProcessing)
    }

    private enum CodingKeys: String, CodingKey {
        case projects, completedSessions, activeSession, settings
        case sessionPresets, developerToolIntegration, automationRules, controlProcessing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let projects = try container.decodeIfPresent([ProjectRecord].self, forKey: .projects) ?? []
        let completedSessions = try container.decodeIfPresent([CompletedSession].self, forKey: .completedSessions) ?? []
        let activeSession = try container.decodeIfPresent(ActiveSession.self, forKey: .activeSession)
        let settings = try container.decodeIfPresent(CodePulseSettings.self, forKey: .settings) ?? CodePulseSettings()
        let sessionPresets = try container.decodeIfPresent([SessionPreset].self, forKey: .sessionPresets) ?? []
        let developerToolIntegration = try container.decodeIfPresent(
            DeveloperToolIntegrationProcessingState.self,
            forKey: .developerToolIntegration
        )
        let automationRules = try container.decodeIfPresent([SessionAutomationRule].self, forKey: .automationRules) ?? []
        // Control bookkeeping is auxiliary recovery state. If it is damaged,
        // keep the user's sessions and configuration and start with an empty
        // ledger rather than treating the whole state file as corrupt.
        let controlProcessing = try? container.decode(
            CodePulseControlProcessingState.self,
            forKey: .controlProcessing
        )
        self.init(
            projects: projects,
            completedSessions: completedSessions,
            activeSession: activeSession,
            settings: settings,
            sessionPresets: sessionPresets,
            developerToolIntegration: developerToolIntegration,
            automationRules: automationRules,
            controlProcessing: controlProcessing
        )
    }

    private static func normalizedPresets(
        _ explicitPresets: [SessionPreset],
        rules: [SessionAutomationRule]
    ) -> [SessionPreset] {
        var presetsByID: [UUID: SessionPreset] = [:]
        var orderedIDs: [UUID] = []

        for preset in explicitPresets where presetsByID[preset.id] == nil {
            presetsByID[preset.id] = preset
            orderedIDs.append(preset.id)
        }

        for rule in rules {
            guard let legacyPreset = rule.legacyPreset,
                  presetsByID[legacyPreset.id] == nil else { continue }
            presetsByID[legacyPreset.id] = legacyPreset
            orderedIDs.append(legacyPreset.id)
        }

        return orderedIDs.compactMap { presetsByID[$0] }
    }

    private static func normalizedControlProcessing(
        _ processing: CodePulseControlProcessingState?
    ) -> CodePulseControlProcessingState? {
        guard var processing,
              !processing.processedCommands.isEmpty else {
            return nil
        }
        processing.processedCommands.sort { $0.processedAt > $1.processedAt }
        if processing.processedCommands.count > CodePulseControlLimits.maximumProcessedCommands {
            processing.processedCommands.removeLast(
                processing.processedCommands.count - CodePulseControlLimits.maximumProcessedCommands
            )
        }
        return processing
    }
}

struct DeveloperToolProcessedEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let processedAt: Date

    init(id: UUID, processedAt: Date) {
        self.id = id
        self.processedAt = processedAt
    }
}

struct DeveloperToolIntegrationProcessingState: Codable, Equatable {
    var processedEvents: [DeveloperToolProcessedEvent] = []
}

struct CodePulseProcessedControlCommand: Codable, Equatable, Identifiable {
    let id: UUID
    let processedAt: Date
    let response: CodePulseControlResponse
}

struct CodePulseControlProcessingState: Codable, Equatable {
    var processedCommands: [CodePulseProcessedControlCommand] = []
}
