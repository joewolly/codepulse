import Foundation

struct DigestNotificationContent: Equatable {
    let title: String
    let body: String
}

/// Deterministically turns a structured digest summary into notification copy.
/// No LLM, no subjective judgments, no user-entered text beyond project names.
enum DigestComposer {
    static func content(summary: DigestSummary, calendar: Calendar) -> DigestNotificationContent {
        let title = "Your CodePulse \(summary.period.kind.periodLabel)"

        guard summary.hasActivity else {
            let body: String
            switch summary.period.kind {
            case .daily:
                body = "No CodePulse activity was recorded yesterday."
            case .weekly:
                body = "No CodePulse activity was recorded last week."
            }
            return DigestNotificationContent(title: title, body: body)
        }

        var sentences: [String] = []

        var first = "\(CodePulseFormatting.duration(summary.totalActiveTime)) across "
            + "\(summary.sessionCount) \(summary.sessionCount == 1 ? "session" : "sessions")"
        if let delta = summary.activeTimeDelta, summary.period.hasComparison {
            if delta > 0 {
                first += ", +\(CodePulseFormatting.duration(delta)) from the previous \(summary.period.kind.periodLabel)"
            } else if delta < 0 {
                first += ", −\(CodePulseFormatting.duration(abs(delta))) from the previous \(summary.period.kind.periodLabel)"
            } else if let sessionDelta = summary.sessionCountDelta, sessionDelta != 0 {
                appendSessionDelta(&first, sessionDelta, periodLabel: summary.period.kind.periodLabel)
            } else {
                first += ", same active time as the previous \(summary.period.kind.periodLabel)"
            }
        } else if let sessionDelta = summary.sessionCountDelta, summary.period.hasComparison, sessionDelta != 0 {
            appendSessionDelta(&first, sessionDelta, periodLabel: summary.period.kind.periodLabel)
        }
        first += "."
        sentences.append(first)

        if let topProject = summary.topProject {
            sentences.append("\(topProject.label) was your top project at \(CodePulseFormatting.duration(topProject.duration)).")
        }
        if let topType = summary.topType {
            sentences.append("\(topType.label) was your top work type at \(CodePulseFormatting.duration(topType.duration)).")
        }
        if summary.developerToolParticipation.hasParticipation {
            sentences.append(participationSentence(summary.developerToolParticipation))
        }

        return DigestNotificationContent(title: title, body: sentences.joined(separator: " "))
    }

    private static func appendSessionDelta(_ sentence: inout String, _ delta: Int, periodLabel: String) {
        let sessionWord = abs(delta) == 1 ? "session" : "sessions"
        if delta > 0 {
            sentence += ", \(delta) more \(sessionWord) than the previous \(periodLabel)"
        } else {
            sentence += ", \(abs(delta)) fewer \(sessionWord) than the previous \(periodLabel)"
        }
    }

    private static func participationSentence(_ participation: DigestDeveloperToolParticipation) -> String {
        if participation.sessionsWithCodex > 0, participation.sessionsWithOpenCode > 0 {
            return "Codex and OpenCode participated in \(participation.sessionsWithCodex) and "
                + "\(participation.sessionsWithOpenCode) sessions, respectively."
        }
        if participation.sessionsWithCodex > 0 {
            return "Codex participated in \(participation.sessionsWithCodex) "
                + "\(participation.sessionsWithCodex == 1 ? "session" : "sessions")."
        }
        return "OpenCode participated in \(participation.sessionsWithOpenCode) "
            + "\(participation.sessionsWithOpenCode == 1 ? "session" : "sessions")."
    }
}
