import Charts
import SwiftUI

struct InsightsView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var timeframe: InsightsTimeframe = .thisWeek

    private var summary: InsightsSummary {
        InsightsCalculator.summary(
            state: store.state,
            calendar: store.calendar,
            referenceDate: store.now,
            timeframe: timeframe
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(timeframe.title)
                            .font(.title2.weight(.semibold))
                        Text("Active time from saved and current local sessions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("Timeframe", selection: $timeframe) {
                        ForEach(InsightsTimeframe.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Insights timeframe")
                    .accessibilityValue(timeframe.title)
                }

                if summary.hasActivity {
                    SummaryHeader(summary: summary)
                    DailyActivityChart(activity: summary.dailyActivity, calendar: store.calendar)

                    HStack(alignment: .top, spacing: 24) {
                        BreakdownSection(
                            title: "Projects",
                            systemImage: "folder",
                            values: summary.projectBreakdown
                        )
                        BreakdownSection(
                            title: "Work Type",
                            systemImage: "square.grid.2x2",
                            values: summary.typeBreakdown
                        )
                    }
                } else {
                    InsightsEmptyState(timeframe: timeframe)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Insights")
        .frame(minWidth: 700, idealWidth: 760, minHeight: 560, idealHeight: 620)
    }
}

private struct SummaryHeader: View {
    let summary: InsightsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(CodePulseFormatting.duration(summary.totalDuration))
                .font(.system(size: 36, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .accessibilityLabel("\(summary.timeframe.title) active time")
                .accessibilityValue(CodePulseFormatting.duration(summary.totalDuration, includeSeconds: true))

            Text(comparisonText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Compared with the previous period")
                .accessibilityValue(comparisonText)
        }
    }

    private var comparisonText: String {
        if summary.comparisonDuration == 0, summary.totalDuration == 0 {
            return "No activity in the comparison period"
        }
        return "\(CodePulseFormatting.signedDuration(summary.difference)) \(comparisonLabel)"
    }

    private var comparisonLabel: String {
        switch summary.timeframe {
        case .thisWeek:
            return "vs last week"
        case .lastWeek:
            return "vs the week before"
        case .last30Days:
            return "vs the previous 30 days"
        }
    }
}

private struct DailyActivityChart: View {
    let activity: [DailyActivity]
    let calendar: Calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Daily Activity")
                .font(.headline)

            Chart(activity) { day in
                BarMark(
                    x: .value("Day", day.date, unit: .day),
                    y: .value("Hours", day.duration / 3_600)
                )
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text(CodePulseFormatting.fullDay(day.date, calendar: calendar)))
                .accessibilityValue(Text(CodePulseFormatting.duration(day.duration)))
            }
            .chartYAxisLabel("Hours")
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.weekday(.narrow))
                }
            }
            .frame(height: 190)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily active time chart")
            .accessibilityValue(accessibilitySummary)
        }
        .padding(.vertical, 2)
    }

    private var accessibilitySummary: String {
        activity.map { day in
            "\(CodePulseFormatting.fullDay(day.date, calendar: calendar)): \(CodePulseFormatting.duration(day.duration))"
        }.joined(separator: "; ")
    }
}

private struct BreakdownSection: View {
    let title: String
    let systemImage: String
    let values: [InsightsBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            if values.isEmpty {
                Text("No activity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(values) { value in
                        HStack(alignment: .firstTextBaseline) {
                            Text(value.label)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Text(CodePulseFormatting.duration(value.duration))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(value.label)
                        .accessibilityValue(CodePulseFormatting.duration(value.duration))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InsightsEmptyState: View {
    let timeframe: InsightsTimeframe

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No coding sessions \(timeframe == .thisWeek ? "this week" : "in this period") yet.")
                .font(.headline)
            Text("Start a session from the menu bar and your local activity will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
        .accessibilityElement(children: .combine)
    }
}
