import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    private let onDismiss: (() -> Void)?
    private let onOpenInsights: (() -> Void)?
    @State private var selectedActivityID: UUID?

    init(onDismiss: (() -> Void)? = nil, onOpenInsights: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        self.onOpenInsights = onOpenInsights
    }

    var body: some View {
        let dismissPopover = onDismiss ?? { dismiss() }
        let currentRuns = CurrentActivityProjection.runs(in: store.activityGraph, at: store.now)

        VStack(alignment: .leading, spacing: 0) {
            if store.phase == .finishing {
                FinishingSessionView()
            } else if currentRuns.isEmpty {
                IdleSessionView()
            } else {
                ActiveNowView(runs: currentRuns) { selectedActivityID = $0 }
            }

            Divider()
                .padding(.top, 16)

            PopoverFooter(onDismiss: dismissPopover, onOpenInsights: onOpenInsights)
        }
        .padding(18)
        .frame(width: 380)
        .sheet(isPresented: Binding(
            get: { selectedActivityID != nil },
            set: { if !$0 { selectedActivityID = nil } }
        )) {
            if let selectedActivityID {
                ActivityDetailView(activityID: selectedActivityID)
                    .environmentObject(store)
            }
        }
    }
}

private struct ActiveNowView: View {
    @EnvironmentObject private var store: SessionStore
    let runs: [CurrentActivityRun]
    let showDetails: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Now")
                .font(.title3.weight(.semibold))

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(runs) { run in
                        ActiveNowRunRow(run: run, showDetails: showDetails)
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }
}

private struct ActiveNowRunRow: View {
    @EnvironmentObject private var store: SessionStore
    let run: CurrentActivityRun
    let showDetails: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.workspaceName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(run.statusDescription)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(run.displayState == .waiting ? .orange : .secondary)
            }

            Text(run.activityTitle)
                .font(.subheadline)
                .lineLimit(1)

            HStack(spacing: 6) {
                Label(run.integration?.title ?? "Manual timer", systemImage: run.integration == nil ? "timer" : "terminal")
                if let model = run.model { Text(model) }
                Spacer()
                Text(CodePulseFormatting.duration(run.activeDuration, includeSeconds: true))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Details") { showDetails(run.activityID) }
                    .buttonStyle(.link)
                if run.isCodePulseOwnedManualRun {
                    Button("Finish Manual") {
                        _ = store.finishCodePulseOwnedManualRun(id: run.runID)
                    }
                    .buttonStyle(.link)
                    .accessibilityHint("Finishes only this CodePulse-owned manual session")
                }
            }
            .font(.caption)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(run.accessibilitySummary)
    }
}

private struct ActivityDetailView: View {
    @EnvironmentObject private var store: SessionStore
    let activityID: UUID

    var body: some View {
        let activity = store.activityGraph.activities.first(where: { $0.id == activityID })
        let metrics = store.activityTimingMetrics(for: activityID)
        VStack(alignment: .leading, spacing: 12) {
            Text(activity?.title ?? "Activity")
                .font(.title2.weight(.semibold))
            LabeledContent("Manual active", value: CodePulseFormatting.duration(metrics.manualActive, includeSeconds: true))
            LabeledContent("Agent runtime", value: CodePulseFormatting.duration(metrics.agentRuntime, includeSeconds: true))
            LabeledContent("Agent waiting", value: CodePulseFormatting.duration(metrics.agentWaiting, includeSeconds: true))
            LabeledContent("Combined wall-active", value: CodePulseFormatting.duration(metrics.combinedWallActive, includeSeconds: true))
            Divider()
            ActivityTimelineView(activityID: activityID)
        }
        .padding(20)
        .frame(minWidth: 360)
    }
}

private struct ActivityTimelineView: View {
    @EnvironmentObject private var store: SessionStore
    let activityID: UUID

    var body: some View {
        let entries = ActivityTimelineProjection.entries(activityID: activityID, in: store.activityGraph)
        VStack(alignment: .leading, spacing: 6) {
            Text("Timeline")
                .font(.headline)
            if entries.isEmpty {
                Text("No recorded intervals")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(entries) { entry in
                            HStack(alignment: .firstTextBaseline) {
                                Text(CodePulseFormatting.time(entry.startedAt))
                                    .monospacedDigit()
                                Text(entry.runLabel)
                                Spacer()
                                Text(entry.stateLabel)
                                    .foregroundStyle(entry.state == .waiting ? .orange : .secondary)
                            }
                            .font(.caption)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel("\(CodePulseFormatting.time(entry.startedAt)), \(entry.runLabel), \(entry.stateLabel)")
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }
}

private struct IdleSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var selectedProjectID: UUID?
    @State private var selectedType: SessionType = .coding
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CodePulse")
                .font(.title3.weight(.semibold))

            Text("Ready to code?")
                .font(.headline)

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
            .accessibilityLabel("Start Session")
            .accessibilityValue("Start Session")
            .accessibilityHint("Starts a coding session")
        }
        .onAppear {
            selectedProjectID = store.defaultProjectID
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
                    ForEach(store.projectsSortedByRecentUse) { project in
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
        selectedProjectID.flatMap { id in store.state.projects.first(where: { $0.id == id })?.name } ?? "No Project"
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
