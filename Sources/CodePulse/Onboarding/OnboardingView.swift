import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case localByDefault
    case optionalProjects
    case firstSession

    var id: Self { self }

    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .localByDefault: return "Local by Default"
        case .optionalProjects: return "Projects Are Optional"
        case .firstSession: return "Start Your First Session"
        }
    }

    var systemImage: String {
        switch self {
        case .welcome: return "timer"
        case .localByDefault: return "lock.shield"
        case .optionalProjects: return "folder"
        case .firstSession: return "play.circle"
        }
    }
}

struct OnboardingView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var step: OnboardingStep = .welcome
    @State private var addedProjectID: UUID?

    private let onDismiss: () -> Void

    init(onDismiss: @escaping () -> Void) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label("Getting Started", systemImage: "sparkles")
                    .font(.headline)
                Spacer()
                Text("Step \(step.number) of \(OnboardingStep.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            ProgressView(
                value: Double(step.number),
                total: Double(OnboardingStep.allCases.count)
            )
            .padding(.top, 10)
            .accessibilityLabel("Introduction progress")
            .accessibilityValue("Step \(step.number) of \(OnboardingStep.allCases.count)")

            Divider()
                .padding(.vertical, 20)

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
                .padding(.top, 18)

            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") {
                        moveBack()
                    }
                    .accessibilityHint("Returns to the previous introduction step")
                }

                Spacer()

                Button("Skip Introduction") {
                    completeAndDismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityHint("Marks the introduction as complete without changing session or feature settings")

                Button(primaryActionTitle) {
                    advanceOrFinish()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityHint(primaryActionHint)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 540, height: 490)
        .onExitCommand {
            completeAndDismiss()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: step.systemImage)
                .font(.system(size: 30))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            Text(step.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            switch step {
            case .welcome:
                Text("A local coding session timer and work journal for macOS.")
                    .font(.body)
                Text("Track focused coding sessions, save goals and outcomes, and review History and Insights. Everything stays on this Mac unless you explicitly export something.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .localByDefault:
                Text("No account, cloud sync, or telemetry is required.")
                    .font(.body)
                Text("Session notes, project information, Git and GitHub snapshots, and developer-tool metadata stay local. Codex, OpenCode, GitHub context, and Session Automation are optional.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

            case .optionalProjects:
                Text("A project is an optional folder connection chosen by you. It makes Git context, developer-tool matching, automation, and project filters more useful. You can always work with No Project.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    addProject()
                } label: {
                    Label("Add Project…", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Choose a folder to reuse as a CodePulse project")

                if let addedProjectID,
                   let project = store.state.projects.first(where: { $0.id == addedProjectID }) {
                    Label("Added \(project.name)", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .help(project.name)
                        .accessibilityLabel("Added project \(project.name)")
                }

            case .firstSession:
                Text("The basic workflow is simple:")
                    .font(.body)
                VStack(alignment: .leading, spacing: 7) {
                    workflowStep("Choose a project or No Project.")
                    workflowStep("Choose a work type and optionally enter a goal.")
                    workflowStep("Press Start.")
                    workflowStep("Finish and save an outcome when you are done.")
                }
                Text("Quick Start presets, developer integrations, and Session Automation are optional. Nothing is enabled or started automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var primaryActionTitle: String {
        switch step {
        case .welcome, .localByDefault:
            return "Continue"
        case .optionalProjects:
            return addedProjectID == nil ? "Continue Without a Project" : "Continue"
        case .firstSession:
            return "Start Using CodePulse"
        }
    }

    private var primaryActionHint: String {
        switch step {
        case .welcome, .localByDefault, .optionalProjects:
            return "Moves to the next introduction step"
        case .firstSession:
            return "Closes the introduction without starting a session or enabling features"
        }
    }

    private func workflowStep(_ text: String) -> some View {
        Label(text, systemImage: "checkmark")
            .foregroundStyle(.primary)
            .accessibilityElement(children: .combine)
    }

    private func addProject() {
        if let projectID = ProjectFolderSelection.chooseAndAddProject(
            to: store,
            prompt: "Add Project"
        ) {
            addedProjectID = projectID
        }
    }

    private func moveBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func advanceOrFinish() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            completeAndDismiss()
            return
        }
        step = next
    }

    private func completeAndDismiss() {
        store.markOnboardingCompleted()
        onDismiss()
    }
}
