import AppKit
import CodePulseIntegration
import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var ruleBeingEdited: SessionAutomationRule?
    @State private var isPresentingEditor = false
    @State private var newEditorIdentity = UUID()

    var body: some View {
        Section("Session Automation") {
            Toggle("Enable Session Automation", isOn: Binding(
                get: { store.state.settings.automationEnabled },
                set: { enabled in store.updateSettings { $0.automationEnabled = enabled } }
            ))
            .accessibilityHint("Allows enabled developer-tool and frontmost-application rules to control eligible sessions")

            if !store.state.settings.automationEnabled {
                Text("Session Automation is off. Enabled rules are saved but will not run until you turn it on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
            }

            Text("Optional and local. Developer-tool rules use lifecycle events and detect the active project from Codex or OpenCode working-directory activity. Frontmost-application rules remain tied to their project-backed session preset; an open developer tool never supplies project context.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let emptyState = EmptyStateCopy.automationEmptyState(
                ruleCount: store.automationRulesSorted.count
            ) {
                EmptyStateView(content: emptyState)
            } else {
                ForEach(store.automationRulesSorted) { rule in
                    let preset = store.sessionPreset(id: rule.presetID)
                    let projectName = preset?.projectID.flatMap { projectID in
                        store.state.projects.first(where: { $0.id == projectID })?.name
                    }
                    AutomationRuleRow(
                        rule: rule,
                        preset: preset,
                        projectName: projectName,
                        status: store.automationRuleStatus(for: rule),
                        edit: {
                            ruleBeingEdited = rule
                            isPresentingEditor = true
                        },
                        delete: { store.deleteAutomationRule(id: rule.id) }
                    )
                }
            }

            Button {
                ruleBeingEdited = nil
                newEditorIdentity = UUID()
                isPresentingEditor = true
            } label: {
                Label("Add Automation Rule…", systemImage: "plus")
            }
            .disabled(store.sessionPresetsAvailableForDeveloperAutomation.isEmpty && store.sessionPresetsAvailableForAutomation.isEmpty)
            .accessibilityHint(
                store.sessionPresetsAvailableForDeveloperAutomation.isEmpty && store.sessionPresetsAvailableForAutomation.isEmpty
                    ? "Create a reusable session preset before creating an automation rule"
                    : "Creates a local developer-tool or application session rule"
            )

            if store.sessionPresetsAvailableForDeveloperAutomation.isEmpty && store.sessionPresetsAvailableForAutomation.isEmpty {
                Text("Add a reusable session preset before creating an automation rule. Developer-tool rules can use a projectless session template; application rules require an active, relinked project preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $isPresentingEditor) {
            AutomationRuleEditorView(
                rule: ruleBeingEdited,
                developerToolPresets: store.developerToolPresetsForAutomationEditing(ruleBeingEdited),
                applicationPresets: store.applicationPresetsForAutomationEditing(ruleBeingEdited),
                projects: store.projectsSortedByRecentUse,
                save: { rule in
                    guard store.upsertAutomationRule(rule) else { return false }
                    isPresentingEditor = false
                    return true
                },
                cancel: { isPresentingEditor = false }
            )
            .id(ruleBeingEdited?.id ?? newEditorIdentity)
        }
    }
}

private struct AutomationRuleRow: View {
    let rule: SessionAutomationRule
    let preset: SessionPreset?
    let projectName: String?
    let status: SessionAutomationRuleStatus
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(status == .enabled ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(rule.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.name)
                    SettingsStatusBadge(
                        statusLabel,
                        style: statusStyle,
                        systemImage: statusSystemImage
                    )
                    .accessibilityHidden(true)
                }
                Text("\(triggerSummary) → \(preset?.name ?? "Missing preset") · \(ownershipSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let invalidDeveloperApplicationMessage {
                    Text(invalidDeveloperApplicationMessage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Pause \(Int(rule.pauseDelay))s · finish \(Int(rule.finishDelay))s · minimum \(Int(rule.minimumSavedDuration))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Edit", action: edit)
                .buttonStyle(.borderless)
                .accessibilityLabel("Edit \(rule.name)")
            Button {
                delete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .accessibilityLabel("Delete \(rule.name)")
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(rule.name), \(triggerSummary), \(preset?.name ?? "missing preset"), \(ownershipSummary)")
        .accessibilityValue(statusLabel)
    }

    private var iconName: String {
        switch rule.trigger {
        case .developerTool(let tool): return tool.systemImage
        case .applications: return "macwindow"
        }
    }

    private var triggerSummary: String {
        switch rule.trigger {
        case .developerTool(let tool):
            return tool.title
        case .applications(let trigger):
            return trigger.applications.map(\.displayName).joined(separator: " + ")
        }
    }

    private var statusLabel: String { status.label }

    private var statusStyle: SettingsStatusStyle {
        switch status {
        case .enabled:
            return .success
        case .projectArchived, .disabled:
            return .neutral
        case .automationOff, .invalidRule, .missingPreset, .missingProject, .needsRelink:
            return .warning
        }
    }

    private var statusSystemImage: String {
        switch status {
        case .enabled:
            return "checkmark.circle"
        case .projectArchived:
            return "archivebox"
        case .disabled:
            return "minus.circle"
        case .automationOff, .invalidRule, .missingPreset, .missingProject, .needsRelink:
            return "exclamationmark.triangle"
        }
    }

    private var ownershipSummary: String {
        switch rule.trigger {
        case .developerTool:
            if let projectName {
                return "Legacy project scope: \(projectName)"
            }
            return "Project detected from activity"
        case .applications:
            return projectName ?? "Missing project"
        }
    }

    private var invalidDeveloperApplicationMessage: String? {
        guard case .applications(let trigger) = rule.trigger,
              trigger.applications.contains(where: SessionAutomationCoordinator.isDeveloperToolApplication) else {
            return nil
        }
        return "Codex/OpenCode application rules are unavailable; use the Developer Tool trigger."
    }

}

private enum AutomationTriggerKind: String, CaseIterable, Identifiable {
    case developerTool
    case applications

    var id: String { rawValue }

    var title: String {
        switch self {
        case .developerTool: return "Developer Tool"
        case .applications: return "Frontmost Applications"
        }
    }
}

private struct AutomationRuleEditorView: View {
    let rule: SessionAutomationRule?
    let developerToolPresets: [SessionPreset]
    let applicationPresets: [SessionPreset]
    let projects: [ProjectRecord]
    let save: (SessionAutomationRule) -> Bool
    let cancel: () -> Void

    @State private var name: String
    @State private var isEnabled: Bool
    @State private var triggerKind: AutomationTriggerKind
    @State private var tool: DeveloperTool
    @State private var applications: [ApplicationIdentity]
    @State private var presetID: UUID?
    @State private var pauseDelay: String
    @State private var finishDelay: String
    @State private var minimumSavedDuration: String
    @State private var isPresentingRunningApplicationPicker = false
    @State private var saveError: String?

    init(
        rule: SessionAutomationRule?,
        developerToolPresets: [SessionPreset],
        applicationPresets: [SessionPreset],
        projects: [ProjectRecord],
        save: @escaping (SessionAutomationRule) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.rule = rule
        self.developerToolPresets = developerToolPresets
        self.applicationPresets = applicationPresets
        self.projects = projects
        self.save = save
        self.cancel = cancel
        let trigger = rule?.trigger
        _name = State(initialValue: rule?.name ?? "Development Automation")
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
        _triggerKind = State(initialValue: trigger?.applicationTrigger == nil ? .developerTool : .applications)
        _tool = State(initialValue: trigger?.developerTool ?? .codex)
        _applications = State(initialValue: trigger?.applicationTrigger?.applications ?? [])
        let initialPresets = trigger?.applicationTrigger == nil
            ? developerToolPresets
            : applicationPresets
        _presetID = State(initialValue: rule?.presetID ?? initialPresets.first?.id)
        _pauseDelay = State(initialValue: String(Int(rule?.pauseDelay ?? 60)))
        _finishDelay = State(initialValue: String(Int(rule?.finishDelay ?? 300)))
        _minimumSavedDuration = State(initialValue: String(Int(rule?.minimumSavedDuration ?? 60)))
        _saveError = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rule == nil ? "Add Automation Rule" : "Edit Automation Rule")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Rule name", text: $name)
                Toggle("Rule enabled", isOn: $isEnabled)

                Picker("Trigger", selection: $triggerKind) {
                    ForEach(AutomationTriggerKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                if triggerKind == .developerTool {
                    Picker("Developer tool", selection: $tool) {
                        ForEach(DeveloperTool.allCases) { tool in
                            Label(tool.title, systemImage: tool.systemImage).tag(tool)
                        }
                    }
                } else {
                    ApplicationSelectionEditor(applications: $applications) {
                        isPresentingRunningApplicationPicker = true
                    }
                }

                Picker(triggerKind == .developerTool ? "Session template" : "Session preset (project ownership)", selection: $presetID) {
                    Text("Choose a preset").tag(UUID?.none)
                    ForEach(availablePresets) { preset in
                        Text(presetDisplayName(preset)).tag(Optional(preset.id))
                    }
                    if let presetID, !availablePresets.contains(where: { $0.id == presetID }) {
                        Text("Missing preset").tag(Optional(presetID))
                    }
                }

                if let selectedPreset = presetID.flatMap({ id in availablePresets.first(where: { $0.id == id }) }) {
                    Text(developerToolContext(for: selectedPreset))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                TextField("Pause delay (seconds)", text: $pauseDelay)
                TextField("Finish delay (seconds)", text: $finishDelay)
                TextField("Minimum saved duration (seconds)", text: $minimumSavedDuration)
            }
            .formStyle(.grouped)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Finish delay is measured from the last matching active claim. Short automatic sessions below the minimum are discarded; manual sessions are never discarded automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveRule)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        .frame(width: 580)
        .sheet(isPresented: $isPresentingRunningApplicationPicker) {
            RunningApplicationPickerView { application in
                addApplication(application)
                isPresentingRunningApplicationPicker = false
            }
        }
    }

    private var parsedPause: Double? {
        finiteNonNegativeDouble(pauseDelay)
    }

    private var parsedFinish: Double? {
        finiteNonNegativeDouble(finishDelay)
    }

    private var parsedMinimum: Double? {
        finiteNonNegativeDouble(minimumSavedDuration)
    }

    private var validationMessage: String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Enter a rule name."
        }
        guard presetID != nil else { return "Choose a session preset." }
        guard let parsedPause else { return "Pause delay must be a non-negative number." }
        guard let parsedFinish else { return "Finish delay must be a non-negative number." }
        guard parsedFinish >= parsedPause else { return "Finish delay must be at least the pause delay." }
        guard parsedMinimum != nil else { return "Minimum saved duration must be a non-negative number." }
        if triggerKind == .applications && applications.contains(where: { !$0.isValid }) {
            return "Each application must have a valid bundle identifier."
        }
        if triggerKind == .applications && applications.contains(where: SessionAutomationCoordinator.isDeveloperToolApplication) {
            return "Use the Developer Tool trigger for Codex or OpenCode; an open tool cannot provide project context."
        }
        if triggerKind == .applications && ApplicationAutomationTrigger(applications: applications).applications.isEmpty {
            return "Choose at least one installed application."
        }
        guard let presetID, let preset = availablePresets.first(where: { $0.id == presetID }) else {
            return "The selected preset is no longer available."
        }
        if triggerKind == .applications, preset.projectID == nil {
            return "Application rules require a preset with a configured project."
        }
        return nil
    }

    private func saveRule() {
        guard let presetID,
              let pause = parsedPause,
              let finish = parsedFinish,
              let minimum = parsedMinimum else { return }

        let trigger: SessionAutomationTrigger
        switch triggerKind {
        case .developerTool:
            trigger = .developerTool(tool)
        case .applications:
            trigger = .applications(ApplicationAutomationTrigger(applications: applications))
        }

        let value = SessionAutomationRule(
            id: rule?.id ?? UUID(),
            name: name,
            isEnabled: isEnabled,
            trigger: trigger,
            presetID: presetID,
            pauseDelay: pause,
            finishDelay: finish,
            minimumSavedDuration: minimum
        )
        if !save(value) {
            saveError = "The rule could not be saved. Check its name, trigger, and session preset."
        }
    }

    private func presetDisplayName(_ preset: SessionPreset) -> String {
        if triggerKind == .developerTool {
            if preset.projectID != nil {
                return "\(preset.name) · Legacy project scope"
            }
            return preset.name
        }
        return "\(preset.name) · \(projectDisplayName(for: preset))"
    }

    private var availablePresets: [SessionPreset] {
        triggerKind == .developerTool ? developerToolPresets : applicationPresets
    }

    private func developerToolContext(for preset: SessionPreset) -> String {
        guard triggerKind == .developerTool else {
            return "Project ownership: \(projectDisplayName(for: preset))"
        }
        if preset.projectID != nil {
            return "Legacy project scope: \(projectDisplayName(for: preset)). Runtime project is still detected from developer-tool activity."
        }
        return "Project is detected automatically from developer-tool activity."
    }

    private func projectDisplayName(for preset: SessionPreset) -> String {
        guard let projectID = preset.projectID,
              let project = projects.first(where: { $0.id == projectID }) else {
            return "Missing Project"
        }
        return project.isArchived ? "\(project.name) (Archived)" : project.name
    }

    private func finiteNonNegativeDouble(_ value: String) -> Double? {
        guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    private func addApplication(_ application: ApplicationIdentity) {
        guard !applications.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) else { return }
        applications.append(application)
    }
}

private struct ApplicationSelectionEditor: View {
    @Binding var applications: [ApplicationIdentity]
    let addRunningApplication: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Applications")
                .font(.caption)
                .foregroundStyle(.secondary)

            if applications.isEmpty {
                Text("No applications selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(applications) { application in
                    HStack {
                        Image(systemName: "app")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(application.displayName)
                            Text(application.bundleIdentifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            applications.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(application.displayName)")
                    }
                }
            }

            HStack {
                Button("Choose Running App…", action: addRunningApplication)
                Button("Choose Application File…", action: chooseApplicationFile)
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application trigger choices")
    }

    private func chooseApplicationFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Application"
        guard panel.runModal() == .OK,
              let url = panel.url,
              let application = ApplicationIdentity(applicationBundleURL: url),
              !applications.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) else {
            return
        }
        applications.append(application)
    }
}

private struct RunningApplicationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let select: (ApplicationIdentity) -> Void

    private var applications: [ApplicationIdentity] {
        NSWorkspace.shared.runningApplications
            .compactMap { (application: NSRunningApplication) -> ApplicationIdentity? in
                guard let url = application.bundleURL,
                      let identity = ApplicationIdentity(applicationBundleURL: url) else { return nil }
                return identity
            }
            .reduce(into: [ApplicationIdentity]()) { result, application in
                guard !result.contains(where: { $0.bundleIdentifier == application.bundleIdentifier }) else { return }
                result.append(application)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose Running Application")
                .font(.title3.weight(.semibold))

            List(applications) { application in
                Button {
                    select(application)
                } label: {
                    HStack {
                        Image(systemName: "app")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(application.displayName)
                            Text(application.bundleIdentifier)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(application.displayName)
                .accessibilityHint("Adds this application's bundle identifier to the automation rule")
            }
            .frame(minHeight: 220)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 400)
    }
}
