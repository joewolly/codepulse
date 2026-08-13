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
    @State private var projectToArchive: ProjectRecord?
    @State private var projectToDelete: ProjectRecord?
    @State private var projectArchiveError: String?
    @State private var loginItemError: String?
    @State private var backupError: String?
    @State private var restoreCandidate: BackupRestoreCandidate?
    @State private var restoreResult: BackupRestoreResult?
    @State private var restoreError: String?

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

            Section("Data") {
                Button {
                    exportBackup()
                } label: {
                    Label("Export Backup…", systemImage: "arrow.down.doc")
                }
                .accessibilityLabel("Export CodePulse Backup")
                .accessibilityHint("Saves a portable JSON backup of local CodePulse data")

                Button {
                    chooseBackupForRestore()
                } label: {
                    Label("Restore Backup…", systemImage: "arrow.up.doc")
                }
                .accessibilityLabel("Restore CodePulse Backup")
                .accessibilityHint("Reviews and replaces local CodePulse data with a selected JSON backup")

                Text("Backups contain your local CodePulse projects, sessions, settings, presets, and automation configuration. Restore replaces current local data after creating a recovery backup. Automation stays disabled after restore, and moved project folders may need relinking. No cloud service is involved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Integrations") {
                Text("Optional local context enrichment for Codex and OpenCode. CodePulse records only tool/session metadata, timestamps, project directory, and optional model/profile details.")
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
            }

            SessionPresetSettingsView()
            AutomationSettingsView()

            Section("Workflow") {
                Toggle("Open History with ⌥⌘T", isOn: Binding(
                    get: { store.state.settings.globalShortcutEnabled },
                    set: { value in store.updateSettings { $0.globalShortcutEnabled = value } }
                ))
                .accessibilityLabel("Global History shortcut")
                .accessibilityHint("Opens the CodePulse History window without starting or stopping a session")
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
                        ForEach(store.selectableProjectsSortedByRecentUse) { project in
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
                    if !store.activeProjectsSortedByRecentUse.isEmpty {
                        Text("Active")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(store.activeProjectsSortedByRecentUse) { project in
                            ProjectSettingsRow(
                                project: project,
                                archive: { projectToArchive = project },
                                restore: nil,
                                relink: { relinkProject(project) },
                                rename: {
                                    projectToRename = project
                                    renameText = project.name
                                },
                                delete: { projectToDelete = project }
                            )
                        }
                    }

                    if !store.archivedProjectsSortedByRecentUse.isEmpty {
                        Text("Archived")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.top, 6)
                        ForEach(store.archivedProjectsSortedByRecentUse) { project in
                            ProjectSettingsRow(
                                project: project,
                                archive: nil,
                                restore: { restoreProject(project) },
                                relink: { relinkProject(project) },
                                rename: {
                                    projectToRename = project
                                    renameText = project.name
                                },
                                delete: { projectToDelete = project }
                            )
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
        .alert("Archive \(projectToArchive?.name ?? "Project")?", isPresented: Binding(
            get: { projectToArchive != nil },
            set: { if !$0 { projectToArchive = nil } }
        )) {
            Button("Archive", role: .destructive) {
                guard let project = projectToArchive else { return }
                projectToArchive = nil
                do {
                    _ = try store.archiveProject(id: project.id)
                } catch {
                    projectArchiveError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {
                projectToArchive = nil
            }
        } message: {
            Text("This project will no longer appear when starting sessions or running automation. Its saved sessions and Insights will remain available.")
        }
        .alert("Project Archive Failed", isPresented: Binding(
            get: { projectArchiveError != nil },
            set: { if !$0 { projectArchiveError = nil } }
        )) {
            Button("OK", role: .cancel) {
                projectArchiveError = nil
            }
        } message: {
            Text(projectArchiveError ?? "CodePulse could not change this project's archive state.")
        }
        .alert("Backup Export Failed", isPresented: Binding(
            get: { backupError != nil },
            set: { if !$0 { backupError = nil } }
        )) {
            Button("OK", role: .cancel) { backupError = nil }
        } message: {
            Text(backupError ?? "CodePulse could not create the backup.")
        }
        .alert("Restore CodePulse Backup?", isPresented: Binding(
            get: { restoreCandidate != nil },
            set: { if !$0 { restoreCandidate = nil } }
        )) {
            Button("Restore Backup", role: .destructive) {
                guard let candidate = restoreCandidate else { return }
                restoreCandidate = nil
                do {
                    restoreResult = try store.restoreBackup(candidate)
                } catch {
                    restoreError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {
                restoreCandidate = nil
            }
        } message: {
            Text(restoreConfirmationMessage)
        }
        .alert("Backup Restored", isPresented: Binding(
            get: { restoreResult != nil },
            set: { if !$0 { restoreResult = nil } }
        )) {
            Button("Done", role: .cancel) {
                restoreResult = nil
            }
        } message: {
            Text(restoreCompletionMessage)
        }
        .alert("Backup Restore Failed", isPresented: Binding(
            get: { restoreError != nil },
            set: { if !$0 { restoreError = nil } }
        )) {
            Button("OK", role: .cancel) {
                restoreError = nil
            }
        } message: {
            Text(restoreError ?? "CodePulse could not restore the selected backup.")
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

    private func restoreProject(_ project: ProjectRecord) {
        do {
            _ = try store.restoreProject(id: project.id)
        } catch {
            projectArchiveError = error.localizedDescription
        }
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

    private func chooseBackupForRestore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Review Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            restoreCandidate = try store.inspectBackup(at: url)
        } catch {
            restoreError = error.localizedDescription
        }
    }

    private var restoreConfirmationMessage: String {
        guard let candidate = restoreCandidate else {
            return "Select a CodePulse backup to review."
        }

        let preview = candidate.preview
        var lines = [
            "Format: \(preview.format) v\(preview.version)",
            "Exported: \(preview.exportedAt.formatted(date: .abbreviated, time: .shortened))",
            "\(preview.projectCount) \(preview.projectCount == 1 ? "project" : "projects")",
            "\(preview.completedSessionCount) \(preview.completedSessionCount == 1 ? "saved session" : "saved sessions")",
            "\(preview.presetCount) \(preview.presetCount == 1 ? "preset" : "presets")",
            "\(preview.automationRuleCount) \(preview.automationRuleCount == 1 ? "automation rule" : "automation rules")"
        ]
        if preview.includesActiveSession {
            lines.append("1 active session")
        }
        if let earliest = preview.earliestSavedSessionAt,
           let latest = preview.latestSavedSessionAt {
            lines.append("History: \(earliest.formatted(date: .abbreviated, time: .omitted)) – \(latest.formatted(date: .abbreviated, time: .omitted))")
        }
        if preview.projectsNeedingRelinkCount > 0 {
            lines.append("\(preview.projectsNeedingRelinkCount) project folder\(preview.projectsNeedingRelinkCount == 1 ? "" : "s") may need relinking")
        }
        lines.append("This will replace your current CodePulse data.")
        lines.append("A recovery backup of your current data will be created first.")
        lines.append("Session Automation will be restored but left disabled.")
        return lines.joined(separator: "\n")
    }

    private var restoreCompletionMessage: String {
        guard let result = restoreResult else { return "Backup restored." }
        let preview = result.preview
        var lines = [
            "\(preview.completedSessionCount) \(preview.completedSessionCount == 1 ? "session" : "sessions") and \(preview.projectCount) \(preview.projectCount == 1 ? "project" : "projects") were restored.",
            "Session Automation was restored but left disabled."
        ]
        if preview.projectsNeedingRelinkCount > 0 {
            lines.append("Some project folders may need to be relinked.")
        }
        lines.append("Recovery backup:")
        lines.append(result.recoveryBackupURL.path)
        return lines.joined(separator: "\n")
    }
}

private struct ProjectSettingsRow: View {
    let project: ProjectRecord
    let archive: (() -> Void)?
    let restore: (() -> Void)?
    let relink: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack {
            Image(systemName: project.isArchived ? "archivebox" : "folder")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(project.name)
                    if project.isArchived {
                        Label("Archived", systemImage: "archivebox")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("\(project.name) is archived")
                    }
                }
                if let path = project.folderPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let path = project.folderPath, !project.requiresRelink {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reveal \(project.name) in Finder")
            }
            if project.requiresRelink {
                Label("Needs Relink", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(project.name) needs relinking")
            }
            Button("Relink", action: relink)
                .buttonStyle(.borderless)
                .accessibilityLabel("Relink \(project.name) folder")
            Button("Rename", action: rename)
                .buttonStyle(.borderless)
                .accessibilityLabel("Rename \(project.name)")
            if let archive {
                Button("Archive", action: archive)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Archive \(project.name)")
                    .accessibilityHint("Removes this project from future session and automation workflows while keeping its history")
            } else if let restore {
                Button("Restore", action: restore)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Restore \(project.name)")
                    .accessibilityHint("Makes this project available for future sessions and automation again")
            }
            Button {
                delete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Delete \(project.name)")
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
