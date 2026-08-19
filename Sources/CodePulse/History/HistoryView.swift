import AppKit
import UniformTypeIdentifiers
import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: SessionStore

    @State private var selectedSessionID: UUID?
    @State private var sessionPendingDeletion: CompletedSession?
    @State private var sessionPendingEdit: CompletedSession?
    @State private var exportError = false
    @State private var exportActivity = HistoryCSVExportActivity()
    @State private var query = HistoryQuery()
    @State private var filteredGroups: [DaySessionGroup] = []
    @State private var projectOptions: [HistoryProjectOption] = []

    private var historyReferenceDay: Date {
        store.calendar.startOfDay(for: store.now)
    }

    private var selectedSession: CompletedSession? {
        guard let selectedSessionID else { return nil }
        return store.completedSession(id: selectedSessionID)
    }

    private var visibleSessionIDs: [UUID] {
        filteredGroups.flatMap { $0.sessions.map(\.id) }
    }

    var body: some View {
        NavigationSplitView {
            HistorySidebar(
                groups: filteredGroups,
                selectedSessionID: $selectedSessionID,
                calendar: store.calendar,
                hasAnySessions: !store.state.completedSessions.isEmpty,
                canClearFilters: query.hasRestrictions,
                clearFilters: clearFilters,
                onEdit: { sessionPendingEdit = $0 },
                onDelete: { sessionPendingDeletion = $0 }
            )
            .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 360)
        } detail: {
            HistoryDetailPane(
                session: selectedSession,
                calendar: store.calendar,
                hasAnySessions: !store.state.completedSessions.isEmpty,
                canClearFilters: query.hasRestrictions,
                clearFilters: clearFilters
            )
            .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("History")
        .searchable(
            text: $query.searchText,
            placement: .toolbar,
            prompt: "Search sessions, goals, branches, tools…"
        )
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                HistoryFilterMenu(query: $query, projectOptions: projectOptions)

                Button(action: exportCSV) {
                    if exportActivity.isActive {
                        Label("Exporting…", systemImage: "arrow.down.circle")
                    } else {
                        Label("Export CSV…", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(exportActivity.isActive)
                .accessibilityLabel("Export History as CSV")
                .accessibilityHint("Saves the currently filtered History sessions as a UTF-8 CSV file")

                Button {
                    if let selectedSession {
                        sessionPendingEdit = selectedSession
                    }
                } label: {
                    Label("Edit Session", systemImage: "pencil")
                }
                .disabled(selectedSession == nil)
                .accessibilityLabel("Edit selected session")
                .accessibilityHint("Edits the selected session's type, project, timeline, goal, and outcome")

                Button(role: .destructive, action: requestDeleteSelectedSession) {
                    Label("Delete Session", systemImage: "trash")
                }
                .disabled(selectedSession == nil)
                .accessibilityLabel("Delete selected session")
                .accessibilityHint("Asks for confirmation before deleting the selected saved session")
            }
        }
        .onAppear { refreshDerivedData() }
        .onChange(of: query) { _ in refreshDerivedData() }
        .onChange(of: store.stateRevision) { _ in refreshDerivedData() }
        .onChange(of: historyReferenceDay) { _ in refreshDerivedData() }
        .sheet(item: $sessionPendingEdit) { session in
            SessionEditView(session: session)
                .environmentObject(store)
        }
        .alert("Delete Session?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                deletePendingSession()
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            Text("This saved session will be removed from CodePulse.")
        }
        .alert("History Export Failed", isPresented: $exportError) {
            Button("OK", role: .cancel) { exportError = false }
        } message: {
            Text("CodePulse couldn't export this History file. Choose another destination or check its permissions.")
        }
        .frame(minWidth: 740, minHeight: 520)
    }

    private func refreshDerivedData(preferredSelectionID: UUID? = nil) {
        let currentSelectionID = selectedSessionID
        let referenceDate = store.now
        let groups = store.historyGroups(for: query, referenceDate: referenceDate)

        projectOptions = store.historyProjectOptions
        filteredGroups = groups
        selectedSessionID = HistorySelectionResolver.resolve(
            currentID: currentSelectionID,
            preferredID: preferredSelectionID,
            visibleIDs: groups.flatMap { $0.sessions.map(\.id) }
        )
    }

    private func clearFilters() {
        query = HistoryQuery()
    }

    private func requestDeleteSelectedSession() {
        guard let selectedSession else { return }
        sessionPendingDeletion = selectedSession
    }

    private func deletePendingSession() {
        guard let session = sessionPendingDeletion else { return }

        let visibleBeforeDeletion = visibleSessionIDs
        store.deleteCompletedSession(id: session.id)
        let visibleAfterDeletion = store.historySessions(for: query, referenceDate: store.now).map(\.id)
        let preferredSelectionID = HistorySelectionResolver.afterDeletion(
            deletedID: session.id,
            currentID: selectedSessionID,
            visibleIDsBeforeDeletion: visibleBeforeDeletion,
            visibleIDsAfterDeletion: visibleAfterDeletion
        )

        sessionPendingDeletion = nil
        refreshDerivedData(preferredSelectionID: preferredSelectionID)
    }

    @MainActor
    private func exportCSV() {
        guard !exportActivity.isActive else { return }

        let referenceDate = store.now
        let sessions = store.historySessions(for: query, referenceDate: referenceDate)
        guard let url = ExportSavePanel.chooseURL(
            defaultName: ExportFilename.history(referenceDate: referenceDate, calendar: store.calendar),
            contentType: .commaSeparatedText,
            prompt: "Export CSV"
        ) else { return }

        guard exportActivity.begin() else { return }

        let exportSnapshot = sessions
        Task { @MainActor in
            let succeeded = await Task.detached(priority: .userInitiated) { [exportSnapshot, url] in
                do {
                    try HistoryCSVExportWorker.write(sessions: exportSnapshot, to: url)
                    return true
                } catch {
                    return false
                }
            }.value

            exportActivity.end()
            if !succeeded {
                exportError = true
            }
        }
    }
}

