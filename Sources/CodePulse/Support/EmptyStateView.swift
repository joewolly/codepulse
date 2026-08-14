import SwiftUI

struct EmptyStateContent: Equatable {
    let systemImage: String
    let title: String
    let message: String
}

enum PresetAvailabilityState: Equatable {
    case noneSaved
    case savedButUnavailable
    case someAvailable
}

enum EmptyStateCopy {
    static func history(hasAnySessions: Bool) -> EmptyStateContent {
        if hasAnySessions {
            return EmptyStateContent(
                systemImage: "line.3.horizontal.decrease.circle",
                title: "No Matching Sessions",
                message: "Try changing your search or filters."
            )
        }

        return EmptyStateContent(
            systemImage: "clock",
            title: "No Sessions Yet",
            message: "Finish and save your first session to build your history."
        )
    }

    static func insights(
        hasSavedSessions: Bool,
        timeframeTitle: String,
        projectTitle: String,
        isAllProjects: Bool
    ) -> EmptyStateContent {
        guard hasSavedSessions else {
            return EmptyStateContent(
                systemImage: "clock",
                title: "Not Enough Activity Yet",
                message: "Insights appear after you save sessions."
            )
        }

        let message: String
        if isAllProjects {
            message = "There is no saved activity in \(timeframeTitle.lowercased()). Try another timeframe."
        } else {
            message = "There is no saved activity for \(projectTitle) in \(timeframeTitle.lowercased()). Try another project or timeframe."
        }

        return EmptyStateContent(
            systemImage: "chart.bar.xaxis",
            title: "No Activity in This Selection",
            message: message
        )
    }

    static let projects = EmptyStateContent(
        systemImage: "folder",
        title: "Projects Are Optional",
        message: "Add a project to enable Git context, more useful developer-tool matching, project-specific automation, and project-specific History and Insights filtering. You can also work with No Project."
    )

    static let presets = EmptyStateContent(
        systemImage: "bolt",
        title: "No Presets Yet",
        message: "Presets save a project, work type, and optional goal for faster starts. Quick Start is optional."
    )

    static let automation = EmptyStateContent(
        systemImage: "bolt.badge.clock",
        title: "No Automation Rules Yet",
        message: "Automation is optional. Rules can start and manage eligible sessions from Codex/OpenCode lifecycle metadata or selected frontmost applications."
    )

    static func automationEmptyState(ruleCount: Int) -> EmptyStateContent? {
        ruleCount == 0 ? automation : nil
    }

    static func presetAvailability(savedCount: Int, availableCount: Int) -> PresetAvailabilityState {
        guard savedCount > 0 else { return .noneSaved }
        return availableCount > 0 ? .someAvailable : .savedButUnavailable
    }

    static let unavailablePresets = EmptyStateContent(
        systemImage: "archivebox",
        title: "Saved Presets Are Unavailable",
        message: "Restore or relink their projects before using them for Quick Start."
    )
}

struct EmptyStateView: View {
    let content: EmptyStateContent
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        content: EmptyStateContent,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.content = content
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: content.systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Text(content.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text(content.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .accessibilityElement(children: .contain)
    }
}
