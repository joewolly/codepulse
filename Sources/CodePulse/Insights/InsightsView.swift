import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct InsightsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var timeframe: InsightsTimeframe = .thisWeek
    @State private var project: InsightsProjectFilter = .allProjects
    @State private var reportExportError = false
    @State private var calculatedProjectOptions: [InsightsProjectOption] = []
    @State private var calculatedSummary: InsightsSummary?

    private var insightsReferenceMinute: Int {
        Int(store.now.timeIntervalSince1970 / 60)
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let summary = calculatedSummary {
                            let contentWidth = min(max(proxy.size.width - 32, 0), 880)
                            InsightSummarySection(
                                summary: summary,
                                contentWidth: contentWidth
                            )

                            if summary.hasActivity {
                                InsightsAnalyticalGrid(
                                    summary: summary,
                                    timeframe: timeframe,
                                    calendar: store.calendar,
                                    contentWidth: contentWidth
                                )

                                GoalOutcomeInsightSection(
                                    insights: summary.goalOutcomeInsights,
                                    contentWidth: contentWidth
                                )
                                ProjectOutcomeInsightSection(
                                    insights: summary.projectOutcomeInsights,
                                    isAllProjects: project == .allProjects,
                                    calendar: store.calendar
                                )

                                if InsightsPresentation.showsGitContext(summary.gitInsights) ||
                                    InsightsPresentation.showsGitHubContext(summary.githubInsights) {
                                    ContextualEcosystemSection(
                                        summary: summary,
                                        contentWidth: contentWidth
                                    )
                                }
                            } else {
                                InsightsEmptyState(
                                    timeframe: timeframe,
                                    projectTitle: project.title(options: calculatedProjectOptions),
                                    isAllProjects: project == .allProjects,
                                    hasSavedSessions: hasSavedSessions,
                                    onShowAllProjects: project == .allProjects
                                        ? nil
                                        : { project = .allProjects }
                                )
                            }
                        } else {
                            ProgressView("Calculating Insights…")
                                .frame(maxWidth: .infinity, minHeight: 180)
                                .accessibilityLabel("Calculating Insights")
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 880, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Insights")
        .toolbar {
            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    Text("Timeframe:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Picker(selection: $timeframe) {
                        ForEach(InsightsTimeframe.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    } label: {
                        Text(timeframe.title)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 128, alignment: .leading)
                    .accessibilityLabel("Insights timeframe")
                    .accessibilityValue(timeframe.title)
                }
            }

            ToolbarItem(placement: .navigation) {
                HStack(spacing: 6) {
                    Text("Project:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    Picker(selection: $project) {
                        Text("All Projects").tag(InsightsProjectFilter.allProjects)
                        Text("No Project").tag(InsightsProjectFilter.noProject)
                        if !calculatedProjectOptions.isEmpty {
                            Divider()
                            ForEach(calculatedProjectOptions) { option in
                                Text(option.title).tag(option.filter)
                            }
                        }
                    } label: {
                        Text(project.title(options: calculatedProjectOptions))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(width: 170, alignment: .leading)
                    .accessibilityLabel("Insights project")
                    .accessibilityValue(project.title(options: calculatedProjectOptions))
                }
                .padding(.leading, 12)
            }

            ToolbarItem(placement: .primaryAction) {
                Button(action: exportReport) {
                    Label("Export Report…", systemImage: "square.and.arrow.down")
                }
                .accessibilityLabel("Export Insights Report")
                .accessibilityHint("Saves the current Insights timeframe and project as a Markdown report")
            }
        }
        .alert("Report Export Failed", isPresented: $reportExportError) {
            Button("OK", role: .cancel) { reportExportError = false }
        } message: {
            Text("CodePulse couldn't export this Insights report. Choose another destination or check its permissions.")
        }
        .onAppear(perform: refreshInsights)
        .onChange(of: timeframe) { _ in refreshInsights() }
        .onChange(of: project) { _ in refreshInsights() }
        .onChange(of: store.stateRevision) { _ in refreshInsights() }
        .onChange(of: insightsReferenceMinute) { _ in refreshInsights() }
    }

    private func refreshInsights() {
        calculatedProjectOptions = store.insightsProjectOptions
        calculatedSummary = InsightsCalculator.summary(
            state: store.state,
            calendar: store.calendar,
            referenceDate: store.now,
            timeframe: timeframe,
            project: project
        )
    }

    private var hasSavedSessions: Bool {
        !store.state.completedSessions.isEmpty
    }

    private func exportReport() {
        let referenceDate = store.now
        let calendar = store.calendar
        let selectedProjectTitle = project.title(options: calculatedProjectOptions)
        let summary = InsightsCalculator.summary(
            state: store.state,
            calendar: calendar,
            referenceDate: referenceDate,
            timeframe: timeframe,
            project: project
        )
        let filenameProject = project == .allProjects ? nil : selectedProjectTitle
        let markdownType = UTType(importedAs: "net.daringfireball.markdown")

        guard let url = ExportSavePanel.chooseURL(
            defaultName: ExportFilename.report(
                projectTitle: filenameProject,
                timeframe: timeframe,
                referenceDate: referenceDate,
                calendar: calendar
            ),
            contentType: markdownType,
            prompt: "Export Report"
        ) else { return }

        do {
            try AtomicExportFileWriter().write(
                InsightsMarkdownExporter.data(
                    summary: summary,
                    projectTitle: selectedProjectTitle,
                    calendar: calendar
                ),
                to: url
            )
        } catch {
            reportExportError = true
        }
    }
}

