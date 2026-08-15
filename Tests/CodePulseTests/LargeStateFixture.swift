import CodePulseIntegration
import Foundation
@testable import CodePulse

enum LargeStateFixture {
    static let referenceDate = Date(timeIntervalSince1970: 1_750_000_000)
    static let longRecoveryError = "Recovery error: " + String(repeating: "The selected backup could not be verified. ", count: 18)
    static let longRecoveryPath = "/tmp/CodePulse-M3-long-content/" + String(repeating: "nested-folder/", count: 12) + "state.json"

    static func makeState(
        sessionCount: Int,
        referenceDate: Date = Self.referenceDate
    ) -> AppState {
        let projectCount = 8
        let projects = (0..<projectCount).map { index in
            ProjectRecord(
                id: uuid(10_000 + index),
                name: "Fixture Project \(index)",
                folderPath: "/tmp/CodePulse-M3-fixture/project-\(index)",
                createdAt: referenceDate.addingTimeInterval(-Double((projectCount - index) * 86_400))
            )
        }

        let sessions = (0..<sessionCount).map { index in
            makeSession(index: index, projectCount: projectCount, referenceDate: referenceDate)
        }

        var settings = CodePulseSettings()
        settings.hasCompletedOnboarding = true
        return AppState(
            projects: projects,
            completedSessions: sessions,
            settings: settings
        )
    }

    static func makeLongContentState(
        referenceDate: Date = Self.referenceDate
    ) -> AppState {
        let projectID = uuid(20_000)
        let projectName = String(repeating: "Project-", count: 28) + "Long Name"
        let goal = String(repeating: "Goal detail with valid long content. ", count: 110).prefix(4_096)
        let outcome = String(repeating: "Outcome detail with valid long content. ", count: 110).prefix(4_096)
        let presetID = uuid(20_001)
        let ruleID = uuid(20_002)
        let sessionStart = referenceDate.addingTimeInterval(-3_600)
        let sessionEnd = referenceDate.addingTimeInterval(-1_800)

        let project = ProjectRecord(
            id: projectID,
            name: String(projectName.prefix(200)),
            folderPath: "/tmp/CodePulse-M3-long-content/project",
            createdAt: referenceDate.addingTimeInterval(-86_400)
        )
        let git = GitSessionContext(
            repositoryRoot: "/tmp/CodePulse-M3-long-content/project",
            branchAtStart: String(repeating: "feature/long-branch-", count: 12),
            startHeadSHA: String(repeating: "a", count: 40),
            startWasDetached: false,
            branchAtEnd: String(repeating: "feature/long-branch-", count: 12),
            endHeadSHA: String(repeating: "b", count: 40),
            endWasDetached: false,
            commitCount: 4,
            filesChanged: 12,
            insertions: 240,
            deletions: 80
        )
        let github = GitHubSessionContext(
            repositoryNameWithOwner: "fixture-owner/" + String(repeating: "repository-name-", count: 10),
            repositoryURL: "https://github.com/fixture-owner/long-repository",
            repositoryIsPrivate: true,
            pullRequest: GitHubPullRequestSnapshot(
                number: 42,
                title: String(repeating: "Pull request title with valid long content. ", count: 12),
                state: .open,
                isDraft: false,
                url: "https://github.com/fixture-owner/long-repository/pull/42",
                baseBranch: "main",
                headBranch: String(repeating: "feature/long-branch-", count: 12)
            )
        )
        let developerContext = DeveloperToolSessionContext(
            id: uuid(20_003),
            tool: .codex,
            externalSessionID: "long-content-developer-session",
            workingDirectory: "/tmp/CodePulse-M3-long-content/project",
            firstActivityAt: sessionStart,
            lastActivityAt: sessionEnd,
            model: String(repeating: "model-name-", count: 28),
            profile: String(repeating: "profile-agent-", count: 18),
            eventCount: 12,
            endedAt: sessionEnd
        )
        let session = CompletedSession(
            id: uuid(20_004),
            projectID: projectID,
            projectName: project.name,
            type: .coding,
            goal: String(goal),
            outcome: String(outcome),
            startedAt: sessionStart,
            endedAt: sessionEnd,
            pauseIntervals: [
                PauseInterval(
                    id: uuid(20_005),
                    startedAt: sessionStart.addingTimeInterval(300),
                    endedAt: sessionStart.addingTimeInterval(420)
                )
            ],
            gitContext: git,
            githubContext: github,
            developerToolContexts: [developerContext]
        )
        let preset = SessionPreset(
            id: presetID,
            name: String((String(repeating: "Preset-", count: 30) + "Long Name").prefix(200)),
            projectID: projectID,
            sessionType: .coding,
            goal: String(goal.prefix(4_096))
        )
        let rule = SessionAutomationRule(
            id: ruleID,
            name: String((String(repeating: "Automation Rule-", count: 14) + "Long Name").prefix(200)),
            isEnabled: true,
            trigger: .developerTool(.codex),
            presetID: presetID,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 60
        )
        var settings = CodePulseSettings(automationEnabled: true)
        settings.hasCompletedOnboarding = true
        return AppState(
            projects: [project],
            completedSessions: [session],
            settings: settings,
            sessionPresets: [preset],
            automationRules: [rule]
        )
    }

