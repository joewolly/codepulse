import Combine
import CodePulseIntegration
import Foundation
import ServiceManagement

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

struct SessionLifecycleErrorPresentation: Equatable {
    let message: String
    let affectedSessionID: UUID?
}

enum SessionAutomationRuleStatus: Equatable, Sendable {
    case disabled
    case automationOff
    case invalidRule
    case missingPreset
    case missingProject
    case projectArchived
    case needsRelink
    case enabled

    var label: String {
        switch self {
        case .disabled:
            return "Disabled"
        case .automationOff:
            return "Enabled · Automation Off"
        case .invalidRule:
            return "Needs attention · Invalid rule"
        case .missingPreset:
            return "Needs attention · Missing preset"
        case .missingProject:
            return "Needs attention · Missing project"
        case .projectArchived:
            return "Project Archived"
        case .needsRelink:
            return "Needs Relink"
        case .enabled:
            return "Enabled"
        }
    }
}

enum ProjectArchiveError: LocalizedError, Equatable {
    case projectNotFound
    case alreadyArchived
    case alreadyActive
    case activeSession
    case recoveryMode

    var errorDescription: String? {
        switch self {
        case .projectNotFound:
            return "The project could not be found."
        case .alreadyArchived:
            return "The project is already archived."
        case .alreadyActive:
            return "The project is already active."
        case .activeSession:
            return "Finish or discard the current session before archiving this project."
        case .recoveryMode:
            return "CodePulse saved data is unavailable until a valid backup is restored."
        }
    }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var stateRevision = 0
    @Published private(set) var now: Date
    /// Compatibility aggregate for the original menu-bar callers. The
    /// authoritative capture state is `gitCaptureStates`, keyed by Session
    /// UUID; this flag is never consulted to decide another Session's
    /// lifecycle or save eligibility.
    @Published private(set) var gitCaptureInProgress = false
    @Published private(set) var gitCaptureStates: [UUID: SessionGitCaptureState] = [:]
    @Published private(set) var lifecycleError: SessionLifecycleErrorPresentation?
    var lifecycleErrorMessage: String? { lifecycleError?.message }
    var lifecycleErrorSessionID: UUID? { lifecycleError?.affectedSessionID }
    @Published private(set) var isInRecoveryMode: Bool

    let persistence: StatePersisting
    let clock: SessionClock
    let gitService: GitServicing
    let githubContextService: GitHubContextServicing
    let developerToolEventConsumer: DeveloperToolEventConsuming
    let sessionAutomationCoordinator: SessionAutomationCoordinator
    let frontmostApplicationMonitor: FrontmostApplicationMonitoring?
    let controlTransport: CodePulseControlTransport?
    var calendar: Calendar
    private var refreshTimer: Timer?
    private struct AsyncJobIdentity: Equatable {
        let token: UUID
        let stateGeneration: UUID
    }
    private var githubCaptureJobs: [UUID: AsyncJobIdentity] = [:]
    /// Replacing/restoring state invalidates every callback from the prior
    /// state generation, even when a UUID is later reused by the replacement.
    private var stateGeneration = UUID()
    private var lastIntegrationScanAt: Date?
    private let controlLaunchDate: Date
    private var lastControlScanAt: Date?
    private var isMonitoringApplications = false
    private let currentLaunchAtLoginState: () -> Bool
    private(set) var currentFrontmostApplication: ApplicationIdentity?
    private var lastCriticalCommitFailed = false
    private var controlCommandNeedsRetry = false

