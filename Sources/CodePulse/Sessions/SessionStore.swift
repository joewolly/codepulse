import Combine
import Foundation

protocol SessionClock {
    var now: Date { get }
}

struct SystemSessionClock: SessionClock {
    var now: Date { Date() }
}

struct DaySessionGroup: Identifiable {
    let id: Date
    let sessions: [CompletedSession]
    let totalDuration: TimeInterval
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var now: Date

    let persistence: StatePersisting
    let clock: SessionClock
    var calendar: Calendar
    private var refreshTimer: Timer?

    init(
        persistence: StatePersisting,
        clock: SessionClock = SystemSessionClock(),
        calendar: Calendar = .autoupdatingCurrent,
        automaticallyRefresh: Bool = true
    ) {
        self.persistence = persistence
        self.clock = clock
        self.calendar = calendar
        self.state = persistence.load()
        self.now = clock.now

        if state.activeSession?.phase == .idle {
            state.activeSession = nil
        }

        if automaticallyRefresh {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    static func live() -> SessionStore {
        SessionStore(persistence: JSONFilePersistence())
    }

    var activeSession: ActiveSession? { state.activeSession }

    var phase: SessionPhase {
        state.activeSession?.phase ?? .idle
    }

    var elapsedDuration: TimeInterval {
        guard let session = state.activeSession else { return 0 }
        return session.activeDuration(at: now)
    }

    var defaultProjectID: UUID? {
        switch state.settings.defaultProjectBehavior {
        case .noProject:
            return nil
        case .specificProject:
            return state.settings.specificProjectID
        case .lastUsed:
            return state.projects
                .compactMap { project in
                    project.lastUsedAt.map { (project.id, $0) }
                }
                .max(by: { $0.1 < $1.1 })?.0
        }
    }

    func refresh() {
        now = clock.now
    }

    @discardableResult
    func startSession(projectID: UUID?, goal: String?, at date: Date? = nil) -> Bool {
        guard state.activeSession == nil else { return false }

        let startDate = date ?? clock.now
        let project = projectID.flatMap { id in state.projects.first(where: { $0.id == id }) }
        let session = ActiveSession(
            projectID: project?.id,
            projectName: project?.name,
            goal: ActiveSession.cleanOptionalText(goal),
            startedAt: startDate
        )

        var nextState = state
        nextState.activeSession = session
        if let projectID,
           let index = nextState.projects.firstIndex(where: { $0.id == projectID }) {
            nextState.projects[index].lastUsedAt = startDate
        }
        commit(nextState)
        now = startDate
        return true
    }

    @discardableResult
    func pause(at date: Date? = nil) -> Bool {
        guard var session = state.activeSession else { return false }
        let changed = session.pause(at: date ?? clock.now)
        guard changed else { return false }

        var nextState = state
        nextState.activeSession = session
        commit(nextState)
        refresh()
        return true
    }

    @discardableResult
    func resume(at date: Date? = nil) -> Bool {
        guard var session = state.activeSession else { return false }
        let changed = session.resume(at: date ?? clock.now)
        guard changed else { return false }

        var nextState = state
        nextState.activeSession = session
        commit(nextState)
        refresh()
        return true
    }

    @discardableResult
    func finish(at date: Date? = nil) -> Bool {
        guard var session = state.activeSession else { return false }
        let changed = session.finish(at: date ?? clock.now)
        guard changed else { return false }

        var nextState = state
        nextState.activeSession = session
        commit(nextState)
        refresh()
        return true
    }

    @discardableResult
    func saveFinishedSession(outcome: String?) -> Bool {
        guard let session = state.activeSession,
              let completed = session.completedSnapshot(outcome: outcome) else {
            return false
        }

        var nextState = state
        nextState.completedSessions.append(completed)
        nextState.completedSessions.sort { $0.startedAt > $1.startedAt }
        nextState.activeSession = nil
        commit(nextState)
        refresh()
        return true
    }

    @discardableResult
    func discardSession() -> Bool {
        guard state.activeSession != nil else { return false }
        var nextState = state
        nextState.activeSession = nil
        commit(nextState)
        refresh()
        return true
    }

    func todayTotal(at date: Date? = nil) -> TimeInterval {
        let referenceDate = date ?? clock.now
        let dayStart = calendar.startOfDay(for: referenceDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let day = DateInterval(start: dayStart, end: dayEnd)

        let completedTotal = state.completedSessions.reduce(into: 0) { total, session in
            total += session.activeDuration(in: day)
        }
        let activeTotal = state.activeSession?.activeDuration(in: day, referenceDate: referenceDate) ?? 0
        return max(0, completedTotal + activeTotal)
    }

    var historyGroups: [DaySessionGroup] {
        let groups = Dictionary(grouping: state.completedSessions) { session in
            calendar.startOfDay(for: session.startedAt)
        }

        return groups.keys.sorted(by: >).map { day in
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else {
                return DaySessionGroup(id: day, sessions: groups[day] ?? [], totalDuration: 0)
            }
            let interval = DateInterval(start: day, end: dayEnd)
            let sessions = (groups[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            let total = sessions.reduce(into: 0) { result, session in
                result += session.activeDuration(in: interval)
            }
            return DaySessionGroup(id: day, sessions: sessions, totalDuration: total)
        }
    }

    @discardableResult
    func addProject(name: String, folderURL: URL?, at date: Date? = nil) -> UUID? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }

        #if os(macOS)
        let bookmarkData = folderURL.flatMap { url in
            try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        #else
        let bookmarkData: Data? = nil
        #endif
        let project = ProjectRecord(
            name: cleanName,
            folderPath: folderURL?.path,
            bookmarkData: bookmarkData,
            createdAt: date ?? clock.now
        )
        var nextState = state
        nextState.projects.append(project)
        commit(nextState)
        return project.id
    }

    func renameProject(id: UUID, name: String) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let index = state.projects.firstIndex(where: { $0.id == id }) else { return }

        var nextState = state
        nextState.projects[index].name = cleanName
        commit(nextState)
    }

    func deleteProject(id: UUID) {
        var nextState = state
        nextState.projects.removeAll { $0.id == id }
        if nextState.settings.specificProjectID == id {
            nextState.settings.specificProjectID = nil
            nextState.settings.defaultProjectBehavior = .noProject
        }
        commit(nextState)
    }

    func updateSettings(_ update: (inout CodePulseSettings) -> Void) {
        var nextState = state
        update(&nextState.settings)
        commit(nextState)
    }

    func deleteCompletedSession(id: UUID) {
        var nextState = state
        nextState.completedSessions.removeAll { $0.id == id }
        commit(nextState)
    }

    private func commit(_ nextState: AppState) {
        state = nextState
        persistence.save(nextState)
    }
}
