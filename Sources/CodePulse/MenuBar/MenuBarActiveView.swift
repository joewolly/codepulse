import CodePulseIntegration
import SwiftUI

struct MenuBarActiveView: View {
    @EnvironmentObject private var store: SessionStore
    let sessionID: UUID

    private var session: ActiveSession? { store.state.activeSession(id: sessionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let session {
                MenuBarSessionContextHeader(
                    projectName: session.projectName,
                    type: session.type,
                    phase: session.phase,
                    automationLabel: store.automationStatusLabel(for: sessionID),
                    hasAutomationMetadata: session.automationMetadata != nil
                )

                MenuBarTimerView(duration: store.elapsedDuration(for: sessionID), phase: session.phase)
                    .accessibilityIdentifier("elapsed-timer")

                MenuBarGoalBlock(goal: session.goal)

                if session.gitContext != nil || !session.developerToolContexts.isEmpty {
                    MenuBarMetadataViews(
                        gitContext: session.gitContext,
                        developerToolContexts: session.developerToolContexts
                    )
                }

                HStack(spacing: 10) {
                    Button {
                        if session.phase == .paused {
                            _ = store.resume(sessionID: sessionID)
                        } else {
                            _ = store.pause(sessionID: sessionID)
                        }
                    } label: {
                        Label(
                            session.phase == .paused ? "Resume" : "Pause",
                            systemImage: session.phase == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .keyboardShortcut(.space, modifiers: [])
                    .accessibilityLabel(session.phase == .paused ? "Resume" : "Pause")
                    .accessibilityValue(session.phase == .paused ? "Resume" : "Pause")
                    .accessibilityHint(session.phase == .paused ? "Resumes this session" : "Pauses this session")
                    .accessibilityIdentifier("pause-resume-button")

                    Button {
                        _ = store.finish(sessionID: sessionID)
                    } label: {
                        Label("Finish", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.accentColor)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .controlSize(.large)
                    .keyboardShortcut("f", modifiers: [.command])
                    .accessibilityLabel("Finish")
                    .accessibilityValue("Finish")
                    .accessibilityHint("Moves the coding session into the finishing workflow")
                    .accessibilityIdentifier("finish-session-button")
                }

            }
        }
        .accessibilityIdentifier("selected-session-detail")
    }
}

struct MenuBarMetadataViews: View {
    static let maximumVisibleDeveloperToolContexts = 1

    let gitContext: GitSessionContext?
    let developerToolContexts: [DeveloperToolSessionContext]

    var visibleDeveloperToolContexts: [DeveloperToolSessionContext] {
        Array(developerToolContexts.prefix(Self.maximumVisibleDeveloperToolContexts))
    }

    var additionalDeveloperToolContextCount: Int {
        max(0, developerToolContexts.count - visibleDeveloperToolContexts.count)
    }

    var additionalDeveloperToolContextTitle: String? {
        guard additionalDeveloperToolContextCount > 0 else { return nil }
        return "+\(additionalDeveloperToolContextCount) more"
    }

    var additionalDeveloperToolContextAccessibilityText: String? {
        guard additionalDeveloperToolContextCount > 0 else { return nil }
        let sessionLabel = additionalDeveloperToolContextCount == 1 ? "session" : "sessions"
        return "\(additionalDeveloperToolContextCount) additional developer tool \(sessionLabel)"
    }

    private var metadataTextWidth: CGFloat {
        additionalDeveloperToolContextCount > 0 ? 100 : (gitContext == nil ? 180 : 150)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let gitContext {
                MenuBarGitMetadataCapsule(context: gitContext, maximumTextWidth: metadataTextWidth)
            }

            ForEach(visibleDeveloperToolContexts) { context in
                MenuBarDeveloperToolMetadataCapsule(context: context, maximumTextWidth: metadataTextWidth)
            }

            if let title = additionalDeveloperToolContextTitle,
               let accessibilityText = additionalDeveloperToolContextAccessibilityText {
                MenuBarMetadataCapsule(
                    title: title,
                    systemImage: "ellipsis",
                    accessibilityText: accessibilityText,
                    maximumTextWidth: metadataTextWidth
                )
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
