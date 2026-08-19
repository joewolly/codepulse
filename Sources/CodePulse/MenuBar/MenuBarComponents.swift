import AppKit
import CodePulseIntegration
import SwiftUI

struct MenuBarMetadataCapsule: View {
    let title: String
    let systemImage: String
    let accessibilityText: String
    var maximumTextWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)

            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maximumTextWidth, alignment: .leading)
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
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
    var maximumTextWidth: CGFloat = 180

    var body: some View {
        if let branchDisplay = context.branchDisplay {
            MenuBarMetadataCapsule(
                title: "git: \(branchDisplay)",
                systemImage: "arrow.triangle.branch",
                accessibilityText: "Git branch \(branchDisplay)",
                maximumTextWidth: maximumTextWidth
            )
        } else if let headDisplay = context.headDisplay {
            MenuBarMetadataCapsule(
                title: "git: \(headDisplay)",
                systemImage: "arrow.triangle.branch",
                accessibilityText: "Git commit \(headDisplay)",
                maximumTextWidth: maximumTextWidth
            )
        }
    }
}

struct MenuBarDeveloperToolMetadataCapsule: View {
    let context: DeveloperToolSessionContext
    var maximumTextWidth: CGFloat = 180

    var body: some View {
        MenuBarMetadataCapsule(
            title: context.displayName,
            systemImage: context.tool.systemImage,
            accessibilityText: "Developer tool \(context.displayName)",
            maximumTextWidth: maximumTextWidth
        )
    }
}

struct MenuBarSessionStatusBadge: View {
    let phase: SessionPhase
    let type: SessionType

    private var stateTitle: String {
        phase == .paused ? "Paused" : "Running"
    }

    private var systemImage: String {
        phase == .paused ? "pause.fill" : "play.fill"
    }

    private var color: Color {
        phase == .paused ? .orange : .green
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.bold))

            Text("\(type.title) · \(stateTitle)")
                .lineLimit(1)
        }
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
        .accessibilityLabel("\(type.title), \(stateTitle)")
        .accessibilityValue(phase == .paused ? "Timer frozen" : "Timer running")
    }
}

struct MenuBarAppIcon: View {
    var body: some View {
        Group {
            if let image = NSImage(named: "CodePulse") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(5)
            }
        }
        .frame(width: 27, height: 27)
        .accessibilityHidden(true)
    }
}

struct MenuBarTimerView: View {
    let duration: TimeInterval
    let phase: SessionPhase

    private var stateText: String {
        phase == .paused ? "Paused · timer frozen" : "Running"
    }

    var body: some View {
        Text(CodePulseFormatting.duration(duration, includeSeconds: true))
            .font(.system(size: 40, weight: .medium, design: .monospaced))
            .monospacedDigit()
            .minimumScaleFactor(0.72)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .frame(height: 92)
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
        Group {
            if let goal, !goal.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Active Goal")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    Text(goal)
                        .font(.body)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("No active goal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        HStack(alignment: .center, spacing: 10) {
            MenuBarAppIcon()

            VStack(alignment: .leading, spacing: 1) {
                Text("CodePulse")
                    .font(.headline.weight(.semibold))

                Text(displayProjectName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let automationLabel {
                    Label(automationLabel, systemImage: "bolt.badge.clock")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityLabel(automationLabel)
                } else if hasAutomationMetadata {
                    Label("Manual control", systemImage: "hand.raised")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Manual control")
                        .accessibilityHint("Automation no longer controls this session")
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            MenuBarSessionStatusBadge(phase: phase, type: type)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("CodePulse, \(displayProjectName), \(type.title), \(phase == .paused ? "Paused" : "Running")")
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
