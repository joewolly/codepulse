import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    private let onDismiss: (() -> Void)?
    private let onOpenInsights: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil, onOpenInsights: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        self.onOpenInsights = onOpenInsights
    }

    var body: some View {
        let dismissPopover = onDismiss ?? { dismiss() }

        VStack(alignment: .leading, spacing: 0) {
            switch store.phase {
            case .idle:
                IdleSessionView()
            case .running, .paused:
                ActiveSessionView()
            case .finishing:
                FinishingSessionView()
            }

            Divider()
                .padding(.top, 16)

            PopoverFooter(onDismiss: dismissPopover, onOpenInsights: onOpenInsights)
        }
        .padding(18)
        .frame(width: 350)
    }
}

private struct IdleSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var selectedPresetID: UUID?
    @State private var selectedProjectID: UUID?
    @State private var selectedType: SessionType = .coding
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CodePulse")
                .font(.title3.weight(.semibold))

            Text("Ready to code?")
                .font(.headline)

            if !store.sessionPresetsSorted.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Quick Start")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if EmptyStateCopy.presetAvailability(
                        savedCount: store.sessionPresetsSorted.count,
                        availableCount: store.sessionPresetsAvailableForManualStart.count
                    ) == .savedButUnavailable {
                        EmptyStateView(content: EmptyStateCopy.unavailablePresets)
                    }

                    HStack {
                        Picker("Session preset", selection: $selectedPresetID) {
                            Text("Choose a preset").tag(UUID?.none)
                            ForEach(store.sessionPresetsAvailableForManualStart) { preset in
                                Text(preset.name).tag(Optional(preset.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        Button {
                            guard let selectedPresetID,
                                  let preset = store.sessionPreset(id: selectedPresetID) else { return }
                            _ = store.startSession(using: preset)
                        } label: {
                            Label("Start", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(selectedPresetID.flatMap { store.sessionPreset(id: $0) }
                            .map { !store.isSessionPresetAvailableForManualStart($0) } ?? true)
                        .accessibilityLabel("Start selected session preset")
                        .accessibilityHint("Starts a manual session using the selected preset, when it is still available")
                    }

                    if let selectedPresetID,
                       let selectedPreset = store.sessionPreset(id: selectedPresetID),
                       !store.isSessionPresetAvailableForManualStart(selectedPreset) {
                        Label("The selected preset uses an archived or unavailable project. Restore the project before starting it.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            ProjectSelectionRow(selectedProjectID: $selectedProjectID)

            SessionTypeSelectionRow(selectedType: $selectedType)

            VStack(alignment: .leading, spacing: 6) {
                Text("Goal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("What are you working on?", text: $goal, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Goal")
            }

            Button {
                _ = store.startSession(projectID: selectedProjectID, goal: goal, type: selectedType)
            } label: {
                Label("Start Session", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!store.isProjectAvailableForManualStart(selectedProjectID))
            .accessibilityLabel("Start Session")
            .accessibilityValue("Start Session")
            .accessibilityHint("Starts a coding session")
        }
        .onAppear {
            selectedProjectID = store.defaultProjectID
        }
        .onChange(of: store.state.projects) { _ in
            guard !store.isProjectAvailableForManualStart(selectedProjectID) else { return }
            selectedProjectID = nil
        }
    }
}

private struct SessionTypeSelectionRow: View {
    @Binding var selectedType: SessionType

    var body: some View {
        HStack {
            Text("Type")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()

            Picker("Session type", selection: $selectedType) {
                ForEach(SessionType.allCases) { sessionType in
                    Label(sessionType.title, systemImage: sessionType.systemImage)
                        .tag(sessionType)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityLabel("Session type")
            .accessibilityValue(selectedType.title)
        }
    }
}

private struct ActiveSessionView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(store.activeSession?.projectName ?? "Coding Session")
                .font(.title3.weight(.semibold))
                .lineLimit(2)

            Label(store.activeSession?.type.title ?? SessionType.coding.title, systemImage: store.activeSession?.type.systemImage ?? SessionType.coding.systemImage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let automationStatus = store.activeAutomationStatusLabel {
                Label(
                    automationStatus,
                    systemImage: "bolt.badge.clock"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(automationStatus)
            } else if store.activeSession?.automationMetadata != nil {
                Label("Manual control", systemImage: "hand.raised")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Manual control")
                    .accessibilityHint("Automation no longer controls this session")
            }

            Text(CodePulseFormatting.duration(store.elapsedDuration, includeSeconds: true))
                .font(.system(size: 34, weight: .medium, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Elapsed time")

            if store.phase == .paused {
                Label("Paused", systemImage: "pause.fill")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let goal = store.activeSession?.goal {
                Text(goal)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let contexts = store.activeSession?.developerToolContexts,
               !contexts.isEmpty {
                ScrollView(.vertical) {
                    DeveloperToolContextList(contexts: contexts, showsEventCounts: false)
                }
                .frame(maxHeight: 120)
            }

            HStack(spacing: 10) {
                Button {
                    if store.phase == .paused {
                        _ = store.resume()
                    } else {
                        _ = store.pause()
                    }
                } label: {
                    Label(store.phase == .paused ? "Resume" : "Pause", systemImage: store.phase == .paused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.space, modifiers: [])
                .accessibilityLabel(store.phase == .paused ? "Resume" : "Pause")
                .accessibilityValue(store.phase == .paused ? "Resume" : "Pause")
                .accessibilityHint(store.phase == .paused ? "Resumes the coding session" : "Pauses the coding session")

                Button {
                    _ = store.finish()
                } label: {
                    Label("Finish", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("f", modifiers: [.command])
                .accessibilityLabel("Finish")
                .accessibilityValue("Finish")
                .accessibilityHint("Finishes the coding session")
            }

            LabeledContent("Started", value: CodePulseFormatting.time(store.activeSession?.startedAt ?? store.now))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FinishingSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var outcome = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Session Complete")
                .font(.title3.weight(.semibold))

            Text(CodePulseFormatting.duration(store.elapsedDuration, includeSeconds: true))
                .font(.system(size: 32, weight: .medium, design: .monospaced))

            if let projectName = store.activeSession?.projectName {
                Text(projectName)
                    .font(.headline)
            }
            if let goal = store.activeSession?.goal {
                Text(goal)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let githubContext = store.activeSession?.githubContext {
                GitHubContextView(context: githubContext, compact: true)
            }

            if let contexts = store.activeSession?.developerToolContexts,
               !contexts.isEmpty {
                ScrollView(.vertical) {
                    DeveloperToolContextList(contexts: contexts, showsEventCounts: false)
                }
                .frame(maxHeight: 120)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Outcome")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("What actually happened?", text: $outcome, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Outcome")
            }

            Button {
                _ = store.saveFinishedSession(outcome: outcome)
            } label: {
                Label(
                    store.gitCaptureInProgress ? "Collecting Git…" : "Save Session",
                    systemImage: store.gitCaptureInProgress ? "arrow.triangle.2.circlepath" : "square.and.arrow.down"
                )
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(store.gitCaptureInProgress)
            .accessibilityLabel(store.gitCaptureInProgress ? "Collecting Git" : "Save Session")
            .accessibilityValue(store.gitCaptureInProgress ? "Collecting Git" : "Save Session")
            .accessibilityHint("Saves the completed coding session")

            Button("Discard Session", role: .destructive) {
                _ = store.discardSession()
            }
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Discard Session")
            .accessibilityValue("Discard Session")
            .accessibilityHint("Discards the completed coding session")
        }
    }
}

private struct PopoverFooter: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowCoordinator: AppWindowCoordinator
    @Environment(\.openWindow) private var openWindow
    let onDismiss: () -> Void
    let onOpenInsights: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(CodePulseFormatting.menuBarDuration(store.todayTotal()))
                    .font(.body.weight(.medium))
            }

            Spacer()

            Button("History") {
                windowCoordinator.showHistory()
                onDismiss()
                activateApp()
            }
            .buttonStyle(.link)
            .accessibilityLabel("History")
            .accessibilityValue("History")
            .accessibilityHint("Opens saved sessions")

            Button("Insights") {
                if let onOpenInsights {
                    onOpenInsights()
                } else {
                    openWindow(id: "insights")
                }
                onDismiss()
                activateApp()
            }
            .buttonStyle(.link)
            .accessibilityLabel("Insights")
            .accessibilityValue("Insights")
            .accessibilityHint("Opens local coding insights")

            SettingsButton(onDismiss: onDismiss)

            Button("Quit") {
                NSApp.terminate(nil)
            }
            .buttonStyle(.link)
            .accessibilityLabel("Quit CodePulse")
            .accessibilityValue("Quit CodePulse")
            .accessibilityHint("Quits CodePulse")
        }
    }

    private func activateApp() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct SettingsButton: View {
    let onDismiss: () -> Void

    var body: some View {
        Button("Settings") {
            NSApp.activate(ignoringOtherApps: true)
            if let settingsItem = NSApp.mainMenu?
                .item(withTitle: "CodePulse")?
                .submenu?
                .item(withTitle: "Settings…") {
                if let action = settingsItem.action {
                    NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
                }
            }
            onDismiss()
        }
        .buttonStyle(.link)
        .accessibilityLabel("Settings")
        .accessibilityValue("Settings")
        .accessibilityHint("Opens CodePulse settings")
    }
}

private struct ProjectSelectionRow: View {
    @EnvironmentObject private var store: SessionStore
    @Binding var selectedProjectID: UUID?

    var body: some View {
        HStack {
            Text("Project")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()

            Menu {
                Button {
                    selectedProjectID = nil
                } label: {
                    Label("No Project", systemImage: selectedProjectID == nil ? "checkmark" : "circle")
                }

                if !store.state.projects.isEmpty {
                    Divider()
                    ForEach(store.selectableProjectsSortedByRecentUse) { project in
                        Button {
                            selectedProjectID = project.id
                        } label: {
                            Label(project.name, systemImage: selectedProjectID == project.id ? "checkmark" : "folder")
                        }
                    }
                }

                Divider()
                Button {
                    chooseFolder()
                } label: {
                    Label("Add Project…", systemImage: "plus")
                }
            } label: {
                HStack(spacing: 5) {
                    Text(selectedProjectName)
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Project, \(selectedProjectName)")
        }
    }

    private var selectedProjectName: String {
        selectedProjectID.flatMap { id in
            store.state.projects.first(where: { $0.id == id && $0.isActive })?.name
        } ?? "No Project"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url,
              let projectID = store.addProject(name: url.lastPathComponent, folderURL: url) else {
            return
        }
        selectedProjectID = projectID
    }
}
