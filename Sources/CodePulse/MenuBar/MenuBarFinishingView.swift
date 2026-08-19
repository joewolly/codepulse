import SwiftUI

struct MenuBarFinishingView: View {
    @EnvironmentObject private var store: SessionStore

    @State private var outcome = ""
    @State private var outcomeSaveWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Finish session", systemImage: "flag.checkered")
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 8)

                Text(CodePulseFormatting.duration(store.elapsedDuration, includeSeconds: true))
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(CodePulseFormatting.duration(store.elapsedDuration, includeSeconds: true))
            }

            Text("Review the session details, add an outcome, then save or discard it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text(store.activeSession?.projectName.flatMap { $0.isEmpty ? nil : $0 } ?? "No Project")
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)

                Label(
                    store.activeSession?.type.title ?? SessionType.coding.title,
                    systemImage: store.activeSession?.type.systemImage ?? SessionType.coding.systemImage
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

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

            if let githubContext = store.activeSession?.githubContext {
                GitHubContextView(context: githubContext, compact: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Outcome")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("What actually happened?", text: $outcome, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Outcome")
                    .accessibilityIdentifier("outcome-field")
            }

            if store.gitCaptureInProgress {
                MenuBarGitCaptureStatus()
            }

            Button {
                _ = store.saveFinishedSession(outcome: outcome)
            } label: {
                HStack(spacing: 7) {
                    if store.gitCaptureInProgress {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }

                    Text(store.gitCaptureInProgress ? "Collecting Git…" : "Save Session")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(store.gitCaptureInProgress)
            .accessibilityLabel(store.gitCaptureInProgress ? "Collecting Git" : "Save Session")
            .accessibilityValue(store.gitCaptureInProgress ? "Collecting Git" : "Save Session")
            .accessibilityHint("Saves the finished coding session")
            .accessibilityIdentifier("save-session-button")

            Button("Discard Session", role: .destructive) {
                _ = store.discardSession()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Discard Session")
            .accessibilityValue("Discard Session")
            .accessibilityHint("Discards the finished coding session")
            .accessibilityIdentifier("discard-session-button")
        }
        .onAppear {
            outcome = store.activeSession?.outcome ?? ""
        }
        .onChange(of: outcome) { newValue in
            outcomeSaveWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                _ = store.updateFinishingOutcome(newValue)
            }
            outcomeSaveWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }
        .onDisappear {
            outcomeSaveWorkItem?.cancel()
            outcomeSaveWorkItem = nil
            _ = store.updateFinishingOutcome(outcome)
        }
    }

    private var hasMetadata: Bool {
        store.activeSession?.gitContext != nil || !(store.activeSession?.developerToolContexts.isEmpty ?? true)
    }
}
