import Foundation

struct InsightsMarkdownExporter {
    static func data(
        summary: InsightsSummary,
        projectTitle: String,
        calendar: Calendar
    ) -> Data {
        Data(markdown(summary: summary, projectTitle: projectTitle, calendar: calendar).utf8)
    }

    static func markdown(
        summary: InsightsSummary,
        projectTitle: String,
        calendar: Calendar
    ) -> String {
        var lines = [
            "# CodePulse Report",
            "**Period:** \(escape(summary.timeframe.title))",
            "**Project:** \(escape(projectTitle))"
        ]

        guard summary.hasActivity else {
            lines += ["", "No CodePulse activity was recorded for this selection."]
            appendGoalOutcomeInsights(&lines, summary.goalOutcomeInsights)
            appendFocusInsights(
                &lines,
                summary.focusInsights,
                comparison: summary.comparisonFocusInsights,
                calendar: calendar,
                timeframe: summary.timeframe
            )
            return output(lines)
        }

        lines += ["", "## Summary"]
        lines.append("- Active Time: \(CodePulseFormatting.duration(summary.totalDuration))")
        lines.append("- Sessions: \(summary.sessionCount)")
        lines.append("- Average Session: \(summary.sessionCount == 0 ? "—" : CodePulseFormatting.duration(summary.averageSessionDuration))")
        lines.append("- Longest Session: \(summary.sessionCount == 0 ? "—" : CodePulseFormatting.duration(summary.longestSessionDuration))")

        appendGoalOutcomeInsights(&lines, summary.goalOutcomeInsights)
        appendFocusInsights(
            &lines,
            summary.focusInsights,
            comparison: summary.comparisonFocusInsights,
            calendar: calendar,
            timeframe: summary.timeframe
        )

        appendDailyActivity(&lines, summary.dailyActivity, calendar: calendar)
        appendDurationBreakdown(&lines, title: "Work Type", columnTitle: "Type", values: summary.typeBreakdown)
        appendDurationBreakdown(&lines, title: "Projects", columnTitle: "Project", values: summary.projectBreakdown)
        appendDeveloperTools(&lines, summary.developerToolInsights)

        if summary.gitInsights.sessionsWithGitContext > 0 {
            appendGitActivity(&lines, summary.gitInsights)
        }
        if summary.githubInsights.sessionsWithGitHubContext > 0 {
            appendGitHubActivity(&lines, summary.githubInsights)
        }

        return output(lines)
    }

    private static func appendGoalOutcomeInsights(
        _ lines: inout [String],
        _ insights: GoalOutcomeInsights
    ) {
        lines += ["", "## Goal vs Actual"]
        guard insights.completedSessionCount > 0 else {
            lines.append("No completed sessions in this period yet.")
            return
        }

        lines.append("- Completed sessions: \(insights.completedSessionCount)")
        lines.append("- Goals set: \(insights.sessionsWithGoal)")
        lines.append("- Outcomes recorded: \(insights.sessionsWithOutcome)")
        lines.append("- Closed loop: \(insights.closedLoopCount)")
        if let rate = insights.closedLoopRate {
            lines.append("- Closed-loop rate: \(percentage(rate))")
        }
        lines.append("- Needs follow-up: \(insights.needsFollowUpCount)")
        if insights.outcomeOnlyCount > 0 {
            lines.append("- Outcome only: \(insights.outcomeOnlyCount)")
        }
        if insights.untrackedCount > 0 {
            lines.append("- Untracked: \(insights.untrackedCount)")
        }
    }

    private static func appendDailyActivity(
        _ lines: inout [String],
        _ activity: [DailyActivity],
        calendar: Calendar
    ) {
        guard !activity.isEmpty else { return }

        lines += [
            "",
            "## Daily Activity",
            "| Date | Active Time |",
            "| --- | ---: |"
        ]
        for value in activity {
            lines.append("| \(date(value.date, calendar: calendar)) | \(CodePulseFormatting.duration(value.duration)) |")
        }
    }

