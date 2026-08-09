import Foundation

enum SessionPhase: String, Codable, CaseIterable {
    case idle
    case running
    case paused
    case finishing
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
        let end = endedAt ?? referenceDate
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
    }

    var pausedAt: Date? {
        pauseIntervals.last(where: { $0.endedAt == nil })?.startedAt
    }

    var accumulatedPausedDuration: TimeInterval {
        pausedDuration(at: endedAt ?? Date())
    }

    func pausedDuration(at referenceDate: Date) -> TimeInterval {
        pauseIntervals.reduce(into: 0) { total, interval in
            total += interval.duration(at: referenceDate)
        }
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
        guard phase == .running else { return false }
        let pauseStart = max(startedAt, date)
        pauseIntervals.append(PauseInterval(startedAt: pauseStart))
        phase = .paused
        return true
    }

    @discardableResult
    mutating func resume(at date: Date) -> Bool {
        guard phase == .paused,
              let index = pauseIntervals.lastIndex(where: { $0.endedAt == nil }) else {
            return false
        }

        let resumeDate = max(pauseIntervals[index].startedAt, date)
        pauseIntervals[index].endedAt = resumeDate
        phase = .running
        return true
    }

    @discardableResult
    mutating func finish(at date: Date) -> Bool {
        guard phase == .running || phase == .paused else { return false }

        let end = max(startedAt, date)
        if let index = pauseIntervals.lastIndex(where: { $0.endedAt == nil }) {
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
            pauseIntervals: pauseIntervals
        )
    }

    static func cleanOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
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