private struct HistoryFilterMenu: View {
    @Binding var query: HistoryQuery
    let projectOptions: [HistoryProjectOption]

    var body: some View {
        Menu {
            Menu("Project") {
                filterButton("All Projects", selected: query.project == .allProjects) {
                    query.project = .allProjects
                }
                filterButton("No Project", selected: query.project == .noProject) {
                    query.project = .noProject
                }
                if !projectOptions.isEmpty {
                    Divider()
                    ForEach(projectOptions) { option in
                        filterButton(option.title, selected: query.project == option.filter) {
                            query.project = option.filter
                        }
                    }
                }
            }

            Menu("Date") {
                ForEach(HistoryDateFilter.allCases) { filter in
                    filterButton(filter.title, selected: query.date == filter) {
                        query.date = filter
                    }
                }
            }

            Menu("Session Type") {
                ForEach(HistoryTypeFilter.allCases) { filter in
                    filterButton(filter.title, selected: query.type == filter) {
                        query.type = filter
                    }
                }
            }

            Menu("Git") {
                ForEach(HistoryGitFilter.allCases) { filter in
                    filterButton(filter.title, selected: query.git == filter) {
                        query.git = filter
                    }
                }
            }

            Menu("Developer Tool") {
                ForEach(HistoryDeveloperToolFilter.allCases) { filter in
                    filterButton(filter.title, selected: query.developerTool == filter) {
                        query.developerTool = filter
                    }
                }
            }

            Menu("Goal / Outcome") {
                ForEach(HistoryGoalOutcomeFilter.allCases) { filter in
                    filterButton(filter.title, selected: query.goalOutcome == filter) {
                        query.goalOutcome = filter
                    }
                }
            }

            if query.hasRestrictions {
                Divider()
                Button("Clear All Filters", action: clearFilters)
            }
        } label: {
            Label("Filter", systemImage: query.hasRestrictions
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("History filters")
        .accessibilityValue(filterSummary)
        .help("Filter History sessions")
    }

    private var filterSummary: String {
        guard query.hasRestrictions else { return "No filters" }
        var values: [String] = []
        if !query.normalizedSearchText.isEmpty { values.append("Search") }
        if query.project != .allProjects { values.append("Project") }
        if query.date != .allTime { values.append(query.date.title) }
        if query.type != .allTypes { values.append(query.type.title) }
        if query.git != .allSessions { values.append(query.git.title) }
        if query.developerTool != .anyTool { values.append(query.developerTool.title) }
        if query.goalOutcome != .allSessions { values.append(query.goalOutcome.title) }
        return values.joined(separator: ", ")
    }

    private func clearFilters() {
        query = HistoryQuery()
    }

    @ViewBuilder
    private func filterButton(
        _ title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

struct HistorySidebar: View {
    let groups: [DaySessionGroup]
    @Binding var selectedSessionID: UUID?
    let calendar: Calendar
    let hasAnySessions: Bool
    let canClearFilters: Bool
    let clearFilters: () -> Void
    let onEdit: (CompletedSession) -> Void
    let onDelete: (CompletedSession) -> Void

    var body: some View {
        if groups.isEmpty {
            HistoryEmptyState(
                hasAnySessions: hasAnySessions,
                canClearFilters: canClearFilters,
                clearFilters: clearFilters
            )
            .padding(12)
        } else {
            List(selection: $selectedSessionID) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.sessions) { session in
                            HistorySidebarRow(session: session)
                                .tag(session.id)
                                .contextMenu {
                                    Button("Edit Session…") { onEdit(session) }
                                    Divider()
                                    Button("Delete Session…", role: .destructive) { onDelete(session) }
                                }
                        }
                    } header: {
                        HistoryDayHeader(group: group, calendar: calendar)
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

struct HistoryEmptyState: View {
    let hasAnySessions: Bool
    let canClearFilters: Bool
    let clearFilters: () -> Void

    var body: some View {
        EmptyStateView(
            content: EmptyStateCopy.history(hasAnySessions: hasAnySessions),
            actionTitle: canClearFilters ? "Clear Filters" : nil,
            action: canClearFilters ? clearFilters : nil
        )
        .frame(maxHeight: .infinity)
    }
}

private struct HistoryDayHeader: View {
    let group: DaySessionGroup
    let calendar: Calendar

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(CodePulseFormatting.day(group.id, calendar: calendar))
                    .font(.subheadline.weight(.semibold))
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(CodePulseFormatting.day(group.id, calendar: calendar)), \(summary)"
        )
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

private struct HistorySidebarRow: View {
    let session: CompletedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(session.projectName ?? "No Project")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(CodePulseFormatting.duration(session.activeDuration))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Label(session.type.title, systemImage: session.type.systemImage)
                Text("·")
                Text("\(CodePulseFormatting.time(session.startedAt)) – \(CodePulseFormatting.time(session.endedAt))")
                metadataIndicators
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.82)

            if let preview = previewText {
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint("Selects this session for detail inspection")
    }

    @ViewBuilder
    private var metadataIndicators: some View {
        if HistoryDetailAvailability.needsFollowUp(session) {
            Image(systemName: "exclamationmark.circle.fill")
                .accessibilityLabel("Needs Outcome")
        }
        if session.gitContext != nil {
            Image(systemName: "arrow.triangle.branch")
                .accessibilityLabel("Git")
        }
        if !session.developerToolContexts.isEmpty {
            Image(systemName: "sparkles")
                .accessibilityLabel("Developer tool metadata")
        }
        if session.githubContext != nil {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .accessibilityLabel("GitHub")
        }
    }

    private var previewText: String? {
        if let goal = session.goal, MeaningfulText.exists(goal) { return goal }
        if let outcome = session.outcome, MeaningfulText.exists(outcome) { return outcome }
        return nil
    }

    private var accessibilitySummary: String {
        var values = [
            session.projectName ?? "No Project",
            session.type.title,
            CodePulseFormatting.duration(session.activeDuration),
            "Started \(CodePulseFormatting.time(session.startedAt))",
            "Finished \(CodePulseFormatting.time(session.endedAt))"
        ]
        if let goal = session.goal, MeaningfulText.exists(goal) {
            values.append("Goal: \(goal)")
        } else if let outcome = session.outcome, MeaningfulText.exists(outcome) {
            values.append("Outcome: \(outcome)")
        }
        if HistoryDetailAvailability.needsFollowUp(session) { values.append("Needs Outcome") }
        if session.gitContext != nil { values.append("Git") }
        if !session.developerToolContexts.isEmpty { values.append("Developer tool metadata") }
        if session.githubContext != nil { values.append("GitHub") }
        return values.joined(separator: ", ")
    }
}
