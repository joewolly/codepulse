import AppKit
import CodePulseIntegration
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowCoordinator: AppWindowCoordinator
    @EnvironmentObject private var updateController: SparkleUpdateController
    @EnvironmentObject private var integrationManager: DeveloperToolIntegrationManager
    @EnvironmentObject private var digestCoordinator: DigestNotificationCoordinator
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
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            generalSettingsTab
                .tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.systemImage) }
                .tag(SettingsTab.general)

            projectsSettingsTab
                .tabItem { Label(SettingsTab.projects.title, systemImage: SettingsTab.projects.systemImage) }
                .tag(SettingsTab.projects)

            automationSettingsTab
                .tabItem { Label(SettingsTab.automation.title, systemImage: SettingsTab.automation.systemImage) }
                .tag(SettingsTab.automation)

            dataSettingsTab
                .tabItem { Label(SettingsTab.data.title, systemImage: SettingsTab.data.systemImage) }
                .tag(SettingsTab.data)
        }
        .navigationTitle("Settings")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                DispatchQueue.main.async {
                    do {
                        _ = try store.archiveProject(id: project.id)
                    } catch {
                        projectArchiveError = error.localizedDescription
                    }
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
                DispatchQueue.main.async {
                    do {
                        restoreResult = try store.restoreBackup(candidate)
                    } catch {
                        restoreError = error.localizedDescription
                    }
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

    private var generalSettingsTab: some View {
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

                Button {
                    windowCoordinator.showOnboarding()
                } label: {
                    Label("Show Introduction…", systemImage: "sparkles")
                }
                .accessibilityHint("Reopens the CodePulse introduction without resetting settings or session data")
            }

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
                    set: setDefaultProjectBehavior
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
        }
        .formStyle(.grouped)
    }

    private var projectsSettingsTab: some View {
        Form {
            Section("Projects") {
                if store.state.projects.isEmpty {
                    EmptyStateView(content: EmptyStateCopy.projects)
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

            SessionPresetSettingsView()
        }
        .formStyle(.grouped)
    }

    private var automationSettingsTab: some View {
        Form {
            Section("Developer Integrations") {
                Text("Optional local context enrichment for Codex and OpenCode. CodePulse records only lifecycle/context metadata, timestamps, project directory, and optional model/profile details. It does not collect prompts, messages, transcripts, command output, or source code.")
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

            AutomationSettingsView()
        }
        .formStyle(.grouped)
    }

    private var dataSettingsTab: some View {
        Form {
            Section("Backup & Restore") {
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

            Section("Actionable Insights") {
                DigestSettingsView()
                    .environmentObject(store)
                    .environmentObject(digestCoordinator)
            }
        }
        .formStyle(.grouped)
    }

    private func addProject() {
        _ = ProjectFolderSelection.chooseAndAddProject(to: store, prompt: "Add Project")
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

    private func setDefaultProjectBehavior(_ behavior: DefaultProjectBehavior) {
        let specificProjectID: UUID?
        if behavior == .specificProject {
            specificProjectID = store.state.settings.specificProjectID.flatMap { id in
                store.state.projects.contains(where: { $0.id == id && $0.isActive }) ? id : nil
            } ?? store.selectableProjectsSortedByRecentUse.first?.id
        } else {
            specificProjectID = nil
        }

        store.updateSettings {
            $0.defaultProjectBehavior = behavior
            $0.specificProjectID = specificProjectID
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
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: project.isArchived ? "archivebox" : "folder")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(project.name)
                    if project.isArchived {
                        SettingsStatusBadge("Archived", style: .neutral, systemImage: "archivebox")
                            .accessibilityLabel("\(project.name) is archived")
                    }
                    if project.requiresRelink {
                        SettingsStatusBadge("Needs Relink", style: .warning, systemImage: "exclamationmark.triangle")
                            .accessibilityLabel("\(project.name) needs relinking")
                    }
                }
                if let path = project.folderPath {
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if project.requiresRelink {
                    Button("Relink…", action: relink)
                        .buttonStyle(.bordered)
                        .fixedSize(horizontal: true, vertical: false)
                        .accessibilityLabel("Relink \(project.name) folder")
                } else if let path = project.folderPath {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityLabel("Reveal \(project.name) in Finder")
                }

                Menu {
                    if !project.requiresRelink {
                        Button("Relink…", action: relink)
                    }
                    Button("Rename…", action: rename)
                    if let archive {
                        Button("Archive", action: archive)
                    } else if let restore {
                        Button("Restore", action: restore)
                    }
                    Divider()
                    Button("Delete…", role: .destructive, action: delete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Actions for \(project.name)")
                .accessibilityLabel("Actions for \(project.name)")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(projectAccessibilityLabel)
    }

    private var projectAccessibilityLabel: String {
        var parts = [project.name]
        if project.isArchived { parts.append("Archived") }
        if project.requiresRelink { parts.append("Needs Relink") }
        return parts.joined(separator: ", ")
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
                SettingsStatusBadge(
                    statusLabel,
                    style: statusStyle,
                    systemImage: statusSystemImage
                )
            }

            Text(status.detail)
                .font(.caption)
                .foregroundStyle(status.errorMessage == nil ? Color.secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)

            Text("Managed at \(status.installationDescription)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(status.installationDescription)

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

    private var statusStyle: SettingsStatusStyle {
        if !status.isDetected { return .warning }
        return status.isEnabled ? .success : .neutral
    }

    private var statusSystemImage: String {
        if !status.isDetected { return "exclamationmark.triangle" }
        return status.isEnabled ? "checkmark.circle" : "minus.circle"
    }
}
