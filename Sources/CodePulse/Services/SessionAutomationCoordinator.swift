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

        let source = SessionAutomationClaimSource.developerTool(
            tool: event.tool,
            externalSessionID: event.externalSessionID
        )
        let isActive = event.eventType == .sessionStarted || event.eventType == .activity

        if let activeSession = state.activeSession {
            guard activeSession.phase == .running || activeSession.phase == .paused,
                  let metadata = activeSession.automationMetadata,
                  metadata.controlEnabled else {
                return []
            }

            // An ending signal for an already-known claim remains meaningful
            // even if the rule was just disabled or the tool reports a final
            // directory that no longer matches the configured folder.
            if !isActive,
               metadata.claims.contains(where: { $0.source == source }) {
                return [.signalWithSource(rule: nil, source: source, isActive: false)]
            }

            guard let rule = matchingDeveloperRules(
                for: event,
                projectID: activeSession.projectID,
                state: state
            ).first else {
                return []
            }
            return [.signal(
                rule: rule,
                tool: event.tool,
                externalSessionID: event.externalSessionID,
                isActive: isActive
            )]
        }

        guard isActive,
              event.timestamp <= now,
              event.timestamp >= now.addingTimeInterval(-Self.maximumStartBackdate),
              let rule = matchingDeveloperRules(for: event, projectID: nil, state: state).first else {
            return []
        }

        return [.start(rule: rule, startDate: event.timestamp)]
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

        if let activeSession = state.activeSession {
            guard activeSession.phase == .running || activeSession.phase == .paused,
                  let metadata = activeSession.automationMetadata,
                  metadata.controlEnabled else {
                return []
            }

            var actions: [SessionAutomationAction] = []
            if let application,
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
                guard case .application(let claimedBundleIdentifier) = claim.source,
                      claimedBundleIdentifier != bundleIdentifier || applicationSource == nil else {
                    continue
                }
                actions.append(.signalWithSource(
                    rule: nil,
                    source: claim.source,
                    isActive: false
                ))
            }
            return actions
        }

        guard let application,
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
        state.automationRules
            .filter { rule in
                guard rule.isEnabled,
                      let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
                      preset.projectID == projectID,
                      let projectID = preset.projectID,
                      let project = state.projects.first(where: { $0.id == projectID }),
                      DeveloperToolProjectResolver.isUsableFolder(for: project) else {
                    return false
                }

                switch source {
                case .developerTool(let tool, _):
                    return rule.developerTool == tool
                case .application(let bundleIdentifier):
                    return rule.applicationTrigger?.matches(bundleIdentifier: bundleIdentifier) == true
                }
            }
            .sorted(by: rulePrecedes)
    }

    func hasSupportingRule(
        for source: SessionAutomationClaimSource,
        projectID: UUID?,
        in state: AppState
    ) -> Bool {
        !rulesSupporting(source, projectID: projectID, in: state).isEmpty
    }

    private func matchingDeveloperRules(
        for event: DeveloperToolEvent,
        projectID: UUID?,
        state: AppState
    ) -> [SessionAutomationRule] {
        state.automationRules
            .filter { rule in
                guard rule.isEnabled,
                      rule.developerTool == event.tool,
                      let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
                      projectID == nil || preset.projectID == projectID,
                      let projectID = preset.projectID,
                      let project = state.projects.first(where: { $0.id == projectID }),
                      let projectPath = DeveloperToolProjectResolver.folderPath(for: project),
                      DeveloperToolProjectResolver.isUsableFolder(for: project) else {
                    return false
                }
                return DeveloperToolProjectPathMatcher.matches(
                    projectPath: projectPath,
                    workingDirectory: event.workingDirectory
                )
            }
            .sorted(by: rulePrecedes)
    }

    private func matchingApplicationRules(
        for application: ApplicationIdentity,
        projectID: UUID?,
        state: AppState
    ) -> [SessionAutomationRule] {
        state.automationRules
            .filter { rule in
                guard rule.isEnabled,
                      rule.applicationTrigger?.matches(bundleIdentifier: application.bundleIdentifier) == true,
                      let preset = state.sessionPresets.first(where: { $0.id == rule.presetID }),
                      projectID == nil || preset.projectID == projectID,
                      let projectID = preset.projectID,
                      let project = state.projects.first(where: { $0.id == projectID }),
                      DeveloperToolProjectResolver.isUsableFolder(for: project) else {
                    return false
                }
                return true
            }
            .sorted(by: rulePrecedes)
    }

    private func rulePrecedes(_ lhs: SessionAutomationRule, _ rhs: SessionAutomationRule) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
