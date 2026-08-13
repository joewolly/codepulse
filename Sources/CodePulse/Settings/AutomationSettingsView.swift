import AppKit
import CodePulseIntegration
import SwiftUI
import UniformTypeIdentifiers

struct AutomationSettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var ruleBeingEdited: SessionAutomationRule?
    @State private var isPresentingEditor = false

    var body: some View {
        Section("Session Automation") {
            Toggle("Enable Session Automation", isOn: Binding(
                get: { store.state.settings.automationEnabled },
                set: { enabled in store.updateSettings { $0.automationEnabled = enabled } }
            ))
            .accessibilityHint("Allows enabled developer-tool and frontmost-application rules to control eligible sessions")

            Text("Optional and local. Developer-tool rules use lifecycle metadata and project paths. Application rules observe only the current frontmost application's bundle identifier while enabled; they do not inspect windows or collect usage history.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if store.automationRulesSorted.isEmpty {
                Text("No automation rules yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.automationRulesSorted) { rule in
                    AutomationRuleRow(
                        rule: rule,
                        preset: store.sessionPreset(id: rule.presetID),
                        isUsable: store.isAutomationRuleUsable(rule),
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
                isPresentingEditor = true
            } label: {
                Label("Add Automation Rule…", systemImage: "plus")
            }
            .disabled(store.sessionPresetsSorted.isEmpty)
            .accessibilityHint(store.sessionPresetsSorted.isEmpty ? "Create a session preset before creating an automation rule" : "Creates a local developer-tool or application session rule")
        }
        .sheet(isPresented: $isPresentingEditor) {
            AutomationRuleEditorView(
                rule: ruleBeingEdited,
                presets: store.sessionPresetsSorted,
                projects: store.projectsSortedByRecentUse,
                save: { rule in
                    guard store.upsertAutomationRule(rule) else { return false }
                    isPresentingEditor = false
                    return true
                },
                cancel: { isPresentingEditor = false }
            )
        }
    }
}

private struct AutomationRuleRow: View {
    let rule: SessionAutomationRule
    let preset: SessionPreset?
    let isUsable: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(rule.isEnabled && isUsable ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(rule.name)
                        .font(.subheadline.weight(.medium))
                    if !rule.isEnabled {
                        Text("Disabled")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if !isUsable {
                        Text("Needs attention")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text("\(triggerSummary) → \(preset?.name ?? "Missing preset")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .accessibilityLabel("\(rule.name), \(triggerSummary), \(preset?.name ?? "missing preset")")
        .accessibilityValue(rule.isEnabled ? (isUsable ? "Enabled" : "Needs attention") : "Disabled")
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
    let presets: [SessionPreset]
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
        presets: [SessionPreset],
        projects: [ProjectRecord],
        save: @escaping (SessionAutomationRule) -> Bool,
        cancel: @escaping () -> Void
    ) {
        self.rule = rule
        self.presets = presets
        self.projects = projects
        self.save = save
        self.cancel = cancel
        let trigger = rule?.trigger
        _name = State(initialValue: rule?.name ?? "Development Automation")
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
        _triggerKind = State(initialValue: trigger?.applicationTrigger == nil ? .developerTool : .applications)
        _tool = State(initialValue: trigger?.developerTool ?? .codex)
        _applications = State(initialValue: trigger?.applicationTrigger?.applications ?? [])
        _presetID = State(initialValue: rule?.presetID ?? presets.first?.id)
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

                Picker("Session preset", selection: $presetID) {
                    Text("Choose a preset").tag(UUID?.none)
                    ForEach(presets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                    if let presetID, !presets.contains(where: { $0.id == presetID }) {
                        Text("Missing preset").tag(Optional(presetID))
                    }
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
        if triggerKind == .applications && ApplicationAutomationTrigger(applications: applications).applications.isEmpty {
            return "Choose at least one installed application."
        }
        guard let presetID, let preset = presets.first(where: { $0.id == presetID }) else {
            return "The selected preset is no longer available."
        }
        guard preset.projectID != nil else {
            return "Automatic rules require a preset with a configured project."
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
