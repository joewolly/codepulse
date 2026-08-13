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
            return output(lines)
        }

        lines += ["", "## Summary"]
        lines.append("- Active Time: \(CodePulseFormatting.duration(summary.totalDuration))")
        lines.append("- Sessions: \(summary.sessionCount)")
        lines.append("- Average Session: \(summary.sessionCount == 0 ? "—" : CodePulseFormatting.duration(summary.averageSessionDuration))")
        lines.append("- Longest Session: \(summary.sessionCount == 0 ? "—" : CodePulseFormatting.duration(summary.longestSessionDuration))")

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
