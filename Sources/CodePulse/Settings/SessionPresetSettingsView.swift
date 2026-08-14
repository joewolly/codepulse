import SwiftUI

struct SessionPresetSettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var presetBeingEdited: SessionPreset?
    @State private var isPresentingEditor = false

    var body: some View {
        Section("Session Presets") {
            Text("Reusable project, work type, and goal combinations for manual Quick Start sessions and local automation rules.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.sessionPresetsSorted.isEmpty {
                EmptyStateView(content: EmptyStateCopy.presets)
            } else {
                ForEach(store.sessionPresetsSorted) { preset in
                    let project = preset.projectID.flatMap { id in
                        store.state.projects.first(where: { $0.id == id })
                    }
                    SessionPresetRow(
                        preset: preset,
                        projectName: project?.name,
                        isProjectArchived: project?.isArchived == true,
                        isAvailableForManualStart: store.isSessionPresetAvailableForManualStart(preset),
                        isAutomationUsable: project.map { !$0.isArchived && DeveloperToolProjectResolver.isUsableFolder(for: $0) } ?? false,
                        edit: {
                            presetBeingEdited = preset
                            isPresentingEditor = true
                        },
                        delete: { store.deleteSessionPreset(id: preset.id) }
                    )
                }
            }

            Button {
                presetBeingEdited = nil
                isPresentingEditor = true
            } label: {
                Label("Add Session Preset…", systemImage: "plus")
            }
            .accessibilityHint("Creates a reusable manual or automation session preset")
        }
        .sheet(isPresented: $isPresentingEditor) {
            SessionPresetEditorView(
                preset: presetBeingEdited,
                projects: store.projectsForPresetEditing(presetBeingEdited),
                save: { preset in
                    guard store.upsertSessionPreset(preset) else { return false }
                    isPresentingEditor = false
                    return true
                },
                cancel: { isPresentingEditor = false }
            )
        }
    }
}

private struct SessionPresetRow: View {
    let preset: SessionPreset
    let projectName: String?
    let isProjectArchived: Bool
    let isAvailableForManualStart: Bool
    let isAutomationUsable: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: preset.sessionType.systemImage)
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(preset.name)
                Text([projectLabel, preset.sessionType.title].joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if isProjectArchived {
                    Text("Project Archived — unavailable until restored")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if preset.projectID != nil && !isAvailableForManualStart {
                    Text("Project unavailable for Quick Start")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                } else if preset.projectID != nil && !isAutomationUsable {
                    Text("Project unavailable for automation")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                if let goal = preset.goal {
                    Text(goal)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Button("Edit", action: edit)
                .buttonStyle(.borderless)
            Button {
                delete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete \(preset.name)")
            .accessibilityHint("Deletes the preset and leaves any referencing automation rule available for repair")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(preset.name), \(projectLabel), \(preset.sessionType.title)")
        .accessibilityValue(availabilitySummary)
    }

    private var projectLabel: String {
        guard let projectName else { return "No Project" }
        return isProjectArchived ? "\(projectName) (Archived)" : projectName
    }

    private var availabilitySummary: String {
        if isProjectArchived { return "Project Archived, unavailable until restored" }
        if preset.projectID != nil && !isAvailableForManualStart {
            return "Project unavailable for Quick Start"
        }
        if preset.projectID != nil && !isAutomationUsable {
            return "Project unavailable for automation"
        }
        return "Available"
    }
}

private struct SessionPresetEditorView: View {
    let preset: SessionPreset?
    let projects: [ProjectRecord]
    let save: (SessionPreset) -> Bool
    let cancel: () -> Void

    @State private var name: String
    @State private var projectID: UUID?
    @State private var sessionType: SessionType
    @State private var goal: String
    @State private var saveError: String?

    init(
        preset: SessionPreset?,
        projects: [ProjectRecord],
        save: @escaping (SessionPreset) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.preset = preset
        self.projects = projects
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: preset?.name ?? "Coding Session")
        _projectID = State(initialValue: preset?.projectID)
        _sessionType = State(initialValue: preset?.sessionType ?? .coding)
        _goal = State(initialValue: preset?.goal ?? "")
        _saveError = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(preset == nil ? "Add Session Preset" : "Edit Session Preset")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Preset name", text: $name)

                Picker("Project", selection: $projectID) {
                    Text("No Project").tag(UUID?.none)
                    ForEach(projects) { project in
                        Text(project.isArchived ? "\(project.name) (Archived)" : project.name)
                            .tag(Optional(project.id))
                    }
                }

                Picker("Session type", selection: $sessionType) {
                    ForEach(SessionType.allCases) { type in
                        Label(type.title, systemImage: type.systemImage).tag(type)
                    }
                }

                TextField("Optional reusable goal", text: $goal, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityLabel("Preset goal")
            }
            .formStyle(.grouped)

            Text("Presets with archived projects remain saved but are unavailable for Quick Start and automation until the project is restored. Automatic rules also require a configured project folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: savePreset)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func savePreset() {
        let value = SessionPreset(
            id: preset?.id ?? UUID(),
            name: name,
            projectID: projectID,
            sessionType: sessionType,
            goal: goal
        )
        if !save(value) {
            saveError = "Preset names must be unique, ignoring capitalization."
        }
    }
}
