import Foundation

/// Pure, deterministic prose for the derived Project Outcomes surface.
/// Counts and durations are the only inputs; user-authored text is rendered by
/// the presentation surface separately and is never interpreted here.
enum ProjectOutcomeNarrativeFormatter {
    static let sectionCaption =
        "Project Outcomes uses only the goals and outcomes you recorded. CodePulse does not decide whether work succeeded, failed, finished, or was abandoned."

    static func narrative(for insights: ProjectOutcomeInsights) -> String {
        var sentences: [String] = [
            sessionSentence(
                count: insights.completedSessionCount,
                duration: insights.completedActiveDuration
            )
        ]

        let goalPhrase = goalPhrase(insights.sessionsWithGoal)
        let outcomePhrase = outcomePhrase(insights.sessionsWithOutcome)
        if insights.sessionsWithGoal > 0, insights.sessionsWithOutcome > 0 {
            sentences.append("\(goalPhrase) and \(outcomePhrase).")
        } else {
            sentences.append("\(goalPhrase).")
            sentences.append("\(outcomePhrase).")
        }

        if insights.sessionsWithGoal > 0 {
            sentences.append(goalStatePhrase(
                closedLoopCount: insights.closedLoopCount,
                needsFollowUpCount: insights.needsFollowUpCount
            ) + ".")
        }

        if insights.outcomeOnlyCount > 0 {
            let outcomeLabel = countLabel(
                insights.outcomeOnlyCount,
                singular: "outcome",
                plural: "outcomes"
            )
            sentences.append(
                "\(outcomeLabel) \(insights.outcomeOnlyCount == 1 ? "was" : "were") recorded without \(insights.outcomeOnlyCount == 1 ? "a goal" : "goals")."
            )
        }

        if insights.untrackedCount > 0 {
            sentences.append(
                "\(countLabel(insights.untrackedCount, singular: "completed session", plural: "completed sessions")) had neither a goal nor outcome."
            )
        }

        return sentences.joined(separator: " ")
    }

    private static func sessionSentence(count: Int, duration: TimeInterval) -> String {
        let session = count == 1 ? "session" : "sessions"
        let verb = count == 1 ? "accounts" : "account"
        return "\(count) completed \(session) \(verb) for \(CodePulseFormatting.duration(duration)) of active time."
    }

    private static func goalPhrase(_ count: Int) -> String {
        guard count > 0 else { return "No goals were set" }
        return count == 1 ? "1 goal was set" : "\(count) goals were set"
    }

    private static func outcomePhrase(_ count: Int) -> String {
        guard count > 0 else { return "No outcomes were recorded" }
        return count == 1 ? "1 outcome was recorded" : "\(count) outcomes were recorded"
    }

    private static func goalStatePhrase(closedLoopCount: Int, needsFollowUpCount: Int) -> String {
        switch (closedLoopCount, needsFollowUpCount) {
        case (0, let followUp) where followUp > 0:
            return "\(countLabel(followUp, singular: "goal session", plural: "goal sessions")) need follow-up"
        case (let closed, 0) where closed > 0:
            return "\(countLabel(closed, singular: "goal session", plural: "goal sessions")) \(closed == 1 ? "is" : "are") closed loop"
        default:
            let closedVerb = closedLoopCount == 1 ? "is" : "are"
            let followUpVerb = needsFollowUpCount == 1 ? "needs" : "need"
            return "\(countLabel(closedLoopCount, singular: "goal session", plural: "goal sessions")) \(closedVerb) closed loop; \(countLabel(needsFollowUpCount, singular: "goal session", plural: "goal sessions")) \(followUpVerb) follow-up"
        }
    }

    private static func countLabel(_ count: Int, singular: String, plural: String) -> String {
        "\(count) \(count == 1 ? singular : plural)"
    }
}
