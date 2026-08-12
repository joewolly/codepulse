import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var selectedSessionID: UUID?
    @State private var sessionPendingDeletion: CompletedSession?
    @State private var sessionPendingEdit: CompletedSession?
    @State private var query = HistoryQuery()

    private var filteredGroups: [DaySessionGroup] {
        store.historyGroups(for: query)
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryFilterBar(query: $query, projectOptions: store.historyProjectOptions)

            Divider()

            if filteredGroups.isEmpty {
                HistoryEmptyState(
                    hasAnySessions: !store.state.completedSessions.isEmpty,
                    canClearFilters: query.hasRestrictions,
                    clearFilters: { query = HistoryQuery() }
                )
            } else {
                List {
                    ForEach(filteredGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                Button {
                                    selectedSessionID = session.id
                                } label: {
                                    HistoryRow(session: session)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button("View Details") {
                                        selectedSessionID = session.id
                                    }
                                    Button("Edit Session") {
                                        sessionPendingEdit = session
                                    }
                                    Divider()
                                    Button("Delete Session", role: .destructive) {
                                        sessionPendingDeletion = session
                                    }
                                }
                            }
                        } header: {
                            HistoryDayHeader(group: group, calendar: store.calendar)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("History")
        .searchable(text: $query.searchText, prompt: "Search sessions")
        .sheet(isPresented: Binding(
            get: { selectedSessionID != nil },
            set: { if !$0 { selectedSessionID = nil } }
        )) {
            if let sessionID = selectedSessionID {
                SessionDetailView(sessionID: sessionID)
                    .environmentObject(store)
            }
        }
        .alert("Delete Session?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = sessionPendingDeletion?.id {
                    store.deleteCompletedSession(id: id)
                }
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            Text("This saved session will be removed from CodePulse.")
        }
        .sheet(item: $sessionPendingEdit) { session in
            SessionEditView(session: session)
                .environmentObject(store)
        }
        .frame(minWidth: 680, minHeight: 500)
    }
}