private extension InsightsProjectFilter {
    func title(options: [InsightsProjectOption]) -> String {
        switch self {
        case .allProjects:
            return "All Projects"
        case .noProject:
            return "No Project"
        case .projectID(let projectID):
            return options.first(where: { $0.filter == .projectID(projectID) })?.title ?? "Project"
        case .historicalName(let name):
            return name
        }
    }
}

private struct InsightCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            }
    }
}

private struct ResponsiveInsightGrid<Content: View>: View {
    let columns: Int
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(minimum: 0), spacing: spacing, alignment: .leading),
                count: max(1, columns)
            ),
            alignment: .leading,
            spacing: spacing,
            content: content
        )
    }
}

private struct InsightSummarySection: View {
    let summary: InsightsSummary
    let contentWidth: CGFloat

    var body: some View {
        ResponsiveInsightGrid(
            columns: InsightsPresentation.summaryColumnCount(for: contentWidth),
            spacing: 10
        ) {
            InsightSummaryCard(
                systemImage: "clock",
                accent: .blue,
                title: "Active Time",
                value: CodePulseFormatting.duration(summary.totalDuration),
                detail: summary.durationDifference.flatMap {
                    guard let label = InsightsPresentation.comparisonLabel(for: summary.timeframe) else {
                        return nil
                    }
                    return "\(CodePulseFormatting.signedDuration($0)) \(label)"
                }
            )
            InsightSummaryCard(
                systemImage: "rectangle.stack",
                accent: .indigo,
                title: "Sessions",
                value: "\(summary.sessionCount)",
                detail: sessionDifference
            )
            InsightSummaryCard(
                systemImage: "timer",
                accent: .green,
                title: "Average Session",
                value: summary.sessionCount == 0
                    ? "—"
                    : CodePulseFormatting.duration(summary.averageSessionDuration),
                detail: nil
            )
            InsightSummaryCard(
                systemImage: "hourglass",
                accent: .orange,
                title: "Longest Session",
                value: summary.sessionCount == 0
                    ? "—"
                    : CodePulseFormatting.duration(summary.longestSessionDuration),
                detail: nil
            )
        }
    }

