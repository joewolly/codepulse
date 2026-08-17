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
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                InsightsFilterBar(
                    timeframe: $timeframe,
                    project: $project,
                    projectOptions: calculatedProjectOptions,
                    onExport: exportReport
                )

                if let summary = calculatedSummary {
                    if summary.hasActivity {
                        InsightSummarySection(summary: summary)
                        GoalOutcomeInsightSection(insights: summary.goalOutcomeInsights)
                        ActivityChart(
                            activity: summary.dailyActivity,
                            timeframe: timeframe,
                            calendar: store.calendar
                        )

                        InsightSection(title: "Work Type", systemImage: "square.grid.2x2") {
                            InsightBreakdownBars(values: summary.typeBreakdown)
                        }

                        InsightSection(title: "Projects", systemImage: "folder") {
                            InsightBreakdownBars(values: summary.projectBreakdown)
                        }

                        DeveloperToolInsightSection(insights: summary.developerToolInsights)

                        if summary.gitInsights.sessionsWithGitContext > 0 {
                            GitInsightSection(insights: summary.gitInsights)
                        }

                        if summary.githubInsights.sessionsWithGitHubContext > 0 {
                            GitHubInsightSection(insights: summary.githubInsights)
                        }
                    } else {
                        GoalOutcomeInsightSection(insights: summary.goalOutcomeInsights)
                        InsightsEmptyState(
                            timeframe: timeframe,
                            projectTitle: project.title(options: calculatedProjectOptions),
                            isAllProjects: project == .allProjects,
                            hasSavedSessions: hasSavedSessions
                        )
                    }
                } else {
                    ProgressView("Calculating Insights…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .accessibilityLabel("Calculating Insights")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Insights")
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
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 620)
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

private struct InsightsFilterBar: View {
    @Binding var timeframe: InsightsTimeframe
    @Binding var project: InsightsProjectFilter
    let projectOptions: [InsightsProjectOption]
    let onExport: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(timeframe.title)
                    .font(.title2.weight(.semibold))
                Text("Local active time from saved and current sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Picker("Timeframe", selection: $timeframe) {
                ForEach(InsightsTimeframe.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Insights timeframe")
            .accessibilityValue(timeframe.title)

            Picker("Project", selection: $project) {
                Text("All Projects").tag(InsightsProjectFilter.allProjects)
                Text("No Project").tag(InsightsProjectFilter.noProject)
                if !projectOptions.isEmpty {
                    Divider()
                    ForEach(projectOptions) { option in
                        Text(option.title).tag(option.filter)
                    }
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Insights project")
            .accessibilityValue(project.title(options: projectOptions))

            Button {
                onExport()
            } label: {
                Label("Export Report…", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Export Insights Report")
            .accessibilityHint("Saves the current Insights timeframe and project as a Markdown report")
        }
        .accessibilityElement(children: .contain)
    }
}

private struct InsightSummarySection: View {
    let summary: InsightsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Summary")
                .font(.headline)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)],
                alignment: .leading,
                spacing: 16
            ) {
                InsightMetric(
                    title: "Active Time",
                    value: CodePulseFormatting.duration(summary.totalDuration),
                    detail: summary.durationDifference.map {
                        "\(CodePulseFormatting.signedDuration($0)) \(comparisonLabel)"
                    }
                )
                InsightMetric(
                    title: "Sessions",
                    value: "\(summary.sessionCount)",
                    detail: sessionDifference
                )
                InsightMetric(
                    title: "Average Session",
                    value: summary.sessionCount == 0
                        ? "—"
                        : CodePulseFormatting.duration(summary.averageSessionDuration),
                    detail: nil
                )
                InsightMetric(
                    title: "Longest Session",
                    value: summary.sessionCount == 0
                        ? "—"
                        : CodePulseFormatting.duration(summary.longestSessionDuration),
                    detail: nil
                )
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.08))
            )
        }
    }

    private var comparisonLabel: String {
        switch summary.timeframe {
        case .thisWeek: return "vs last week"
        case .lastWeek: return "vs the week before"
        case .thisMonth: return "vs last month"
        case .last30Days: return "vs the previous 30 days"
        case .last90Days: return "vs the previous 90 days"
        case .allTime: return ""
        }
    }

    private var sessionDifference: String? {
        guard let comparisonSessionCount = summary.comparisonSessionCount else { return nil }
        let difference = summary.sessionCount - comparisonSessionCount
        let sign = difference < 0 ? "−" : "+"
        return "\(sign)\(abs(difference)) \(comparisonLabel)"
    }
}

private struct GoalOutcomeInsightSection: View {
    let insights: GoalOutcomeInsights

    var body: some View {
        InsightSection(title: "Goal vs Actual", systemImage: "target") {
            if insights.completedSessionCount == 0 {
                Text("No completed sessions in this period yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No completed sessions in this period yet")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 135), alignment: .leading)],
                    alignment: .leading,
                    spacing: 16
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
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )

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
            }

            Text("Actual reflects the outcome you recorded. CodePulse does not judge whether a goal was achieved.")
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

