import AppKit
import CodePulseIntegration
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var updateController: SparkleUpdateController
    @EnvironmentObject private var integrationManager: DeveloperToolIntegrationManager
    @State private var projectToRename: ProjectRecord?
    @State private var renameText = ""
    @State private var projectToDelete: ProjectRecord?
    @State private var loginItemError: String?
    @State private var backupError: String?
    @State private var recoveryExportError: String?

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

            Section("Integrations") {
                Text("Optional local lifecycle tracking for Codex, Claude Code, and OpenCode. CodePulse records only timing metadata, project directory, and optional model/effort details.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Codex lifecycle tracking is timing-only: it uses local Codex hooks to record active, permission-waiting, review-grace, and ended intervals. It never reads prompts, responses, transcripts, commands, tool input/output, or permission decisions. A cloud-only Codex session with no local hook/process is not tracked.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Claude Code tracking uses local hooks configured in your user-level Claude settings. Local sessions, including Remote Control sessions running on this Mac, may be tracked; cloud-only work with no local Claude process or hook is not. CodePulse stores neither transcripts nor prompt, tool, or permission content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("OpenCode tracking uses a CodePulse-owned global plugin in its documented plugin directory. It reads local plugin session events only; no OpenCode database, project configuration, prompts, messages, tool data, or transcripts are read. Restart OpenCode after changing this integration.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(DeveloperTool.allCases) { tool in
                    DeveloperToolIntegrationRow(
                        tool: tool,
                        status: integrationManager.status(for: tool),
                        enable: { _ = integrationManager.enable(tool) },
                        disable: { _ = integrationManager.disable(tool) }
                    )
                }

                Stepper(
                    "Agent review grace: \(store.state.settings.agentReviewGraceSeconds / 60) minutes",
                    value: Binding(
                        get: { store.state.settings.agentReviewGraceSeconds / 60 },
                        set: { minutes in store.updateSettings { $0.agentReviewGraceSeconds = minutes * 60 } }
                    ),
                    in: 0...15
                )
                Text("After an agent stop, CodePulse counts this limited review period before marking the run waiting. A new activity, permission request, or session end cancels it.")
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

            if let recoveryIssue = store.persistenceRecoveryIssue {
                Section("Data Recovery") {
                    Text(recoveryIssue.userMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        exportRecoveryCopy()
                    } label: {
                        Label("Export Recovery Copy…", systemImage: "cross.case")
                    }
                    .accessibilityHint("Saves the unreadable or last known-good CodePulse state without changing it")
                }
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
        .onAppear {
            integrationManager.refresh()
        }
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
        .alert("Recovery Export Failed", isPresented: Binding(
            get: { recoveryExportError != nil },
            set: { if !$0 { recoveryExportError = nil } }
        )) {
            Button("OK", role: .cancel) { recoveryExportError = nil }
        } message: {
            Text(recoveryExportError ?? "CodePulse could not export the recovery copy.")
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

    private func exportRecoveryCopy() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "CodePulse Recovery \(CodePulseFormatting.exportDate(store.now)).json"
        panel.prompt = "Export Recovery Copy"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.exportPersistenceRecoveryCopy(to: url)
        } catch {
            recoveryExportError = error.localizedDescription
        }
    }
}

private struct DeveloperToolIntegrationRow: View {
    let tool: DeveloperTool
    let status: DeveloperToolIntegrationStatus
    let enable: () -> Void
    let disable: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Label(tool.title, systemImage: tool.systemImage)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(status.isEnabled ? .green : .secondary)
            }

            Text(status.detail)
                .font(.caption)
                .foregroundStyle(status.errorMessage == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            Text("Managed at \(status.installationDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Button(status.isEnabled ? "Disable integration" : "Enable integration") {
                if status.isEnabled {
                    disable()
                } else {
                    enable()
                }
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("\(status.isEnabled ? "Disable" : "Enable") \(tool.title) integration")
            .disabled(!status.isDetected && !status.isEnabled)
        }
        .padding(.vertical, 3)
    }

    private var statusLabel: String {
        if !status.isDetected { return "Not detected" }
        return status.isEnabled ? "Enabled" : "Disabled"
    }
}