    private var sessionDifference: String? {
        guard let comparisonSessionCount = summary.comparisonSessionCount else { return nil }
        guard let comparisonLabel = InsightsPresentation.comparisonLabel(for: summary.timeframe) else {
            return nil
        }
        let difference = summary.sessionCount - comparisonSessionCount
        let sign = difference < 0 ? "−" : "+"
        return "\(sign)\(abs(difference)) \(comparisonLabel)"
    }
}

private struct InsightSummaryCard: View {
    let systemImage: String
    let accent: Color
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        InsightCard {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    InsightAccentBadge(systemImage: systemImage, color: accent)
                    Text(title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Group {
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else {
                        Color.clear
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
    }
}

private struct InsightAccentBadge: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.58, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: Circle())
    }
}

private struct InsightsAnalyticalGrid: View {
    let summary: InsightsSummary
    let timeframe: InsightsTimeframe
    let calendar: Calendar
    let contentWidth: CGFloat

    private let columnSpacing: CGFloat = 12

    var body: some View {
        if InsightsPresentation.mainGridColumnCount(for: contentWidth) == 2 {
            let leftWidth = max(0, (contentWidth - columnSpacing) * 0.55)
            let rightWidth = max(0, contentWidth - columnSpacing - leftWidth)

            HStack(alignment: .top, spacing: columnSpacing) {
                leftColumn
                    .frame(width: leftWidth, alignment: .topLeading)
                rightColumn
                    .frame(width: rightWidth, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: columnSpacing) {
                leftColumn
                rightColumn
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: columnSpacing) {
            ActivityChart(
                activity: summary.dailyActivity,
                timeframe: timeframe,
                calendar: calendar
            )
            FocusPatternsSection(
                insights: summary.focusInsights,
                calendar: calendar
            )
        }
    }

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: columnSpacing) {
            WorkTypeSection(typeBreakdown: summary.typeBreakdown)
            ProjectDistributionSection(projectBreakdown: summary.projectBreakdown)
            if InsightsPresentation.showsDeveloperToolParticipation(summary.developerToolInsights) {
                DeveloperToolInsightSection(insights: summary.developerToolInsights)
            }
        }
    }
}

private struct GoalOutcomeInsightSection: View {
    let insights: GoalOutcomeInsights
    let contentWidth: CGFloat

