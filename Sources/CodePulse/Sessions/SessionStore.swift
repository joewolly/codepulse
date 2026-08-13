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

    let persistence: StatePersisting
    let clock: SessionClock
    let gitService: GitServicing
    let githubContextService: GitHubContextServicing
    let developerToolEventConsumer: DeveloperToolEventConsuming
    let sessionAutomationCoordinator: SessionAutomationCoordinator
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
        automaticallyRefresh: Bool = true
    ) {
        self.persistence = persistence
        self.clock = clock
        self.gitService = gitService
        self.githubContextService = githubContextService
        self.developerToolEventConsumer = developerToolEventConsumer
        self.sessionAutomationCoordinator = SessionAutomationCoordinator()
        self.calendar = calendar
        self.state = persistence.load()
        self.now = clock.now
        self.gitCaptureSessionID = nil
        self.lastIntegrationScanAt = nil

        if state.activeSession?.phase == .idle {
            state.activeSession = nil
        }

        processPendingIntegrationEvents(force: true)
        restoreAutomaticFinishingState()
        evaluateAutomaticLifecycle(at: clock.now)

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
        SessionStore(
            persistence: JSONFilePersistence(),
            developerToolEventConsumer: DeveloperToolEventConsumer(
                inbox: DeveloperToolInbox()
            )
        )
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
        evaluateAutomaticLifecycle(at: now)
    }

    @discardableResult
    func startSession(
        projectID: UUID?,
        goal: String?,
        type: SessionType = .coding,
        at date: Date? = nil
    ) -> Bool {
        let didStart = startSessionInternal(
            projectID: projectID,
            goal: goal,
            type: type,
            at: date ?? clock.now,
            automationMetadata: nil
        )
        if didStart {
            processPendingIntegrationEvents(force: true)
        }
        return didStart
    }

    @discardableResult
    func startAutomatedSession(
        with rule: SessionAutomationRule,
        event: DeveloperToolEvent,
        at startDate: Date,
        signalAt: Date
    ) -> Bool {
        guard state.activeSession == nil,
              let project = state.projects.first(where: { $0.id == rule.projectID }),
              DeveloperToolProjectResolver.isUsableFolder(for: project),
              let tool = rule.developerTool else {
            return false
        }

        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedByTool: tool,
            lastMatchingSignalAt: signalAt,
            pauseEligibleAt: signalAt.addingTimeInterval(rule.pauseDelay),
            finishEligibleAt: signalAt.addingTimeInterval(rule.finishDelay),
            pauseDelay: rule.pauseDelay,
            finishDelay: rule.finishDelay,
            minimumSavedDuration: rule.minimumSavedDuration,
            claims: [SessionAutomationClaim(
                tool: event.tool,
                externalSessionID: event.externalSessionID,
                isActive: true,
                lastSignalAt: signalAt
            )]
        )

        return startSessionInternal(
            projectID: rule.projectID,
            goal: rule.goal,
            type: rule.sessionType,
            at: startDate,
            automationMetadata: metadata
        )
    }

    private func startSessionInternal(
        projectID: UUID?,
        goal: String?,
        type: SessionType,
        at startDate: Date,
        automationMetadata: SessionAutomationMetadata?
    ) -> Bool {
        guard state.activeSession == nil else { return false }

        let project = projectID.flatMap { id in state.projects.first(where: { $0.id == id }) }
        let folderURL = project.flatMap { projectFolderURL(for: $0) }
        let session = ActiveSession(
            projectID: project?.id,
            projectName: project?.name,
            type: type,
            goal: ActiveSession.cleanOptionalText(goal),
            startedAt: startDate,
            automationMetadata: automationMetadata
        )

        var nextState = state
        nextState.activeSession = session
        if let projectID,
           let index = nextState.projects.firstIndex(where: { $0.id == projectID }) {
            nextState.projects[index].lastUsedAt = startDate
        }
        commit(nextState)
        now = clock.now
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
        relinquishManualAutomationControl(in: &session)

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
        relinquishManualAutomationControl(in: &session)

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
        relinquishManualAutomationControl(in: &session)

        var nextState = state
        nextState.activeSession = session
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
        guard var session = state.activeSession,
              session.phase == .finishing else { return false }
        relinquishManualAutomationControl(in: &session)
        var nextState = state
        nextState.activeSession = session
        commit(nextState)
        return completeFinishedSession(outcome: outcome)
    }

    @discardableResult
    func discardSession() -> Bool {
        guard state.activeSession?.phase == .finishing else { return false }
        var nextState = state
        if var session = nextState.activeSession {
            relinquishManualAutomationControl(in: &session)
            nextState.activeSession = session
        }
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
        relinquishInvalidAutomation(in: &nextState)
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
        relinquishInvalidAutomation(in: &nextState)
        commit(nextState)
    }

    func updateSettings(_ update: (inout CodePulseSettings) -> Void) {
        var nextState = state
        update(&nextState.settings)
        relinquishInvalidAutomation(in: &nextState)
        commit(nextState)
    }

    var automationRulesSorted: [SessionAutomationRule] {
        state.automationRules.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func isAutomationRuleUsable(_ rule: SessionAutomationRule) -> Bool {
        guard state.projects.contains(where: { $0.id == rule.projectID }),
              let project = state.projects.first(where: { $0.id == rule.projectID }),
              let folderPath = DeveloperToolProjectResolver.folderPath(for: project),
              DeveloperToolProjectResolver.isUsableFolder(for: project) else {
            return false
        }
        return !folderPath.isEmpty
    }

    @discardableResult
    func upsertAutomationRule(_ rule: SessionAutomationRule) -> Bool {
        guard state.projects.contains(where: { $0.id == rule.projectID }) else { return false }
        var nextState = state
        if let index = nextState.automationRules.firstIndex(where: { $0.id == rule.id }) {
            nextState.automationRules[index] = rule
        } else {
            nextState.automationRules.append(rule)
        }
        relinquishInvalidAutomation(in: &nextState)
        commit(nextState)
        return true
    }

    func deleteAutomationRule(id: UUID) {
        var nextState = state
        nextState.automationRules.removeAll { $0.id == id }
        relinquishInvalidAutomation(in: &nextState)
        commit(nextState)
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

    private func commit(_ nextState: AppState) {
        state = nextState
        persistence.save(nextState)
    }

    private func processPendingIntegrationEvents(force: Bool = false) {
        let scanDate = clock.now
        if !force,
           let lastIntegrationScanAt,
           scanDate.timeIntervalSince(lastIntegrationScanAt) < 5 {
            return
        }
        lastIntegrationScanAt = scanDate

        var drainedState = state
        let pending = developerToolEventConsumer.drainPending(state: &drainedState, now: scanDate)
            .sorted { lhs, rhs in
                if lhs.event.timestamp != rhs.event.timestamp {
                    return lhs.event.timestamp < rhs.event.timestamp
                }
                return lhs.event.id.uuidString < rhs.event.id.uuidString
            }
        if drainedState != state {
            commit(drainedState)
        }

        for item in pending {
            if let action = sessionAutomationCoordinator.action(
                for: item.event,
                in: state,
                now: scanDate
            ) {
                applyAutomationAction(action, for: item.event, at: scanDate)
            }

            var attachedState = state
            if developerToolEventConsumer.attach(item.event, to: &attachedState, now: scanDate) {
                commit(attachedState)
            }

            var acknowledgedState = state
            _ = developerToolEventConsumer.markProcessed(item, in: &acknowledgedState, at: scanDate)
            if acknowledgedState != state {
                commit(acknowledgedState)
            }
            developerToolEventConsumer.cleanup(item)
        }
    }

    private func applyAutomationAction(
        _ action: SessionAutomationAction,
        for event: DeveloperToolEvent,
        at date: Date
    ) {
        switch action {
        case .start(let rule, let startDate):
            _ = startAutomatedSession(with: rule, event: event, at: startDate, signalAt: event.timestamp)
        case .signal(let rule, let tool, let externalSessionID, let isActive):
            applyAutomationSignal(
                rule: rule,
                tool: tool,
                externalSessionID: externalSessionID,
                isActive: isActive,
                signalAt: event.timestamp,
                transitionAt: date
            )
        case .relinquish:
            var nextState = state
            relinquishInvalidAutomation(in: &nextState)
            if nextState != state {
                commit(nextState)
            }
        }
    }

    private func applyAutomationSignal(
        rule: SessionAutomationRule,
        tool: DeveloperTool,
        externalSessionID: String,
        isActive: Bool,
        signalAt eventDate: Date,
        transitionAt date: Date
    ) {
        guard var session = state.activeSession,
              var metadata = session.automationMetadata,
              metadata.controlEnabled,
              session.phase == .running || session.phase == .paused else {
            return
        }

        let signalDate = max(metadata.lastMatchingSignalAt, eventDate)
        if let index = metadata.claims.firstIndex(where: {
            $0.tool == tool && $0.externalSessionID == externalSessionID
        }) {
            metadata.claims[index].isActive = isActive
            metadata.claims[index].lastSignalAt = max(metadata.claims[index].lastSignalAt, signalDate)
        } else if metadata.claims.count < DeveloperToolIntegrationLimits.maximumContextsPerSession {
            metadata.claims.append(SessionAutomationClaim(
                tool: tool,
                externalSessionID: externalSessionID,
                isActive: isActive,
                lastSignalAt: signalDate
            ))
        }

        if isActive {
            metadata.lastMatchingSignalAt = signalDate
            metadata.pauseEligibleAt = signalDate.addingTimeInterval(metadata.pauseDelay)
            metadata.finishEligibleAt = signalDate.addingTimeInterval(metadata.finishDelay)
        }
        if isActive, session.phase == .paused {
            _ = session.resume(at: date)
        }
        session.automationMetadata = metadata

        var nextState = state
        nextState.activeSession = session
        commit(nextState)
    }

    private func evaluateAutomaticLifecycle(at date: Date) {
        guard state.settings.automationEnabled,
              var session = state.activeSession,
              (session.phase == .running || session.phase == .paused),
              var metadata = session.automationMetadata,
              metadata.controlEnabled,
              !metadata.pendingAutomaticSave else {
            return
        }

        guard let rule = state.automationRules.first(where: { $0.id == metadata.startedByRuleID }),
              rule.isEnabled,
                  let project = state.projects.first(where: { $0.id == session.projectID }),
                  DeveloperToolProjectResolver.isUsableFolder(for: project) else {
            var nextState = state
            relinquishInvalidAutomation(in: &nextState)
            if nextState != state { commit(nextState) }
            return
        }

        let pauseEligibleAt = metadata.pauseEligibleAt
            ?? metadata.lastMatchingSignalAt.addingTimeInterval(metadata.pauseDelay)
        let finishEligibleAt = metadata.finishEligibleAt
            ?? metadata.lastMatchingSignalAt.addingTimeInterval(metadata.finishDelay)
        metadata.pauseEligibleAt = pauseEligibleAt
        metadata.finishEligibleAt = finishEligibleAt

        let hasRecentActiveClaim = metadata.claims.contains { claim in
            claim.isActive && date < claim.lastSignalAt.addingTimeInterval(metadata.pauseDelay)
        }
        guard !hasRecentActiveClaim else { return }

        if session.phase == .running, date >= pauseEligibleAt {
            if session.pause(at: pauseEligibleAt) {
                session.automationMetadata = metadata
                var nextState = state
                nextState.activeSession = session
                commit(nextState)
            }
        }

        guard let refreshedSession = state.activeSession,
              refreshedSession.phase == .paused,
              refreshedSession.automationMetadata?.controlEnabled == true,
              date >= finishEligibleAt else {
            return
        }
        finishAutomatically(at: min(date, finishEligibleAt))
    }

    private func finishAutomatically(at date: Date) {
        guard var session = state.activeSession,
              var metadata = session.automationMetadata,
              metadata.controlEnabled,
              !metadata.pendingAutomaticSave,
              (session.phase == .running || session.phase == .paused),
              session.finish(at: date) else {
            return
        }

        metadata.pendingAutomaticSave = true
        session.automationMetadata = metadata
        var nextState = state
        nextState.activeSession = session
        commit(nextState)
        now = clock.now

        if session.gitContext != nil {
            scheduleFinalGitCapture(for: session.id)
        } else if !gitCaptureInProgress {
            attemptAutomaticSaveIfReady(for: session.id)
        }
    }

    private func restoreAutomaticFinishingState() {
        guard let session = state.activeSession, session.phase == .finishing else { return }

        if session.automationMetadata?.pendingAutomaticSave == true {
            if session.gitContext != nil {
                scheduleFinalGitCapture(for: session.id)
            } else if let project = session.projectID.flatMap({ id in
                state.projects.first(where: { $0.id == id })
            }),
                      let folderURL = projectFolderURL(for: project),
                      FileManager.default.fileExists(atPath: folderURL.path) {
                // A relaunch can interrupt the initial Git capture. Recreate
                // that boundary before attempting the final capture/save.
                scheduleStartGitCapture(for: session.id, folderURL: folderURL)
            } else {
                attemptAutomaticSaveIfReady(for: session.id)
            }
        } else if session.gitContext != nil {
            scheduleFinalGitCapture(for: session.id)
        }
    }

    private func attemptAutomaticSaveIfReady(for sessionID: UUID) {
        guard !gitCaptureInProgress,
              let session = state.activeSession,
              session.id == sessionID,
              session.phase == .finishing,
              let metadata = session.automationMetadata,
              metadata.pendingAutomaticSave else {
            return
        }

        let endedAt = session.endedAt ?? clock.now
        if session.activeDuration(at: endedAt) < metadata.minimumSavedDuration {
            var nextState = state
            nextState.activeSession = nil
            commit(nextState)
            gitCaptureSessionID = nil
            gitCaptureInProgress = false
            now = clock.now
            return
        }

        _ = completeFinishedSession(outcome: nil, refreshAfter: false)
    }

    private func completeFinishedSession(outcome: String?, refreshAfter: Bool = true) -> Bool {
        guard !gitCaptureInProgress,
              let session = state.activeSession,
              let completed = session.completedSnapshot(outcome: outcome) else {
            return false
        }

        var nextState = state
        nextState.completedSessions.append(completed)
        nextState.completedSessions.sort { $0.startedAt > $1.startedAt }
        nextState.activeSession = nil
        commit(nextState)
        gitCaptureSessionID = nil
        gitCaptureInProgress = false
        now = clock.now
        if refreshAfter { refresh() }
        return true
    }

    private func relinquishManualAutomationControl(in session: inout ActiveSession) {
        guard var metadata = session.automationMetadata else { return }
        metadata.controlEnabled = false
        metadata.pendingAutomaticSave = false
        session.automationMetadata = metadata
    }

    private func relinquishInvalidAutomation(in state: inout AppState) {
        guard var session = state.activeSession,
              var metadata = session.automationMetadata else {
            return
        }

        let ruleIsValid: Bool = {
            guard state.settings.automationEnabled,
                  let rule = state.automationRules.first(where: { $0.id == metadata.startedByRuleID }),
                  rule.isEnabled,
                  let project = state.projects.first(where: { $0.id == session.projectID }),
                  DeveloperToolProjectResolver.folderPath(for: project) != nil else {
                return false
            }
            return true
        }()

        guard !ruleIsValid else { return }
        metadata.controlEnabled = false
        metadata.pendingAutomaticSave = false
        session.automationMetadata = metadata
        state.activeSession = session
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
            attemptAutomaticSaveIfReady(for: sessionID)
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
        attemptAutomaticSaveIfReady(for: sessionID)

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
            attemptAutomaticSaveIfReady(for: sessionID)
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
        attemptAutomaticSaveIfReady(for: sessionID)
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
