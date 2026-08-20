import CodePulseIntegration
import Foundation

enum SessionAutomationAction: Equatable {
    // These two cases remain source-compatible with Milestone 1 callers.
    case start(rule: SessionAutomationRule, startDate: Date)
    case signal(
        rule: SessionAutomationRule,
        tool: DeveloperTool,
        externalSessionID: String,
        isActive: Bool
    )

    /// Developer-tool actions carry the event-resolved project explicitly.
    /// This prevents a later session mutation from consulting a global or
    /// manually selected project.
    case startWithResolvedProject(
        rule: SessionAutomationRule,
        projectID: UUID,
        startDate: Date
    )
    case signalWithResolvedProject(
        rule: SessionAutomationRule,
        projectID: UUID,
        tool: DeveloperTool,
        externalSessionID: String,
        isActive: Bool
    )

    // New sources use the same lifecycle application path with a generic
    // claim source. The coordinator does not own session mutations.
    case startWithSource(
        rule: SessionAutomationRule,
        source: SessionAutomationClaimSource,
        startDate: Date
    )
    case signalWithSource(
        rule: SessionAutomationRule?,
        source: SessionAutomationClaimSource,
        isActive: Bool
    )
    case relinquish
}

struct SessionAutomationCoordinator {
    static let maximumStartBackdate: TimeInterval = 5 * 60

    /// A frontmost application identity is not a developer-tool session.
    /// Known Codex/OpenCode identities therefore cannot establish project
    /// automation context; only lifecycle events carry a working directory.
    static func isDeveloperToolApplication(_ application: ApplicationIdentity) -> Bool {
        DeveloperToolApplicationClassifier.isDeveloperTool(application)
    }

    static func isDeveloperToolApplicationBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        DeveloperToolApplicationClassifier.isDeveloperToolBundleIdentifier(bundleIdentifier)
    }

    /// Projectless templates are reusable for any resolved project. A legacy
    /// project-backed template remains eligible only for its saved project;
    /// the saved project never supplies the runtime session project.
    static func developerToolPresetMatchesRuntimeProject(
        _ preset: SessionPreset,
        resolvedProjectID: UUID
    ) -> Bool {
        preset.projectID == nil || preset.projectID == resolvedProjectID
    }

    func action(
        for event: DeveloperToolEvent,
        in state: AppState,
        now: Date
    ) -> SessionAutomationAction? {
        actions(for: event, in: state, now: now).first
    }

    func actions(
        for event: DeveloperToolEvent,
        in state: AppState,
        now: Date
    ) -> [SessionAutomationAction] {
        guard state.settings.automationEnabled else {
            guard state.activeSession?.automationMetadata?.controlEnabled == true else { return [] }
            return [.relinquish]
        }

        let isActive = event.eventType == .sessionStarted || event.eventType == .activity
        let resolvedProjectID = DeveloperToolProjectResolver.projectID(
            for: event.workingDirectory,
            in: state.projects
        )

        if let activeSession = state.activeSession {
            guard activeSession.phase == .running || activeSession.phase == .paused,
                  let metadata = activeSession.automationMetadata,
                  metadata.controlEnabled else {
                return []
            }

            guard let resolvedProjectID,
                  resolvedProjectID == activeSession.projectID else {
                return []
            }

            guard let rule = matchingDeveloperRule(
                for: event,
                projectID: resolvedProjectID,
                state: state
            ) else {
                return []
            }
            return [.signalWithResolvedProject(
                rule: rule,
                projectID: resolvedProjectID,
                tool: event.tool,
                externalSessionID: event.externalSessionID,
                isActive: isActive
            )]
        }

        guard isActive,
              event.timestamp <= now,
              event.timestamp >= now.addingTimeInterval(-Self.maximumStartBackdate),
              let resolvedProjectID,
              let rule = matchingDeveloperRule(
                  for: event,
                  projectID: resolvedProjectID,
                  state: state
              ) else {
            return []
        }

        return [.startWithResolvedProject(
            rule: rule,
            projectID: resolvedProjectID,
            startDate: event.timestamp
        )]
    }

    func action(
        for application: ApplicationIdentity?,
        in state: AppState,
        now: Date
    ) -> SessionAutomationAction? {
        applicationActions(for: application, in: state, now: now).first
    }

    func applicationActions(
        for application: ApplicationIdentity?,
        in state: AppState,
        now: Date
    ) -> [SessionAutomationAction] {
        guard state.settings.automationEnabled else {
            guard state.activeSession?.automationMetadata?.controlEnabled == true else { return [] }
            return [.relinquish]
        }

        let bundleIdentifier = application?.isValid == true ? application?.bundleIdentifier : nil
        let applicationSource = bundleIdentifier.map {
            SessionAutomationClaimSource.application(bundleIdentifier: $0)
        }
        let isDeveloperToolApplication = application.map(Self.isDeveloperToolApplication) == true

        if let activeSession = state.activeSession {
            guard activeSession.phase == .running || activeSession.phase == .paused,
                  let metadata = activeSession.automationMetadata,
                  metadata.controlEnabled else {
                return []
            }

            var actions: [SessionAutomationAction] = []
            if let application,
               !isDeveloperToolApplication,
               let rule = matchingApplicationRules(
                   for: application,
                   projectID: activeSession.projectID,
                   state: state
               ).first {
                actions.append(.signalWithSource(
                    rule: rule,
                    source: .application(bundleIdentifier: application.bundleIdentifier),
                    isActive: true
                ))
            }

            // A workspace activation notification only reports the new app.
            // Deactivate any previous app claims before lifecycle evaluation;
            // the current matching claim above is immediately refreshed.
            for claim in metadata.claims {
                guard case .application(let claimedBundleIdentifier) = claim.source else {
                    continue
                }
                let isSupportedCurrentApplication = applicationSource != nil
                    && !isDeveloperToolApplication
                    && claimedBundleIdentifier == bundleIdentifier
                guard !isSupportedCurrentApplication else { continue }
                actions.append(.signalWithSource(
                    rule: nil,
                    source: claim.source,
                    isActive: false
                ))
            }
            return actions
        }

        guard let application,
              !isDeveloperToolApplication,
              let rule = matchingApplicationRules(for: application, projectID: nil, state: state).first else {
            return []
        }

        return [.startWithSource(
            rule: rule,
            source: .application(bundleIdentifier: application.bundleIdentifier),
            startDate: now
        )]
    }

    /// Returns enabled, project-valid rules that can legitimately maintain a
    /// claim for an existing automated session. This is also used when a rule,
    /// preset, project, or global setting changes while a session is active.
    func rulesSupporting(
        _ source: SessionAutomationClaimSource,
        projectID: UUID?,
        in state: AppState
    ) -> [SessionAutomationRule] {
        switch source {
        case .developerTool(let tool, _):
            guard let projectID,
                  let project = state.projects.first(where: { $0.id == projectID }),
                  project.isActive,
                  DeveloperToolProjectResolver.isUsableFolder(for: project),
                  let rule = matchingDeveloperRule(
                      for: tool,
                      projectID: projectID,
                      state: state
                  ) else {
                return []
            }
            return [rule]
        case .application(let bundleIdentifier):
            return state.automationRules
                .filter { rule in
                    guard rule.isEnabled,
                          rule.isValid,
                          let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
                          preset.isValid,
                          isDeveloperToolPresetUsable(preset, in: state),
                          preset.projectID == projectID,
                          let projectID,
                          let project = state.projects.first(where: { $0.id == projectID }),
                          project.isActive,
                          DeveloperToolProjectResolver.isUsableFolder(for: project),
                          !Self.isDeveloperToolApplicationBundleIdentifier(bundleIdentifier),
                          rule.applicationTrigger?.applications.contains(where: Self.isDeveloperToolApplication) != true else {
                        return false
                    }
                    return rule.applicationTrigger?.matches(bundleIdentifier: bundleIdentifier) == true
                }
                .sorted(by: rulePrecedes)
        }
    }

    func hasSupportingRule(
        for source: SessionAutomationClaimSource,
        projectID: UUID?,
        in state: AppState
    ) -> Bool {
        !rulesSupporting(source, projectID: projectID, in: state).isEmpty
    }

    private func matchingDeveloperRule(
        for event: DeveloperToolEvent,
        projectID: UUID,
        state: AppState
    ) -> SessionAutomationRule? {
        matchingDeveloperRule(
            for: event.tool,
            projectID: projectID,
            state: state
        )
    }

    /// Project-backed developer-tool rules retain their former project scope.
    /// Projectless rules are reusable fallbacks only when no eligible scoped
    /// rule exists. Neither category has an intentional priority feature, so
    /// an equal-precedence collision fails closed instead of sorting by name.
    private func matchingDeveloperRule(
        for tool: DeveloperTool,
        projectID: UUID,
        state: AppState
    ) -> SessionAutomationRule? {
        let eligible = state.automationRules.compactMap { rule -> (rule: SessionAutomationRule, preset: SessionPreset)? in
            guard rule.isEnabled,
                  rule.isValid,
                  rule.developerTool == tool,
                  let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
                  isDeveloperToolPresetUsable(preset, in: state),
                  Self.developerToolPresetMatchesRuntimeProject(
                      preset,
                      resolvedProjectID: projectID
                  ),
                  let project = state.projects.first(where: { $0.id == projectID }),
                  project.isActive,
                  DeveloperToolProjectResolver.isUsableFolder(for: project) else {
                return nil
            }
            return (rule: rule, preset: preset)
        }

        let scoped = eligible.filter { $0.preset.projectID == projectID }
        let selected = scoped.isEmpty
            ? eligible.filter { $0.preset.projectID == nil }
            : scoped
        guard selected.count == 1 else { return nil }
        return selected[0].rule
    }

    private func matchingApplicationRules(
        for application: ApplicationIdentity,
        projectID: UUID?,
        state: AppState
    ) -> [SessionAutomationRule] {
        guard !Self.isDeveloperToolApplication(application) else { return [] }
        return state.automationRules
            .filter { rule in
                guard rule.isEnabled,
                      rule.isValid,
                      rule.applicationTrigger?.matches(bundleIdentifier: application.bundleIdentifier) == true,
                      let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
                      projectID == nil || preset.projectID == projectID,
                      let projectID = preset.projectID,
                      let project = state.projects.first(where: { $0.id == projectID }),
                      project.isActive,
                      DeveloperToolProjectResolver.isUsableFolder(for: project),
                      rule.applicationTrigger?.applications.contains(where: Self.isDeveloperToolApplication) != true else {
                    return false
                }
                return true
            }
            .sorted(by: rulePrecedes)
    }

    private func isDeveloperToolPresetUsable(_ preset: SessionPreset, in state: AppState) -> Bool {
        guard preset.isValid else { return false }
        guard let configuredProjectID = preset.projectID else { return true }
        guard let configuredProject = state.projects.first(where: { $0.id == configuredProjectID }),
              configuredProject.isActive else {
            return false
        }
        return DeveloperToolProjectResolver.isUsableFolder(for: configuredProject)
    }

    private func rulePrecedes(_ lhs: SessionAutomationRule, _ rhs: SessionAutomationRule) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
