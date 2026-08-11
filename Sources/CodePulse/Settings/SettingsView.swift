import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var updateController: SparkleUpdateController
    @State private var projectToRename: ProjectRecord?
    @State private var renameText = ""
    @State private var projectToDelete: ProjectRecord?
    @State private var loginItemError: String?
    @State private var backupError: String?

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch CodePulse at login", isOn: Binding(
                    get: { store.state.settings.launchAtLogin },
                    set: setLaunchAtLogin
                ))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Updates") {
                Button {
                    updateController.checkForUpdates()
                } label: {
                    Label("Check for Updates…", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityHint("Checks GitHub Releases for a newer CodePulse version")

                Text("CodePulse checks for updates automatically and verifies downloaded updates with Sparkle before installation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Workflow") {
                Toggle("Open History with ⌥⌘T", isOn: Binding(
                    get: { store.state.settings.globalShortcutEnabled },
                    set: { value in store.updateSettings { $0.globalShortcutEnabled = value } }
                ))
                .accessibilityLabel("Global History shortcut")
                .accessibilityHint("Opens the CodePulse History window without starting or stopping a session")

                Button {
                    exportBackup()
                } label: {
                    Label("Export Backup…", systemImage: "arrow.down.doc")
                }
                .accessibilityLabel("Export CodePulse Backup")
                .accessibilityHint("Saves a portable JSON backup of local CodePulse data")

                Text("Backups include local projects, settings, saved sessions, and any active session. No secrets or external data are included.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Menu Bar") {
                Picker("Display", selection: Binding(
                    get: { store.state.settings.menuBarDisplay },
                    set: { value in store.updateSettings { $0.menuBarDisplay = value } }
                )) {
                    ForEach(MenuBarDisplay.allCases) { display in
                        Text(display.title).tag(display)
                    }
                }

                Picker("Idle appearance", selection: Binding(
                    get: { store.state.settings.idleAppearance },
                    set: { value in store.updateSettings { $0.idleAppearance = value } }
                )) {
                    Text("Code").tag(IdleAppearance.code)
                    Text("Icon Only").tag(IdleAppearance.iconOnly)
                }
            }

            Section("Sessions") {
                Picker("Default project", selection: Binding(
                    get: { store.state.settings.defaultProjectBehavior },
                    set: { value in store.updateSettings { $0.defaultProjectBehavior = value } }
                )) {
                    Text("Last used").tag(DefaultProjectBehavior.lastUsed)
                    Text("No project").tag(DefaultProjectBehavior.noProject)
                    Text("Specific project").tag(DefaultProjectBehavior.specificProject)
                }

                if store.state.settings.defaultProjectBehavior == .specificProject {
                    Picker("Project", selection: Binding(
                        get: { store.state.settings.specificProjectID },
                        set: { value in store.updateSettings { $0.specificProjectID = value } }
                    )) {
                        Text("No project").tag(UUID?.none)
                        ForEach(store.projectsSortedByRecentUse) { project in
                            Text(project.name).tag(Optional(project.id))
                        }
                    }
                }
            }

            Section("Projects") {
                if store.state.projects.isEmpty {
                    Text("Projects are optional. Add one when you want to associate a folder with a session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.projectsSortedByRecentUse) { project in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(project.name)
                                if let path = project.folderPath {
                                    Text(path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            Spacer()
                            if let path = project.folderPath {
                                Button {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                } label: {
                                    Image(systemName: "arrow.up.forward.app")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reveal \(project.name) in Finder")
                            }
                            Button("Relink") {
                                relinkProject(project)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Relink \(project.name) folder")
                            Button("Rename") {
                                projectToRename = project
                                renameText = project.name
                            }
                            .buttonStyle(.borderless)
                            Button {
                                projectToDelete = project
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Delete \(project.name)")
                        }
                    }
                }

                Button {
                    addProject()
                } label: {
                    Label("Add Project…", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(20)
        .navigationTitle("Settings")
        .alert("Rename Project", isPresented: Binding(
            get: { projectToRename != nil },
            set: { if !$0 { projectToRename = nil } }
        )) {
            TextField("Project name", text: $renameText)
            Button("Save") {
                if let id = projectToRename?.id {
                    store.renameProject(id: id, name: renameText)
                }
                projectToRename = nil
            }
            Button("Cancel", role: .cancel) {
                projectToRename = nil
            }
        } message: {
            Text("Choose the name shown in CodePulse sessions.")
        }
        .alert("Delete Project?", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = projectToDelete?.id {
                    store.deleteProject(id: id)
                }
                projectToDelete = nil
            }
            Button("Cancel", role: .cancel) {
                projectToDelete = nil
            }
        } message: {
            Text("Saved sessions keep their project name, but this project will no longer be available for new sessions.")
        }
        .alert("Backup Export Failed", isPresented: Binding(
            get: { backupError != nil },
            set: { if !$0 { backupError = nil } }
        )) {
            Button("OK", role: .cancel) { backupError = nil }
        } message: {
            Text(backupError ?? "CodePulse could not create the backup.")
        }
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = store.addProject(name: url.lastPathComponent, folderURL: url)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
            store.updateSettings { $0.launchAtLogin = enabled }
        } catch {
            loginItemError = error.localizedDescription
        }
    }

    private func relinkProject(_ project: ProjectRecord) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Relink Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = store.updateProjectFolder(id: project.id, folderURL: url)
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "CodePulse Backup \(CodePulseFormatting.exportDate(store.now)).json"
        panel.prompt = "Export Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.exportBackup(to: url)
        } catch {
            backupError = error.localizedDescription
        }
    }
}