    var body: some View {
        InsightSection(title: "Goals & Outcomes", systemImage: "target") {
            ResponsiveInsightGrid(
                columns: InsightsPresentation.summaryColumnCount(for: contentWidth),
                spacing: 12
            ) {
                InsightMetric(
                    title: "Goals Set",
                    value: "\(insights.sessionsWithGoal)",
                    detail: nil
                )
                InsightMetric(
                    title: "Outcomes Recorded",
                    value: "\(insights.sessionsWithOutcome)",
                    detail: nil
                )
                InsightMetric(
                    title: "Closed Loop",
                    value: "\(insights.closedLoopCount)",
                    detail: insights.closedLoopRate.map { "\(percentage($0)) of goal sessions" }
                )
                InsightMetric(
                    title: "Needs Follow-Up",
                    value: "\(insights.needsFollowUpCount)",
                    detail: nil
                )
            }

            if insights.completedSessionCount == 0 {
                Text("No completed sessions in this period yet. Active sessions are excluded from Goals & Outcomes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("No completed sessions in this period yet. Active sessions are excluded from Goals and Outcomes.")
            }

            if insights.outcomeOnlyCount > 0 {
                Text("\(insights.outcomeOnlyCount) \(sessionLabel(insights.outcomeOnlyCount)) recorded \(insights.outcomeOnlyCount == 1 ? "an outcome" : "outcomes") without \(insights.outcomeOnlyCount == 1 ? "a goal" : "goals").")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if insights.untrackedCount > 0 {
                Text("\(insights.untrackedCount) completed \(sessionLabel(insights.untrackedCount)) had neither a goal nor outcome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Reflects the outcome you recorded. CodePulse does not judge whether a goal was achieved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sessionLabel(_ count: Int) -> String {
        count == 1 ? "session" : "sessions"
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct ProjectOutcomeInsightSection: View {
    let insights: [ProjectOutcomeInsights]
    let isAllProjects: Bool
    let calendar: Calendar

    private var visibleInsights: [ProjectOutcomeInsights] {
        let limits = InsightsPresentation.outcomeLimits(isAllProjects: isAllProjects)
        return Array(insights.prefix(limits.projects))
    }

    var body: some View {
        InsightSection(title: "Project Outcomes", systemImage: "list.bullet.clipboard") {
            Text(ProjectOutcomeNarrativeFormatter.sectionCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if visibleInsights.isEmpty {
                Text("No completed project outcomes in this period yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No completed project outcomes in this period yet")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(visibleInsights) { project in
                        ProjectOutcomeCard(
                            insights: project,
                            calendar: calendar,
                            entryLimit: InsightsPresentation.outcomeLimits(isAllProjects: isAllProjects).entries
                        )
                    }
                }
                let projectLimit = InsightsPresentation.outcomeLimits(isAllProjects: isAllProjects).projects
                if isAllProjects, insights.count > projectLimit {
                    Text("Showing \(projectLimit) of \(insights.count) project summaries. Choose a project above to inspect it individually.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Showing \(projectLimit) of \(insights.count) project summaries. Choose a project above to inspect it individually.")
                }
            }
        }
    }
}

private struct ProjectOutcomeCard: View {
    let insights: ProjectOutcomeInsights
    let calendar: Calendar
    let entryLimit: Int

    private var outcomeEntries: ArraySlice<ProjectOutcomeEntry> {
        insights.recentOutcomes.prefix(entryLimit)
    }

    private var followUpEntries: ArraySlice<ProjectOutcomeEntry> {
        insights.followUps.prefix(entryLimit)
    }

    private var outcomeOverflow: Int {
        max(0, insights.recordedOutcomeCount - outcomeEntries.count)
    }

    private var followUpOverflow: Int {
        max(0, insights.needsFollowUpCount - followUpEntries.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(insights.label)
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(ProjectOutcomeNarrativeFormatter.narrative(for: insights))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)

            if !outcomeEntries.isEmpty {
                Text("Recent Outcomes")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(outcomeEntries) { entry in
                    ProjectOutcomeEntryView(entry: entry, calendar: calendar)
                }
                if outcomeOverflow > 0 {
                    Text("+\(outcomeOverflow) more recorded \(outcomeOverflow == 1 ? "outcome" : "outcomes") in this period")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !followUpEntries.isEmpty {
                Text("Needs Follow-Up")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(followUpEntries) { entry in
                    FollowUpEntryView(entry: entry, calendar: calendar)
                }
                if followUpOverflow > 0 {
                    Text("+\(followUpOverflow) more \(followUpOverflow == 1 ? "goal" : "goals") need follow-up in this period")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Record missing outcomes from History.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(insights.label)
    }
}

private struct ProjectOutcomeEntryView: View {
    let entry: ProjectOutcomeEntry
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shortDate(entry.endedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let goal = entry.goal {
                Text("Goal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(goal)
                    .font(.subheadline)
                    .lineLimit(3)
            }
            if let outcome = entry.outcome {
                Text("Outcome")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(outcome)
                    .font(.subheadline)
                    .lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var parts = [shortDate(entry.endedAt)]
        if let goal = entry.goal { parts.append("Goal: \(goal)") }
        if let outcome = entry.outcome { parts.append("Outcome: \(outcome)") }
        return parts.joined(separator: ", ")
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

private struct FollowUpEntryView: View {
    let entry: ProjectOutcomeEntry
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(shortDate(entry.endedAt))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Goal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.goal ?? "")
                .font(.subheadline)
                .lineLimit(3)
            Text("Needs outcome")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shortDate(entry.endedAt)), Goal: \(entry.goal ?? ""), Needs outcome")
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

private struct InsightMetric: View {
    let title: String
    let value: String
    let detail: String?
    let systemImage: String?
    let accent: Color?

    init(
        title: String,
        value: String,
        detail: String?,
        systemImage: String? = nil,
        accent: Color? = nil
    ) {
        self.title = title
        self.value = value
        self.detail = detail
        self.systemImage = systemImage
        self.accent = accent
    }

    var body: some View {
        Group {
            if let systemImage, let accent {
                HStack(alignment: .top, spacing: 8) {
                    InsightAccentBadge(systemImage: systemImage, color: accent, size: 20)
                    metricContent
                }
            } else {
                metricContent
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
    }

    @ViewBuilder
    private var metricContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

private struct InsightSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        InsightCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(title, systemImage: systemImage)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                content()
            }
        }
    }
}

private struct FocusPatternsSection: View {
    let insights: FocusInsights
    let calendar: Calendar

    var body: some View {
        InsightSection(title: "Focus Patterns", systemImage: "scope") {
            ResponsiveInsightGrid(columns: 2, spacing: 8) {
                InsightMetric(
                    title: "Focus Blocks",
                    value: "\(insights.focusBlockCount)",
                    detail: nil,
                    systemImage: "scope",
                    accent: .blue
                )
                InsightMetric(
                    title: "Sustained Focus",
                    value: CodePulseFormatting.duration(insights.sustainedFocusDuration),
                    detail: "at least 30m per block",
                    systemImage: "target",
                    accent: .green
                )
                InsightMetric(
                    title: "Sustained Share",
                    value: insights.sustainedFocusShare.map(percentage) ?? "—",
                    detail: insights.sustainedFocusShare.map { "\(percentage($0)) of active time" },
                    systemImage: "chart.pie",
                    accent: .teal
                )
                InsightMetric(
                    title: "Average Block",
                    value: CodePulseFormatting.duration(insights.averageFocusBlockDuration),
                    detail: nil,
                    systemImage: "timer",
                    accent: .purple
                )
                InsightMetric(
                    title: "Longest Focus",
                    value: CodePulseFormatting.duration(insights.longestFocusBlockDuration),
                    detail: nil,
                    systemImage: "hourglass",
                    accent: .orange
                )
                InsightMetric(
                    title: "Project Switches",
                    value: "\(insights.projectSwitchCount)",
                    detail: "within 15m",
                    systemImage: "arrow.left.arrow.right",
                    accent: .indigo
                )
            }

            if let bestFocusDay = insights.bestFocusDay {
                Text("Best focus day: \(shortDate(bestFocusDay.date, calendar: calendar)) · \(CodePulseFormatting.duration(bestFocusDay.duration)) sustained focus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let peakFocusHour = insights.peakFocusHour {
                Text("Peak focus hour: \(hourRange(peakFocusHour, calendar: calendar))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FocusHourChart(hourly: insights.hourlySustainedFocus, calendar: calendar)

            Text("Focus blocks join work on the same project across interruptions up to 15m. Sustained focus requires at least 30m of active time. Project switches count rapid transitions between identified projects without estimating cognitive cost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func hourRange(_ hour: Int, calendar: Calendar) -> String {
        let start = dateForHour(hour, calendar: calendar)
        let end = dateForHour((hour + 1) % 24, calendar: calendar)
        let hourFormatter = DateFormatter()
        hourFormatter.calendar = calendar
        hourFormatter.locale = calendar.locale ?? .current
        hourFormatter.timeZone = calendar.timeZone
        hourFormatter.dateFormat = "h"
        let periodFormatter = DateFormatter()
        periodFormatter.calendar = calendar
        periodFormatter.locale = calendar.locale ?? .current
        periodFormatter.timeZone = calendar.timeZone
        periodFormatter.dateFormat = "a"
        let startPeriod = periodFormatter.string(from: start)
        let endPeriod = periodFormatter.string(from: end)
        if startPeriod == endPeriod {
            return "\(hourFormatter.string(from: start))–\(hourFormatter.string(from: end)) \(startPeriod)"
        }
        return "\(hourFormatter.string(from: start)) \(startPeriod)–\(hourFormatter.string(from: end)) \(endPeriod)"
    }

    private func dateForHour(_ hour: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour)) ?? .distantPast
    }

    private func shortDate(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

private struct FocusHourChart: View {
    let hourly: [HourlyFocusActivity]
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Sustained Focus by Hour")
                .font(.subheadline.weight(.semibold))
            Chart(hourly) { value in
                BarMark(
                    x: .value("Hour", value.hour),
                    y: .value("Sustained Focus Hours", value.duration / 3_600)
                )
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text(hourLabel(value.hour)))
                .accessibilityValue(Text(CodePulseFormatting.duration(value.duration)))
            }
            .chartYAxisLabel("Hours")
            .chartXAxis {
                AxisMarks(values: Array(stride(from: 0, through: 20, by: 4))) { value in
                    AxisGridLine()
                    AxisTick()
                    if let hour = value.as(Int.self) {
                        AxisValueLabel(hourLabel(hour))
                    }
                }
            }
            .frame(height: 84)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sustained Focus by Hour")
            .accessibilityValue(accessibilitySummary)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "h a"
        let date = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour)) ?? .distantPast
        return formatter.string(from: date)
    }

    private var accessibilitySummary: String {
        let total = hourly.reduce(0) { $0 + $1.duration }
        let nonzero = hourly.filter { $0.duration > 0 }.count
        guard total > 0 else { return "No sustained focus blocks in this period" }
        return "\(CodePulseFormatting.duration(total)) across \(nonzero) local hours"
    }
}

private struct WorkTypeSection: View {
    let typeBreakdown: [InsightsBreakdown]

    var body: some View {
        InsightSection(title: "Work Type Breakdown", systemImage: "square.grid.2x2") {
            InsightBreakdownBars(values: typeBreakdown)
        }
    }
}

private struct ProjectDistributionSection: View {
    let projectBreakdown: [InsightsBreakdown]

    var body: some View {
        InsightSection(title: "Project Distribution", systemImage: "folder") {
            InsightBreakdownBars(
                values: projectBreakdown,
                limit: InsightsPresentation.projectBreakdownLimit,
                overflowLabel: "projects"
            )
        }
    }
}

private struct InsightBreakdownBars: View {
    let values: [InsightsBreakdown]
    let limit: Int?
    let overflowLabel: String?

    init(
        values: [InsightsBreakdown],
        limit: Int? = nil,
        overflowLabel: String? = nil
    ) {
        self.values = values
        self.limit = limit
        self.overflowLabel = overflowLabel
    }

    private var boundedValues: (visible: [InsightsBreakdown], overflow: Int) {
        guard let limit else { return (values, 0) }
        return InsightsPresentation.boundedBreakdown(values, limit: limit)
    }

    private var totalDuration: TimeInterval {
        values.reduce(0) { $0 + $1.duration }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if boundedValues.visible.isEmpty {
                Text("No activity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(boundedValues.visible) { value in
                    DistributionBar(
                        label: value.label,
                        value: value.duration,
                        total: totalDuration,
                        valueLabel: valueLabel(for: value)
                    )
                }

                if boundedValues.overflow > 0, let overflowLabel {
                    Text("+\(boundedValues.overflow) more \(overflowLabel)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func valueLabel(for value: InsightsBreakdown) -> String {
        let percentage = totalDuration > 0
            ? Int((value.duration / totalDuration * 100).rounded())
            : 0
        return "\(percentage)% · \(CodePulseFormatting.duration(value.duration))"
    }
}

private struct DistributionBar: View {
    let label: String
    let value: TimeInterval
    let total: TimeInterval
    let valueLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Text(valueLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 102, alignment: .trailing)
            }

            GeometryReader { geometry in
                let fraction = total > 0 ? value / total : 0
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.32))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.82))
                        .frame(width: max(3, geometry.size.width * fraction))
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueLabel)
    }
}

private struct ActivityChart: View {
    let activity: [DailyActivity]
    let timeframe: InsightsTimeframe
    let calendar: Calendar
    private let buckets: [InsightsActivityBucket]

    init(
        activity: [DailyActivity],
        timeframe: InsightsTimeframe,
        calendar: Calendar
    ) {
        self.activity = activity
        self.timeframe = timeframe
        self.calendar = calendar
        self.buckets = InsightsPresentation.activityBuckets(
            activity: activity,
            timeframe: timeframe,
            calendar: calendar
        )
    }

    private var usesWeeklyBuckets: Bool {
        InsightsPresentation.usesWeeklyActivityBuckets(
            timeframe: timeframe,
            dailyBucketCount: activity.count
        )
    }

    var body: some View {
        InsightSection(title: "Activity Over Time", systemImage: "chart.bar.xaxis") {
            Chart(buckets) { bucket in
                BarMark(
                    x: .value("Period", bucket.date, unit: usesWeeklyBuckets ? .weekOfYear : .day),
                    y: .value("Active Hours", bucket.duration / 3_600)
                )
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text(bucket.label))
                .accessibilityValue(Text(CodePulseFormatting.duration(bucket.duration)))
            }
            .chartYAxisLabel("Hours")
            .chartXAxis {
                AxisMarks(
                    values: .automatic(
                        desiredCount: usesWeeklyBuckets ? 6 : min(7, max(3, buckets.count))
                    )
                ) { value in
                    AxisGridLine()
                    AxisTick()
                    if usesWeeklyBuckets {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    } else {
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
            }
            .frame(height: 168)
            .accessibilityElement(children: buckets.count <= 31 ? .contain : .ignore)
            .accessibilityLabel(usesWeeklyBuckets ? "Weekly active time chart" : "Daily active time chart")
            .accessibilityValue(accessibilitySummary)
        }
    }

    private var accessibilitySummary: String {
        guard !buckets.isEmpty else { return "No active time in this period" }
        let totalDuration = buckets.reduce(0) { $0 + $1.duration }
        let peak = buckets.max { lhs, rhs in lhs.duration < rhs.duration }
        var summary = "\(CodePulseFormatting.duration(totalDuration)) across \(buckets.count) periods"
        if let peak {
            summary += "; peak \(peak.label), \(CodePulseFormatting.duration(peak.duration))"
        }
        return summary
    }
}

private struct ContextualEcosystemSection: View {
    let summary: InsightsSummary
    let contentWidth: CGFloat

    var body: some View {
        ResponsiveInsightGrid(
            columns: InsightsPresentation.mainGridColumnCount(for: contentWidth),
            spacing: 16
        ) {
            if InsightsPresentation.showsGitContext(summary.gitInsights) {
                GitInsightSection(insights: summary.gitInsights)
            }
            if InsightsPresentation.showsGitHubContext(summary.githubInsights) {
                GitHubInsightSection(insights: summary.githubInsights)
            }
        }
    }
}

private struct DeveloperToolInsightSection: View {
    let insights: DeveloperToolInsights

    var body: some View {
        InsightSection(title: "Developer Tool Participation", systemImage: "terminal") {
            VStack(alignment: .leading, spacing: 6) {
                InsightCountRow(label: "Codex", count: insights.sessionsWithCodex)
                InsightCountRow(label: "OpenCode", count: insights.sessionsWithOpenCode)
                InsightCountRow(label: "Both tools", count: insights.sessionsWithBoth)
                InsightCountRow(label: "Any developer tool", count: insights.sessionsWithAnyTool)
                InsightCountRow(label: "No developer tool", count: insights.sessionsWithNoTool)
            }

            Text("Participation counts sessions containing tool context. It does not estimate usage time, output, effectiveness, or productivity.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if insights.hasModelData {
                InsightMetadataList(title: "Models", values: insights.modelBreakdown)
            }
            if insights.hasProfileData {
                InsightMetadataList(title: "Profiles / Agents", values: insights.profileBreakdown)
            }
        }
    }
}

private struct InsightCountRow: View {
    let label: String
    let count: Int

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count) \(count == 1 ? "session" : "sessions")")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InsightMetadataList: View {
    let title: String
    let values: [InsightsCountBreakdown]

    private var boundedValues: (visible: [InsightsCountBreakdown], overflow: Int) {
        let limit = title == "Models"
            ? InsightsPresentation.modelBreakdownLimit
            : InsightsPresentation.profileBreakdownLimit
        return InsightsPresentation.boundedMetadata(values, limit: limit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
            ForEach(boundedValues.visible) { value in
                HStack {
                    Text(value.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text("\(value.count) \(value.count == 1 ? "session" : "sessions")")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if boundedValues.overflow > 0 {
                Text("+\(boundedValues.overflow) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct GitInsightSection: View {
    let insights: GitInsights

    var body: some View {
        InsightSection(title: "Git Activity", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 6) {
                InsightCountRow(label: "Sessions with Git context", count: insights.sessionsWithGitContext)
                InsightValueRow(label: "Commits", value: InsightsPresentation.gitMetricText(insights.totalCommits))
                InsightValueRow(label: "Files Changed", value: InsightsPresentation.gitMetricText(insights.totalFilesChanged))
                InsightValueRow(
                    label: "Insertions",
                    value: insights.totalInsertions.map { "+\($0)" } ?? "Unavailable"
                )
                InsightValueRow(
                    label: "Deletions",
                    value: insights.totalDeletions.map { "−\($0)" } ?? "Unavailable"
                )
                if !insights.hasMetrics ||
                    insights.totalCommits == nil ||
                    insights.totalFilesChanged == nil ||
                    insights.totalInsertions == nil ||
                    insights.totalDeletions == nil {
                    Text(InsightsPresentation.unavailableGitTotalsCopy)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Git values are totals from the included session snapshots, not time-apportioned events in this period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GitHubInsightSection: View {
    let insights: GitHubInsights

    var body: some View {
        InsightSection(title: "GitHub Activity", systemImage: "arrow.up.forward.app") {
            VStack(alignment: .leading, spacing: 6) {
                InsightCountRow(label: "Sessions with GitHub context", count: insights.sessionsWithGitHubContext)
                InsightCountRow(label: "Sessions with pull requests", count: insights.sessionsWithPullRequest)
                InsightValueRow(label: "Repositories", value: "\(insights.uniqueRepositories)")
                InsightValueRow(label: "Pull requests", value: "\(insights.uniquePullRequests)")
            }

            if !insights.repositoryBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Repository Time")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 2)
                    InsightBreakdownBars(
                        values: insights.repositoryBreakdown,
                        limit: InsightsPresentation.repositoryBreakdownLimit,
                        overflowLabel: "repositories"
                    )
                }
            }
        }
    }
}

private struct InsightValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct InsightsEmptyState: View {
    let timeframe: InsightsTimeframe
    let projectTitle: String
    let isAllProjects: Bool
    let hasSavedSessions: Bool
    let onShowAllProjects: (() -> Void)?

    var body: some View {
        EmptyStateView(
            content: EmptyStateCopy.insights(
                hasSavedSessions: hasSavedSessions,
                timeframeTitle: timeframe.title,
                projectTitle: projectTitle,
                isAllProjects: isAllProjects
            ),
            actionTitle: isAllProjects ? nil : "Show All Projects",
            action: onShowAllProjects
        )
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}
