import CodePulseIntegration
import Foundation

enum SessionAutomationAction: Equatable {
    case start(rule: SessionAutomationRule, startDate: Date)
    case signal(
        rule: SessionAutomationRule,
        tool: DeveloperTool,
        externalSessionID: String,
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
        guard state.settings.automationEnabled else {
            guard state.activeSession?.automationMetadata?.controlEnabled == true else { return nil }
            return .relinquish
        }

        if let activeSession = state.activeSession {
            guard activeSession.phase == .running || activeSession.phase == .paused else { return nil }
            guard let metadata = activeSession.automationMetadata else {
                // Manual sessions remain completely outside automation control.
                return nil
            }
            guard metadata.controlEnabled else { return nil }

            guard let startedRule = state.automationRules.first(where: { $0.id == metadata.startedByRuleID }),
                  startedRule.isEnabled,
                  let project = state.projects.first(where: { $0.id == activeSession.projectID }),
                  DeveloperToolProjectResolver.isUsableFolder(for: project) else {
                return .relinquish
            }

            let rules = matchingRules(
                for: event,
                projectID: activeSession.projectID,
                state: state
            )
            guard let rule = rules.first else { return nil }
            return .signal(
                rule: rule,
                tool: event.tool,
                externalSessionID: event.externalSessionID,
                isActive: event.eventType == .sessionStarted || event.eventType == .activity
            )
        }

        guard event.eventType == .sessionStarted || event.eventType == .activity,
              event.timestamp <= now,
              event.timestamp >= now.addingTimeInterval(-Self.maximumStartBackdate),
              let rule = matchingRules(for: event, projectID: nil, state: state).first else {
            return nil
        }

        return .start(rule: rule, startDate: event.timestamp)
    }

    private func matchingRules(
        for event: DeveloperToolEvent,
        projectID: UUID?,
        state: AppState
    ) -> [SessionAutomationRule] {
        state.automationRules
            .filter { rule in
                guard rule.isEnabled,
                      rule.developerTool == event.tool,
                      projectID == nil || rule.projectID == projectID,
                      let project = state.projects.first(where: { $0.id == rule.projectID }),
                      let projectPath = DeveloperToolProjectResolver.folderPath(for: project),
                      DeveloperToolProjectResolver.isUsableFolder(for: project) else {
                    return false
                }
                return DeveloperToolProjectPathMatcher.matches(
                    projectPath: projectPath,
                    workingDirectory: event.workingDirectory
                )
            }
            .sorted { lhs, rhs in
                if lhs.name != rhs.name { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }
}
