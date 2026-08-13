import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

struct InsightsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var timeframe: InsightsTimeframe = .thisWeek
    @State private var project: InsightsProjectFilter = .allProjects

    private var projectOptions: [InsightsProjectOption] {
        store.insightsProjectOptions
    }

    private var summary: InsightsSummary {
        InsightsCalculator.summary(
            state: store.state,
            calendar: store.calendar,
            referenceDate: store.now,
            timeframe: timeframe,
            project: project
        )
    }

    private var usageReport: UsageAnalyticsReport {
        let interval = InsightsCalculator.interval(
            for: timeframe,
            state: store.state,
            calendar: store.calendar,
            referenceDate: store.now
        )
        let window: UsageAnalyticsWindow
        switch timeframe {
        case .thisWeek:
            window = .week
        case .thisMonth:
            window = .month
        case .lastWeek, .last30Days, .last90Days, .allTime:
            window = .custom(interval)
        }
        return UsageAttributionService.report(
            state: store.state,
            calendar: store.calendar,
            referenceDate: store.now,
            window: window,
            project: project
        )
    }

    var body: some View {
        let summary = self.summary
        let usageReport = self.usageReport

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                InsightsFilterBar(
                    timeframe: $timeframe,
                    project: $project,
                    projectOptions: projectOptions
                )

                if summary.hasActivity || !usageReport.samples.isEmpty {
                    if summary.hasActivity {
                        InsightSummarySection(summary: summary)
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
                    }

                    if !usageReport.samples.isEmpty {
                        UsageAttributionSection(state: store.state, report: usageReport, exportedAt: store.now)
                    }
                } else {
                    InsightsEmptyState(
                        timeframe: timeframe,
                        projectTitle: project.title(options: projectOptions),
                        isAllProjects: project == .allProjects,
                        hasAnySessions: hasAnySessions
                    )
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Insights")
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 620)
    }

    private var hasAnySessions: Bool {
        !store.state.completedSessions.isEmpty || store.state.activeSession != nil
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

private struct UsageAttributionSection: View {
    let state: AppState
    let report: UsageAnalyticsReport
    let exportedAt: Date
    @State private var exportFormat: UsageExportFormat = .json
    @State private var exportOptions = UsageExportOptions()
    @State private var exportError: String?

    private let visibleDimensions: [UsageAttributionDimension] = [.workspace, .domain, .workType, .integration, .provider, .model]

    var body: some View {
        let quality = UsageInsightsDataQuality.resolve(state: state, report: report)
        InsightSection(title: "Usage Insights", systemImage: "chart.bar.doc.horizontal") {
            VStack(alignment: .leading, spacing: 14) {
                Text(quality.state.title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                    UsageMetricCard(title: "Tokens", value: "\(report.tokens.total)", detail: "Recorded local usage")
                    UsageMetricCard(title: "Manual active", value: CodePulseFormatting.duration(report.timing.manualActive), detail: "Manual runs only")
                    UsageMetricCard(title: "Agent runtime", value: CodePulseFormatting.duration(report.timing.agentRuntime), detail: "Overlaps allowed")
                    UsageMetricCard(title: "Combined wall-active", value: CodePulseFormatting.duration(report.timing.combinedWallActive), detail: "Overlaps de-duplicated")
                    UsageMetricCard(title: "Agent waiting", value: CodePulseFormatting.duration(report.timing.agentWaiting), detail: "Excluded from active time")
                }

                if !quality.messages.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(quality.messages, id: \.self) { message in
                            Label(message, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Usage data quality")
                }

                if !report.costs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(report.costs) { cost in
                            LabeledContent(cost.representation.displayLabel, value: money(cost))
                                .font(.caption)
                        }
                    }
                }

                ForEach(visibleDimensions) { dimension in
                    if let values = report.dimensions[dimension], !values.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(dimension.title)
                                .font(.subheadline.weight(.medium))
                            ForEach(values.prefix(5)) { value in
                                HStack {
                                    Text(value.label)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(value.tokens.total) tokens")
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                }

                HStack {
                    Text("Privacy-safe details")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    exportMenu
                }

                DisclosureGroup("Activity, run, and sample details (\(report.reconciliation.count) samples)") {
                    ForEach(report.reconciliation.prefix(25)) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(row.workspace) · \(row.activity)")
                                .font(.caption.weight(.medium))
                            Text("\(CodePulseFormatting.time(row.observedAt)) · \(row.integration) · \(row.provider) · \(row.model) · \(row.tokens.total) tokens")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let rollupDetail = row.rollupDetail {
                                Text(rollupDetail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    if report.reconciliation.count > 25 {
                        Text("Showing the first 25 privacy-safe sample summaries.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Usage insights")
        }
        .alert("Usage Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "CodePulse could not export usage data.")
        }
    }

    private var exportMenu: some View {
        Menu {
            Picker("Format", selection: $exportFormat) {
                ForEach(UsageExportFormat.allCases) { format in
                    Text(format.rawValue.uppercased()).tag(format)
                }
            }
            Divider()
            Text("Include context labels")
            ForEach(UsageExportField.allCases) { field in
                Toggle(field.title, isOn: Binding(
                    get: { exportOptions.includes(field) },
                    set: { enabled in
                        if enabled { exportOptions.includedFields.insert(field) }
                        else { exportOptions.includedFields.remove(field) }
                    }
                ))
            }
            Divider()
            Button("Choose location…") { export() }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .accessibilityLabel("Export usage insights")
        .accessibilityHint("Exports local usage rows without paths or source identifiers")
    }

    private func export() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = exportFormat == .json ? [.json] : [.commaSeparatedText]
        panel.nameFieldStringValue = "CodePulse Usage \(CodePulseFormatting.exportDate(exportedAt)).\(exportFormat.fileExtension)"
        panel.prompt = "Export Usage"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let data: Data
                switch exportFormat {
                case .json:
                    data = try UsageExportCodec.jsonData(report: report, exportedAt: exportedAt, options: exportOptions)
                case .csv:
                    data = UsageExportCodec.csvData(report: report, exportedAt: exportedAt, options: exportOptions)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                exportError = error.localizedDescription
            }
        }
    }

    private func money(_ total: UsageMoneyTotal) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = total.currency
        return formatter.string(from: total.amount as NSDecimalNumber) ?? "\(total.amount) \(total.currency)"
    }
}

private struct UsageMetricCard: View {
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption.weight(.medium))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value), \(detail)")
    }
}

private extension UsageAttributionDimension {
    var title: String {
        switch self {
        case .workspace: return "Workspace"
        case .activity: return "Activity"
        case .workType: return "Work Type"
        case .domain: return "Domain"
        case .integration: return "Integration"
        case .provider: return "Provider"
        case .model: return "Model"
        case .effort: return "Effort"
        case .serviceMode: return "Service Mode"
        }
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
            .accessibilityElement(children: .contain)
            .accessibilityLabel(usesWeeklyBuckets ? "Weekly active time chart" : "Daily active time chart")
            .accessibilityValue(accessibilitySummary)
        }
    }

    private var accessibilitySummary: String {
        buckets.map { "\($0.label): \(CodePulseFormatting.duration($0.duration))" }
            .joined(separator: "; ")
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
    let hasAnySessions: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: hasAnySessions ? "chart.bar.xaxis" : "clock")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(hasAnySessions ? "No Active Time in This Selection" : "No Sessions Yet")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        if !hasAnySessions {
            return "Start a session from the menu bar and your local activity will appear here."
        }
        if isAllProjects {
            return "There is no active session overlap in \(timeframe.title.lowercased()). Try another timeframe."
        }
        return "There is no active session overlap for \(projectTitle) in \(timeframe.title.lowercased()). Try another project or timeframe."
    }
}
