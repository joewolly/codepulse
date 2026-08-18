import CodePulseIntegration
import SwiftUI

struct MenuBarActiveView: View {
    @EnvironmentObject private var store: SessionStore

    private var sessionType: SessionType {
        store.activeSession?.type ?? .coding
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MenuBarSessionContextHeader(
                projectName: store.activeSession?.projectName,
                type: sessionType,
                phase: store.phase,
                automationLabel: store.activeAutomationStatusLabel,
                hasAutomationMetadata: store.activeSession?.automationMetadata != nil
            )

            MenuBarTimerView(duration: store.elapsedDuration, phase: store.phase)
                .accessibilityIdentifier("elapsed-timer")

            MenuBarGoalBlock(goal: store.activeSession?.goal)

            if hasMetadata {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Context")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    MenuBarMetadataViews(
                        gitContext: store.activeSession?.gitContext,
                        developerToolContexts: store.activeSession?.developerToolContexts ?? []
                    )
                }
            }

            HStack(spacing: 10) {
                Button {
                    if store.phase == .paused {
                        _ = store.resume()
                    } else {
                        _ = store.pause()
                    }
                } label: {
                    Label(
                        store.phase == .paused ? "Resume" : "Pause",
                        systemImage: store.phase == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(store.phase == .paused ? "Resume" : "Pause")
                .accessibilityValue(store.phase == .paused ? "Resume" : "Pause")
                .accessibilityHint(store.phase == .paused ? "Resumes the coding session" : "Pauses the coding session")
                .accessibilityIdentifier("pause-resume-button")

                Button {
                    _ = store.finish()
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

            Label(
                "Started \(CodePulseFormatting.time(store.activeSession?.startedAt ?? store.now))",
                systemImage: "clock"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var hasMetadata: Bool {
        store.activeSession?.gitContext != nil || !(store.activeSession?.developerToolContexts.isEmpty ?? true)
    }
}

struct MenuBarMetadataViews: View {
    let gitContext: GitSessionContext?
    let developerToolContexts: [DeveloperToolSessionContext]

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if let gitContext {
                MenuBarGitMetadataCapsule(context: gitContext)
            }

            ForEach(developerToolContexts) { context in
                MenuBarDeveloperToolMetadataCapsule(context: context)
            }
        }
    }
}
