import SwiftUI

struct MenuBarFinishingView: View {
    @EnvironmentObject private var store: SessionStore
    let sessionID: UUID

    @State private var outcome = ""
    @State private var outcomeSaveWorkItem: DispatchWorkItem?

    private var session: ActiveSession? { store.state.activeSession(id: sessionID) }
    private var isCapturingGit: Bool { store.isGitCaptureInProgress(for: sessionID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label("Finish session", systemImage: "flag.checkered")
                    .font(.title3.weight(.semibold))

                Spacer(minLength: 8)

                Text(CodePulseFormatting.duration(store.elapsedDuration(for: sessionID), includeSeconds: true))
                    .font(.system(.subheadline, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(CodePulseFormatting.duration(store.elapsedDuration(for: sessionID), includeSeconds: true))
            }

            Text("Review the session details, add an outcome, then save or discard it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Text(session?.projectName.flatMap { $0.isEmpty ? nil : $0 } ?? "No Project")
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.tail)

                Label(
                    session?.type.title ?? SessionType.coding.title,
                    systemImage: session?.type.systemImage ?? SessionType.coding.systemImage
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            MenuBarGoalBlock(goal: session?.goal)

            if hasMetadata {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Context")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    MenuBarMetadataViews(
                        gitContext: session?.gitContext,
                        developerToolContexts: session?.developerToolContexts ?? []
                    )
                }
            }

            if let githubContext = session?.githubContext {
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

            if isCapturingGit {
                MenuBarGitCaptureStatus()
            }

            Button {
                outcomeSaveWorkItem?.cancel()
                _ = store.saveFinishedSession(sessionID: sessionID, outcome: outcome)
            } label: {
                HStack(spacing: 7) {
                    if isCapturingGit {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }

                    Text(isCapturingGit ? "Collecting Git…" : "Save Session")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(isCapturingGit)
            .accessibilityLabel(isCapturingGit ? "Collecting Git" : "Save Session")
            .accessibilityValue(isCapturingGit ? "Collecting Git" : "Save Session")
            .accessibilityHint("Saves the finished coding session")
            .accessibilityIdentifier("save-session-button")

            Button("Discard Session", role: .destructive) {
                outcomeSaveWorkItem?.cancel()
                _ = store.discardSession(sessionID: sessionID)
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
            outcome = session?.outcome ?? ""
        }
        .onChange(of: sessionID) { newSessionID in
            outcomeSaveWorkItem?.cancel()
            outcomeSaveWorkItem = nil
            outcome = store.state.activeSession(id: newSessionID)?.outcome ?? ""
        }
        .onChange(of: outcome) { newValue in
            outcomeSaveWorkItem?.cancel()
            let targetSessionID = sessionID
            let workItem = DispatchWorkItem {
                _ = store.updateFinishingOutcome(sessionID: targetSessionID, outcome: newValue)
            }
            outcomeSaveWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
        }
        .onDisappear {
            outcomeSaveWorkItem?.cancel()
            outcomeSaveWorkItem = nil
            _ = store.updateFinishingOutcome(sessionID: sessionID, outcome: outcome)
        }
        .accessibilityIdentifier("selected-session-detail")
    }

    private var hasMetadata: Bool {
        session?.gitContext != nil || !(session?.developerToolContexts.isEmpty ?? true)
    }
}