private struct InsightMetric: View {
    let title: String
    let value: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title3.weight(.semibold))
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(detail.map { "\(value), \($0)" } ?? value)
    }
}

private struct InsightSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            content()
        }
    }
}

private struct InsightBreakdownBars: View {
    let values: [InsightsBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if values.isEmpty {
                Text("No activity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values) { value in
                    DistributionBar(
                        label: value.label,
                        value: value.duration,
                        maximum: values.first?.duration ?? value.duration,
                        valueLabel: CodePulseFormatting.duration(value.duration)
                    )
                }
            }
        }
    }
}

private struct DistributionBar: View {
    let label: String
    let value: TimeInterval
    let maximum: TimeInterval
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
            }

            GeometryReader { geometry in
                let fraction = maximum > 0 ? value / maximum : 0
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.accentColor.opacity(0.78))
                    .frame(width: max(3, geometry.size.width * fraction), height: 7)
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueLabel)
    }
}

private struct ActivityBucket: Identifiable {
    let date: Date
    let duration: TimeInterval
    let label: String

    var id: Date { date }
}

private struct ActivityChart: View {
    let activity: [DailyActivity]
    let timeframe: InsightsTimeframe
    let calendar: Calendar

    private var usesWeeklyBuckets: Bool {
        timeframe == .last90Days || (timeframe == .allTime && activity.count > 45)
    }

    private var buckets: [ActivityBucket] {
        guard usesWeeklyBuckets else {
            return activity.map {
                ActivityBucket(
                    date: $0.date,
                    duration: $0.duration,
                    label: CodePulseFormatting.fullDay($0.date, calendar: calendar)
                )
            }
        }

        var grouped: [Date: TimeInterval] = [:]
        for day in activity {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
            grouped[weekStart, default: 0] += day.duration
        }
        return grouped.map { date, duration in
            ActivityBucket(
                date: date,
                duration: duration,
                label: CodePulseFormatting.fullDay(date, calendar: calendar)
            )
        }.sorted { $0.date < $1.date }
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
                AxisMarks(values: .automatic) { value in
                    AxisGridLine()
                    AxisTick()
                    if usesWeeklyBuckets {
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    } else {
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
            }
            .frame(height: 190)
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

private struct DeveloperToolInsightSection: View {
    let insights: DeveloperToolInsights

    var body: some View {
        InsightSection(title: "Developer Tools", systemImage: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 8) {
                InsightCountRow(label: "Codex", count: insights.sessionsWithCodex)
                InsightCountRow(label: "OpenCode", count: insights.sessionsWithOpenCode)
                InsightCountRow(label: "Both tools", count: insights.sessionsWithBoth)
                InsightCountRow(label: "Any developer tool", count: insights.sessionsWithAnyTool)
                InsightCountRow(label: "No developer tool", count: insights.sessionsWithNoTool)
            }

            Text("Participation counts sessions. A session using both tools is included in both tool totals and the overlapping Both tools total.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            ForEach(values) { value in
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
        }
    }
}

private struct GitInsightSection: View {
    let insights: GitInsights

    var body: some View {
        InsightSection(title: "Git Activity", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 8) {
                InsightCountRow(label: "Sessions with Git context", count: insights.sessionsWithGitContext)
                if let totalCommits = insights.totalCommits {
                    InsightValueRow(label: "Commits", value: "\(totalCommits)")
                }
                if let totalFilesChanged = insights.totalFilesChanged {
                    InsightValueRow(label: "Files Changed", value: "\(totalFilesChanged)")
                }
                if let totalInsertions = insights.totalInsertions {
                    InsightValueRow(label: "Insertions", value: "+\(totalInsertions)")
                }
                if let totalDeletions = insights.totalDeletions {
                    InsightValueRow(label: "Deletions", value: "−\(totalDeletions)")
                }
                if !insights.hasMetrics {
                    Text("Detailed Git totals are unavailable for these historical snapshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct GitHubInsightSection: View {
    let insights: GitHubInsights

    var body: some View {
        InsightSection(title: "GitHub Activity", systemImage: "arrow.up.forward.app") {
            VStack(alignment: .leading, spacing: 8) {
                InsightCountRow(label: "Sessions with GitHub context", count: insights.sessionsWithGitHubContext)
                InsightCountRow(label: "Sessions with pull requests", count: insights.sessionsWithPullRequest)
                InsightValueRow(label: "Repositories", value: "\(insights.uniqueRepositories)")
                InsightValueRow(label: "Pull requests", value: "\(insights.uniquePullRequests)")
            }

            if !insights.repositoryBreakdown.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Repository Time")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)
                    InsightBreakdownBars(values: insights.repositoryBreakdown)
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

    var body: some View {
        EmptyStateView(
            content: EmptyStateCopy.insights(
                hasSavedSessions: hasSavedSessions,
                timeframeTitle: timeframe.title,
                projectTitle: projectTitle,
                isAllProjects: isAllProjects
            )
        )
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}