    init(
        persistence: StatePersisting,
        clock: SessionClock = SystemSessionClock(),
        calendar: Calendar = .autoupdatingCurrent,
        gitService: GitServicing = SystemGitService(),
        githubContextService: GitHubContextServicing = SystemGitHubContextService(),
        developerToolEventConsumer: DeveloperToolEventConsuming = DeveloperToolEventConsumer(),
        automaticallyRefresh: Bool = true,
        frontmostApplicationMonitor: FrontmostApplicationMonitoring? = nil,
        controlTransport: CodePulseControlTransport? = nil,
        currentLaunchAtLoginState: @escaping () -> Bool = { SMAppService.mainApp.status == .enabled }
    ) {
        self.persistence = persistence
        self.clock = clock
        self.gitService = gitService
        self.githubContextService = githubContextService
        self.developerToolEventConsumer = developerToolEventConsumer
        self.sessionAutomationCoordinator = SessionAutomationCoordinator()
        self.frontmostApplicationMonitor = frontmostApplicationMonitor
        self.controlTransport = controlTransport
        self.calendar = calendar
        self.currentLaunchAtLoginState = currentLaunchAtLoginState
        let loadedState = persistence.load()
        let recoveryMode = persistence.loadStatus.requiresRecovery
        self.state = loadedState
        self.isInRecoveryMode = recoveryMode
        let initialNow = clock.now
        self.now = initialNow
        self.lastIntegrationScanAt = nil
        self.controlLaunchDate = initialNow
        self.lastControlScanAt = nil
        self.currentFrontmostApplication = nil
        self.lifecycleError = recoveryMode
            ? SessionLifecycleErrorPresentation(
                message: "CodePulse could not read its saved data. The original state file was left unchanged.",
                affectedSessionID: nil
            )
            : nil
        self.lastCriticalCommitFailed = false
        self.controlCommandNeedsRetry = false

        self.frontmostApplicationMonitor?.onChange = { [weak self] application in
            self?.handleFrontmostApplication(application)
        }

        if !isInRecoveryMode,
           state.activeSessions.count == 1,
           state.activeSessions[0].phase == .idle {
            state.activeSessions.removeAll()
        }

        if !isInRecoveryMode {
            var normalizedState = state
            normalizeProjectConfiguration(in: &normalizedState)
            relinquishInvalidAutomation(in: &normalizedState)
            if normalizedState != state {
                state = normalizedState
                persistence.save(normalizedState)
            }

            processPendingControlCommands(force: true)
            processPendingIntegrationEvents(force: true)
            restoreAutomaticFinishingState()
            evaluateAutomaticLifecycle(at: clock.now)
            configureApplicationMonitoring()
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
        frontmostApplicationMonitor?.stop()
    }

    static func live() -> SessionStore {
        SessionStore(
            persistence: JSONFilePersistence(),
            developerToolEventConsumer: DeveloperToolEventConsumer(
                inbox: DeveloperToolInbox()
            ),
            frontmostApplicationMonitor: NSWorkspaceFrontmostApplicationMonitor(),
            controlTransport: CodePulseControlTransport()
        )
    }

    var activeSession: ActiveSession? { state.soleActiveSession }

    /// Returns the aggregate status for one Session's Git work. A terminal
    /// status is retained until that Session retires so UI/tests can explain
    /// why saving is or is not available.
    func gitCaptureStatus(for sessionID: UUID) -> SessionGitCaptureStatus? {
        gitCaptureStates[sessionID]?.aggregateStatus
    }

    func isGitCaptureInProgress(for sessionID: UUID) -> Bool {
        gitCaptureStates[sessionID]?.isInFlight == true
    }

#if DEBUG
    /// Narrow presentation-test hook. Production lifecycle authority never
    /// consults or calls this; tests use it to model independent in-flight
    /// capture state without scheduling real Git processes.
    func setGitCaptureStateForPresentationTesting(
        _ captureState: SessionGitCaptureState?,
        sessionID: UUID
    ) {
        gitCaptureStates[sessionID] = captureState
        refreshGitCaptureAggregate()
    }
#endif

    var hasAnyRelevantGitCaptureInProgress: Bool {
        gitCaptureStates.values.contains(where: \.isInFlight)
    }

    private var hasAnyRelevantCaptureOrEnrichmentInProgress: Bool {
        hasAnyRelevantGitCaptureInProgress || !githubCaptureJobs.isEmpty
    }

    private func refreshGitCaptureAggregate() {
        let value = hasAnyRelevantGitCaptureInProgress
        if gitCaptureInProgress != value {
            gitCaptureInProgress = value
        }
    }

    /// A newly completed same-root observation can make a different
    /// Session's already-terminal Git numbers ambiguous. Reflect that derived
    /// outcome in the per-Session status without disturbing an in-flight
    /// start/final job.
    private func refreshTerminalGitCaptureStatuses() {
        // Snapshot the keys before assigning updated values. This keeps the
        // reconciliation safe even on runtimes that treat value assignment as
        // a dictionary mutation during key-view iteration.
        for sessionID in Array(gitCaptureStates.keys) {
            guard var capture = gitCaptureStates[sessionID],
                  !capture.isInFlight,
                  state.activeSession(id: sessionID)?.gitContext?.deltaAttribution == .ambiguous else {
                continue
            }
            if capture.finalStatus != nil {
                capture.finalStatus = .ambiguous
            } else if capture.startStatus != nil {
                capture.startStatus = .ambiguous
            }
            gitCaptureStates[sessionID] = capture
        }
    }

    private func replaceActiveSession(_ session: ActiveSession, in state: inout AppState) -> Bool {
        guard let index = state.activeSessionIndex(id: session.id) else { return false }
        state.activeSessions[index] = session
        return true
    }

    var phase: SessionPhase {
        state.soleActiveSession?.phase ?? .idle
    }

    var shouldPresentOnboarding: Bool {
        !isInRecoveryMode && !state.settings.hasCompletedOnboarding
    }

    var activeAutomationStatusLabel: String? {
        guard let sessionID = state.soleActiveSession?.id else { return nil }
        return automationStatusLabel(for: sessionID)
    }

    func automationStatusLabel(for sessionID: UUID) -> String? {
        guard let metadata = state.activeSession(id: sessionID)?.automationMetadata,
              metadata.controlEnabled else {
            return nil
        }

        let activeClaims = metadata.claims.filter(\.isActive)
        let labels = Set(activeClaims.map { claim -> String in
            switch claim.source {
            case .developerTool(let tool, _):
                return tool.title
            case .application(let bundleIdentifier):
                return applicationDisplayName(for: bundleIdentifier) ?? bundleIdentifier
            }
        })

        if labels.count == 1, let label = labels.first {
            return "Automatic · \(label)"
        }
        if labels.isEmpty {
            switch metadata.startedBySource {
            case .developerTool(let tool, _):
                return "Automatic · \(tool.title)"
            case .application(let bundleIdentifier):
                return "Automatic · \(applicationDisplayName(for: bundleIdentifier) ?? bundleIdentifier)"
            }
        }
        return "Automatic · Multiple"
    }

    var menuBarAccessibilityText: String {
        let sessions = state.activeSessions
        if sessions.count > 1 {
            let counts = activeSessionCounts
            return "CodePulse, \(counts.total) active sessions, \(counts.running) running, \(counts.paused) paused, \(counts.finishing) finishing"
        }
        switch phase {
        case .idle:
            return "CodePulse, ready to start a session"
        case .running, .paused, .finishing:
            let phaseDescription: String
            switch phase {
            case .running:
                phaseDescription = "running"
            case .paused:
                phaseDescription = "paused"
            case .finishing:
                phaseDescription = "finishing"
            case .idle:
                phaseDescription = "ready to start a session"
            }
            let project = activeSession?.projectName.flatMap { $0.isEmpty ? nil : $0 } ?? "No Project"
            let sessionType = activeSession?.type.title ?? SessionType.coding.title
            let duration = CodePulseFormatting.duration(elapsedDuration, includeSeconds: true)
            let automation = activeAutomationStatusLabel.map { ", \($0)" } ?? ""
            return "CodePulse, \(phaseDescription), \(project), \(sessionType), \(duration)\(automation)"
        }
    }

    func dismissLifecycleError() {
        lifecycleError = nil
    }

    var elapsedDuration: TimeInterval {
        guard let session = state.soleActiveSession else { return 0 }
        return session.activeDuration(at: now)
    }

    func elapsedDuration(for sessionID: UUID) -> TimeInterval {
        state.activeSession(id: sessionID)?.activeDuration(at: now) ?? 0
    }

    var activeSessionCounts: (total: Int, running: Int, paused: Int, finishing: Int) {
        let sessions = state.activeSessions
        return (
            sessions.count,
            sessions.filter { $0.phase == .running }.count,
            sessions.filter { $0.phase == .paused }.count,
            sessions.filter { $0.phase == .finishing }.count
        )
    }

    var defaultProjectID: UUID? {
        defaultProjectID(for: selectedWorkspaceID)
    }

    /// Resolves the configured default without changing it. When a specific
    /// default belongs to another workspace, idle presentation returns No
    /// Project until the user chooses a project; the saved preference remains
    /// intact and is never silently reassigned.
    func defaultProjectID(for workspaceID: UUID?) -> UUID? {
        switch state.settings.defaultProjectBehavior {
        case .noProject:
            return nil
        case .specificProject:
            guard let specificProjectID = state.settings.specificProjectID,
                  let project = state.projects.first(where: { $0.id == specificProjectID && $0.isActive }),
                  workspaceID == nil || project.workspaceID == workspaceID else {
                return nil
            }
            return specificProjectID
        case .lastUsed:
            return state.projects
                .filter { project in
                    project.isActive && (workspaceID == nil || project.workspaceID == workspaceID)
                }
                .compactMap { project in
                    project.lastUsedAt.map { (project.id, $0) }
                }
                .max(by: { $0.1 < $1.1 })?.0
        }
    }

    var selectedWorkspaceID: UUID? {
        guard let selected = state.settings.selectedWorkspaceID,
              state.workspaces.contains(where: { $0.id == selected }) else {
            return state.workspaces.first?.id
        }
        return selected
    }

    var selectedWorkspace: WorkspaceRecord? {
        selectedWorkspaceID.flatMap { id in
            state.workspaces.first(where: { $0.id == id })
        }
    }

    var workspacesSorted: [WorkspaceRecord] {
        state.workspaces.sorted { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    var workspaceScopeOptions: [WorkspaceScopeOption] {
        [WorkspaceScopeOption(
            id: "all-workspaces",
            title: "All Workspaces",
            scope: .allWorkspaces
        )] + workspacesSorted.map { workspace in
            WorkspaceScopeOption(
                id: "workspace-\(workspace.id.uuidString)",
                title: workspace.name,
                scope: .workspaceID(workspace.id)
            )
        }
    }

    func projects(in workspaceID: UUID) -> [ProjectRecord] {
        state.projects.filter { $0.workspaceID == workspaceID }
    }

    func selectableProjectsSortedByRecentUse(in workspaceID: UUID?) -> [ProjectRecord] {
        let projects = state.projects.filter { project in
            project.isActive && (workspaceID == nil || project.workspaceID == workspaceID)
        }
        return sortProjectsByRecentUse(projects)
    }

    func workspaceProjectIDs(for scope: WorkspaceScope) -> Set<UUID> {
        switch scope {
        case .allWorkspaces:
            return Set(state.projects.map(\.id))
        case .workspaceID(let workspaceID):
            return Set(state.projects.filter { $0.workspaceID == workspaceID }.map(\.id))
        }
    }

    /// Changes only durable presentation/navigation state for future manual
    /// work. Active Session ownership is UUID-backed and remains untouched.
    @discardableResult
    func selectWorkspace(id: UUID) -> Bool {
        guard !isInRecoveryMode,
              state.workspaces.contains(where: { $0.id == id }) else {
            return false
        }
        guard state.settings.selectedWorkspaceID != id else { return true }
        var nextState = state
        nextState.settings.selectedWorkspaceID = id
        return commit(nextState)
    }

    var projectsSortedByRecentUse: [ProjectRecord] {
        sortProjectsByRecentUse(state.projects)
    }

    var activeProjectsSortedByRecentUse: [ProjectRecord] {
        sortProjectsByRecentUse(state.projects.filter(\.isActive))
    }

    var archivedProjectsSortedByRecentUse: [ProjectRecord] {
        sortProjectsByRecentUse(state.projects.filter(\.isArchived))
    }

    /// Projects that may be selected for future manual work. Folder relinking
    /// remains a separate concern; manual sessions have historically allowed a
    /// project whose folder is currently unresolved.
    var selectableProjectsSortedByRecentUse: [ProjectRecord] {
        activeProjectsSortedByRecentUse
    }

    var automationEligibleProjects: [ProjectRecord] {
        activeProjectsSortedByRecentUse.filter { !$0.requiresRelink }
    }

    private func sortProjectsByRecentUse(_ projects: [ProjectRecord]) -> [ProjectRecord] {
        projects.sorted { lhs, rhs in
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

    func isProjectAvailableForManualStart(_ projectID: UUID?) -> Bool {
        guard let projectID else { return true }
        return state.projects.contains { $0.id == projectID && $0.isActive }
    }

    func isSessionPresetAvailableForManualStart(_ preset: SessionPreset) -> Bool {
        preset.isValid && isProjectAvailableForManualStart(preset.projectID)
    }

    var sessionPresetsAvailableForManualStart: [SessionPreset] {
        sessionPresetsSorted.filter(isSessionPresetAvailableForManualStart)
    }

    var sessionPresetsAvailableForAutomation: [SessionPreset] {
        sessionPresetsSorted.filter(isPresetUsableForAutomation)
    }

    /// New developer-tool rules use these values as session templates. Their
    /// runtime project comes from the triggering event, so only projectless
    /// presets are offered for new configuration.
    var sessionPresetsAvailableForDeveloperAutomation: [SessionPreset] {
        sessionPresetsSorted.filter { $0.projectID == nil && isDeveloperToolPresetUsable($0) }
    }

    func projectsForPresetEditing(_ preset: SessionPreset?) -> [ProjectRecord] {
        var projects = activeProjectsSortedByRecentUse
        if let archivedProjectID = preset?.projectID,
           let archivedProject = state.projects.first(where: { $0.id == archivedProjectID && $0.isArchived }) {
            projects.append(archivedProject)
        }
        return projects
    }

    /// Presets offered for a developer-tool rule. New rules can select only
    /// projectless templates. An existing developer rule may retain its
    /// current project-backed preset as a legacy compatibility option, while
    /// project-backed presets from other projects stay hidden.
    func developerToolPresetsForAutomationEditing(_ rule: SessionAutomationRule?) -> [SessionPreset] {
        let projectlessIDs = Set(
            sessionPresetsSorted
                .filter { $0.projectID == nil && isDeveloperToolPresetUsable($0) }
                .map(\.id)
        )
        let legacyPresetID: UUID?
        if let rule,
           rule.trigger.developerTool != nil,
           let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
           preset.projectID != nil {
            legacyPresetID = preset.id
        } else {
            legacyPresetID = nil
        }

        let allowedIDs = projectlessIDs.union(legacyPresetID.map { [$0] } ?? [])
        return sessionPresetsSorted.filter { allowedIDs.contains($0.id) }
    }

    /// Presets offered for a frontmost-application rule remain project-bound.
    /// The current preset is retained for editing even when its project is
    /// archived or needs relinking, matching existing repair behavior.
    func applicationPresetsForAutomationEditing(_ rule: SessionAutomationRule?) -> [SessionPreset] {
        sessionPresetsSorted.filter { preset in
            isPresetUsableForAutomation(preset) || preset.id == rule?.presetID
        }
    }

    /// The default editor path is developer-tool scoped because a newly
    /// created rule starts with the Developer Tool trigger.
    func presetsForAutomationEditing(_ rule: SessionAutomationRule?) -> [SessionPreset] {
        if rule?.trigger.applicationTrigger != nil {
            return applicationPresetsForAutomationEditing(rule)
        }
        return developerToolPresetsForAutomationEditing(rule)
    }

    func isPresetUsableForAutomation(_ preset: SessionPreset) -> Bool {
        guard let projectID = preset.projectID,
              let project = state.projects.first(where: { $0.id == projectID }),
              project.isActive else {
            return false
        }
        return DeveloperToolProjectResolver.isUsableFolder(for: project)
    }

    func isDeveloperToolPresetUsable(_ preset: SessionPreset) -> Bool {
        guard preset.isValid else { return false }
        guard let projectID = preset.projectID else { return true }
        guard let project = state.projects.first(where: { $0.id == projectID }),
              project.isActive else {
            return false
        }
        return DeveloperToolProjectResolver.isUsableFolder(for: project)
    }

    func refresh() {
        guard !isInRecoveryMode else { return }
        now = clock.now
        processPendingControlCommands()
        processPendingIntegrationEvents()
        evaluateAutomaticLifecycle(at: now)
    }

    /// The historical one-session UI refreshes immediately after a lifecycle
    /// transition. With concurrent Sessions, that collection-wide pass could
    /// mutate an unrelated automated Session as a side effect of targeting
    /// this one. Keep the compatibility refresh only while the target remains
    /// the sole active Session; otherwise advance the display clock without
    /// running another Session's lifecycle evaluator.
    private func refreshAfterLifecycleMutation(for sessionID: UUID) {
        now = clock.now
        // With no remaining active Session there is no unrelated lifecycle
        // owner to advance, so retain the historical post-retirement refresh
        // (including a pending integration-event drain). When another Session
        // remains, only refresh while the target is still the sole owner.
        if state.activeSessions.isEmpty {
            refresh()
            return
        }
        guard state.activeSessions.count == 1,
              state.activeSession(id: sessionID) != nil else {
            return
        }
        refresh()
    }

    /// Feeds only the current frontmost identity into the coordinator. No
    /// activation history is retained or persisted.
    func handleFrontmostApplication(_ application: ApplicationIdentity?) {
        guard !isInRecoveryMode else { return }
        currentFrontmostApplication = application?.isValid == true ? application : nil
        guard state.settings.automationEnabled else { return }

        let actions = sessionAutomationCoordinator.applicationActions(
            for: currentFrontmostApplication,
            in: state,
            now: clock.now
        )
        for action in actions {
            _ = applyAutomationAction(action, for: nil, at: clock.now)
        }
        evaluateAutomaticLifecycle(at: clock.now)
    }

    private func configureApplicationMonitoring() {
        guard let frontmostApplicationMonitor else { return }

        let needsMonitoring = state.settings.automationEnabled && state.automationRules.contains { rule in
            rule.isEnabled && rule.applicationTrigger != nil && isAutomationRuleUsable(rule)
        }

        if needsMonitoring {
            if !isMonitoringApplications {
                isMonitoringApplications = true
                frontmostApplicationMonitor.start()
                handleFrontmostApplication(frontmostApplicationMonitor.currentApplication)
            }
        } else if isMonitoringApplications {
            isMonitoringApplications = false
            frontmostApplicationMonitor.stop()
            currentFrontmostApplication = nil
        }
    }

    private func isAutomationTriggerValid(_ trigger: SessionAutomationTrigger) -> Bool {
        switch trigger {
        case .developerTool(let tool):
            return DeveloperTool.allCases.contains(tool)
        case .applications(let applicationTrigger):
            return applicationTrigger.isValid
                && !applicationTrigger.applications.contains(where: SessionAutomationCoordinator.isDeveloperToolApplication)
        }
    }

    private func sourceMatchesTrigger(
        _ source: SessionAutomationClaimSource,
        trigger: SessionAutomationTrigger
    ) -> Bool {
        switch source {
        case .developerTool(let tool, _):
            return trigger.developerTool == tool
        case .application(let bundleIdentifier):
            return trigger.applicationTrigger?.matches(bundleIdentifier: bundleIdentifier) == true
        }
    }

    private func applicationDisplayName(for bundleIdentifier: String) -> String? {
        state.automationRules
            .compactMap { $0.applicationTrigger?.displayName(for: bundleIdentifier) }
            .first
    }

    @discardableResult
    func startSession(
        projectID: UUID?,
        goal: String?,
        type: SessionType = .coding,
        at date: Date? = nil
    ) -> Bool {
        // Keep the menu-bar compatibility entry point's original single-
        // Session behavior. Phase 2 callers that need concurrent manual
        // Sessions use `createManualSession`, which returns the new UUID.
        guard state.activeSessions.isEmpty else { return false }
        let didStart = createManualSession(
            projectID: projectID,
            goal: goal,
            type: type,
            at: date
        ) != nil
        if didStart {
            processPendingIntegrationEvents(force: true)
        }
        return didStart
    }

    /// Creates and durably commits one manual Session, returning its stable
    /// UUID only after the critical start state has been persisted. Existing
    /// active Sessions are left unchanged, subject only to the new Project's
    /// `lastUsedAt` update.
    @discardableResult
    func createManualSession(
        projectID: UUID?,
        goal: String?,
        type: SessionType = .coding,
        at date: Date? = nil
    ) -> UUID? {
        guard let prepared = preparedStartState(
            projectID: projectID,
            goal: goal,
            type: type,
            at: date ?? clock.now,
            automationMetadata: nil,
            gitDiscoveryFolderURL: nil
        ) else {
            return nil
        }
        guard commit(prepared.state, critical: true, normalizeAutomation: false) else { return nil }
        now = clock.now
        scheduleStartGitCaptureIfNeeded(for: prepared.session, folderURL: prepared.folderURL)
        return prepared.session.id
    }

    @discardableResult
    func createManualSession(using preset: SessionPreset, at date: Date? = nil) -> UUID? {
        createManualSession(
            projectID: preset.projectID,
            goal: preset.goal,
            type: preset.sessionType,
            at: date
        )
    }

    @discardableResult
    func startSession(using preset: SessionPreset, at date: Date? = nil) -> Bool {
        startSession(
            projectID: preset.projectID,
            goal: preset.goal,
            type: preset.sessionType,
            at: date
        )
    }

    @discardableResult
    func startAutomatedSession(
        with rule: SessionAutomationRule,
        event: DeveloperToolEvent,
        at startDate: Date,
        signalAt: Date
    ) -> Bool {
        guard let resolvedProjectID = DeveloperToolProjectResolver.projectID(
            for: event.workingDirectory,
            in: state.projects
        ) else {
            return false
        }
        guard let canonicalWorkingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(
            for: event.workingDirectory
        ) else {
            return false
        }

        return startAutomatedSession(
            with: rule,
            resolvedProjectID: resolvedProjectID,
            event: event,
            source: .developerTool(
                tool: event.tool,
                externalSessionID: event.externalSessionID
            ),
            at: startDate,
            signalAt: signalAt,
            gitDiscoveryFolderURL: URL(fileURLWithPath: canonicalWorkingDirectory, isDirectory: true)
        )
    }

    /// Direct developer-tool starts must receive the project resolved from the
    /// event that caused them. Keeping this value in the call boundary prevents
    /// a later mutation from consulting a global current-project variable.
    @discardableResult
    private func startAutomatedSession(
        with rule: SessionAutomationRule,
        resolvedProjectID: UUID,
        event: DeveloperToolEvent,
        source: SessionAutomationClaimSource,
        at startDate: Date,
        signalAt: Date,
        gitDiscoveryFolderURL: URL?
    ) -> Bool {
        guard DeveloperToolProjectResolver.projectID(
                  for: event.workingDirectory,
                  in: state.projects
              ) == resolvedProjectID else {
            return false
        }
        guard case .developerTool(let sourceTool, let sourceSessionID) = source,
              sourceTool == event.tool,
              sourceSessionID == event.externalSessionID else {
            return false
        }
        return startAutomatedSession(
            with: rule,
            resolvedProjectID: resolvedProjectID,
            source: source,
            at: startDate,
            signalAt: signalAt,
            gitDiscoveryFolderURL: gitDiscoveryFolderURL
        )
    }

    @discardableResult
    private func startAutomatedSession(
        with rule: SessionAutomationRule,
        resolvedProjectID: UUID,
        source: SessionAutomationClaimSource,
        at startDate: Date,
        signalAt: Date,
        gitDiscoveryFolderURL: URL? = nil
    ) -> Bool {
        guard rule.isEnabled,
              rule.isValid,
              case .developerTool = source,
              state.activeSessions.isEmpty,
              let project = state.projects.first(where: { $0.id == resolvedProjectID }),
              project.isActive,
              DeveloperToolProjectResolver.isUsableFolder(for: project),
              let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
              isDeveloperToolPresetUsable(preset),
              // Legacy developer-tool presets retain their project as an
              // eligibility constraint. Projectless presets are reusable
              // templates, but neither kind supplies the runtime project.
              SessionAutomationCoordinator.developerToolPresetMatchesRuntimeProject(
                  preset,
                  resolvedProjectID: resolvedProjectID
              ),
              isAutomationTriggerValid(rule.trigger),
              sourceMatchesTrigger(source, trigger: rule.trigger) else {
            return false
        }

        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedBySource: source,
            lastMatchingSignalAt: signalAt,
            pauseEligibleAt: signalAt.addingTimeInterval(rule.pauseDelay),
            finishEligibleAt: signalAt.addingTimeInterval(rule.finishDelay),
            pauseDelay: rule.pauseDelay,
            finishDelay: rule.finishDelay,
            minimumSavedDuration: rule.minimumSavedDuration,
            claims: [SessionAutomationClaim(
                source: source,
                isActive: true,
                lastSignalAt: signalAt
            )]
        )

        return startSessionInternal(
            projectID: resolvedProjectID,
            goal: preset.goal,
            type: preset.sessionType,
            at: startDate,
            automationMetadata: metadata,
            gitDiscoveryFolderURL: gitDiscoveryFolderURL
        )
    }

    @discardableResult
    func startAutomatedSession(
        with rule: SessionAutomationRule,
        source: SessionAutomationClaimSource,
        at startDate: Date,
        signalAt: Date
    ) -> Bool {
        guard rule.isEnabled,
              rule.isValid,
              case .application(let bundleIdentifier) = source else { return false }

        let hasApplicationOwner = state.activeSessions.contains {
            if case .application = $0.automationMetadata?.startedBySource { return true }
            return false
        }
        guard !hasApplicationOwner,
              state.activeSessions.count < ConcurrentSessionLimits.maximumActiveSessions,
              let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
              let projectID = preset.projectID,
              isPresetUsableForAutomation(preset),
              isAutomationTriggerValid(rule.trigger),
              !SessionAutomationCoordinator.isDeveloperToolApplicationBundleIdentifier(bundleIdentifier),
              rule.applicationTrigger?.applications.contains(where: SessionAutomationCoordinator.isDeveloperToolApplication) != true,
              sourceMatchesTrigger(source, trigger: rule.trigger) else {
            return false
        }

        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedBySource: source,
            lastMatchingSignalAt: signalAt,
            pauseEligibleAt: signalAt.addingTimeInterval(rule.pauseDelay),
            finishEligibleAt: signalAt.addingTimeInterval(rule.finishDelay),
            pauseDelay: rule.pauseDelay,
            finishDelay: rule.finishDelay,
            minimumSavedDuration: rule.minimumSavedDuration,
            claims: [SessionAutomationClaim(
                source: source,
                isActive: true,
                lastSignalAt: signalAt
            )]
        )

        return startSessionInternal(
            projectID: projectID,
            goal: preset.goal,
            type: preset.sessionType,
            at: startDate,
            automationMetadata: metadata,
            gitDiscoveryFolderURL: nil
        )
    }

    private func startSessionInternal(
        projectID: UUID?,
        goal: String?,
        type: SessionType,
        at startDate: Date,
        automationMetadata: SessionAutomationMetadata?,
        gitDiscoveryFolderURL: URL? = nil
    ) -> Bool {
        guard !isInRecoveryMode else { return false }
        guard let prepared = preparedStartState(
            projectID: projectID,
            goal: goal,
            type: type,
            at: startDate,
            automationMetadata: automationMetadata,
            gitDiscoveryFolderURL: gitDiscoveryFolderURL
        ) else {
            return false
        }

        guard commit(prepared.state, critical: true) else { return false }
        now = clock.now
        scheduleStartGitCaptureIfNeeded(for: prepared.session, folderURL: prepared.folderURL)
        return true
    }

    private func preparedStartState(
        projectID: UUID?,
        goal: String?,
        type: SessionType,
        at startDate: Date,
        automationMetadata: SessionAutomationMetadata?,
        gitDiscoveryFolderURL: URL? = nil
    ) -> (state: AppState, session: ActiveSession, folderURL: URL?)? {
        guard state.activeSessions.count < ConcurrentSessionLimits.maximumActiveSessions else { return nil }

        guard projectID == nil || state.projects.contains(where: { $0.id == projectID && $0.isActive }) else {
            return nil
        }

        let project = projectID.flatMap { id in state.projects.first(where: { $0.id == id }) }
        let folderURL = gitDiscoveryFolderURL ?? project.flatMap { projectFolderURL(for: $0) }
        let session = ActiveSession(
            projectID: project?.id,
            projectName: project?.name,
            type: type,
            goal: ActiveSession.cleanOptionalText(goal),
            startedAt: startDate,
            automationMetadata: automationMetadata
        )

        var nextState = state
        if automationMetadata != nil {
            // Reserve every ownership identity represented by the candidate
            // metadata before publishing the new Session. This also handles a
            // valid multi-claim migration payload without dropping a
            // secondary Thread reservation.
            let identities = session.developerToolOwnershipIdentities.sorted {
                if $0.tool != $1.tool { return $0.tool.rawValue < $1.tool.rawValue }
                return $0.externalSessionID < $1.externalSessionID
            }
            do {
                for identity in identities {
                    try nextState.admitDeveloperToolOwner(
                        tool: identity.tool,
                        externalSessionID: identity.externalSessionID,
                        at: startDate
                    )
                }
            } catch {
                return nil
            }
        }
        nextState.activeSessions.append(session)
        if let projectID,
           let index = nextState.projects.firstIndex(where: { $0.id == projectID }) {
            nextState.projects[index].lastUsedAt = startDate
        }
        return (nextState, session, folderURL)
    }

    private func scheduleStartGitCaptureIfNeeded(for session: ActiveSession, folderURL: URL?) {
        guard let folderURL,
              FileManager.default.fileExists(atPath: folderURL.path) else {
            return
        }
        scheduleStartGitCapture(for: session.id, folderURL: folderURL)
    }

    @discardableResult
    func pause(at date: Date? = nil) -> Bool {
        guard let sessionID = uniqueEligibleSessionID(for: [.running]) else { return false }
        return pause(sessionID: sessionID, at: date)
    }

    @discardableResult
    func pause(sessionID: UUID, at date: Date? = nil) -> Bool {
        guard !isInRecoveryMode,
              let prepared = preparedManualPauseState(
                  sessionID: sessionID,
                  at: date ?? clock.now
              ) else {
            return false
        }
        guard commit(
            prepared.state,
            critical: true,
            normalizeAutomation: false,
            affectedSessionID: sessionID
        ) else { return false }
        refreshAfterLifecycleMutation(for: sessionID)
        return true
    }

    @discardableResult
    func resume(at date: Date? = nil) -> Bool {
        guard let sessionID = uniqueEligibleSessionID(for: [.paused]) else { return false }
        return resume(sessionID: sessionID, at: date)
    }

    @discardableResult
    func resume(sessionID: UUID, at date: Date? = nil) -> Bool {
        guard !isInRecoveryMode,
              let prepared = preparedManualResumeState(
                  sessionID: sessionID,
                  at: date ?? clock.now
              ) else {
            return false
        }
        guard commit(
            prepared.state,
            critical: true,
            normalizeAutomation: false,
            affectedSessionID: sessionID
        ) else { return false }
        refreshAfterLifecycleMutation(for: sessionID)
        return true
    }

    @discardableResult
    func finish(at date: Date? = nil) -> Bool {
        guard let sessionID = uniqueEligibleSessionID(for: [.running, .paused]) else { return false }
        return finish(sessionID: sessionID, at: date)
    }

    @discardableResult
    func finish(sessionID: UUID, at date: Date? = nil) -> Bool {
        guard !isInRecoveryMode,
              let prepared = preparedManualFinishState(
                  sessionID: sessionID,
                  at: date ?? clock.now
              ) else {
            return false
        }
        guard commit(
            prepared.state,
            critical: true,
            normalizeAutomation: false,
            affectedSessionID: sessionID
        ) else { return false }
        refreshAfterLifecycleMutation(for: sessionID)

        if prepared.session.gitContext != nil || isGitCaptureInProgress(for: sessionID) {
            scheduleFinalGitCapture(for: sessionID)
        }
        return true
    }

    private func uniqueEligibleSessionID(for phases: Set<SessionPhase>) -> UUID? {
        let matches = state.activeSessions.filter { phases.contains($0.phase) }.map(\.id)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func preparedManualPauseState(
        sessionID: UUID,
        at date: Date
    ) -> (state: AppState, session: ActiveSession)? {
        guard var session = state.activeSession(id: sessionID),
              session.pause(at: date) else {
            return nil
        }
        relinquishManualAutomationControl(in: &session)
        var nextState = state
        guard replaceActiveSession(session, in: &nextState) else { return nil }
        return (nextState, session)
    }

    private func preparedManualResumeState(
        sessionID: UUID,
        at date: Date
    ) -> (state: AppState, session: ActiveSession)? {
        guard var session = state.activeSession(id: sessionID),
              session.resume(at: date) else {
            return nil
        }
        relinquishManualAutomationControl(in: &session)
        var nextState = state
        guard replaceActiveSession(session, in: &nextState) else { return nil }
        return (nextState, session)
    }

    private func preparedManualFinishState(
        sessionID: UUID,
        at date: Date
    ) -> (state: AppState, session: ActiveSession)? {
        guard var session = state.activeSession(id: sessionID),
              session.finish(at: date) else {
            return nil
        }
        relinquishManualAutomationControl(in: &session)
        var nextState = state
        guard replaceActiveSession(session, in: &nextState) else { return nil }
        return (nextState, session)
    }

    @discardableResult
    func saveFinishedSession(outcome: String?) -> Bool {
        guard let sessionID = uniqueEligibleSessionID(for: [.finishing]) else { return false }
        return saveFinishedSession(sessionID: sessionID, outcome: outcome)
    }

    @discardableResult
    func saveFinishedSession(sessionID: UUID, outcome: String?) -> Bool {
        guard !isInRecoveryMode,
              state.activeSession(id: sessionID)?.phase == .finishing else {
            return false
        }
        // Preserve the legacy force-drain for the one-session UI, but do not
        // let an explicit save of A process a pending event that can mutate B
        // while concurrent Sessions are present.
        if state.activeSessions.count == 1 {
            processPendingIntegrationEvents(force: true)
        }
        guard state.activeSession(id: sessionID)?.phase == .finishing,
              !isGitCaptureInProgress(for: sessionID) else {
            return false
        }
        return completeFinishedSession(sessionID: sessionID, outcome: outcome)
    }

    @discardableResult
    func updateFinishingOutcome(_ outcome: String?) -> Bool {
        guard let sessionID = uniqueEligibleSessionID(for: [.finishing]) else { return false }
        return updateFinishingOutcome(sessionID: sessionID, outcome: outcome)
    }

    @discardableResult
    func updateFinishingOutcome(sessionID: UUID, outcome: String?) -> Bool {
        guard !isInRecoveryMode,
              state.activeSession(id: sessionID)?.phase == .finishing else {
            return false
        }

        var nextState = state
        guard let index = nextState.activeSessionIndex(id: sessionID) else { return false }
        nextState.activeSessions[index].outcome = ActiveSession.cleanOptionalText(outcome)
        guard nextState != state else { return true }
        return commit(
            nextState,
            critical: true,
            normalizeAutomation: false,
            affectedSessionID: sessionID
        )
    }

    @discardableResult
    func discardSession() -> Bool {
        guard let sessionID = uniqueEligibleSessionID(for: [.finishing]) else { return false }
        return discardSession(sessionID: sessionID)
    }

    @discardableResult
    func discardSession(sessionID: UUID) -> Bool {
        guard !isInRecoveryMode,
              state.activeSession(id: sessionID)?.phase == .finishing else { return false }
        var nextState = state
        if var session = nextState.activeSession(id: sessionID) {
            relinquishManualAutomationControl(in: &session)
            guard replaceActiveSession(session, in: &nextState) else { return false }
            do {
                try nextState.retireDeveloperToolOwnership(for: session, retiredAt: clock.now)
                _ = try nextState.removeActiveSession(id: sessionID)
            } catch {
                return false
            }
        }
        guard commit(
            nextState,
            critical: true,
            normalizeAutomation: false,
            affectedSessionID: sessionID
        ) else { return false }
        invalidateAsyncWork(for: sessionID)
        refreshAfterLifecycleMutation(for: sessionID)
        return true
    }

    func controlStatus(at date: Date? = nil) -> CodePulseControlStatus {
        controlStatus(for: state, at: date ?? clock.now)
    }

    @discardableResult
    func processControlCommand(
        _ rawCommand: CodePulseControlCommand,
        at date: Date? = nil
    ) -> CodePulseControlResponse {
        controlCommandNeedsRetry = false
        let date = date ?? clock.now
        let isMutation = isControlMutation(rawCommand.action)
        if isInRecoveryMode {
            controlCommandNeedsRetry = isMutation
            return CodePulseControlResponse(
                commandID: rawCommand.id,
                result: .internalFailure,
                message: isMutation
                    ? "CodePulse saved data is unavailable; recover it before sending lifecycle commands."
                    : "CodePulse saved data is unavailable; recover it before requesting status.",
                status: controlStatus(at: date)
            )
        }
        if isMutation,
           let existing = state.controlProcessing?.processedCommands.first(where: { $0.id == rawCommand.id }) {
            return existing.response
        }

        let command: CodePulseControlCommand
        do {
            command = try CodePulseControlCommandValidator.sanitized(rawCommand, now: date)
        } catch let error as CodePulseControlValidationError {
            let response = CodePulseControlResponse(
                commandID: rawCommand.id,
                result: .commandRejected,
                message: controlValidationMessage(error),
                status: controlStatus(at: date)
            )
            recordControlResponseIfNeeded(response, for: rawCommand.action, at: date)
            return response
        } catch {
            let response = CodePulseControlResponse(
                commandID: rawCommand.id,
                result: .internalFailure,
                message: "CodePulse could not validate the local control command.",
                status: controlStatus(at: date)
            )
            recordControlResponseIfNeeded(response, for: rawCommand.action, at: date)
            return response
        }

        if !LocalInputAcceptance.accepts(
            timestamp: command.issuedAt,
            after: state.localInputAcceptanceDate
        ) {
            let response = CodePulseControlResponse(
                commandID: command.id,
                result: .commandRejected,
                message: "The command was issued before the most recent CodePulse restore.",
                status: controlStatus(at: date)
            )
            recordControlResponseIfNeeded(response, for: command.action, at: date)
            return response
        }

        if command.issuedAt < controlLaunchDate {
            let response = CodePulseControlResponse(
                commandID: command.id,
                result: .commandRejected,
                message: "The command was issued before CodePulse launched.",
                status: controlStatus(at: date)
            )
            recordControlResponseIfNeeded(response, for: command.action, at: date)
            return response
        }

        switch command.action {
        case .status:
            if command.schemaVersion == 1 {
                guard state.activeSessions.count <= 1 else {
                    return CodePulseControlResponse(
                        schemaVersion: 1,
                        commandID: command.id,
                        result: .commandRejected,
                        message: "Concurrent status requires protocol v2 and the current codepulsectl."
                    )
                }
                return CodePulseControlResponse(
                    schemaVersion: 1,
                    commandID: command.id,
                    result: .success,
                    message: "CodePulse status retrieved.",
                    status: legacyControlStatus(for: state, at: date)
                )
            }
            return CodePulseControlResponse(
                commandID: command.id,
                result: .success,
                message: "CodePulse status retrieved.",
                status: controlStatus(at: date)
            )

        case .startPreset(let name):
            return processControlStart(
                commandID: command.id,
                action: command.action,
                preset: resolvePreset(named: name),
                date: date
            )

        case .startPresetID(let id):
            return processControlStart(
                commandID: command.id,
                action: command.action,
                preset: state.sessionPresets.first(where: { $0.id == id }).map { .found($0) } ?? .notFound,
                date: date
            )

        case .startManual(let projectName, let sessionType, let goal):
            guard state.activeSessions.isEmpty else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .invalidStateTransition,
                    message: "A session is already active.",
                    action: command.action,
                    date: date
                )
            }
            guard let project = uniqueProject(named: projectName) else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .presetOrProjectNotFound,
                    message: "The requested project was not found or is ambiguous.",
                    action: command.action,
                    date: date
                )
            }
            guard !project.isArchived else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .presetOrProjectNotFound,
                    message: "Project \"\(project.name)\" is archived.",
                    action: command.action,
                    date: date
                )
            }
            guard let type = SessionType(rawValue: sessionType) else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .commandRejected,
                    message: "The requested session type is not supported.",
                    action: command.action,
                    date: date
                )
            }
            guard let prepared = preparedStartState(
                projectID: project.id,
                goal: goal,
                type: type,
                at: date,
                automationMetadata: nil
            ) else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .invalidStateTransition,
                    message: "A session could not be started from the current state.",
                    action: command.action,
                    date: date
                )
            }
            let responseStatus = controlStatus(for: prepared.state, at: date)
            let response = CodePulseControlResponse(
                commandID: command.id,
                result: .success,
                message: "CodePulse: started manual session. Session: \(prepared.session.id.uuidString).",
                status: responseStatus,
                sessionID: prepared.session.id
            )
            var nextState = prepared.state
            appendControlResponse(response, to: &nextState, at: date)
            let committedResponse = commitControlMutation(response, state: nextState)
            guard committedResponse.result == .success else { return committedResponse }
            now = clock.now
            scheduleStartGitCaptureIfNeeded(for: prepared.session, folderURL: prepared.folderURL)
            processPendingIntegrationEvents(force: true)
            return committedResponse

        case .pause, .pauseSession:
            let requestedID: UUID? = {
                if case .pauseSession(let id) = command.action { return id }
                return nil
            }()
            let eligible = state.activeSessions.filter { $0.phase == .running }
            if requestedID == nil, eligible.count > 1 {
                return recordControlFailure(
                    commandID: command.id,
                    result: command.schemaVersion == 1 ? .commandRejected : .ambiguousSession,
                    message: "Multiple Sessions can be paused; use --session-id <uuid>.",
                    action: command.action,
                    date: date
                )
            }
            guard let sessionID = requestedID ?? eligible.first?.id,
                  state.activeSession(id: sessionID)?.phase == .running,
                  let prepared = preparedManualPauseState(sessionID: sessionID, at: date) else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .invalidStateTransition,
                    message: "Pause is not valid while CodePulse is idle or already paused.",
                    action: command.action,
                    date: date
                )
            }
            let response = CodePulseControlResponse(
                commandID: command.id,
                result: .success,
                message: "CodePulse: paused session.",
                status: controlStatus(for: prepared.state, at: date),
                sessionID: sessionID
            )
            var nextState = prepared.state
            appendControlResponse(response, to: &nextState, at: date)
            let committedResponse = commitControlMutation(response, state: nextState)
            guard committedResponse.result == .success else { return committedResponse }
            refreshAfterLifecycleMutation(for: sessionID)
            return committedResponse

        case .resume, .resumeSession:
            let requestedID: UUID? = {
                if case .resumeSession(let id) = command.action { return id }
                return nil
            }()
            let eligible = state.activeSessions.filter { $0.phase == .paused }
            if requestedID == nil, eligible.count > 1 {
                return recordControlFailure(
                    commandID: command.id,
                    result: command.schemaVersion == 1 ? .commandRejected : .ambiguousSession,
                    message: "Multiple Sessions can be resumed; use --session-id <uuid>.",
                    action: command.action,
                    date: date
                )
            }
            guard let sessionID = requestedID ?? eligible.first?.id,
                  state.activeSession(id: sessionID)?.phase == .paused,
                  let prepared = preparedManualResumeState(sessionID: sessionID, at: date) else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .invalidStateTransition,
                    message: "Resume is only valid for a paused session.",
                    action: command.action,
                    date: date
                )
            }
            let response = CodePulseControlResponse(
                commandID: command.id,
                result: .success,
                message: "CodePulse: resumed session.",
                status: controlStatus(for: prepared.state, at: date),
                sessionID: sessionID
            )
            var nextState = prepared.state
            appendControlResponse(response, to: &nextState, at: date)
            let committedResponse = commitControlMutation(response, state: nextState)
            guard committedResponse.result == .success else { return committedResponse }
            refreshAfterLifecycleMutation(for: sessionID)
            return committedResponse

        case .finish, .finishSession:
            let requestedID: UUID? = {
                if case .finishSession(let id) = command.action { return id }
                return nil
            }()
            let eligible = state.activeSessions.filter { $0.phase == .running || $0.phase == .paused }
            if requestedID == nil, eligible.count > 1 {
                return recordControlFailure(
                    commandID: command.id,
                    result: command.schemaVersion == 1 ? .commandRejected : .ambiguousSession,
                    message: "Multiple Sessions can be finished; use --session-id <uuid>.",
                    action: command.action,
                    date: date
                )
            }
            guard let sessionID = requestedID ?? eligible.first?.id,
                  [.running, .paused].contains(state.activeSession(id: sessionID)?.phase),
                  let prepared = preparedManualFinishState(sessionID: sessionID, at: date) else {
                return recordControlFailure(
                    commandID: command.id,
                    result: .invalidStateTransition,
                    message: "Finish is not valid while CodePulse is idle or already finishing.",
                    action: command.action,
                    date: date
                )
            }
            let response = CodePulseControlResponse(
                commandID: command.id,
                result: .success,
                message: "CodePulse: finishing session. Save the outcome in the app.",
                status: controlStatus(for: prepared.state, at: date),
                sessionID: sessionID
            )
            var nextState = prepared.state
            appendControlResponse(response, to: &nextState, at: date)
            let committedResponse = commitControlMutation(response, state: nextState)
            guard committedResponse.result == .success else { return committedResponse }
            refreshAfterLifecycleMutation(for: sessionID)
            if prepared.session.gitContext != nil || isGitCaptureInProgress(for: sessionID) {
                scheduleFinalGitCapture(for: prepared.session.id)
            }
            return committedResponse
        }
    }

    private enum PresetResolution {
        case found(SessionPreset)
        case notFound
        case ambiguous
    }

    private func processControlStart(
        commandID: UUID,
        action: CodePulseControlAction,
        preset resolution: PresetResolution,
        date: Date
    ) -> CodePulseControlResponse {
        guard state.activeSessions.isEmpty else {
            return recordControlFailure(
                commandID: commandID,
                result: .invalidStateTransition,
                message: "A session is already active.",
                action: action,
                date: date
            )
        }

        let preset: SessionPreset
        switch resolution {
        case .notFound:
            return recordControlFailure(
                commandID: commandID,
                result: .presetOrProjectNotFound,
                message: "The requested session preset was not found.",
                action: action,
                date: date
            )
        case .ambiguous:
            return recordControlFailure(
                commandID: commandID,
                result: .commandRejected,
                message: "The preset name is ambiguous; use --preset-id.",
                action: action,
                date: date
            )
        case .found(let value):
            preset = value
        }

        guard preset.isValid,
              preset.projectID == nil || state.projects.contains(where: { $0.id == preset.projectID }) else {
            return recordControlFailure(
                commandID: commandID,
                result: .presetOrProjectNotFound,
                message: "The session preset references a missing project.",
                action: action,
                date: date
            )
        }
        if let projectID = preset.projectID,
           let project = state.projects.first(where: { $0.id == projectID }),
           project.isArchived {
            return recordControlFailure(
                commandID: commandID,
                result: .presetOrProjectNotFound,
                message: "Project \"\(project.name)\" is archived.",
                action: action,
                date: date
            )
        }
        guard let prepared = preparedStartState(
            projectID: preset.projectID,
            goal: preset.goal,
            type: preset.sessionType,
            at: date,
            automationMetadata: nil
        ) else {
            return recordControlFailure(
                commandID: commandID,
                result: .invalidStateTransition,
                message: "A session could not be started from the current state.",
                action: action,
                date: date
            )
        }

        let response = CodePulseControlResponse(
            commandID: commandID,
            result: .success,
            message: "CodePulse: started manual session from \(preset.name). Session: \(prepared.session.id.uuidString).",
            status: controlStatus(for: prepared.state, at: date),
            sessionID: prepared.session.id
        )
        var nextState = prepared.state
        appendControlResponse(response, to: &nextState, at: date)
        let committedResponse = commitControlMutation(response, state: nextState)
        guard committedResponse.result == .success else { return committedResponse }
        now = clock.now
        scheduleStartGitCaptureIfNeeded(for: prepared.session, folderURL: prepared.folderURL)
        processPendingIntegrationEvents(force: true)
        return committedResponse
    }

    private func resolvePreset(named name: String) -> PresetResolution {
        let matches = state.sessionPresets.filter {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard !matches.isEmpty else { return .notFound }
        guard matches.count == 1, let match = matches.first else { return .ambiguous }
        return .found(match)
    }

    private func uniqueProject(named name: String) -> ProjectRecord? {
        let matches = state.projects.filter {
            $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private func recordControlFailure(
        commandID: UUID,
        result: CodePulseControlResultCode,
        message: String,
        action: CodePulseControlAction,
        date: Date
    ) -> CodePulseControlResponse {
        let response = CodePulseControlResponse(
            commandID: commandID,
            result: result,
            message: message,
            status: controlStatus(at: date)
        )
        recordControlResponseIfNeeded(response, for: action, at: date)
        return response
    }

    private func recordControlResponseIfNeeded(
        _ response: CodePulseControlResponse,
        for action: CodePulseControlAction,
        at date: Date
    ) {
        guard isControlMutation(action) else { return }
        var nextState = state
        appendControlResponse(response, to: &nextState, at: date)
        commit(nextState)
    }

    private func commitControlMutation(
        _ response: CodePulseControlResponse,
        state nextState: AppState
    ) -> CodePulseControlResponse {
        guard commit(nextState, critical: true, normalizeAutomation: false) else {
            controlCommandNeedsRetry = true
            return CodePulseControlResponse(
                commandID: response.commandID,
                result: .internalFailure,
                message: "CodePulse could not durably save this lifecycle change; retry the command.",
                status: controlStatus(at: clock.now)
            )
        }
        return response
    }

    private func appendControlResponse(
        _ response: CodePulseControlResponse,
        to state: inout AppState,
        at date: Date
    ) {
        var processing = state.controlProcessing ?? CodePulseControlProcessingState()
        processing.processedCommands.removeAll {
            date.timeIntervalSince($0.processedAt) > CodePulseControlLimits.processedCommandRetention
        }
        processing.processedCommands.removeAll { $0.id == response.commandID }
        processing.processedCommands.append(CodePulseProcessedControlCommand(
            id: response.commandID,
            processedAt: date,
            response: response
        ))
        processing.processedCommands.sort { $0.processedAt > $1.processedAt }
        if processing.processedCommands.count > CodePulseControlLimits.maximumProcessedCommands {
            processing.processedCommands.removeLast(
                processing.processedCommands.count - CodePulseControlLimits.maximumProcessedCommands
            )
        }
        state.controlProcessing = processing
    }

    private func isControlMutation(_ action: CodePulseControlAction) -> Bool {
        switch action {
        case .status: return false
        case .startPreset, .startPresetID, .startManual, .pause, .pauseSession,
             .resume, .resumeSession, .finish, .finishSession: return true
        }
    }

    private func controlStatus(
        for state: AppState,
        at date: Date
    ) -> CodePulseControlStatus {
        let sessions = state.activeSessions.map { session -> CodePulseControlSessionStatus in
            let project = session.projectID.flatMap { id in state.projects.first { $0.id == id } }
            let workspace = project.flatMap { project in state.workspaces.first { $0.id == project.workspaceID } }
            let tools = Set(session.developerToolContexts.map(\.tool.title)).sorted()
            let gitStatus: String? = gitCaptureStatus(for: session.id).map { status in
                switch status {
                case .scheduled: return "scheduled"
                case .running: return "running"
                case .succeeded: return "succeeded"
                case .failed: return "failed"
                case .ambiguous: return "ambiguous"
                }
            }
            return CodePulseControlSessionStatus(
                sessionID: session.id,
                projectID: session.projectID,
                projectName: session.projectName.flatMap { $0.isEmpty ? nil : $0 },
                workspaceID: workspace?.id,
                workspaceName: workspace?.name,
                sessionType: session.type.rawValue,
                phase: session.phase.rawValue,
                elapsedSeconds: Int(max(0, session.activeDuration(at: date)).rounded(.down)),
                automationControlled: session.automationMetadata?.controlEnabled == true,
                developerTools: tools,
                gitCaptureStatus: gitStatus
            )
        }
        return CodePulseControlStatus(sessions: sessions)
    }

    private func legacyControlStatus(for state: AppState, at date: Date) -> CodePulseControlStatus {
        guard let session = state.activeSessions.first else {
            return CodePulseControlStatus(
                schemaVersion: 1,
                phase: SessionPhase.idle.rawValue,
                elapsedSeconds: 0,
                automationControlled: false
            )
        }
        return CodePulseControlStatus(
            schemaVersion: 1,
            phase: session.phase.rawValue,
            project: session.projectName.flatMap { $0.isEmpty ? nil : $0 },
            sessionType: session.type.rawValue,
            elapsedSeconds: Int(max(0, session.activeDuration(at: date)).rounded(.down)),
            automationControlled: session.automationMetadata?.controlEnabled == true
        )
    }

    private func controlValidationMessage(_ error: CodePulseControlValidationError) -> String {
        switch error {
        case .commandTooLarge:
            return "The control command is too large."
        case .unsupportedSchemaVersion:
            return "The control command schema is unsupported."
        case .commandTooOld:
            return "The control command has expired."
        case .commandInFuture:
            return "The control command timestamp is invalid."
        case .invalidEnvelope, .unexpectedField:
            return "The control command envelope is invalid."
        case .emptyValue(let field):
            return "The control command has an empty \(field)."
        case .valueTooLong(let field):
            return "The control command \(field) is too long."
        case .invalidValue(let field):
            return "The control command \(field) is invalid."
        }
    }

    func todayTotal(at date: Date? = nil) -> TimeInterval {
        let referenceDate = date ?? clock.now
        let dayStart = calendar.startOfDay(for: referenceDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return 0 }
        let day = DateInterval(start: dayStart, end: dayEnd)

        let completed = state.completedSessions.flatMap { session in
            ActivityCoverageCalculator.activeIntervals(
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                pauseIntervals: session.pauseIntervals,
                in: day,
                referenceDate: referenceDate
            )
        }
        let active = state.activeSessions.flatMap { session in
            ActivityCoverageCalculator.activeIntervals(
                startedAt: session.startedAt,
                endedAt: session.endedAt,
                pauseIntervals: session.pauseIntervals,
                in: day,
                referenceDate: referenceDate
            )
        }
        return ActivityCoverageCalculator.unionDuration(completed + active)
    }

    var historyGroups: [DaySessionGroup] {
        historyGroups(for: HistoryQuery())
    }

    /// Returns saved sessions in the same filtered, newest-first order used by
    /// History. Keeping this collection separate from grouping lets exports
    /// consume the exact same canonical matches without reimplementing query
    /// semantics.
    func historySessions(
        for query: HistoryQuery,
        referenceDate: Date? = nil
    ) -> [CompletedSession] {
        let referenceDate = referenceDate ?? clock.now
        let workspaceProjectIDs = workspaceProjectIDs(for: query.workspace)
        return state.completedSessions
            .filter { session in
                query.matches(
                    session,
                    calendar: calendar,
                    referenceDate: referenceDate,
                    workspaceProjectIDs: workspaceProjectIDs
                )
            }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt {
                    return lhs.startedAt > rhs.startedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    func historyGroups(
        for query: HistoryQuery,
        referenceDate: Date? = nil
    ) -> [DaySessionGroup] {
        let referenceDate = referenceDate ?? clock.now
        let matchingSessions = historySessions(for: query, referenceDate: referenceDate)
        let groups = Dictionary(grouping: matchingSessions) { session in
            calendar.startOfDay(for: session.startedAt)
        }

        return groups.keys.sorted(by: >).map { day in
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else {
                return DaySessionGroup(id: day, sessions: groups[day] ?? [], totalDuration: 0)
            }
            let interval = DateInterval(start: day, end: dayEnd)
            let sessions = groups[day] ?? []
            let total = sessions.reduce(into: 0) { result, session in
                result += session.activeDuration(in: interval)
            }
            return DaySessionGroup(id: day, sessions: sessions, totalDuration: total)
        }
    }

    var historyProjectOptions: [HistoryProjectOption] {
        historyProjectOptions(for: .allWorkspaces)
    }

    func historyProjectOptions(for workspace: WorkspaceScope) -> [HistoryProjectOption] {
        let workspaceProjectIDs = workspaceProjectIDs(for: workspace)
        let currentOptions = projectsSortedByRecentUse
            .filter { workspace == .allWorkspaces || workspaceProjectIDs.contains($0.id) }
            .map { project in
            HistoryProjectOption(
                id: "project-\(project.id.uuidString)",
                title: project.name,
                filter: .projectID(project.id)
            )
        }
        guard workspace == .allWorkspaces else { return currentOptions }
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
        insightsProjectOptions(for: .allWorkspaces)
    }

    func insightsProjectOptions(for workspace: WorkspaceScope) -> [InsightsProjectOption] {
        let workspaceProjectIDs = workspaceProjectIDs(for: workspace)
        let currentProjects = projectsSortedByRecentUse
            .filter { workspace == .allWorkspaces || workspaceProjectIDs.contains($0.id) }
            .map { project in
            InsightsProjectOption(
                id: "project-\(project.id.uuidString)",
                title: project.name,
                filter: .projectID(project.id)
            )
        }
        guard workspace == .allWorkspaces else { return currentProjects }
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
        for activeSession in state.activeSessions {
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
        guard !isInRecoveryMode else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }

        #if os(macOS)
        let bookmarkData = folderURL.flatMap { url in
            try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        }
        #else
        let bookmarkData: Data? = nil
        #endif
        guard let workspaceID = state.settings.selectedWorkspaceID
            ?? state.workspaces.first?.id,
              state.workspaces.contains(where: { $0.id == workspaceID }) else {
            return nil
        }
        let project = ProjectRecord(
            workspaceID: workspaceID,
            name: cleanName,
            folderPath: folderURL?.path,
            bookmarkData: bookmarkData,
            createdAt: date ?? clock.now
        )
        var nextState = state
        nextState.projects.append(project)
        guard commit(nextState) else { return nil }
        return project.id
    }

    /// Creates a workspace and selects it as the current presentation scope.
    /// The workspace graph and selection are committed atomically so a failed
    /// save cannot report a created workspace or leave a stale selection.
    @discardableResult
    func createWorkspace(name: String, at date: Date? = nil) -> UUID? {
        guard !isInRecoveryMode else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return nil }

        let timestamp = date ?? clock.now
        let workspace = WorkspaceRecord(
            name: cleanName,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var nextState = state
        nextState.workspaces.append(workspace)
        if state.activeSessions.isEmpty {
            nextState.settings.selectedWorkspaceID = workspace.id
        }
        guard commit(nextState) else { return nil }
        return workspace.id
    }

    @discardableResult
    func renameWorkspace(id: UUID, name: String, at date: Date? = nil) -> Bool {
        guard !isInRecoveryMode else { return false }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let index = state.workspaces.firstIndex(where: { $0.id == id }) else {
            return false
        }

        var nextState = state
        nextState.workspaces[index].name = cleanName
        nextState.workspaces[index].updatedAt = date ?? clock.now
        return commit(nextState)
    }

    /// Moves a project by changing only its workspace relationship. Archived
    /// projects may be moved, but the project owning the active session may
    /// not be moved while that session is in progress.
    @discardableResult
    func moveProject(id: UUID, to workspaceID: UUID) -> Bool {
        guard !isInRecoveryMode,
              state.workspaces.contains(where: { $0.id == workspaceID }),
              let index = state.projects.firstIndex(where: { $0.id == id }),
              !state.activeSessions.contains(where: { $0.projectID == id }) else {
            return false
        }
        guard state.projects[index].workspaceID != workspaceID else { return true }

        let project = state.projects[index]
        var nextState = state
        nextState.projects[index] = ProjectRecord(
            id: project.id,
            workspaceID: workspaceID,
            name: project.name,
            folderPath: project.folderPath,
            bookmarkData: project.bookmarkData,
            createdAt: project.createdAt,
            lastUsedAt: project.lastUsedAt,
            archivedAt: project.archivedAt
        )
        return commit(nextState)
    }

    func renameProject(id: UUID, name: String) {
        guard !isInRecoveryMode else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              let index = state.projects.firstIndex(where: { $0.id == id }) else { return }

        var nextState = state
        nextState.projects[index].name = cleanName
        commit(nextState)
    }

    @discardableResult
    func archiveProject(id: UUID, at date: Date? = nil) throws -> ProjectRecord {
        guard !isInRecoveryMode else { throw ProjectArchiveError.recoveryMode }
        guard let index = state.projects.firstIndex(where: { $0.id == id }) else {
            throw ProjectArchiveError.projectNotFound
        }
        guard !state.projects[index].isArchived else {
            throw ProjectArchiveError.alreadyArchived
        }
        guard !state.activeSessions.contains(where: { $0.projectID == id }) else {
            throw ProjectArchiveError.activeSession
        }

        var nextState = state
        nextState.projects[index].archivedAt = date ?? clock.now
        if nextState.settings.defaultProjectBehavior == .specificProject,
           nextState.settings.specificProjectID == id {
            nextState.settings.defaultProjectBehavior = .lastUsed
            nextState.settings.specificProjectID = nil
        }
        commit(nextState)
        guard let archivedProject = state.projects.first(where: { $0.id == id }) else {
            throw ProjectArchiveError.projectNotFound
        }
        return archivedProject
    }

    @discardableResult
    func restoreProject(id: UUID) throws -> ProjectRecord {
        guard !isInRecoveryMode else { throw ProjectArchiveError.recoveryMode }
        guard let index = state.projects.firstIndex(where: { $0.id == id }) else {
            throw ProjectArchiveError.projectNotFound
        }
        guard state.projects[index].isArchived else {
            throw ProjectArchiveError.alreadyActive
        }

        var nextState = state
        nextState.projects[index].archivedAt = nil
        commit(nextState)
        guard let restoredProject = state.projects.first(where: { $0.id == id }) else {
            throw ProjectArchiveError.projectNotFound
        }
        return restoredProject
    }

    @discardableResult
    func updateProjectFolder(id: UUID, folderURL: URL) -> Bool {
        guard !isInRecoveryMode else { return false }
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
        guard !isInRecoveryMode,
              !state.activeSessions.contains(where: { $0.projectID == id }) else { return }
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
        guard !isInRecoveryMode else { return }
        var nextState = state
        update(&nextState.settings)
        relinquishInvalidAutomation(in: &nextState)
        commit(nextState)
    }

    func markOnboardingCompleted() {
        guard !state.settings.hasCompletedOnboarding else { return }
        updateSettings { settings in
            settings.hasCompletedOnboarding = true
        }
    }

    var sessionPresetsSorted: [SessionPreset] {
        state.sessionPresets.sorted { lhs, rhs in
            let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    func sessionPreset(id: UUID) -> SessionPreset? {
        state.sessionPresets.first(where: { $0.id == id })
    }

    @discardableResult
    func upsertSessionPreset(_ preset: SessionPreset) -> Bool {
        guard !isInRecoveryMode else { return false }
        guard preset.isValid,
              !state.sessionPresets.contains(where: {
                  $0.id != preset.id &&
                      $0.name.localizedCaseInsensitiveCompare(preset.name) == .orderedSame
              }) else {
            return false
        }
        var nextState = state
        if let index = nextState.sessionPresets.firstIndex(where: { $0.id == preset.id }) {
            nextState.sessionPresets[index] = preset
        } else {
            nextState.sessionPresets.append(preset)
        }
        relinquishInvalidAutomation(in: &nextState)
        commit(nextState)
        return true
    }

    func deleteSessionPreset(id: UUID) {
        guard !isInRecoveryMode else { return }
        var nextState = state
        nextState.sessionPresets.removeAll { $0.id == id }
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
        guard rule.isValid,
              isAutomationTriggerValid(rule.trigger),
              let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }) else {
            return false
        }
        switch rule.trigger {
        case .developerTool:
            return isDeveloperToolPresetUsable(preset)
        case .applications:
            return isPresetUsableForAutomation(preset)
        }
    }

    func automationRuleStatus(for rule: SessionAutomationRule) -> SessionAutomationRuleStatus {
        guard rule.isEnabled else { return .disabled }
        guard state.settings.automationEnabled else { return .automationOff }
        guard rule.isValid, isAutomationTriggerValid(rule.trigger) else {
            return .invalidRule
        }
        guard let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }) else {
            return .missingPreset
        }
        switch rule.trigger {
        case .developerTool:
            // A projectless preset is a reusable developer-tool session
            // template. Legacy project-backed presets retain their saved
            // project metadata for repair/status purposes, but that metadata
            // is not the runtime project selected by a developer-tool event.
            guard let projectID = preset.projectID else { return .enabled }
            guard let project = state.projects.first(where: { $0.id == projectID }) else {
                return .missingProject
            }
            if project.isArchived { return .projectArchived }
            if project.requiresRelink { return .needsRelink }
            return .enabled
        case .applications:
            guard let projectID = preset.projectID,
                  let project = state.projects.first(where: { $0.id == projectID }) else {
                return .missingProject
            }
            if project.isArchived { return .projectArchived }
            if project.requiresRelink { return .needsRelink }
            return .enabled
        }
    }

    func automationRuleStatusLabel(for rule: SessionAutomationRule) -> String {
        automationRuleStatus(for: rule).label
    }

    @discardableResult
    func upsertAutomationRule(_ rule: SessionAutomationRule) -> Bool {
        guard !isInRecoveryMode else { return false }
        guard rule.isValid,
              let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
              isAutomationTriggerValid(rule.trigger) else { return false }

        let existingRule = state.automationRules.first(where: { $0.id == rule.id })
        let preservesExistingPreset = existingRule?.presetID == rule.presetID
        if case .developerTool = rule.trigger,
           !isDeveloperToolPresetSelectionAllowed(
               preset,
               existingRule: existingRule
           ) {
            return false
        }

        let presetIsUsable: Bool
        switch rule.trigger {
        case .developerTool:
            presetIsUsable = isDeveloperToolPresetUsable(preset)
        case .applications:
            presetIsUsable = isPresetUsableForAutomation(preset)
        }
        if !preservesExistingPreset && !presetIsUsable {
            return false
        }
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

    /// Project-backed developer-tool presets are legacy-only. They may remain
    /// attached to an already persisted developer-tool rule, but cannot be
    /// introduced by a new rule or retargeted from one legacy project-backed
    /// preset to another.
    private func isDeveloperToolPresetSelectionAllowed(
        _ preset: SessionPreset,
        existingRule: SessionAutomationRule?
    ) -> Bool {
        guard preset.projectID != nil else { return true }
        guard let existingRule,
              existingRule.trigger.developerTool != nil,
              let existingPreset = state.sessionPresets.first(where: { $0.id == existingRule.presetID }),
              existingPreset.projectID != nil,
              existingPreset.id == preset.id else {
            return false
        }
        return true
    }

    func deleteAutomationRule(id: UUID) {
        guard !isInRecoveryMode else { return }
        var nextState = state
        nextState.automationRules.removeAll { $0.id == id }
        relinquishInvalidAutomation(in: &nextState)
        commit(nextState)
    }

    func deleteCompletedSession(id: UUID) {
        guard !isInRecoveryMode else { return }
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
        guard !isInRecoveryMode else { return false }
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
        guard !isInRecoveryMode else {
            throw BackupRestoreError.persistence(.unreadablePrimaryState)
        }
        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: date ?? clock.now)
        try data.write(to: fileURL, options: .atomic)
    }

    func inspectBackup(at fileURL: URL) throws -> BackupRestoreCandidate {
        let data: Data
        do {
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw BackupRestoreError.fileUnreadable
            }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            } catch {
                throw BackupRestoreError.fileUnreadable
            }
            guard let size = attributes[.size] as? NSNumber else {
                throw BackupRestoreError.fileUnreadable
            }
            guard size.uint64Value <= UInt64(CodePulseBackupError.maximumInputBytes) else {
                throw CodePulseBackupError.inputTooLarge
            }
            guard let readData = try? Data(contentsOf: fileURL) else {
                throw BackupRestoreError.fileUnreadable
            }
            guard readData.count <= CodePulseBackupError.maximumInputBytes else {
                throw CodePulseBackupError.inputTooLarge
            }
            data = readData
        } catch let error as CodePulseBackupError {
            throw error
        } catch let error as BackupRestoreError {
            throw error
        } catch {
            throw BackupRestoreError.fileUnreadable
        }

        let backup = try CodePulseBackupCodec.decode(data)
        let normalizedState = try BackupRestoreNormalizer.normalize(
            backup.state,
            preservingLaunchAtLogin: currentLaunchAtLoginState()
        )
        return BackupRestoreCandidate(
            backup: backup,
            state: normalizedState,
            preview: CodePulseBackupPreview(backup: backup, state: normalizedState)
        )
    }

    func restoreBackup(_ candidate: BackupRestoreCandidate) throws -> BackupRestoreResult {
        guard state.activeSessions.isEmpty, !hasAnyRelevantCaptureOrEnrichmentInProgress else {
            throw BackupRestoreError.activeSession
        }
        guard let restoringPersistence = persistence as? StateRestoring else {
            throw BackupRestoreError.persistenceUnavailable
        }

        do {
            let restoreAcceptanceDate = clock.now
            var restoredState = candidate.state
            // The boundary is included in the candidate verified by the
            // transactional persistence layer. It becomes effective only if
            // the durable replacement succeeds, and therefore cannot advance
            // on a failed or rolled-back restore.
            restoredState.localInputAcceptanceDate = restoreAcceptanceDate
            let receipt = try restoringPersistence.replaceStateTransactionally(
                with: restoredState,
                recoverySnapshot: state,
                exportedAt: restoreAcceptanceDate
            )
            // The durable replacement and its readback have completed. This is
            // the first point where the live in-memory store may change.
            state = restoredState
            stateRevision += 1
            isInRecoveryMode = false
            lifecycleError = nil
            now = restoreAcceptanceDate
            stateGeneration = UUID()
            gitCaptureStates.removeAll()
            githubCaptureJobs.removeAll()
            refreshGitCaptureAggregate()
            configureApplicationMonitoring()
            restoreAutomaticFinishingState()
            return BackupRestoreResult(
                preview: candidate.preview,
                recoveryBackupURL: receipt.recoveryBackupURL
            )
        } catch let error as StatePersistenceError {
            NSLog("CodePulse restore failed (%@).", error.logIdentifier)
            throw BackupRestoreError.persistence(error)
        } catch {
            NSLog("CodePulse restore failed (persistence-unavailable).")
            throw BackupRestoreError.persistenceUnavailable
        }
    }

    func restoreBackup(from fileURL: URL) throws -> BackupRestoreResult {
        try restoreBackup(inspectBackup(at: fileURL))
    }

    private func normalizeProjectConfiguration(in state: inout AppState) {
        AppStateIntegrityValidator.normalizeSelectedWorkspace(in: &state)
        switch state.settings.defaultProjectBehavior {
        case .specificProject:
            guard let specificProjectID = state.settings.specificProjectID,
                  state.projects.contains(where: { $0.id == specificProjectID && $0.isActive }) else {
                state.settings.defaultProjectBehavior = .lastUsed
                state.settings.specificProjectID = nil
                return
            }
            // Keep the explicit reference only while it points to an active
            // project. The guard above intentionally leaves a valid setting
            // untouched, including for projects that need relinking.
            state.settings.specificProjectID = specificProjectID
        case .lastUsed, .noProject:
            state.settings.specificProjectID = nil
        }
    }

    @discardableResult
    private func commit(
        _ nextState: AppState,
        critical: Bool = false,
        normalizeAutomation: Bool = true,
        affectedSessionID: UUID? = nil
    ) -> Bool {
        guard !isInRecoveryMode else {
            if critical {
                lastCriticalCommitFailed = true
            }
            return false
        }

        var normalizedState = nextState
        normalizeProjectConfiguration(in: &normalizedState)
        if normalizeAutomation {
            relinquishInvalidAutomation(in: &normalizedState)
        }

        do {
            try AppStateIntegrityValidator.validate(normalizedState)
        } catch {
            lifecycleError = SessionLifecycleErrorPresentation(
                message: "CodePulse could not save because its workspace/project relationships are invalid.",
                affectedSessionID: critical ? affectedSessionID : nil
            )
            if critical {
                lastCriticalCommitFailed = true
            }
            return false
        }

        if critical {
            // Lifecycle authority is published only after the durable write;
            // Git, GitHub, and presentation/configuration enrichment remains
            // best effort through the non-critical path.
            do {
                try persistence.saveCritical(normalizedState)
            } catch {
                lastCriticalCommitFailed = true
                if let persistenceError = error as? StatePersistenceError {
                    lifecycleError = SessionLifecycleErrorPresentation(
                        message: persistenceError.errorDescription
                            ?? "CodePulse couldn't save this lifecycle change. Try again or open Recovery.",
                        affectedSessionID: affectedSessionID
                    )
                    NSLog(
                        "CodePulse critical lifecycle commit failed (%@): %@",
                        persistenceError.logIdentifier,
                        persistenceError.technicalDescription
                    )
                } else {
                    lifecycleError = SessionLifecycleErrorPresentation(
                        message: "CodePulse couldn't save this lifecycle change. Your previous session state is unchanged. Try again or dismiss this message.",
                        affectedSessionID: affectedSessionID
                    )
                    NSLog("CodePulse critical lifecycle commit failed: %@", error.localizedDescription)
                }
                if persistence.loadStatus.requiresRecovery {
                    isInRecoveryMode = true
                }
                return false
            }
            lastCriticalCommitFailed = false
            if lifecycleError?.affectedSessionID == affectedSessionID {
                lifecycleError = nil
            }
        } else {
            persistence.save(normalizedState)
            guard !persistence.loadStatus.requiresRecovery else {
                isInRecoveryMode = true
                return false
            }
        }

        state = normalizedState
        stateRevision += 1
        configureApplicationMonitoring()
        return true
    }

    func processPendingControlCommands(force: Bool = false) {
        guard !isInRecoveryMode, let controlTransport else { return }
        let scanDate = clock.now
        if !force,
           let lastControlScanAt,
           scanDate.timeIntervalSince(lastControlScanAt) < 0.25 {
            return
        }
        lastControlScanAt = scanDate
        pruneControlLedger(at: scanDate)
        controlTransport.pruneResponses(now: scanDate)

        for url in controlTransport.pendingCommandURLs() {
            let response: CodePulseControlResponse
            do {
                let command = try controlTransport.readCommand(from: url)
                response = processControlCommand(command, at: scanDate)
            } catch {
                // A malformed or oversized envelope has no trustworthy
                // response ID. Remove only the direct child file surfaced by
                // the transport and continue processing other commands.
                _ = controlTransport.removeCommand(at: url)
                continue
            }

            do {
                try controlTransport.writeResponse(response)
                if !controlCommandNeedsRetry {
                    _ = controlTransport.removeCommand(at: url)
                }
            } catch {
                // Keep the command for the next scan. Mutation responses are
                // already persisted in the bounded ledger, so retrying the
                // response cannot execute the action twice.
            }
        }
    }

    private func pruneControlLedger(at date: Date) {
        guard var processing = state.controlProcessing else { return }
        let retained = processing.processedCommands.filter {
            date.timeIntervalSince($0.processedAt) <= CodePulseControlLimits.processedCommandRetention
        }
        guard retained.count != processing.processedCommands.count else { return }
        processing.processedCommands = retained
        var nextState = state
        nextState.controlProcessing = processing.processedCommands.isEmpty ? nil : processing
        commit(nextState)
    }

    private func processPendingIntegrationEvents(force: Bool = false) {
        guard !isInRecoveryMode else { return }
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
            lastCriticalCommitFailed = false
            var candidate = state
            let postCommitStart = routeDeveloperToolEvent(
                item.event,
                in: &candidate,
                now: scanDate
            )
            _ = developerToolEventConsumer.markProcessed(item, in: &candidate, at: scanDate)
            guard candidate == state || commit(candidate, critical: true, normalizeAutomation: false) else {
                // Mutation and acknowledgement remain unpublished together;
                // retaining the inbox file makes the event safely retryable.
                return
            }
            developerToolEventConsumer.cleanup(item)
            if let postCommitStart,
               let session = state.activeSession(id: postCommitStart.sessionID) {
                scheduleStartGitCaptureIfNeeded(for: session, folderURL: postCommitStart.folderURL)
            }
        }
    }

    private struct DeveloperToolPostCommitStart {
        let sessionID: UUID
        let folderURL: URL
    }

    /// Routes one validated event entirely against a candidate AppState. No
    /// async work is started here; callers publish the candidate and its replay
    /// acknowledgement in one critical save before scheduling Git discovery.
    private func routeDeveloperToolEvent(
        _ event: DeveloperToolEvent,
        in candidate: inout AppState,
        now: Date
    ) -> DeveloperToolPostCommitStart? {
        guard let canonicalWorkingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(
            for: event.workingDirectory
        ),
        let resolvedProjectID = DeveloperToolProjectResolver.projectID(
            for: canonicalWorkingDirectory,
            in: candidate.projects
        ) else { return nil }

        let identity = DeveloperToolThreadIdentity(
            tool: event.tool,
            externalSessionID: event.externalSessionID
        )
        guard identity.isValid else { return nil }

        let owners = candidate.activeSessions.filter {
            $0.developerToolOwnershipIdentities.contains(identity)
        }
        guard owners.count <= 1 else { return nil }
        if let owner = owners.first {
            guard owner.projectID == resolvedProjectID,
                  event.timestamp >= owner.startedAt,
                  event.timestamp <= (owner.endedAt ?? now) else { return nil }

            _ = developerToolEventConsumer.attach(
                event,
                toSessionID: owner.id,
                in: &candidate,
                now: now
            )
            applyDeveloperToolSignal(
                event,
                toSessionID: owner.id,
                in: &candidate,
                transitionAt: now
            )
            return nil
        }

        candidate.pruneExpiredRetiredDeveloperToolThreads(at: now)
        if candidate.developerToolIntegration?.retiredDeveloperToolThreads.contains(where: {
            $0.identity == identity && $0.isProtected(at: now)
        }) == true { return nil }

        let isStartCapable = event.eventType == .sessionStarted || event.eventType == .activity
        let matchingRule = (isStartCapable && candidate.settings.automationEnabled) ? sessionAutomationCoordinator.matchingDeveloperRule(
            for: event.tool,
            projectID: resolvedProjectID,
            state: candidate
        ) : nil

        if let rule = matchingRule {
            guard event.timestamp <= now,
                  event.timestamp >= now.addingTimeInterval(-SessionAutomationCoordinator.maximumStartBackdate),
                  candidate.activeSessions.count < ConcurrentSessionLimits.maximumActiveSessions,
                  let preset = candidate.sessionPresets.first(where: { $0.id == rule.presetID }) else {
                return nil
            }
            do {
                try candidate.admitDeveloperToolOwner(
                    tool: event.tool,
                    externalSessionID: event.externalSessionID,
                    at: now
                )
            } catch { return nil }

            let source = SessionAutomationClaimSource.developerTool(
                tool: event.tool,
                externalSessionID: event.externalSessionID
            )
            let metadata = SessionAutomationMetadata(
                startedByRuleID: rule.id,
                startedByRuleName: rule.name,
                startedBySource: source,
                lastMatchingSignalAt: event.timestamp,
                pauseEligibleAt: event.timestamp.addingTimeInterval(rule.pauseDelay),
                finishEligibleAt: event.timestamp.addingTimeInterval(rule.finishDelay),
                pauseDelay: rule.pauseDelay,
                finishDelay: rule.finishDelay,
                minimumSavedDuration: rule.minimumSavedDuration,
                claims: [SessionAutomationClaim(source: source, isActive: true, lastSignalAt: event.timestamp)]
            )
            let project = candidate.projects.first { $0.id == resolvedProjectID }
            var session = ActiveSession(
                projectID: resolvedProjectID,
                projectName: project?.name,
                type: preset.sessionType,
                goal: ActiveSession.cleanOptionalText(preset.goal),
                startedAt: event.timestamp,
                automationMetadata: metadata
            )
            candidate.activeSessions.append(session)
            _ = developerToolEventConsumer.attach(
                event,
                toSessionID: session.id,
                in: &candidate,
                now: now
            )
            session = candidate.activeSession(id: session.id) ?? session
            if let projectIndex = candidate.projects.firstIndex(where: { $0.id == resolvedProjectID }) {
                candidate.projects[projectIndex].lastUsedAt = event.timestamp
            }
            return DeveloperToolPostCommitStart(
                sessionID: session.id,
                folderURL: URL(fileURLWithPath: canonicalWorkingDirectory, isDirectory: true)
            )
        }

        // Unowned events that automation does not claim may context-enrich
        // exactly one timeline-eligible manual Session. They never create
        // automation ownership or lifecycle control.
        let manualTargets = candidate.activeSessions.filter {
            $0.automationMetadata == nil &&
            $0.projectID == resolvedProjectID &&
            event.timestamp >= $0.startedAt &&
            event.timestamp <= ($0.endedAt ?? now)
        }
        guard manualTargets.count == 1, let manualID = manualTargets.first?.id else { return nil }
        _ = developerToolEventConsumer.attach(
            event,
            toSessionID: manualID,
            in: &candidate,
            now: now
        )
        return nil
    }

    private func applyDeveloperToolSignal(
        _ event: DeveloperToolEvent,
        toSessionID sessionID: UUID,
        in candidate: inout AppState,
        transitionAt: Date
    ) {
        guard let index = candidate.activeSessionIndex(id: sessionID) else { return }
        var session = candidate.activeSessions[index]
        guard session.phase == .running || session.phase == .paused,
              var metadata = session.automationMetadata,
              metadata.controlEnabled else { return }
        let source = SessionAutomationClaimSource.developerTool(
            tool: event.tool,
            externalSessionID: event.externalSessionID
        )
        guard let claimIndex = metadata.claims.firstIndex(where: { $0.source == source }),
              event.timestamp >= metadata.claims[claimIndex].lastSignalAt else { return }
        guard sessionAutomationCoordinator.hasSupportingRule(
            for: source,
            projectID: session.projectID,
            in: candidate
        ) else { return }

        let isActive = event.eventType == .sessionStarted || event.eventType == .activity
        let isEnd = event.eventType == .sessionEnded || event.eventType == .sessionIdle
        guard isActive || isEnd else { return }
        metadata.claims[claimIndex].isActive = isActive
        metadata.claims[claimIndex].lastSignalAt = event.timestamp
        metadata.lastMatchingSignalAt = max(metadata.lastMatchingSignalAt, event.timestamp)
        metadata.pauseEligibleAt = event.timestamp.addingTimeInterval(metadata.pauseDelay)
        metadata.finishEligibleAt = event.timestamp.addingTimeInterval(metadata.finishDelay)
        if isActive, session.phase == .paused {
            _ = session.resume(at: transitionAt)
        }
        session.automationMetadata = metadata
        candidate.activeSessions[index] = session
    }

    private func applyAutomationAction(
        _ action: SessionAutomationAction,
        for event: DeveloperToolEvent?,
        at date: Date
    ) -> Bool {
        switch action {
        case .start(let rule, let startDate):
            guard let event else { return true }
            let didStart = startAutomatedSession(with: rule, event: event, at: startDate, signalAt: event.timestamp)
            return didStart || !lastCriticalCommitFailed
        case .startWithResolvedProject(let rule, let projectID, let startDate):
            guard let event else { return true }
            guard let canonicalWorkingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(
                for: event.workingDirectory
            ) else {
                return true
            }
            let didStart = startAutomatedSession(
                with: rule,
                resolvedProjectID: projectID,
                event: event,
                source: .developerTool(
                    tool: event.tool,
                    externalSessionID: event.externalSessionID
                ),
                at: startDate,
                signalAt: event.timestamp,
                gitDiscoveryFolderURL: URL(fileURLWithPath: canonicalWorkingDirectory, isDirectory: true)
            )
            return didStart || !lastCriticalCommitFailed
        case .signal(let rule, let tool, let externalSessionID, let isActive):
            guard let event,
                  let resolvedProjectID = DeveloperToolProjectResolver.projectID(
                      for: event.workingDirectory,
                      in: state.projects
                  ),
                  state.soleActiveSession?.projectID == resolvedProjectID,
                  sessionAutomationCoordinator.hasSupportingRule(
                      for: .developerTool(tool: tool, externalSessionID: externalSessionID),
                      projectID: resolvedProjectID,
                      in: state
                  ) else {
                return true
            }
            return applyAutomationSignal(
                rule: rule,
                source: .developerTool(tool: tool, externalSessionID: externalSessionID),
                isActive: isActive,
                signalAt: event.timestamp,
                transitionAt: date
            )
        case .signalWithResolvedProject(let rule, let projectID, let tool, let externalSessionID, let isActive):
            guard let event,
                  event.tool == tool,
                  event.externalSessionID == externalSessionID,
                  DeveloperToolProjectResolver.projectID(
                      for: event.workingDirectory,
                      in: state.projects
                  ) == projectID,
                  state.soleActiveSession?.projectID == projectID,
                  sessionAutomationCoordinator.hasSupportingRule(
                      for: .developerTool(tool: tool, externalSessionID: externalSessionID),
                      projectID: projectID,
                      in: state
                  ) else {
                return true
            }
            return applyAutomationSignal(
                rule: rule,
                source: .developerTool(tool: tool, externalSessionID: externalSessionID),
                isActive: isActive,
                signalAt: event.timestamp,
                transitionAt: date
            )
        case .startWithSource(let rule, let source, let startDate):
            let didStart = startAutomatedSession(with: rule, source: source, at: startDate, signalAt: date)
            return didStart || !lastCriticalCommitFailed
        case .signalWithSource(let rule, let source, let isActive):
            if case .developerTool(let tool, let externalSessionID) = source {
                guard let event,
                      let resolvedProjectID = DeveloperToolProjectResolver.projectID(
                          for: event.workingDirectory,
                          in: state.projects
                      ),
                      state.soleActiveSession?.projectID == resolvedProjectID,
                      sessionAutomationCoordinator.hasSupportingRule(
                          for: .developerTool(tool: tool, externalSessionID: externalSessionID),
                          projectID: resolvedProjectID,
                          in: state
                      ) else {
                    return true
                }
            }
            return applyAutomationSignal(
                rule: rule,
                source: source,
                isActive: isActive,
                signalAt: date,
                transitionAt: date
            )
        case .signalSession(let sessionID, let rule, let source, let isActive):
            return applyAutomationSignal(
                sessionID: sessionID,
                rule: rule,
                source: source,
                isActive: isActive,
                signalAt: date,
                transitionAt: date
            )
        case .relinquish:
            var nextState = state
            relinquishInvalidAutomation(in: &nextState)
            if nextState != state {
                return commit(nextState, critical: true)
            }
            return true
        }
    }

    private func applyAutomationSignal(
        rule: SessionAutomationRule?,
        source: SessionAutomationClaimSource,
        isActive: Bool,
        signalAt eventDate: Date,
        transitionAt date: Date
    ) -> Bool {
        guard let sessionID = state.soleActiveSession?.id else { return true }
        return applyAutomationSignal(
            sessionID: sessionID,
            rule: rule,
            source: source,
            isActive: isActive,
            signalAt: eventDate,
            transitionAt: date
        )
    }

    private func applyAutomationSignal(
        sessionID: UUID,
        rule: SessionAutomationRule?,
        source: SessionAutomationClaimSource,
        isActive: Bool,
        signalAt eventDate: Date,
        transitionAt date: Date
    ) -> Bool {
        guard var session = state.activeSession(id: sessionID),
              var metadata = session.automationMetadata,
              metadata.controlEnabled,
              session.phase == .running || session.phase == .paused else {
            return true
        }

        let signalDate = max(metadata.lastMatchingSignalAt, eventDate)
        let existingClaimIndex = metadata.claims.firstIndex(where: { $0.source == source })

        // A previously unseen Developer-Tool claim is an ownership change,
        // not just a lifecycle signal. Reserve its retirement slot in the
        // same candidate transaction, before the claim is appended. A Thread
        // already owned by another active Session is rejected rather than
        // being silently shared or rebound.
        var nextState = state
        if let identity = source.developerToolThreadIdentity {
            let sessionOwnership = session.developerToolOwnershipIdentities
            guard !state.developerToolOwnershipIdentities.contains(identity)
                    || sessionOwnership.contains(identity) else {
                return false
            }
            if !nextState.reservedDeveloperToolOwnershipIdentities.contains(identity) {
                do {
                    try nextState.admitDeveloperToolOwner(
                        tool: identity.tool,
                        externalSessionID: identity.externalSessionID,
                        at: date
                    )
                } catch {
                    return false
                }
            }
        }

        if existingClaimIndex == nil, !isActive {
            return true
        }
        if existingClaimIndex == nil,
           metadata.claims.count >= DeveloperToolIntegrationLimits.maximumContextsPerSession {
            return true
        }

        if let index = existingClaimIndex {
            metadata.claims[index].isActive = isActive
            metadata.claims[index].lastSignalAt = max(metadata.claims[index].lastSignalAt, signalDate)
        } else if isActive, metadata.claims.count < DeveloperToolIntegrationLimits.maximumContextsPerSession {
            metadata.claims.append(SessionAutomationClaim(
                source: source,
                isActive: isActive,
                lastSignalAt: signalDate
            ))
        }

        if isActive {
            metadata.lastMatchingSignalAt = signalDate
            metadata.pauseEligibleAt = signalDate.addingTimeInterval(metadata.pauseDelay)
            metadata.finishEligibleAt = signalDate.addingTimeInterval(metadata.finishDelay)
        } else if metadata.claims.contains(where: { $0.source == source }) {
            // A developer-tool Stop/session-end event is the transition to
            // idle. Its timestamp, rather than the preceding turn-start
            // signal, begins the automatic pause/finish countdown. The same
            // transition also keeps application claims' existing behavior
            // explicit when a frontmost application deactivates.
            metadata.pauseEligibleAt = signalDate.addingTimeInterval(metadata.pauseDelay)
            metadata.finishEligibleAt = signalDate.addingTimeInterval(metadata.finishDelay)
        }
        if isActive, session.phase == .paused {
            _ = session.resume(at: date)
        }
        session.automationMetadata = metadata

        guard replaceActiveSession(session, in: &nextState) else { return false }
        return commit(nextState, critical: true)
    }

    private func evaluateAutomaticLifecycle(at date: Date) {
        guard state.settings.automationEnabled else { return }

        // Snapshot only stable IDs. Every mutation below resolves the ID
        // against current state again, so an earlier commit cannot make a
        // later array position point at another Session.
        let sessionIDs = state.activeSessions
            .filter { session in
                guard session.phase == .running || session.phase == .paused,
                      let metadata = session.automationMetadata else { return false }
                return metadata.controlEnabled && !metadata.pendingAutomaticSave
            }
            .map(\.id)
        for sessionID in sessionIDs {
            evaluateAutomaticLifecycle(for: sessionID, at: date)
        }
    }

    private func evaluateAutomaticLifecycle(for sessionID: UUID, at date: Date) {
        guard state.settings.automationEnabled,
              var session = state.activeSession(id: sessionID),
              (session.phase == .running || session.phase == .paused),
              var metadata = session.automationMetadata,
              metadata.controlEnabled,
              !metadata.pendingAutomaticSave else {
            return
        }

        guard hasSupportingAutomationRule(for: session, metadata: metadata, in: state) else {
            var nextState = state
            relinquishInvalidAutomation(for: sessionID, in: &nextState)
            if nextState != state {
                _ = commit(nextState, critical: true, normalizeAutomation: false)
            }
            return
        }

        let pauseEligibleAt = automaticLifecycleDeadline(
            stored: metadata.pauseEligibleAt,
            fallbackSignalAt: metadata.lastMatchingSignalAt,
            delay: metadata.pauseDelay,
            claims: metadata.claims
        )
        let finishEligibleAt = automaticLifecycleDeadline(
            stored: metadata.finishEligibleAt,
            fallbackSignalAt: metadata.lastMatchingSignalAt,
            delay: metadata.finishDelay,
            claims: metadata.claims
        )
        metadata.pauseEligibleAt = pauseEligibleAt
        metadata.finishEligibleAt = finishEligibleAt

        let hasActiveClaim = metadata.claims.contains { claim in
            claimKeepsAutomationAlive(
                claim,
                at: date,
                pauseDelay: metadata.pauseDelay
            )
        }
        guard !hasActiveClaim else { return }

        if session.phase == .running, date >= pauseEligibleAt,
           session.pause(at: pauseEligibleAt) {
            session.automationMetadata = metadata
            var nextState = state
            guard replaceActiveSession(session, in: &nextState),
                  commit(nextState, critical: true, normalizeAutomation: false) else { return }
        }

        guard let refreshedSession = state.activeSession(id: sessionID),
              refreshedSession.phase == .paused,
              refreshedSession.automationMetadata?.controlEnabled == true,
              date >= finishEligibleAt else {
            return
        }
        finishAutomatically(sessionID: sessionID, at: min(date, finishEligibleAt))
    }

    /// Developer-tool claims describe a real session/turn and remain active
    /// until an explicit idle or end event arrives. Application claims retain
    /// their existing absence-of-notification timeout semantics.
    private func claimKeepsAutomationAlive(
        _ claim: SessionAutomationClaim,
        at date: Date,
        pauseDelay: TimeInterval
    ) -> Bool {
        guard claim.isActive else { return false }
        switch claim.source {
        case .developerTool:
            return true
        case .application:
            return date < claim.lastSignalAt.addingTimeInterval(pauseDelay)
        }
    }

    /// Preserve the persisted deadline as the primary compatibility value,
    /// while accounting for a still-fresh application claim that may have a
    /// later deadline after a mixed-source signal sequence.
    private func automaticLifecycleDeadline(
        stored: Date?,
        fallbackSignalAt: Date,
        delay: TimeInterval,
        claims: [SessionAutomationClaim]
    ) -> Date {
        var deadline = stored ?? fallbackSignalAt.addingTimeInterval(delay)
        for claim in claims {
            guard claim.isActive,
                  case .application = claim.source else {
                continue
            }
            deadline = max(deadline, claim.lastSignalAt.addingTimeInterval(delay))
        }
        return deadline
    }

    private func finishAutomatically(sessionID: UUID, at date: Date) {
        guard var session = state.activeSession(id: sessionID),
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
        guard replaceActiveSession(session, in: &nextState) else { return }
        guard commit(nextState, critical: true, normalizeAutomation: false) else { return }
        now = clock.now

        if session.gitContext != nil || isGitCaptureInProgress(for: sessionID) {
            scheduleFinalGitCapture(for: sessionID)
        } else {
            attemptAutomaticSaveIfReady(for: sessionID)
        }
    }

    private func restoreAutomaticFinishingState() {
        let finishingIDs = state.activeSessions
            .filter { $0.phase == .finishing }
            .map(\.id)
        for sessionID in finishingIDs {
            guard let session = state.activeSession(id: sessionID) else { continue }
            let hasCompletedFinalObservation = session.gitContext?.observationEndedAt
                .map { $0.timeIntervalSinceReferenceDate.isFinite } == true
            if session.automationMetadata?.pendingAutomaticSave == true {
                if hasCompletedFinalObservation {
                    // The final observation boundary is durable. Do not
                    // recapture it merely because the Session remained in its
                    // finishing review state across relaunch.
                    attemptAutomaticSaveIfReady(for: sessionID)
                } else if session.gitContext != nil {
                    scheduleFinalGitCapture(for: sessionID)
                } else if let project = session.projectID.flatMap({ id in
                    state.projects.first(where: { $0.id == id })
                }),
                          let folderURL = projectFolderURL(for: project),
                          FileManager.default.fileExists(atPath: folderURL.path) {
                    // A relaunch can interrupt the initial Git capture.
                    // Recreate only this Session's missing boundary.
                    scheduleStartGitCapture(for: sessionID, folderURL: folderURL)
                } else {
                    attemptAutomaticSaveIfReady(for: sessionID)
                }
            } else if session.gitContext != nil, !hasCompletedFinalObservation {
                scheduleFinalGitCapture(for: sessionID)
            }
        }
    }

    private func attemptAutomaticSaveIfReady(for sessionID: UUID) {
        guard !isGitCaptureInProgress(for: sessionID),
              let session = state.activeSession(id: sessionID),
              session.phase == .finishing,
              let metadata = session.automationMetadata,
              metadata.pendingAutomaticSave else {
            return
        }

        let endedAt = session.endedAt ?? clock.now
        if session.activeDuration(at: endedAt) < metadata.minimumSavedDuration {
            var nextState = state
            do {
                try nextState.retireDeveloperToolOwnership(for: session, retiredAt: clock.now)
                _ = try nextState.removeActiveSession(id: sessionID)
            } catch {
                return
            }
            guard commit(nextState, critical: true, normalizeAutomation: false) else { return }
            // Automatic minimum-duration discard retires the Session without
            // a completed History record; invalidate both local Git and
            // GitHub jobs so a late enrichment cannot linger as a restore
            // blocker or attempt to recreate the discarded Session.
            invalidateAsyncWork(for: sessionID)
            now = clock.now
            return
        }

        _ = completeFinishedSession(sessionID: sessionID, outcome: nil, refreshAfter: false)
    }

    private func completeFinishedSession(
        sessionID: UUID,
        outcome: String?,
        refreshAfter: Bool = true
    ) -> Bool {
        guard !isGitCaptureInProgress(for: sessionID),
              var session = state.activeSession(id: sessionID),
              session.phase == .finishing else {
            return false
        }

        session.outcome = ActiveSession.cleanOptionalText(outcome) ?? session.outcome
        guard let completed = session.completedSnapshot(outcome: session.outcome) else {
            return false
        }

        var nextState = state
        if !nextState.completedSessions.contains(where: { $0.id == completed.id }) {
            nextState.completedSessions.append(completed)
        }
        nextState.completedSessions.sort { $0.startedAt > $1.startedAt }
        do {
            try nextState.retireDeveloperToolOwnership(for: session, retiredAt: clock.now)
            _ = try nextState.removeActiveSession(id: session.id)
        } catch {
            return false
        }
        // Saving a legacy or otherwise partially observed Session is another
        // durable boundary at which same-root attribution must be resolved.
        // This may suppress derived numeric fields on the completed target
        // and any overlapping same-root Session, but never changes lifecycle
        // or ownership authority.
        nextState.reconcileGitObservationAttribution()
        guard commit(
            nextState,
            critical: true,
            normalizeAutomation: false,
            affectedSessionID: sessionID
        ) else { return false }
        refreshTerminalGitCaptureStatuses()
        invalidateGitCaptureState(for: sessionID)
        now = clock.now
        if refreshAfter { refreshAfterLifecycleMutation(for: sessionID) }
        return true
    }

    private func relinquishManualAutomationControl(in session: inout ActiveSession) {
        guard var metadata = session.automationMetadata else { return }
        metadata.controlEnabled = false
        metadata.pendingAutomaticSave = false
        session.automationMetadata = metadata
    }

    /// Targeted form used by automatic lifecycle evaluation. The existing
    /// collection-wide normalization remains appropriate for configuration
    /// changes, but a deadline evaluation must not touch another Session.
    private func relinquishInvalidAutomation(for sessionID: UUID, in state: inout AppState) {
        guard let index = state.activeSessionIndex(id: sessionID) else { return }
        var session = state.activeSessions[index]
        guard var metadata = session.automationMetadata else { return }

        guard state.settings.automationEnabled else {
            metadata.controlEnabled = false
            metadata.pendingAutomaticSave = false
            metadata.claims = metadata.claims.map { claim in
                var claim = claim
                claim.isActive = false
                return claim
            }
            session.automationMetadata = metadata
            state.activeSessions[index] = session
            return
        }

        let sources = Set(metadata.claims.map(\.source) + [metadata.startedBySource])
        let supportedSources = sources.filter { source in
            sessionAutomationCoordinator.hasSupportingRule(
                for: source,
                projectID: session.projectID,
                in: state
            )
        }
        metadata.claims = metadata.claims.map { claim in
            var claim = claim
            if !supportedSources.contains(claim.source) {
                claim.isActive = false
            }
            return claim
        }
        if supportedSources.isEmpty {
            metadata.controlEnabled = false
            metadata.pendingAutomaticSave = false
        }
        session.automationMetadata = metadata
        state.activeSessions[index] = session
    }

    private func relinquishInvalidAutomation(in state: inout AppState) {
        for index in state.activeSessions.indices {
            var session = state.activeSessions[index]
            guard var metadata = session.automationMetadata else { continue }

            guard state.settings.automationEnabled else {
                metadata.controlEnabled = false
                metadata.pendingAutomaticSave = false
                metadata.claims = metadata.claims.map { claim in
                    var claim = claim
                    claim.isActive = false
                    return claim
                }
                session.automationMetadata = metadata
                state.activeSessions[index] = session
                continue
            }

            let sources = Set(metadata.claims.map(\.source) + [metadata.startedBySource])
            let supportedSources = sources.filter { source in
                sessionAutomationCoordinator.hasSupportingRule(
                    for: source,
                    projectID: session.projectID,
                    in: state
                )
            }

            // Claims are both lifecycle state and historical ownership
            // metadata. When a rule is disabled, deleted, or becomes invalid,
            // relinquish lifecycle control by marking its claim inactive, but
            // retain the entry so its Developer-Tool identity remains owned
            // until this Session is finally saved or discarded.
            metadata.claims = metadata.claims.map { claim in
                var claim = claim
                if !supportedSources.contains(claim.source) {
                    claim.isActive = false
                }
                return claim
            }
            if supportedSources.isEmpty {
                metadata.controlEnabled = false
                metadata.pendingAutomaticSave = false
            }
            session.automationMetadata = metadata
            state.activeSessions[index] = session
        }
    }

    private func hasSupportingAutomationRule(
        for session: ActiveSession,
        metadata: SessionAutomationMetadata,
        in state: AppState
    ) -> Bool {
        let sources = Set(metadata.claims.map(\.source) + [metadata.startedBySource])
        return sources.contains { source in
            sessionAutomationCoordinator.hasSupportingRule(
                for: source,
                projectID: session.projectID,
                in: state
            )
        }
    }

    private func scheduleStartGitCapture(for sessionID: UUID, folderURL: URL) {
        guard state.activeSession(id: sessionID) != nil else { return }

        var capture = gitCaptureStates[sessionID] ?? SessionGitCaptureState()
        if capture.activeStage != nil {
            return
        }
        // A successful start boundary is immutable for a Session. Relaunch
        // recovery only retries when the boundary was never established.
        guard capture.startStatus != .succeeded else { return }

        let token = UUID()
        capture.startStatus = .scheduled
        capture.activeStage = .start
        capture.jobToken = token
        capture.generation = stateGeneration
        gitCaptureStates[sessionID] = capture
        refreshGitCaptureAggregate()

        let service = gitService
        let generation = stateGeneration
        DispatchQueue.main.async { [weak self] in
            self?.markGitJobRunning(
                sessionID: sessionID,
                stage: .start,
                token: token,
                generation: generation
            )
        }
        DispatchQueue.global(qos: .utility).async {
            let snapshot = service.captureStartSnapshot(at: folderURL)
            // A legacy/test GitServicing implementation may not populate the
            // optional boundary itself. Capture the completion instant on the
            // worker immediately after the repository observation returns so
            // the fallback still describes Git observation, never the Session
            // timer transition.
            let observationCompletedAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.applyStartGitSnapshot(
                    snapshot,
                    to: sessionID,
                    token: token,
                    generation: generation,
                    fallbackObservationStartedAt: observationCompletedAt
                )
            }
        }
    }

    private func applyStartGitSnapshot(
        _ snapshot: GitStartSnapshot?,
        to sessionID: UUID,
        token: UUID,
        generation: UUID,
        fallbackObservationStartedAt: Date
    ) {
        guard isCurrentGitJob(
            sessionID: sessionID,
            token: token,
            generation: generation,
            stage: .start
        ) else {
            return
        }

        guard var session = state.activeSession(id: sessionID) else {
            invalidateAsyncWork(for: sessionID)
            return
        }

        guard let snapshot else {
            finishGitJob(
                sessionID: sessionID,
                stage: .start,
                status: .failed,
                token: token,
                generation: generation
            )
            attemptAutomaticSaveIfReady(for: sessionID)
            return
        }

        session.gitContext = GitSessionContext(
            repositoryRoot: snapshot.repositoryRoot.path,
            branchAtStart: snapshot.branch,
            startHeadSHA: snapshot.headSHA,
            startWasDetached: snapshot.isDetached,
            preExistingWorkingTreePaths: snapshot.preExistingWorkingTreePaths.map { $0.sorted() },
            observationStartedAt: snapshot.observationStartedAt ?? fallbackObservationStartedAt
        )
        var nextState = state
        guard replaceActiveSession(session, in: &nextState) else { return }
        nextState.reconcileGitObservationAttribution()
        guard commit(nextState, normalizeAutomation: false) else {
            finishGitJob(
                sessionID: sessionID,
                stage: .start,
                status: .failed,
                token: token,
                generation: generation
            )
            attemptAutomaticSaveIfReady(for: sessionID)
            return
        }
        refreshTerminalGitCaptureStatuses()

        finishGitJob(
            sessionID: sessionID,
            stage: .start,
            status: state.activeSession(id: sessionID)?.gitContext?.deltaAttribution == .ambiguous
                ? .ambiguous
                : .succeeded,
            token: token,
            generation: generation
        )

        if state.activeSession(id: sessionID)?.phase == .finishing ||
            gitCaptureStates[sessionID]?.pendingFinalCapture == true {
            scheduleFinalGitCapture(for: sessionID)
        }
        attemptAutomaticSaveIfReady(for: sessionID)
        scheduleGitHubCapture(for: sessionID, snapshot: snapshot)
    }

    private func scheduleGitHubCapture(for sessionID: UUID, snapshot: GitStartSnapshot) {
        guard let repository = snapshot.remotes
            .sorted(by: { lhs, rhs in
                if lhs.name == "origin" { return rhs.name != "origin" }
                if rhs.name == "origin" { return false }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            })
            .compactMap({ GitHubRemoteParser.parse($0.url) })
            .first else {
            return
        }

        let token = UUID()
        let generation = stateGeneration
        githubCaptureJobs[sessionID] = AsyncJobIdentity(token: token, stateGeneration: generation)
        let service = githubContextService
        let repositoryRoot = snapshot.repositoryRoot
        let branch = snapshot.branch
        Task.detached(priority: .utility) { [service, repositoryRoot, branch, repository, sessionID] in
            let context = await service.captureContext(
                repositoryRoot: repositoryRoot,
                repository: repository,
                branch: branch
            )
            DispatchQueue.main.async { [weak self] in
                self?.applyGitHubContext(
                    context,
                    to: sessionID,
                    token: token,
                    generation: generation
                )
            }
        }
    }

    private func applyGitHubContext(
        _ context: GitHubSessionContext?,
        to sessionID: UUID,
        token: UUID,
        generation: UUID
    ) {
        guard githubCaptureJobs[sessionID] == AsyncJobIdentity(token: token, stateGeneration: generation),
              generation == stateGeneration else {
            return
        }
        githubCaptureJobs.removeValue(forKey: sessionID)
        guard let context else { return }

        if var session = state.activeSession(id: sessionID) {
            guard session.githubContext != context else { return }
            session.githubContext = context
            var nextState = state
            guard replaceActiveSession(session, in: &nextState) else { return }
            _ = commit(nextState, normalizeAutomation: false)
            return
        }

        guard let index = state.completedSessions.firstIndex(where: { $0.id == sessionID }) else {
            return
        }
        let completed = state.completedSessions[index]
        guard completed.githubContext != context else { return }
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
        nextState.completedSessions[index] = updated
        _ = commit(nextState, normalizeAutomation: false)
    }

    private func scheduleFinalGitCapture(for sessionID: UUID) {
        guard let session = state.activeSession(id: sessionID) else {
            return
        }

        var capture = gitCaptureStates[sessionID] ?? SessionGitCaptureState()
        if capture.activeStage == .start {
            capture.pendingFinalCapture = true
            gitCaptureStates[sessionID] = capture
            refreshGitCaptureAggregate()
            return
        }
        if capture.activeStage == .final {
            return
        }

        guard let gitContext = session.gitContext,
              let startSnapshot = gitStartSnapshot(from: gitContext) else {
            // A missing start boundary means there is no valid final job to
            // run. Mark the required final phase terminally failed when this
            // was an explicit finishing request, then let save/discard logic
            // proceed without blocking unrelated Sessions.
            capture.pendingFinalCapture = false
            capture.finalStatus = .failed
            capture.activeStage = nil
            capture.jobToken = nil
            gitCaptureStates[sessionID] = capture
            refreshGitCaptureAggregate()
            attemptAutomaticSaveIfReady(for: sessionID)
            return
        }

        let token = UUID()
        capture.finalStatus = .scheduled
        capture.activeStage = .final
        capture.pendingFinalCapture = false
        capture.jobToken = token
        capture.generation = stateGeneration
        gitCaptureStates[sessionID] = capture
        refreshGitCaptureAggregate()

        let service = gitService
        let generation = stateGeneration
        DispatchQueue.main.async { [weak self] in
            self?.markGitJobRunning(
                sessionID: sessionID,
                stage: .final,
                token: token,
                generation: generation
            )
        }
        DispatchQueue.global(qos: .utility).async {
            let snapshot = service.captureFinishSnapshot(for: startSnapshot)
            let observationCompletedAt = Date()
            DispatchQueue.main.async { [weak self] in
                self?.applyFinishGitSnapshot(
                    snapshot,
                    to: sessionID,
                    token: token,
                    generation: generation,
                    fallbackObservationEndedAt: observationCompletedAt
                )
            }
        }
    }

    private func applyFinishGitSnapshot(
        _ snapshot: GitFinishSnapshot?,
        to sessionID: UUID,
        token: UUID,
        generation: UUID,
        fallbackObservationEndedAt: Date
    ) {
        guard isCurrentGitJob(
            sessionID: sessionID,
            token: token,
            generation: generation,
            stage: .final
        ) else {
            return
        }
        guard var session = state.activeSession(id: sessionID),
              var gitContext = session.gitContext else {
            finishGitJob(
                sessionID: sessionID,
                stage: .final,
                status: .failed,
                token: token,
                generation: generation
            )
            return
        }

        let status: SessionGitCaptureStatus
        if let snapshot {
            let hadProvenAmbiguity = gitContext.deltaAttribution == .ambiguous
            gitContext.branchAtEnd = snapshot.branch
            gitContext.endHeadSHA = snapshot.headSHA
            gitContext.endWasDetached = snapshot.isDetached
            let observationEndedAt = snapshot.observationEndedAt ?? fallbackObservationEndedAt
            gitContext.observationEndedAt = observationEndedAt

            // A final snapshot is numerically attributable only when the
            // persisted start boundary is also known. Historical contexts
            // may have no observationStartedAt; never backfill that missing
            // boundary from Session.startedAt or manufacture confident
            // deltas from the final snapshot alone.
            if let observationStartedAt = gitContext.observationStartedAt,
               observationStartedAt.timeIntervalSinceReferenceDate.isFinite,
               observationEndedAt.timeIntervalSinceReferenceDate.isFinite,
               observationStartedAt <= observationEndedAt {
                gitContext.commitCount = snapshot.commitCount
                if let statistics = snapshot.statistics {
                    gitContext.filesChanged = statistics.filesChanged
                    gitContext.insertions = statistics.insertions
                    gitContext.deletions = statistics.deletions
                } else {
                    gitContext.filesChanged = nil
                    gitContext.insertions = nil
                    gitContext.deletions = nil
                }
                // Reconciliation may clear a prior ambiguity only when the
                // conflicting same-root peer evidence is still present and
                // now proves every comparison strictly separated. Preserve
                // the marker until that decision is made.
                gitContext.deltaAttribution = hadProvenAmbiguity ? .ambiguous : .attributable
            } else {
                gitContext.commitCount = nil
                gitContext.filesChanged = nil
                gitContext.insertions = nil
                gitContext.deletions = nil
                gitContext.deltaAttribution = .indeterminate
            }
            status = .succeeded
        } else {
            // Never infer an exact end from Session.endedAt after a failed
            // observation. Preserve independently valid start/repository
            // metadata but suppress every numeric delta.
            gitContext.observationEndedAt = nil
            gitContext.commitCount = nil
            gitContext.filesChanged = nil
            gitContext.insertions = nil
            gitContext.deletions = nil
            gitContext.deltaAttribution = .indeterminate
            status = .failed
        }
        session.gitContext = gitContext

        var nextState = state
        guard replaceActiveSession(session, in: &nextState) else { return }
        nextState.reconcileGitObservationAttribution()
        guard commit(nextState, normalizeAutomation: false) else {
            finishGitJob(
                sessionID: sessionID,
                stage: .final,
                status: .failed,
                token: token,
                generation: generation
            )
            attemptAutomaticSaveIfReady(for: sessionID)
            return
        }

        refreshTerminalGitCaptureStatuses()

        let resolvedStatus: SessionGitCaptureStatus = state.activeSession(id: sessionID)?.gitContext?.deltaAttribution == .ambiguous
            ? .ambiguous
            : status
        finishGitJob(
            sessionID: sessionID,
            stage: .final,
            status: resolvedStatus,
            token: token,
            generation: generation
        )
        attemptAutomaticSaveIfReady(for: sessionID)
    }

    private func isCurrentGitJob(
        sessionID: UUID,
        token: UUID,
        generation: UUID,
        stage: SessionGitCaptureStage
    ) -> Bool {
        guard generation == stateGeneration,
              let capture = gitCaptureStates[sessionID],
              capture.activeStage == stage,
              capture.jobToken == token,
              capture.generation == generation else {
            return false
        }
        return true
    }

    private func markGitJobRunning(
        sessionID: UUID,
        stage: SessionGitCaptureStage,
        token: UUID,
        generation: UUID
    ) {
        guard isCurrentGitJob(
            sessionID: sessionID,
            token: token,
            generation: generation,
            stage: stage
        ), var capture = gitCaptureStates[sessionID] else {
            return
        }
        switch stage {
        case .start:
            capture.startStatus = .running
        case .final:
            capture.finalStatus = .running
        }
        gitCaptureStates[sessionID] = capture
        refreshGitCaptureAggregate()
    }

    private func finishGitJob(
        sessionID: UUID,
        stage: SessionGitCaptureStage,
        status: SessionGitCaptureStatus,
        token: UUID,
        generation: UUID
    ) {
        guard isCurrentGitJob(
            sessionID: sessionID,
            token: token,
            generation: generation,
            stage: stage
        ), var capture = gitCaptureStates[sessionID] else {
            return
        }
        switch stage {
        case .start:
            capture.startStatus = status
            if status == .failed, capture.pendingFinalCapture {
                // A finish request may have arrived while the start
                // observation was running. There is no valid start context
                // from which to establish a final snapshot, so close that
                // queued requirement explicitly instead of leaving a stale
                // pending flag behind.
                capture.finalStatus = .failed
                capture.pendingFinalCapture = false
            }
        case .final:
            capture.finalStatus = status
            capture.pendingFinalCapture = false
        }
        capture.activeStage = nil
        capture.jobToken = nil
        gitCaptureStates[sessionID] = capture
        refreshGitCaptureAggregate()
    }

    private func invalidateGitCaptureState(for sessionID: UUID) {
        gitCaptureStates.removeValue(forKey: sessionID)
        refreshGitCaptureAggregate()
    }

    private func invalidateAsyncWork(for sessionID: UUID) {
        gitCaptureStates.removeValue(forKey: sessionID)
        githubCaptureJobs.removeValue(forKey: sessionID)
        refreshGitCaptureAggregate()
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
            preExistingWorkingTreePaths: context.preExistingWorkingTreePaths.map { Set($0) },
            observationStartedAt: context.observationStartedAt
        )
    }
}

extension SessionStore: DigestStateProviding {
    var digestAppState: AppState { state }
}
