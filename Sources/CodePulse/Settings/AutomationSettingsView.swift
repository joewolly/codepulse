import CodePulseIntegration
import SwiftUI

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
            .accessibilityHint("Allows enabled Codex and OpenCode rules to control sessions started by automation")

            Text("Optional and local. CodePulse uses only enabled Codex/OpenCode lifecycle metadata and the working directory to match a configured project. Manual sessions always remain under your control.")
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
                        projectName: store.state.projects.first(where: { $0.id == rule.projectID })?.name,
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
            .disabled(store.state.projects.isEmpty)
            .accessibilityHint(store.state.projects.isEmpty ? "Add a project before creating an automation rule" : "Creates a local Codex or OpenCode session rule")
        }
        .sheet(isPresented: $isPresentingEditor) {
            AutomationRuleEditorView(
                rule: ruleBeingEdited,
                projects: store.projectsSortedByRecentUse,
                save: { rule in
                    _ = store.upsertAutomationRule(rule)
                    isPresentingEditor = false
                },
                cancel: { isPresentingEditor = false }
            )
        }
    }
}

private struct AutomationRuleRow: View {
    let rule: SessionAutomationRule
    let projectName: String?
    let isUsable: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: rule.developerTool?.systemImage ?? "bolt")
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
                        Text("Project unavailable")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                Text([rule.developerTool?.title, projectName].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Pause (Int(rule.pauseDelay))s · finish (Int(rule.finishDelay))s · minimum (Int(rule.minimumSavedDuration))s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
            .accessibilityLabel("Delete (rule.name)")
        }
        .padding(.vertical, 3)
    }
}

private struct AutomationRuleEditorView: View {
    let rule: SessionAutomationRule?
    let projects: [ProjectRecord]
    let save: (SessionAutomationRule) -> Void
    let cancel: () -> Void

    @State private var name: String
    @State private var isEnabled: Bool
    @State private var tool: DeveloperTool
    @State private var projectID: UUID?
    @State private var sessionType: SessionType
    @State private var goal: String
    @State private var pauseDelay: String
    @State private var finishDelay: String
    @State private var minimumSavedDuration: String

    init(
        rule: SessionAutomationRule?,
        projects: [ProjectRecord],
        save: @escaping (SessionAutomationRule) -> Void,
        cancel: @escaping () -> Void
    ) {
        self.rule = rule
        self.projects = projects
        self.save = save
        self.cancel = cancel
        _name = State(initialValue: rule?.name ?? "Developer Tool Session")
        _isEnabled = State(initialValue: rule?.isEnabled ?? true)
        _tool = State(initialValue: rule?.developerTool ?? .codex)
        _projectID = State(initialValue: rule?.projectID ?? projects.first?.id)
        _sessionType = State(initialValue: rule?.sessionType ?? .coding)
        _goal = State(initialValue: rule?.goal ?? "")
        _pauseDelay = State(initialValue: String(Int(rule?.pauseDelay ?? 60)))
        _finishDelay = State(initialValue: String(Int(rule?.finishDelay ?? 300)))
        _minimumSavedDuration = State(initialValue: String(Int(rule?.minimumSavedDuration ?? 60)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(rule == nil ? "Add Automation Rule" : "Edit Automation Rule")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Rule name", text: $name)
                Toggle("Rule enabled", isOn: $isEnabled)

                Picker("Developer tool", selection: $tool) {
                    ForEach(DeveloperTool.allCases) { tool in
                        Label(tool.title, systemImage: tool.systemImage).tag(tool)
                    }
                }

                Picker("Project", selection: $projectID) {
                    Text("Choose a project").tag(UUID?.none)
                    ForEach(projects) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }

                Picker("Session type", selection: $sessionType) {
                    ForEach(SessionType.allCases) { type in
                        Text(type.title).tag(type)
                    }
                }

                TextField("Optional reusable goal", text: $goal, axis: .vertical)
                    .lineLimit(1...3)

                TextField("Pause delay (seconds)", text: $pauseDelay)
                TextField("Finish delay (seconds)", text: $finishDelay)
                TextField("Minimum saved duration (seconds)", text: $minimumSavedDuration)
            }
            .formStyle(.grouped)

            Text("Finish delay is measured from the last matching active signal. Short automatic sessions below the minimum are discarded; manual sessions are never discarded automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: saveRule)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(projectID == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func saveRule() {
        guard let projectID else { return }
        let pause = max(0, Double(pauseDelay) ?? 60)
        let finish = max(pause, Double(finishDelay) ?? 300)
        let minimum = max(0, Double(minimumSavedDuration) ?? 60)
        let newRule = SessionAutomationRule(
            id: rule?.id ?? UUID(),
            name: name,
            isEnabled: isEnabled,
            trigger: .developerTool(tool),
            projectID: projectID,
            sessionType: sessionType,
            goal: goal,
            pauseDelay: pause,
            finishDelay: finish,
            minimumSavedDuration: minimum
        )
        save(newRule)
    }
}
