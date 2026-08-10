import Foundation

enum SessionPhase: String, Codable, CaseIterable {
    case idle
    case running
    case paused
    case finishing
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
    let goal: String?
    let startedAt: Date
    var endedAt: Date?
    var phase: SessionPhase
    var pauseIntervals: [PauseInterval]
    var outcome: String?
    var gitContext: GitSessionContext?

    init(
        id: UUID = UUID(),
        projectID: UUID? = nil,
        projectName: String? = nil,
        goal: String? = nil,
        startedAt: Date,
        phase: SessionPhase = .running
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.goal = goal
        self.startedAt = startedAt
        self.endedAt = nil
        self.phase = phase
        self.pauseIntervals = []
        self.outcome = nil
        self.gitContext = nil
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
            goal: goal,
            outcome: Self.cleanOptionalText(outcome),
            startedAt: startedAt,
            endedAt: endedAt,
            pauseIntervals: pauseIntervals,
            gitContext: gitContext?.historicalSnapshot
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
    let goal: String?
    let outcome: String?
    let startedAt: Date
    let endedAt: Date
    let pauseIntervals: [PauseInterval]
    let gitContext: GitSessionContext?

    init(
        id: UUID,
        projectID: UUID?,
        projectName: String?,
        goal: String?,
        outcome: String?,
        startedAt: Date,
        endedAt: Date,
        pauseIntervals: [PauseInterval],
        gitContext: GitSessionContext? = nil
    ) {
        self.id = id
        self.projectID = projectID
        self.projectName = projectName
        self.goal = goal
        self.outcome = outcome
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.pauseIntervals = pauseIntervals
        self.gitContext = gitContext
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
    var launchAtLogin = false
    var menuBarDisplay: MenuBarDisplay = .projectAndTimer
    var idleAppearance: IdleAppearance = .code
    var defaultProjectBehavior: DefaultProjectBehavior = .lastUsed
    var specificProjectID: UUID? = nil
}

struct AppState: Codable, Equatable {
    var projects: [ProjectRecord] = []
    var completedSessions: [CompletedSession] = []
    var activeSession: ActiveSession? = nil
    var settings = CodePulseSettings()
}
