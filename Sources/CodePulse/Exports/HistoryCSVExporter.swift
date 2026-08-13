import Foundation

struct HistoryCSVExporter {
    static let columns = [
        "Session ID",
        "Started At",
        "Ended At",
        "Active Seconds",
        "Paused Seconds",
        "Project",
        "Session Type",
        "Goal",
        "Outcome",
        "Git Branch Start",
        "Git Branch End",
        "Git Commits",
        "Git Files Changed",
        "Git Insertions",
        "Git Deletions",
        "GitHub Repository",
        "Pull Request Number",
        "Pull Request Title",
        "Pull Request State",
        "Developer Tools",
        "Models",
        "Profiles"
    ]

    static func data(for sessions: [CompletedSession]) -> Data {
        Data(csv(for: sessions).utf8)
    }

    static func csv(for sessions: [CompletedSession]) -> String {
        let rows = [columns] + sessions.map(row(for:))
        let serializedRows = rows.map { row in
            row.map(escape).joined(separator: ",")
        }
        return serializedRows.joined(separator: "\r\n") + "\r\n"
    }

    private static func row(for session: CompletedSession) -> [String] {
        let totalSeconds = wholeSeconds(session.endedAt.timeIntervalSince(session.startedAt))
        let activeSeconds = min(totalSeconds, wholeSeconds(session.activeDuration))
        // Existing CodePulse formatting truncates non-negative durations. Use
        // that same rule and derive paused time from the total span so the
        // exported integer durations always add back to the span.
        let pausedSeconds = max(0, totalSeconds - activeSeconds)
        let git = session.gitContext
        let pullRequest = session.githubContext?.pullRequest

        return [
            session.id.uuidString,
            timestamp(session.startedAt),
            timestamp(session.endedAt),
            String(activeSeconds),
            String(pausedSeconds),
            session.projectName ?? "",
            session.type.title,
            session.goal ?? "",
            session.outcome ?? "",
            branchName(git?.branchAtStart, detached: git?.startWasDetached) ?? "",
            branchName(git?.branchAtEnd, detached: git?.endWasDetached) ?? "",
            git.map { $0.commitCount.map(String.init) ?? "" } ?? "",
            git.map { $0.filesChanged.map(String.init) ?? "" } ?? "",
            git.map { $0.insertions.map(String.init) ?? "" } ?? "",
            git.map { $0.deletions.map(String.init) ?? "" } ?? "",
            session.githubContext?.repositoryNameWithOwner ?? "",
            pullRequest.map { String($0.number) } ?? "",
            pullRequest?.title ?? "",
            pullRequest?.statusDisplay ?? "",
            joinedUnique(session.developerToolContexts.map { $0.tool.title }),
            joinedUnique(session.developerToolContexts.compactMap(\.model)),
            joinedUnique(session.developerToolContexts.compactMap(\.profile))
        ]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func wholeSeconds(_ duration: TimeInterval) -> Int {
        max(0, Int(max(0, duration).rounded(.down)))
    }

    private static func branchName(_ name: String?, detached: Bool?) -> String? {
        if detached == true { return "Detached HEAD" }
        return name
    }

    private static func joinedUnique(_ values: [String]) -> String {
        var seen = Set<String>()
        let unique = values.compactMap { value -> String? in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
        return unique.joined(separator: "; ")
    }

    private static func escape(_ field: String) -> String {
        let trimmed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeField: String
        if let first = trimmed.first, "=+-@".contains(first) {
            safeField = "'\(field)"
        } else {
            safeField = field
        }
        let escaped = safeField.replacingOccurrences(of: "\"", with: "\"\"")
        let needsQuotes = safeField.contains { character in
            character == "," || character == "\"" || character == "\r" || character == "\n"
        }
        return needsQuotes ? "\"\(escaped)\"" : escaped
    }
}
