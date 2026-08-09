import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
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

            PopoverFooter()
        }
        .padding(18)
        .frame(width: 350)
    }
}

private struct IdleSessionView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var selectedProjectID: UUID?
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CodePulse")
                .font(.title3.weight(.semibold))

            Text("Ready to code?")
                .font(.headline)

            ProjectSelectionRow(selectedProjectID: $selectedProjectID)

            VStack(alignment: .leading, spacing: 6) {
                Text("Goal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("What are you working on?", text: $goal, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                _ = store.startSession(projectID: selectedProjectID, goal: goal)
            } label: {
                Label("Start Session", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityHint("Starts a coding session")
        }
        .onAppear {
            selectedProjectID = store.defaultProjectID
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

                Button {
                    _ = store.finish()
                } label: {
                    Label("Finish", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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

            VStack(alignment: .leading, spacing: 6) {
                Text("Outcome")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("What actually happened?", text: $outcome, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
            }

            Button {
                _ = store.saveFinishedSession(outcome: outcome)
            } label: {
                Label("Save Session", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button("Discard Session", role: .destructive) {
                _ = store.discardSession()
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PopoverFooter: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

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
                openWindow(id: "history")
                dismiss()
                activateApp()
            }
            .buttonStyle(.link)

            SettingsButton(dismiss: dismiss)
        }
    }

    private func activateApp() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct SettingsButton: View {
    let dismiss: DismissAction

    var body: some View {
        if #available(macOS 14.0, *) {
            ModernSettingsButton(dismiss: dismiss)
        } else {
            LegacySettingsButton(dismiss: dismiss)
        }
    }
}

@available(macOS 14.0, *)
private struct ModernSettingsButton: View {
    let dismiss: DismissAction
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Settings") {
            openSettings()
            dismiss()
            activateApp()
        }
        .buttonStyle(.link)
    }

    private func activateApp() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct LegacySettingsButton: View {
    let dismiss: DismissAction

    var body: some View {
        Button("Settings") {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: NSApp, from: nil)
            dismiss()
            activateApp()
        }
        .buttonStyle(.link)
    }

    private func activateApp() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
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
                    ForEach(store.state.projects) { project in
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