    static func encodedData(for state: AppState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    static func decodedState(from data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: data)
    }

    static func uuid(_ seed: Int) -> UUID {
        let raw = String(seed, radix: 16)
        let suffix = String(repeating: "0", count: max(0, 12 - raw.count)) + raw
        return UUID(uuidString: "00000000-0000-4000-8000-\(String(suffix.suffix(12)))")!
    }

    private static func makeSession(
        index: Int,
        projectCount: Int,
        referenceDate: Date
    ) -> CompletedSession {
        let dayOffset = index % 730
        let withinDay = 7_200 + (index % 43_200)
        let startedAt = referenceDate
            .addingTimeInterval(-Double(dayOffset * 86_400))
            .addingTimeInterval(-Double(withinDay))
        let span = 600 + (index % 5_400)
        let endedAt = startedAt.addingTimeInterval(Double(span))
        let hasPause = index % 7 == 0
        let pauseStart = startedAt.addingTimeInterval(Double(span / 3))
        let pauseEnd = pauseStart.addingTimeInterval(Double(min(90, max(30, span / 12))))
        let projectIndex = index % (projectCount + 1)
        let projectID = projectIndex == projectCount ? nil : uuid(10_000 + projectIndex)
        let projectName = projectIndex == projectCount ? nil : "Fixture Project \(projectIndex)"

        let git: GitSessionContext? = index % 3 == 0 ? GitSessionContext(
            repositoryRoot: "/tmp/CodePulse-M3-fixture/project-\(projectIndex)",
            branchAtStart: "feature/fixture-\(index % 17)",
            startHeadSHA: String(repeating: "a", count: 40),
            startWasDetached: false,
            branchAtEnd: "feature/fixture-\(index % 17)",
            endHeadSHA: String(repeating: "b", count: 40),
            endWasDetached: false,
            commitCount: index % 8,
            filesChanged: index % 24,
            insertions: index % 300,
            deletions: index % 120
        ) : nil

        let github: GitHubSessionContext? = index % 5 == 0 ? GitHubSessionContext(
            repositoryNameWithOwner: "fixture-owner/project-\(projectIndex)",
            repositoryURL: "https://github.com/fixture-owner/project-\(projectIndex)",
            repositoryIsPrivate: index % 2 == 0,
            pullRequest: index % 2 == 0 ? GitHubPullRequestSnapshot(
                number: index + 1,
                title: "Fixture pull request \(index)",
                state: index % 4 == 0 ? .merged : .open,
                isDraft: index % 6 == 0,
                url: "https://github.com/fixture-owner/project-\(projectIndex)/pull/\(index + 1)",
                baseBranch: "main",
                headBranch: "feature/fixture-\(index % 17)"
            ) : nil
        ) : nil

        let developerContexts: [DeveloperToolSessionContext] = index % 4 == 0 ? [
            DeveloperToolSessionContext(
                id: uuid(100_000 + index),
                tool: index % 8 == 0 ? .opencode : .codex,
                externalSessionID: "fixture-developer-\(index)",
                workingDirectory: "/tmp/CodePulse-M3-fixture/project-\(projectIndex)",
                firstActivityAt: startedAt,
                lastActivityAt: endedAt,
                model: "fixture-model-\(index % 4)",
                profile: "fixture-profile-\(index % 3)",
                eventCount: 1 + (index % 12),
                endedAt: endedAt
            )
        ] : []

        return CompletedSession(
            id: uuid(index + 1),
            projectID: projectID,
            projectName: projectName,
            type: SessionType.allCases[index % SessionType.allCases.count],
            goal: index % 2 == 0 ? "Fixture goal \(index)" : nil,
            outcome: index % 3 == 0 ? "Fixture outcome \(index)" : nil,
            startedAt: startedAt,
            endedAt: endedAt,
            pauseIntervals: hasPause ? [
                PauseInterval(
                    id: uuid(200_000 + index),
                    startedAt: pauseStart,
                    endedAt: pauseEnd
                )
            ] : [],
            gitContext: git,
            githubContext: github,
            developerToolContexts: developerContexts
        )
    }
}
