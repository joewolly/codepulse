import Combine
import CodePulseIntegration
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

    var sessionCount: Int { sessions.count }

    var distinctNamedProjectCount: Int {
        Set(sessions.compactMap(\.projectName)).count
    }
}

enum CompletedSessionProjectAssignment: Equatable {
    case keepSnapshot
    case noProject
    case project(UUID)
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var now: Date
    @Published private(set) var gitCaptureInProgress = false
    @Published private(set) var persistenceRecoveryIssue: PersistenceRecoveryIssue?

    let persistence: StatePersisting
    let clock: SessionClock
    let gitService: GitServicing
    let githubContextService: GitHubContextServicing
    let developerToolEventConsumer: DeveloperToolEventConsuming
    let developerEventV2Consumer: DeveloperEventV2Consuming
    let developerToolLifecycleCoordinator: DeveloperToolLifecycleCoordinating
    var calendar: Calendar
    private var refreshTimer: Timer?
    private var gitCaptureSessionID: UUID?
    private var lastIntegrationScanAt: Date?

    init(
        persistence: StatePersisting,
        clock: SessionClock = SystemSessionClock(),
        calendar: Calendar = .autoupdatingCurrent,
        gitService: GitServicing = SystemGitService(),
        githubContextService: GitHubContextServicing = SystemGitHubContextService(),
        developerToolEventConsumer: DeveloperToolEventConsuming = DeveloperToolEventConsumer(),
        developerEventV2Consumer: DeveloperEventV2Consuming = DeveloperEventV2Consumer(),
        developerToolLifecycleCoordinator: DeveloperToolLifecycleCoordinating = DeveloperToolLifecycleCoordinator(),
        automaticallyRefresh: Bool = true
    ) {
        self.persistence = persistence
        self.clock = clock
        self.gitService = gitService
        self.githubContextService = githubContextService
        self.developerToolEventConsumer = developerToolEventConsumer
        self.developerEventV2Consumer = developerEventV2Consumer
        self.developerToolLifecycleCoordinator = developerToolLifecycleCoordinator
        self.calendar = calendar
        self.state = persistence.load()
        self.persistenceRecoveryIssue = (persistence as? StatePersistenceRecoveryProviding)?.recoveryIssue
        self.now = clock.now
        self.gitCaptureSessionID = nil
        self.lastIntegrationScanAt = nil

        if state.activeSession?.phase == .idle {
            state.activeSession = nil
        }

        processPendingIntegrationEvents(force: true)
        reconcileAgentRuns()

        if automaticallyRefresh {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refresh()
                }
            }
        }

        if let session = state.activeSession,
           session.phase == .finishing,
           session.gitContext != nil {
            scheduleFinalGitCapture(for: session.id)
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    static func live() -> SessionStore {
        SessionStore(
            persistence: JSONFilePersistence(),
            developerToolEventConsumer: DeveloperToolEventConsumer(
                inbox: DeveloperToolInbox()
            )
        )
    }

    var activeSession: ActiveSession? { state.activeSession }
    var activityGraph: ActivityGraph { state.activityGraph }
    var activityGraphDiagnostics: ActivityGraphDiagnostics { ActivityGraphDiagnostics(graph: state.activityGraph) }

    /// Compatibility lookup for existing ProjectRecord-backed UI paths.
    func workspace(forLegacyProjectID projectID: UUID) -> Workspace? {
        state.activityGraph.workspaces.first(where: { $0.legacyProjectID == projectID })
    }

    /// Compatibility lookup for existing ActiveSession/CompletedSession UI paths.
    func activity(forLegacySessionID sessionID: UUID) -> Activity? {
        state.activityGraph.activities.first(where: { $0.legacySessionID == sessionID })
    }

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

    var projectsSortedByRecentUse: [ProjectRecord] {
        state.projects.sorted { lhs, rhs in
            switch (lhs.lastUsedAt, rhs.lastUsedAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func refresh() {
        now = clock.now
        processPendingIntegrationEvents()
        reconcileAgentRuns()
    }

    @discardableResult
    func addWorkspace(name: String, roots: [WorkspaceRoot] = [], at date: Date? = nil) -> UUID? {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        let timestamp = date ?? clock.now
        let workspace = Workspace(name: cleaned, roots: roots, createdAt: timestamp, source: .manual)
        var nextState = state
        nextState.activityGraph.workspaces.append(workspace)
        commit(nextState)
        return workspace.id
    }

    @discardableResult
    func createActivity(
        workspaceID: UUID,
        title: String,
        workType: SessionType = .coding,
        domain: ActivityDomain = .development,
        at date: Date? = nil
    ) -> UUID? {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        var nextState = state
        do {
            let activity = try ActivityGraphRepository.createActivity(
                in: &nextState.activityGraph,
                workspaceID: workspaceID,
                title: cleaned,
                workType: workType,
                domain: domain,
                at: date ?? clock.now
            )
            commit(nextState)
            return activity.id
        } catch {
            return nil
        }
    }

    @discardableResult
    func updateActivity(
        id: UUID,
        title: String? = nil,
        workType: SessionType? = nil,
        domain: ActivityDomain? = nil,
        at date: Date? = nil
    ) -> Bool {
        if let title, title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        var nextState = state
        do {
            try ActivityGraphRepository.updateActivity(
                in: &nextState.activityGraph,
                id: id,
                title: title?.trimmingCharacters(in: .whitespacesAndNewlines),
                workType: workType,
                domain: domain,
                at: date ?? clock.now
            )
            commit(nextState)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func startRun(activityID: UUID, kind: RunKind = .manual, at date: Date? = nil) -> UUID? {
        var nextState = state
        do {
            let run = try ActivityGraphRepository.startRun(in: &nextState.activityGraph, activityID: activityID, kind: kind, at: date ?? clock.now)
            commit(nextState)
            return run.id
        } catch {
            return nil
        }
    }

    @discardableResult
    func startAgentRun(
        activityID: UUID,
        integration: DeveloperEventIntegration,
        sessionFingerprint: String,
        parentSessionFingerprint: String? = nil,
        at date: Date? = nil
    ) -> UUID? {
        let startedAt = date ?? clock.now
        var nextState = state
        do {
            let run = try ActivityGraphRepository.startRun(
                in: &nextState.activityGraph,
                activityID: activityID,
                kind: .agent,
                at: startedAt,
                agentMetadata: AgentRunMetadata(
                    integration: integration,
                    sessionFingerprint: sessionFingerprint,
                    parentSessionFingerprint: parentSessionFingerprint,
                    lastEventAt: startedAt
                )
            )
            commit(nextState)
            return run.id
        } catch {
            return nil
        }
    }

    @discardableResult
    func applyAgentLifecycleEvent(_ event: DeveloperEventV2, to runID: UUID) -> Bool {
        var nextState = state
        guard ActivityGraphRepository.applyAgentEvent(
            in: &nextState.activityGraph,
            runID: runID,
            event: event,
            reviewGrace: TimeInterval(nextState.settings.agentReviewGraceSeconds)
        ) else {
            return false
        }
        commit(nextState)
        return true
    }

    @discardableResult
    func closeRunInterval(id runID: UUID, at date: Date? = nil) -> Bool {
        var nextState = state
        do {
            try ActivityGraphRepository.closeOpenInterval(in: &nextState.activityGraph, runID: runID, at: date ?? clock.now)
            commit(nextState)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func beginRunInterval(id runID: UUID, state intervalState: IntervalState, at date: Date? = nil, reason: String? = nil) -> Bool {
        var nextState = state
        do {
            try ActivityGraphRepository.beginInterval(in: &nextState.activityGraph, runID: runID, state: intervalState, at: date ?? clock.now, reason: reason)
            commit(nextState)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func endRun(id runID: UUID, at date: Date? = nil) -> Bool {
        var nextState = state
        do {
            try ActivityGraphRepository.endRun(in: &nextState.activityGraph, runID: runID, at: date ?? clock.now)
            commit(nextState)
            return true
        } catch {
            return false
        }
    }

    func runs(workspaceID: UUID? = nil, activityID: UUID? = nil) -> [Run] {
        ActivityGraphRepository.runs(in: state.activityGraph, workspaceID: workspaceID, activityID: activityID)
    }

    func activityGraphDiagnosticsJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(activityGraphDiagnostics)
    }

    @discardableResult
    func startSession(
        projectID: UUID?,
        goal: String?,
        type: SessionType = .coding,
        at date: Date? = nil
    ) -> Bool {
        guard state.activeSession == nil else { return false }

        let startDate = date ?? clock.now
        let project = projectID.flatMap { id in state.projects.first(where: { $0.id == id }) }
        let folderURL = project.flatMap { projectFolderURL(for: $0) }
        let session = ActiveSession(
            projectID: project?.id,
            projectName: project?.name,
            type: type,
            goal: ActiveSession.cleanOptionalText(goal),
            startedAt: startDate
        )

        var nextState = state
        nextState.activeSession = session
        if let projectID,
           let index = nextState.projects.firstIndex(where: { $0.id == projectID }) {
            nextState.projects[index].lastUsedAt = startDate
        }
        attachCompatibilityRun(for: session, to: &nextState)
        commit(nextState)
        now = startDate
        processPendingIntegrationEvents(force: true)
        if let folderURL,
           FileManager.default.fileExists(atPath: folderURL.path) {
            scheduleStartGitCapture(for: session.id, folderURL: folderURL)
        }
        return true
    }

    @discardableResult
    func pause(at date: Date? = nil) -> Bool {
        guard var session = state.activeSession else { return false }
        let changed = session.pause(at: date ?? clock.now)
        guard changed else { return false }

        var nextState = state
        nextState.activeSession = session
        transitionCompatibilityRun(for: session.id, to: .waiting, at: session.pausedAt ?? date ?? clock.now, in: &nextState)
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
        transitionCompatibilityRun(for: session.id, to: .active, at: session.pauseIntervals.last?.endedAt ?? date ?? clock.now, in: &nextState)
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
        endCompatibilityRun(for: session.id, at: session.endedAt ?? date ?? clock.now, in: &nextState)
        commit(nextState)
        refresh()

        if session.gitContext != nil {
            scheduleFinalGitCapture(for: session.id)
        }
        return true
    }

    @discardableResult
    func saveFinishedSession(outcome: String?) -> Bool {
        processPendingIntegrationEvents(force: true)
        guard !gitCaptureInProgress else { return false }
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
        guard state.activeSession?.phase == .finishing else { return false }
        var nextState = state
        nextState.activeSession = nil
        commit(nextState)
        gitCaptureSessionID = nil
        gitCaptureInProgress = false
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
        historyGroups(for: HistoryQuery())
    }

    func historyGroups(
        for query: HistoryQuery,
        referenceDate: Date? = nil
    ) -> [DaySessionGroup] {
        let referenceDate = referenceDate ?? clock.now
        let matchingSessions = state.completedSessions.filter { session in
            query.matches(session, calendar: calendar, referenceDate: referenceDate)
        }
        let groups = Dictionary(grouping: matchingSessions) { session in
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

    var historyProjectOptions: [HistoryProjectOption] {
        let currentOptions = projectsSortedByRecentUse.map { project in
            HistoryProjectOption(
                id: "project-\(project.id.uuidString)",
                title: project.name,
                filter: .projectID(project.id)
            )
        }
        let currentNames = Set(state.projects.map(\.name))
        let historicalNames = Set(state.completedSessions.compactMap(\.projectName))
            .subtracting(currentNames)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { name in
                HistoryProjectOption(
                    id: "historical-\(name)",
                title: name,
                filter: .historicalName(name)
            )
            }
        return currentOptions + historicalNames
    }

    var insightsProjectOptions: [InsightsProjectOption] {
        let currentProjects = projectsSortedByRecentUse.map { project in
            InsightsProjectOption(
                id: "project-\(project.id.uuidString)",
                title: project.name,
                filter: .projectID(project.id)
            )
        }
        let currentIDs = Set(state.projects.map(\.id))
        let currentNames = Set(state.projects.map(\.name))
        var historicalByID: [UUID: (name: String, startedAt: Date)] = [:]
        var historicalNames = Set<String>()

        func collect(projectID: UUID?, projectName: String?, startedAt: Date) {
            if let projectID, !currentIDs.contains(projectID) {
                let name = projectName.flatMap { $0.isEmpty ? nil : $0 } ?? "Historical Project"
                if let existing = historicalByID[projectID], existing.startedAt >= startedAt { return }
                historicalByID[projectID] = (name: name, startedAt: startedAt)
            } else if projectID == nil,
                      let projectName,
                      !projectName.isEmpty,
                      !currentNames.contains(projectName) {
                historicalNames.insert(projectName)
            }
        }
        for session in state.completedSessions {
            collect(
                projectID: session.projectID,
                projectName: session.projectName,
                startedAt: session.startedAt
            )
        }
        if let activeSession = state.activeSession {
            collect(
                projectID: activeSession.projectID,
                projectName: activeSession.projectName,
                startedAt: activeSession.startedAt
            )
        }

        func precedes(_ lhs: InsightsProjectOption, _ rhs: InsightsProjectOption) -> Bool {
            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
            return lhs.id < rhs.id
        }

        let historicalIDOptions = historicalByID.map { projectID, value in
            InsightsProjectOption(
                id: "historical-project-\(projectID.uuidString)",
                title: value.name,
                filter: .projectID(projectID)
            )
        }.sorted(by: precedes)
        let historicalNameOptions = historicalNames.map { name in
            InsightsProjectOption(
                id: "historical-name-\(name)",
                title: name,
                filter: .historicalName(name)
            )
        }.sorted(by: precedes)

        return currentProjects + historicalIDOptions + historicalNameOptions
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

    @discardableResult
    func updateProjectFolder(id: UUID, folderURL: URL) -> Bool {
        guard let index = state.projects.firstIndex(where: { $0.id == id }) else { return false }

        #if os(macOS)
        let bookmarkData = try? folderURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        #else
        let bookmarkData: Data? = nil
        #endif

        var nextState = state
        nextState.projects[index].folderPath = folderURL.path
        nextState.projects[index].bookmarkData = bookmarkData
        commit(nextState)
        return true
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

    @discardableResult
    func setWorkspaceAutomaticDiscovery(id: UUID, enabled: Bool) -> Bool {
        guard let index = state.activityGraph.workspaces.firstIndex(where: { $0.id == id }) else { return false }
        var nextState = state
        nextState.activityGraph.workspaces[index].automaticDiscoveryEnabled = enabled
        commit(nextState)
        return true
    }

    func deleteCompletedSession(id: UUID) {
        var nextState = state
        nextState.completedSessions.removeAll { $0.id == id }
        commit(nextState)
    }

    func completedSession(id: UUID) -> CompletedSession? {
        state.completedSessions.first(where: { $0.id == id })
    }

    @discardableResult
    func updateCompletedSession(
        id: UUID,
        type: SessionType,
        goal: String?,
        outcome: String?,
        project: CompletedSessionProjectAssignment,
        startedAt: Date
    ) -> Bool {
        guard let index = state.completedSessions.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let original = state.completedSessions[index]
        guard let shifted = original.shifted(to: startedAt) else { return false }

        let projectValues: (UUID?, String?)
        switch project {
        case .keepSnapshot:
            projectValues = (original.projectID, original.projectName)
        case .noProject:
            projectValues = (nil, nil)
        case .project(let projectID):
            guard let projectRecord = state.projects.first(where: { $0.id == projectID }) else {
                return false
            }
            projectValues = (projectRecord.id, projectRecord.name)
        }

        let updated = CompletedSession(
            id: original.id,
            projectID: projectValues.0,
            projectName: projectValues.1,
            type: type,
            goal: ActiveSession.cleanOptionalText(goal),
            outcome: ActiveSession.cleanOptionalText(outcome),
            startedAt: shifted.startedAt,
            endedAt: shifted.endedAt,
            pauseIntervals: shifted.pauseIntervals,
            gitContext: original.gitContext,
            githubContext: original.githubContext,
            developerToolContexts: original.developerToolContexts
        )

        var nextState = state
        nextState.completedSessions[index] = updated
        nextState.completedSessions.sort { $0.startedAt > $1.startedAt }
        commit(nextState)
        return true
    }

    func exportBackup(to fileURL: URL, at date: Date? = nil) throws {
        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: date ?? clock.now)
        try data.write(to: fileURL, options: .atomic)
    }

    func exportPersistenceRecoveryCopy(to fileURL: URL) throws {
        guard let persistence = persistence as? StatePersistenceRecoveryProviding else { return }
        try persistence.exportRecoveryCopy(to: fileURL)
    }

    private func commit(_ nextState: AppState) {
        state = nextState
        persistence.save(nextState)
        persistenceRecoveryIssue = (persistence as? StatePersistenceRecoveryProviding)?.recoveryIssue
    }

    private func attachCompatibilityRun(for session: ActiveSession, to state: inout AppState) {
        let workspaceID: UUID
        if let projectID = session.projectID,
           let workspace = state.activityGraph.workspaces.first(where: { $0.legacyProjectID == projectID || $0.id == projectID }) {
            workspaceID = workspace.id
        } else {
            let workspace = Workspace(
                id: session.projectID ?? UUID(),
                name: session.projectName ?? "No Project",
                createdAt: session.startedAt,
                source: session.projectID == nil ? .legacySession : .legacyProject,
                legacyProjectID: session.projectID
            )
            state.activityGraph.workspaces.append(workspace)
            workspaceID = workspace.id
        }
        let activity = Activity(
            workspaceID: workspaceID,
            title: session.goal ?? session.projectName ?? "Manual session",
            workType: session.type,
            createdAt: session.startedAt,
            legacySessionID: session.id
        )
        state.activityGraph.activities.append(activity)
        state.activityGraph.runs.append(Run(
            activityID: activity.id,
            kind: .manual,
            startedAt: session.startedAt,
            intervals: [Interval(state: .active, startedAt: session.startedAt, reason: "manualSession")],
            legacySessionID: session.id
        ))
    }

    private func transitionCompatibilityRun(for sessionID: UUID, to intervalState: IntervalState, at date: Date, in state: inout AppState) {
        guard let run = state.activityGraph.runs.last(where: { $0.legacySessionID == sessionID && $0.endedAt == nil }) else { return }
        try? ActivityGraphRepository.closeOpenInterval(in: &state.activityGraph, runID: run.id, at: date)
        try? ActivityGraphRepository.beginInterval(in: &state.activityGraph, runID: run.id, state: intervalState, at: date, reason: "manualSession")
    }

    private func endCompatibilityRun(for sessionID: UUID, at date: Date, in state: inout AppState) {
        guard let run = state.activityGraph.runs.last(where: { $0.legacySessionID == sessionID && $0.endedAt == nil }) else { return }
        try? ActivityGraphRepository.endRun(in: &state.activityGraph, runID: run.id, at: date)
    }

    private func processPendingIntegrationEvents(force: Bool = false) {
        let scanDate = clock.now
        if !force,
           let lastIntegrationScanAt,
           scanDate.timeIntervalSince(lastIntegrationScanAt) < 5 {
            return
        }
        lastIntegrationScanAt = scanDate

        var nextState = state
        let didProcessV1 = developerToolEventConsumer.processPending(state: &nextState, now: scanDate)
        let didProcessV2 = developerEventV2Consumer.processPending(
            state: &nextState,
            now: scanDate
        ) { [developerToolLifecycleCoordinator] event, sessionFingerprint, parentSessionFingerprint, state in
            developerToolLifecycleCoordinator.apply(
                event,
                sessionFingerprint: sessionFingerprint,
                parentSessionFingerprint: parentSessionFingerprint,
                to: &state
            )
        }
        guard didProcessV1 || didProcessV2 else {
            return
        }
        commit(nextState)
    }

    private func reconcileAgentRuns() {
        var nextState = state
        guard developerToolLifecycleCoordinator.reconcile(state: &nextState, now: clock.now) else { return }
        commit(nextState)
    }

    private func scheduleStartGitCapture(for sessionID: UUID, folderURL: URL) {
        gitCaptureSessionID = sessionID
        gitCaptureInProgress = true
        let service = gitService
        DispatchQueue.global(qos: .utility).async {
            let snapshot = service.captureStartSnapshot(at: folderURL)
            DispatchQueue.main.async { [weak self] in
                self?.applyStartGitSnapshot(snapshot, to: sessionID)
            }
        }
    }

    private func applyStartGitSnapshot(_ snapshot: GitStartSnapshot?, to sessionID: UUID) {
        guard var session = state.activeSession, session.id == sessionID else {
            clearGitCapture(for: sessionID)
            return
        }

        guard let snapshot else {
            clearGitCapture(for: sessionID)
            return
        }

        session.gitContext = GitSessionContext(
            repositoryRoot: snapshot.repositoryRoot.path,
            branchAtStart: snapshot.branch,
            startHeadSHA: snapshot.headSHA,
            startWasDetached: snapshot.isDetached,
            preExistingWorkingTreePaths: snapshot.preExistingWorkingTreePaths.map { $0.sorted() }
        )
        var nextState = state
        nextState.activeSession = session
        commit(nextState)

        if session.phase == .finishing {
            scheduleFinalGitCapture(for: sessionID)
        } else {
            clearGitCapture(for: sessionID)
        }

        scheduleGitHubCapture(for: sessionID, snapshot: snapshot)
    }

    private func scheduleGitHubCapture(for sessionID: UUID, snapshot: GitStartSnapshot) {
        let service = githubContextService
        let repositoryRoot = snapshot.repositoryRoot
        let branch = snapshot.branch
        let remotes = snapshot.remotes
        Task.detached(priority: .utility) { [service, repositoryRoot, branch, remotes, sessionID] in
            guard let repository = remotes
                .sorted(by: { lhs, rhs in
                    if lhs.name == "origin" { return rhs.name != "origin" }
                    if rhs.name == "origin" { return false }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                })
                .compactMap({ GitHubRemoteParser.parse($0.url) })
                .first else {
                return
            }

            let context = await service.captureContext(
                repositoryRoot: repositoryRoot,
                repository: repository,
                branch: branch
            )
            DispatchQueue.main.async { [weak self] in
                self?.applyGitHubContext(context, to: sessionID)
            }
        }
    }

    private func applyGitHubContext(_ context: GitHubSessionContext?, to sessionID: UUID) {
        guard let context else { return }

        if var session = state.activeSession, session.id == sessionID {
            guard session.githubContext != context else { return }
            session.githubContext = context
            var nextState = state
            nextState.activeSession = session
            commit(nextState)
            return
        }

        guard let completed = state.completedSessions.first(where: { $0.id == sessionID }),
              completed.githubContext != context else {
            return
        }

        let updated = CompletedSession(
            id: completed.id,
            projectID: completed.projectID,
            projectName: completed.projectName,
            type: completed.type,
            goal: completed.goal,
            outcome: completed.outcome,
            startedAt: completed.startedAt,
            endedAt: completed.endedAt,
            pauseIntervals: completed.pauseIntervals,
            gitContext: completed.gitContext,
            githubContext: context,
            developerToolContexts: completed.developerToolContexts
        )
        var nextState = state
        if let index = nextState.completedSessions.firstIndex(where: { $0.id == sessionID }) {
            nextState.completedSessions[index] = updated
            commit(nextState)
        }
    }

    private func scheduleFinalGitCapture(for sessionID: UUID) {
        guard let session = state.activeSession,
              session.id == sessionID,
              let gitContext = session.gitContext,
              let startSnapshot = gitStartSnapshot(from: gitContext) else {
            clearGitCapture(for: sessionID)
            return
        }

        gitCaptureSessionID = sessionID
        gitCaptureInProgress = true
        let service = gitService
        DispatchQueue.global(qos: .utility).async {
            let snapshot = service.captureFinishSnapshot(for: startSnapshot)
            DispatchQueue.main.async { [weak self] in
                self?.applyFinishGitSnapshot(snapshot, to: sessionID)
            }
        }
    }

    private func applyFinishGitSnapshot(_ snapshot: GitFinishSnapshot?, to sessionID: UUID) {
        guard var session = state.activeSession, session.id == sessionID else {
            clearGitCapture(for: sessionID)
            return
        }

        if let snapshot, var gitContext = session.gitContext {
            gitContext.branchAtEnd = snapshot.branch
            gitContext.endHeadSHA = snapshot.headSHA
            gitContext.endWasDetached = snapshot.isDetached
            gitContext.commitCount = snapshot.commitCount
            if let statistics = snapshot.statistics {
                gitContext.filesChanged = statistics.filesChanged
                gitContext.insertions = statistics.insertions
                gitContext.deletions = statistics.deletions
            }
            session.gitContext = gitContext

            var nextState = state
            nextState.activeSession = session
            commit(nextState)
        }
        clearGitCapture(for: sessionID)
    }

    private func clearGitCapture(for sessionID: UUID) {
        guard gitCaptureSessionID == sessionID else { return }
        gitCaptureSessionID = nil
        gitCaptureInProgress = false
    }

    private func projectFolderURL(for project: ProjectRecord) -> URL? {
        #if os(macOS)
        if let bookmarkData = project.bookmarkData {
            var isStale = false
            if let bookmarkedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return bookmarkedURL
            }
        }
        #endif

        guard let folderPath = project.folderPath else { return nil }
        return URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    private func gitStartSnapshot(from context: GitSessionContext) -> GitStartSnapshot? {
        guard !context.repositoryRoot.isEmpty else { return nil }
        return GitStartSnapshot(
            repositoryRoot: URL(fileURLWithPath: context.repositoryRoot, isDirectory: true),
            branch: context.branchAtStart,
            headSHA: context.startHeadSHA,
            isDetached: context.startWasDetached,
            preExistingWorkingTreePaths: context.preExistingWorkingTreePaths.map { Set($0) }
        )
    }
}
