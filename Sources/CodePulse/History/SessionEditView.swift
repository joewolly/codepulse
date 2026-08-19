import AppKit
import SwiftUI

private enum CompletedSessionProjectChoice: Hashable {
    case keepSnapshot
    case noProject
    case project(UUID)

    var assignment: CompletedSessionProjectAssignment {
        switch self {
        case .keepSnapshot: return .keepSnapshot
        case .noProject: return .noProject
        case .project(let id): return .project(id)
        }
    }
}

struct SessionEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore
    let session: CompletedSession

    @State private var type: SessionType
    @State private var goal: String
    @State private var outcome: String
    @State private var startedAt: Date
    @State private var projectChoice: CompletedSessionProjectChoice
    @State private var errorMessage: String?

    init(session: CompletedSession) {
        self.session = session
        _type = State(initialValue: session.type)
        _goal = State(initialValue: session.goal ?? "")
        _outcome = State(initialValue: session.outcome ?? "")
        _startedAt = State(initialValue: session.startedAt)
        if session.projectName != nil {
            _projectChoice = State(initialValue: .keepSnapshot)
        } else {
            _projectChoice = State(initialValue: .noProject)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Session") {
                    Picker("Type", selection: $type) {
                        ForEach(SessionType.allCases) { sessionType in
                            Label(sessionType.title, systemImage: sessionType.systemImage)
                                .tag(sessionType)
                        }
                    }

                    Picker("Project", selection: $projectChoice) {
                        if let projectName = session.projectName {
                            Text("Keep “\(projectName)”")
                                .tag(CompletedSessionProjectChoice.keepSnapshot)
                        }
                        Text("No Project").tag(CompletedSessionProjectChoice.noProject)
                        ForEach(store.projectsSortedByRecentUse) { project in
                            Text(project.name).tag(CompletedSessionProjectChoice.project(project.id))
                        }
                    }

                    DatePicker("Started", selection: $startedAt)
                    Text("Changing the start shifts the end and pause intervals by the same amount, preserving active duration.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Section("Journal") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Goal")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $goal)
                            .frame(minHeight: 60, idealHeight: 80)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                            .accessibilityLabel("Goal")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Outcome")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $outcome)
                            .frame(minHeight: 80, idealHeight: 110)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                            }
                            .accessibilityLabel("Outcome")
                    }
                }

                if session.gitContext != nil {
                    Section("Git Snapshot") {
                        Text("Git metadata is historical and cannot be changed from an edited session.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Save Session Changes")
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
    }

    private func save() {
        let saved = store.updateCompletedSession(
            id: session.id,
            type: type,
            goal: goal,
            outcome: outcome,
            project: projectChoice.assignment,
            startedAt: startedAt
        )
        if saved {
            dismiss()
        } else {
            errorMessage = "The session could not be updated. Check the date and project selection."
        }
    }
}
