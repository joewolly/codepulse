import AppKit
import SwiftUI

struct MenuBarIdleView: View {
    @EnvironmentObject private var store: SessionStore

    @State private var selectedPresetID: UUID?
    @State private var selectedProjectID: UUID?
    @State private var selectedType: SessionType = .coding
    @State private var goal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                MenuBarAppIcon()

                Text("CodePulse")
                    .font(.headline.weight(.semibold))

                Spacer(minLength: 8)

                Text("Idle")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if !store.sessionPresetsSorted.isEmpty {
                MenuBarQuickStartView(selectedPresetID: $selectedPresetID)
            }

            Divider()

            MenuBarProjectPicker(selectedProjectID: $selectedProjectID)
            MenuBarSessionTypePicker(selectedType: $selectedType)

            VStack(alignment: .leading, spacing: 4) {
                Text("Goal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("What are you working on?", text: $goal, axis: .vertical)
                    .lineLimit(1...2)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Goal")
                    .accessibilityIdentifier("goal-field")
            }

            Button {
                _ = store.startSession(projectID: selectedProjectID, goal: goal, type: selectedType)
            } label: {
                Label("Start Session", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .foregroundStyle(.white)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(!store.isProjectAvailableForManualStart(selectedProjectID))
            .accessibilityLabel("Start Session")
            .accessibilityValue("Start Session")
            .accessibilityHint("Starts a \(selectedType.title.lowercased()) session")
            .accessibilityIdentifier("start-session-button")
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

private struct MenuBarQuickStartView: View {
    @EnvironmentObject private var store: SessionStore
    @Binding var selectedPresetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Quick Start", systemImage: "bolt.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if EmptyStateCopy.presetAvailability(
                savedCount: store.sessionPresetsSorted.count,
                availableCount: store.sessionPresetsAvailableForManualStart.count
            ) == .savedButUnavailable {
                EmptyStateView(content: EmptyStateCopy.unavailablePresets)
                    .padding(.vertical, -8)
            }

            HStack(spacing: 8) {
                Picker("Session preset", selection: $selectedPresetID) {
                    Text("Choose a preset").tag(UUID?.none)
                    ForEach(store.sessionPresetsAvailableForManualStart) { preset in
                        Text(preset.name)
                            .tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .accessibilityLabel("Session preset")

                Button {
                    guard let selectedPresetID,
                          let preset = store.sessionPreset(id: selectedPresetID) else { return }
                    _ = store.startSession(using: preset)
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .foregroundStyle(.white)
                .controlSize(.regular)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .disabled(selectedPresetID.flatMap { store.sessionPreset(id: $0) }
                    .map { !store.isSessionPresetAvailableForManualStart($0) } ?? true)
                .accessibilityLabel("Start selected session preset")
                .accessibilityHint("Starts a manual session using the selected preset, when it is still available")
            }

            if let selectedPresetID,
               let selectedPreset = store.sessionPreset(id: selectedPresetID),
               !store.isSessionPresetAvailableForManualStart(selectedPreset) {
                Label(
                    "The selected preset uses an archived or unavailable project. Restore the project before starting it.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct MenuBarProjectPicker: View {
    @EnvironmentObject private var store: SessionStore
    @Binding var selectedProjectID: UUID?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Project")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

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
                            Label(
                                project.name,
                                systemImage: selectedProjectID == project.id ? "checkmark" : "folder"
                            )
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
                    Image(systemName: selectedProjectID == nil ? "folder" : "folder.fill")
                        .foregroundStyle(.secondary)

                    Text(selectedProjectName)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 215, alignment: .trailing)
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Project, \(selectedProjectName)")
            .accessibilityIdentifier("project-picker")
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

        guard panel.runModal() == .OK,
              let url = panel.url,
              let projectID = store.addProject(name: url.lastPathComponent, folderURL: url) else {
            return
        }

        selectedProjectID = projectID
    }
}

struct MenuBarSessionTypePicker: View {
    @Binding var selectedType: SessionType

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Type")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Picker("Session type", selection: $selectedType) {
                ForEach(SessionType.allCases) { sessionType in
                    Label(sessionType.title, systemImage: sessionType.systemImage)
                        .tag(sessionType)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 215, alignment: .trailing)
            .accessibilityLabel("Session type")
            .accessibilityValue(selectedType.title)
            .accessibilityIdentifier("session-type-picker")
        }
    }
}
