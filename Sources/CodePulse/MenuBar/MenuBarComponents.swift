import CodePulseIntegration
import SwiftUI

struct MenuBarMetadataCapsule: View {
    let title: String
    let systemImage: String
    let accessibilityText: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

struct MenuBarGitMetadataCapsule: View {
    let context: GitSessionContext

    var body: some View {
        if let branchDisplay = context.branchDisplay {
            MenuBarMetadataCapsule(
                title: "git: \(branchDisplay)",
                systemImage: "arrow.triangle.branch",
                accessibilityText: "Git branch \(branchDisplay)"
            )
        } else if let headDisplay = context.headDisplay {
            MenuBarMetadataCapsule(
                title: "git: \(headDisplay)",
                systemImage: "arrow.triangle.branch",
                accessibilityText: "Git commit \(headDisplay)"
            )
        }
    }
}

struct MenuBarDeveloperToolMetadataCapsule: View {
    let context: DeveloperToolSessionContext

    var body: some View {
        MenuBarMetadataCapsule(
            title: context.displayName,
            systemImage: context.tool.systemImage,
            accessibilityText: "Developer tool \(context.displayName)"
        )
    }
}

struct MenuBarSessionStatusBadge: View {
    let phase: SessionPhase

    private var title: String {
        phase == .paused ? "Paused" : "Running"
    }

    private var systemImage: String {
        phase == .paused ? "pause.fill" : "play.fill"
    }

    private var color: Color {
        phase == .paused ? .orange : .green
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(color.opacity(0.18), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(phase == .paused ? "Timer frozen" : "Timer running")
    }
}

struct MenuBarTimerView: View {
    let duration: TimeInterval
    let phase: SessionPhase

    private var stateText: String {
        phase == .paused ? "Paused · timer frozen" : "Running"
    }

    private var stateColor: Color {
        phase == .paused ? .orange : .green
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(CodePulseFormatting.duration(duration, includeSeconds: true))
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)

            Label(stateText, systemImage: phase == .paused ? "pause.fill" : "play.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elapsed time")
        .accessibilityValue("\(CodePulseFormatting.duration(duration, includeSeconds: true)), \(stateText)")
        .accessibilityHint(phase == .paused ? "The timer is frozen until you resume the session" : "The timer is running")
    }
}

struct MenuBarGoalBlock: View {
    let goal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Active goal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let goal, !goal.isEmpty {
                Text(goal)
                    .font(.body)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No goal set")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

struct MenuBarSessionContextHeader: View {
    let projectName: String?
    let type: SessionType
    let phase: SessionPhase
    let automationLabel: String?
    let hasAutomationMetadata: Bool

    private var displayProjectName: String {
        guard let projectName, !projectName.isEmpty else { return "No Project" }
        return projectName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(displayProjectName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                MenuBarSessionStatusBadge(phase: phase)
            }

            HStack(spacing: 8) {
                Label(type.title, systemImage: type.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let automationLabel {
                    Label(automationLabel, systemImage: "bolt.badge.clock")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(automationLabel)
                } else if hasAutomationMetadata {
                    Label("Manual control", systemImage: "hand.raised")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Manual control")
                        .accessibilityHint("Automation no longer controls this session")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct MenuBarGitCaptureStatus: View {
    var body: some View {
        HStack(spacing: 7) {
            ProgressView()
                .controlSize(.small)

            Text("Collecting Git…")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Collecting Git")
        .accessibilityValue("Saving is disabled until Git capture finishes")
    }
}