    private static func appendFocusInsights(
        _ lines: inout [String],
        _ insights: FocusInsights,
        comparison: FocusInsights?,
        calendar: Calendar,
        timeframe: InsightsTimeframe
    ) {
        lines += ["", "## Focus Patterns"]
        guard insights.focusBlockCount > 0 else {
            lines.append("No focus blocks in this period.")
            return
        }

        lines.append("- Focus blocks: \(insights.focusBlockCount)")
        var longest = "- Longest focus block: \(CodePulseFormatting.duration(insights.longestFocusBlockDuration))"
        if let comparison {
            longest += " (\(CodePulseFormatting.signedDuration(insights.longestFocusBlockDuration - comparison.longestFocusBlockDuration)) \(comparisonLabel(timeframe)))"
        }
        lines.append(longest)
        lines.append("- Average focus block: \(CodePulseFormatting.duration(insights.averageFocusBlockDuration))")
        lines.append("- Sustained focus blocks: \(insights.sustainedFocusBlockCount)")
        lines.append("- Sustained focus active time: \(CodePulseFormatting.duration(insights.sustainedFocusDuration))")

        if let share = insights.sustainedFocusShare {
            var shareLine = "- Sustained focus share: \(percentage(share))"
            if let comparisonShare = comparison?.sustainedFocusShare {
                let points = (share - comparisonShare) * 100
                let sign = points < 0 ? "−" : "+"
                shareLine += " (\(sign)\(Int(abs(points).rounded())) percentage points \(comparisonLabel(timeframe)))"
            }
            lines.append(shareLine)
        } else {
            lines.append("- Sustained focus share: —")
        }

        var switches = "- Project switches: \(insights.projectSwitchCount) within 15m"
        if let comparison {
            switches += " (\(comparison.projectSwitchCount) \(comparisonLabel(timeframe)))"
        }
        lines.append(switches)

        if let peakHour = insights.peakFocusHour {
            lines.append("- Peak focus hour: \(hourRange(peakHour, calendar: calendar))")
        }
        if let bestFocusDay = insights.bestFocusDay {
            lines.append("- Best focus day: \(date(bestFocusDay.date, calendar: calendar)) (\(CodePulseFormatting.duration(bestFocusDay.duration)) sustained focus)")
        }
    }

    private static func appendDurationBreakdown(
        _ lines: inout [String],
        title: String,
        columnTitle: String,
        values: [InsightsBreakdown]
    ) {
        guard !values.isEmpty else { return }

        lines += [
            "",
            "## \(title)",
            "| \(columnTitle) | Active Time |",
            "| --- | ---: |"
        ]
        for value in values {
            lines.append("| \(escape(value.label)) | \(CodePulseFormatting.duration(value.duration)) |")
        }
    }

    private static func appendDeveloperTools(
        _ lines: inout [String],
        _ insights: DeveloperToolInsights
    ) {
        lines += [
            "",
            "## Developer Tools",
            "| Metric | Sessions |",
            "| --- | ---: |",
            "| Codex | \(insights.sessionsWithCodex) |",
            "| OpenCode | \(insights.sessionsWithOpenCode) |",
            "| Both tools | \(insights.sessionsWithBoth) |",
            "| Any developer tool | \(insights.sessionsWithAnyTool) |",
            "| No developer tool | \(insights.sessionsWithNoTool) |"
        ]

        if !insights.modelBreakdown.isEmpty {
            lines += ["", "### Models", "| Model | Sessions |", "| --- | ---: |"]
            for value in insights.modelBreakdown {
                lines.append("| \(escape(value.label)) | \(value.count) |")
            }
        }

        if !insights.profileBreakdown.isEmpty {
            lines += ["", "### Profiles / Agents", "| Profile | Sessions |", "| --- | ---: |"]
            for value in insights.profileBreakdown {
                lines.append("| \(escape(value.label)) | \(value.count) |")
            }
        }
    }

    private static func appendGitActivity(_ lines: inout [String], _ insights: GitInsights) {
        lines += [
            "",
            "## Git Activity",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Sessions with Git context | \(insights.sessionsWithGitContext) |"
        ]
        if let value = insights.totalCommits {
            lines.append("| Commits | \(value) |")
        }
        if let value = insights.totalFilesChanged {
            lines.append("| Files Changed | \(value) |")
        }
        if let value = insights.totalInsertions {
            lines.append("| Insertions | +\(value) |")
        }
        if let value = insights.totalDeletions {
            lines.append("| Deletions | −\(value) |")
        }
    }

    private static func appendGitHubActivity(_ lines: inout [String], _ insights: GitHubInsights) {
        lines += [
            "",
            "## GitHub Activity",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Sessions with GitHub context | \(insights.sessionsWithGitHubContext) |",
            "| Sessions with pull requests | \(insights.sessionsWithPullRequest) |",
            "| Repositories | \(insights.uniqueRepositories) |",
            "| Pull requests | \(insights.uniquePullRequests) |"
        ]

        guard !insights.repositoryBreakdown.isEmpty else { return }
        lines += ["", "### Repository Time", "| Repository | Active Time |", "| --- | ---: |"]
        for value in insights.repositoryBreakdown {
            lines.append("| \(escape(value.label)) | \(CodePulseFormatting.duration(value.duration)) |")
        }
    }

    private static func date(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func percentage(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func comparisonLabel(_ timeframe: InsightsTimeframe) -> String {
        switch timeframe {
        case .thisWeek: return "vs last week"
        case .lastWeek: return "vs the week before"
        case .thisMonth: return "vs last month"
        case .last30Days: return "vs the previous 30 days"
        case .last90Days: return "vs the previous 90 days"
        case .allTime: return "vs comparison"
        }
    }

    private static func hourRange(_ hour: Int, calendar: Calendar) -> String {
        let start = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: hour)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: 2000, month: 1, day: 1, hour: (hour + 1) % 24)) ?? .distantPast
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

    private static func escape(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        for character in ["\\", "|", "*", "_", "`", "[", "]"] {
            result = result.replacingOccurrences(of: character, with: "\\\(character)")
        }
        return result
    }

    private static func output(_ lines: [String]) -> String {
        lines.joined(separator: "\n") + "\n"
    }
}