private struct HistoryFilterBar: View {
    @Binding var query: HistoryQuery
    let projectOptions: [HistoryProjectOption]

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Button {
                    query.project = .allProjects
                } label: {
                    filterLabel("All Projects", selected: query.project == .allProjects)
                }
                Button {
                    query.project = .noProject
                } label: {
                    filterLabel("No Project", selected: query.project == .noProject)
                }
                if !projectOptions.isEmpty {
                    Divider()
                    ForEach(projectOptions) { option in
                        Button {
                            query.project = option.filter
                        } label: {
                            filterLabel(option.title, selected: query.project == option.filter)
                        }
                    }
                }
            } label: {
                Label(projectTitle, systemImage: "folder")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Project filter")
            .accessibilityValue(projectTitle)

            Menu {
                Picker("Date", selection: $query.date) {
                    ForEach(HistoryDateFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } label: {
                Label(query.date.title, systemImage: "calendar")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Date filter")
            .accessibilityValue(query.date.title)

            Menu {
                Picker("Type", selection: $query.type) {
                    ForEach(HistoryTypeFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } label: {
                Label(query.type.title, systemImage: "square.grid.2x2")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Session type filter")
            .accessibilityValue(query.type.title)

            Menu {
                Picker("Git", selection: $query.git) {
                    ForEach(HistoryGitFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
            } label: {
                Label(query.git.title, systemImage: "arrow.triangle.branch")
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("Git filter")
            .accessibilityValue(query.git.title)

            Spacer()

            if query.hasRestrictions {
                Button("Clear Filters") {
                    query = HistoryQuery()
                }
                .buttonStyle(.link)
                .accessibilityLabel("Clear History Filters")
                .accessibilityHint("Removes search text and all History filters")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var projectTitle: String {
        switch query.project {
        case .allProjects:
            return "All Projects"
        case .noProject:
            return "No Project"
        case .projectID(let id):
            return projectOptions.first(where: {
                if case .projectID(let optionID) = $0.filter { return optionID == id }
                return false
            })?.title ?? "Project"
        case .historicalName(let name):
            return name
        }
    }

    private func filterLabel(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "circle")
    }
}

private struct HistoryEmptyState: View {
    let hasAnySessions: Bool
    let canClearFilters: Bool
    let clearFilters: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hasAnySessions ? "line.3.horizontal.decrease.circle" : "clock")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(hasAnySessions ? "No Matching Sessions" : "No Sessions Yet")
                .font(.headline)
            Text(hasAnySessions
                 ? "Try changing your search or filters."
                 : "Saved coding sessions will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if canClearFilters {
                Button("Clear Filters", action: clearFilters)
                    .buttonStyle(.link)
                    .accessibilityLabel("Clear History Filters")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .accessibilityElement(children: .combine)
    }
}

private struct HistoryDayHeader: View {
    let group: DaySessionGroup
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CodePulseFormatting.fullDay(group.id, calendar: calendar))
                    .font(.headline)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(CodePulseFormatting.fullDay(group.id, calendar: calendar)), \(summary)")
    }

    private var summary: String {
        var parts = [
            CodePulseFormatting.duration(group.totalDuration),
            "\(group.sessionCount) \(group.sessionCount == 1 ? "session" : "sessions")"
        ]
        if group.distinctNamedProjectCount > 1 {
            parts.append("\(group.distinctNamedProjectCount) projects")
        }
        return parts.joined(separator: " · ")
    }
}

private struct HistoryRow: View {
    let session: CompletedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.projectName ?? "No Project")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(CodePulseFormatting.duration(session.activeDuration))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }

            HStack(spacing: 7) {
                Label(session.type.title, systemImage: session.type.systemImage)
                Text("\(CodePulseFormatting.time(session.startedAt)) – \(CodePulseFormatting.time(session.endedAt))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            if let goal = session.goal {
                Text(goal)
                    .font(.body)
                    .lineLimit(2)
            }
            if let outcome = session.outcome {
                Text(outcome)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let branch = session.gitContext?.branchDisplay {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Opens session details")
    }

    private var accessibilitySummary: String {
        var values = [
            session.projectName ?? "No Project",
            session.type.title,
            CodePulseFormatting.duration(session.activeDuration)
        ]
        if let goal = session.goal { values.append(goal) }
        if let outcome = session.outcome { values.append(outcome) }
        if let branch = session.gitContext?.branchDisplay { values.append(branch) }
        return values.joined(separator: ", ")
    }
}

private struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore
    let sessionID: UUID
    @State private var showDeleteConfirmation = false
    @State private var showEditSheet = false

    private var session: CompletedSession? {
        store.completedSession(id: sessionID)
    }

    var body: some View {
        Group {
            if let session {
                detailContent(session)
            } else {
                Text("This session is no longer available.")
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showEditSheet) {
            if let session {
                SessionEditView(session: session)
                    .environmentObject(store)
            }
        }
        .alert("Delete Session?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteCompletedSession(id: sessionID)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This saved session will be removed from CodePulse.")
        }
    }

    @ViewBuilder
    private func detailContent(_ session: CompletedSession) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.projectName ?? "No Project")
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    Text(session.type.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .accessibilityLabel("Done")
            }

            HStack(spacing: 10) {
                LabeledContent("Active Duration", value: CodePulseFormatting.duration(session.activeDuration, includeSeconds: true))
                Spacer()
                Button("Edit Session") {
                    showEditSheet = true
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Edit Session")
                .accessibilityHint("Edits the journal fields and shifts the session timeline")
            }
            LabeledContent("Started", value: CodePulseFormatting.time(session.startedAt))
            LabeledContent("Finished", value: CodePulseFormatting.time(session.endedAt))

            if let goal = session.goal {
                DetailTextBlock(title: "Goal", text: goal)
            }
            if let outcome = session.outcome {
                DetailTextBlock(title: "Outcome", text: outcome)
            }

            if !session.developerToolContexts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Developer Tools")
                        .font(.headline)
                    DeveloperToolContextList(
                        contexts: session.developerToolContexts,
                        showsEventCounts: true
                    )
                }
            }

            if let gitContext = session.gitContext {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Git")
                        .font(.headline)

                    LabeledContent("Repository", value: gitContext.repositoryRoot)
                        .lineLimit(2)

                    if let branch = gitContext.branchDisplay {
                        LabeledContent("Branch", value: branch)
                    }
                    if let commitCount = gitContext.commitCount, commitCount > 0 {
                        LabeledContent("Commits", value: "\(commitCount)")
                    }
                    if let changes = gitContext.changesDisplay {
                        LabeledContent("Changes", value: changes)
                    }
                    if let head = gitContext.headDisplay {
                        LabeledContent("HEAD", value: head)
                    }
                }
            }

            if let githubContext = session.githubContext {
                GitHubContextView(context: githubContext)
            }

            Spacer()

            Button("Delete Session", role: .destructive) {
                showDeleteConfirmation = true
            }
            .accessibilityLabel("Delete Session")
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 540, maxWidth: 620, minHeight: 380, maxHeight: 620)
    }
}

private struct DetailTextBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

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

private struct SessionEditView: View {
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
                        if session.projectName != nil {
                            Text("Keep “\(session.projectName!)”").tag(CompletedSessionProjectChoice.keepSnapshot)
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
                            .border(Color.secondary.opacity(0.2))
                            .accessibilityLabel("Goal")
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("Outcome")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $outcome)
                            .frame(minHeight: 80, idealHeight: 110)
                            .border(Color.secondary.opacity(0.2))
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
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Save Session Changes")
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 640)
        .onAppear {
            if let projectID = session.projectID,
               store.state.projects.contains(where: { $0.id == projectID }) {
                projectChoice = .project(projectID)
            }
        }
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
