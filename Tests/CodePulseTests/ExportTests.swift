import Foundation
import CodePulseIntegration
import XCTest
@testable import CodePulse

@MainActor
final class ExportTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()

    private let alphaProjectID = UUID(uuidString: "00000000-0000-0000-0000-00000000a001")!

    func testHistorySessionsAreCanonicalMatchesForAllFiltersAndStableTies() {
        let reference = date(year: 2024, month: 4, day: 20, hour: 12)
        let sessions = historyFixture(reference: reference)
        let persistence = ExportTestPersistence(AppState(completedSessions: sessions))
        let store = SessionStore(
            persistence: persistence,
            clock: ExportTestClock(reference),
            calendar: calendar,
            automaticallyRefresh: false
        )

        let id = { (value: Int) in UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))! }
        let cases: [(String, HistoryQuery, [UUID])] = [
            ("all", HistoryQuery(), [id(1), id(3), id(5), id(6), id(2), id(4)]),
            ("project", HistoryQuery(project: .projectID(alphaProjectID)), [id(1)]),
            ("no project", HistoryQuery(project: .noProject), [id(3), id(5), id(6)]),
            ("historical name", HistoryQuery(project: .historicalName("Legacy Name")), [id(4)]),
            ("date", HistoryQuery(date: .today), [id(1), id(3), id(5), id(6)]),
            ("type", HistoryQuery(type: .debugging), [id(2)]),
            ("git", HistoryQuery(git: .gitSessions), [id(1), id(4)]),
            ("non-git", HistoryQuery(git: .nonGitSessions), [id(3), id(5), id(6), id(2)]),
            ("Codex", HistoryQuery(developerTool: .codex), [id(1), id(4)]),
            ("OpenCode", HistoryQuery(developerTool: .openCode), [id(2), id(4)]),
            ("no tool", HistoryQuery(developerTool: .noDeveloperTool), [id(3), id(5), id(6)]),
            ("search", HistoryQuery(searchText: "  QUOTED "), [id(1)]),
            (
                "combined",
                HistoryQuery(
                    searchText: "comma",
                    project: .projectID(alphaProjectID),
                    date: .today,
                    type: .coding,
                    git: .gitSessions,
                    developerTool: .codex
                ),
                [id(1)]
            )
        ]

        for (label, query, expectedIDs) in cases {
            let canonical = store.historySessions(for: query, referenceDate: reference)
            XCTAssertEqual(canonical.map(\.id), expectedIDs, label)

            let grouped = store.historyGroups(for: query, referenceDate: reference)
            XCTAssertEqual(grouped.flatMap(\.sessions).map(\.id), expectedIDs, label)
        }

        XCTAssertEqual(persistence.saveCount, 0)
        XCTAssertEqual(persistence.state, AppState(completedSessions: sessions))
    }

    func testHistoryCSVHasStableSchemaAndEscapesRFC4180Fields() {
        let start = date(year: 2024, month: 4, day: 20, hour: 10)
        let context = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "external-codex-id",
            workingDirectory: "/private/worktree",
            firstActivityAt: start,
            lastActivityAt: start.addingTimeInterval(100),
            model: "GPT-5.6",
            profile: "Builder"
        )
        let duplicateContext = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "another-external-id",
            workingDirectory: "/private/worktree-2",
            firstActivityAt: start,
            lastActivityAt: start.addingTimeInterval(100),
            model: " GPT-5.6 ",
            profile: "Builder"
        )
        let openCodeContext = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "external-opencode-id",
            workingDirectory: "/private/worktree-3",
            firstActivityAt: start,
            lastActivityAt: start.addingTimeInterval(100),
            model: "DeepSeek",
            profile: "Reviewer"
        )
        let pullRequest = GitHubPullRequestSnapshot(
            number: 7,
            title: "Review, \"quoted\"",
            state: .open,
            isDraft: true,
            url: "https://github.com/owner/repository/pull/7"
        )
        let session = CompletedSession(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            projectID: alphaProjectID,
            projectName: "Café 🚀",
            type: .coding,
            goal: "Ship, \"quoted\"\r\nnext",
            outcome: "First\rSecond\n🙂",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_720),
            pauseIntervals: [
                PauseInterval(startedAt: start.addingTimeInterval(1_800), endedAt: start.addingTimeInterval(1_920))
            ],
            gitContext: GitSessionContext(
                repositoryRoot: "/private/repository-root",
                branchAtStart: "main",
                startWasDetached: false,
                branchAtEnd: "feature/export",
                endWasDetached: false,
                commitCount: 2,
                filesChanged: 3,
                insertions: 12,
                deletions: 4
            ),
            githubContext: GitHubSessionContext(
                repositoryNameWithOwner: "owner/repository",
                repositoryURL: "https://github.com/owner/repository",
                pullRequest: pullRequest
            ),
            developerToolContexts: [context, duplicateContext, openCodeContext]
        )

        let csv = HistoryCSVExporter.csv(for: [session])
        let expected = [
            HistoryCSVExporter.columns.joined(separator: ","),
            "00000000-0000-0000-0000-000000000010,2024-04-20T10:00:00Z,2024-04-20T11:02:00Z,3600,120,Café 🚀,Coding,\"Ship, \"\"quoted\"\"\r\nnext\",\"First\rSecond\n🙂\",main,feature/export,2,3,12,4,owner/repository,7,\"Review, \"\"quoted\"\"\",Draft · Open,Codex; OpenCode,GPT-5.6; DeepSeek,Builder; Reviewer"
        ].joined(separator: "\r\n") + "\r\n"

        XCTAssertEqual(csv, expected)
        XCTAssertEqual(Data(csv.utf8), HistoryCSVExporter.data(for: [session]))
        XCTAssertTrue(csv.contains("\"Ship, \"\"quoted\"\"\r\nnext\""))
        XCTAssertTrue(csv.contains("\"First\rSecond\n🙂\""))
        XCTAssertFalse(csv.contains("external-codex-id"))
        XCTAssertFalse(csv.contains("/private/repository-root"))
    }

    func testHistoryCSVUsesIntegerDurationsThatReconcileToSpan() {
        let start = date(year: 2024, month: 4, day: 20, hour: 8)
        let sessions = [
            CompletedSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000021")!,
                projectID: nil,
                projectName: nil,
                goal: "no pause",
                outcome: nil,
                startedAt: start,
                endedAt: start.addingTimeInterval(61.9),
                pauseIntervals: []
            ),
            CompletedSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000022")!,
                projectID: nil,
                projectName: nil,
                goal: "one pause",
                outcome: nil,
                startedAt: start,
                endedAt: start.addingTimeInterval(100.9),
                pauseIntervals: [
                    PauseInterval(startedAt: start.addingTimeInterval(20.1), endedAt: start.addingTimeInterval(50.1))
                ]
            ),
            CompletedSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000023")!,
                projectID: nil,
                projectName: nil,
                goal: "multiple pauses",
                outcome: nil,
                startedAt: start,
                endedAt: start.addingTimeInterval(200.9),
                pauseIntervals: [
                    PauseInterval(startedAt: start.addingTimeInterval(20.1), endedAt: start.addingTimeInterval(40.1)),
                    PauseInterval(startedAt: start.addingTimeInterval(100.2), endedAt: start.addingTimeInterval(130.2))
                ]
            ),
            CompletedSession(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000024")!,
                projectID: nil,
                projectName: nil,
                goal: "boundary pause",
                outcome: nil,
                startedAt: start,
                endedAt: start.addingTimeInterval(10),
                pauseIntervals: [
                    PauseInterval(startedAt: start, endedAt: start.addingTimeInterval(4.9))
                ]
            )
        ]

        let rows = HistoryCSVExporter.csv(for: sessions)
            .components(separatedBy: "\r\n")
            .dropLast()
            .dropFirst()
            .map { $0.components(separatedBy: ",") }

        XCTAssertEqual(rows.map { "\($0[3]):\($0[4])" }, ["61:0", "70:30", "150:50", "5:5"])
        for (row, session) in zip(rows, sessions) {
            let span = Int(session.endedAt.timeIntervalSince(session.startedAt).rounded(.down))
            XCTAssertEqual(Int(row[3])! + Int(row[4])!, span)
        }
    }

    func testHistoryCSVEmptyResultIsHeaderOnlyAndUTF8WithoutBOM() {
        let data = HistoryCSVExporter.data(for: [])
        let expected = Data((HistoryCSVExporter.columns.joined(separator: ",") + "\r\n").utf8)

        XCTAssertEqual(data, expected)
        XCTAssertFalse(data.starts(with: [0xEF, 0xBB, 0xBF]))
        XCTAssertEqual(String(data: data, encoding: .utf8), String(data: expected, encoding: .utf8))
    }

    func testMarkdownReportMatchesProvidedSummaryFixture() {
        let summary = summaryFixture()
        let report = InsightsMarkdownExporter.markdown(
            summary: summary,
            projectTitle: "CodePulse *Report*",
            calendar: calendar
        )
        let expected = [
            "# CodePulse Report",
            "**Period:** This Month",
            "**Project:** CodePulse \\*Report\\*",
            "",
            "## Summary",
            "- Active Time: 18h 42m",
            "- Sessions: 31",
            "- Average Session: 36m",
            "- Longest Session: 2h 08m",
            "",
            "## Daily Activity",
            "| Date | Active Time |",
            "| --- | ---: |",
            "| 2024-08-10 | 2h 14m |",
            "| 2024-08-11 | 3h 02m |",
            "",
            "## Work Type",
            "| Type | Active Time |",
            "| --- | ---: |",
            "| Coding | 12h 04m |",
            "| Debugging | 6h 38m |",
            "",
            "## Projects",
            "| Project | Active Time |",
            "| --- | ---: |",
            "| CodePulse \\| Docs West | 12h 04m |",
            "| Café | 6h 38m |",
            "",
            "## Developer Tools",
            "| Metric | Sessions |",
            "| --- | ---: |",
            "| Codex | 3 |",
            "| OpenCode | 2 |",
            "| Both tools | 1 |",
            "| Any developer tool | 4 |",
            "| No developer tool | 27 |",
            "",
            "### Models",
            "| Model | Sessions |",
            "| --- | ---: |",
            "| GPT\\_5 | 3 |",
            "| DeepSeek | 2 |",
            "",
            "### Profiles / Agents",
            "| Profile | Sessions |",
            "| --- | ---: |",
            "| Builder | 3 |",
            "| Reviewer \\| Safe | 1 |",
            "",
            "## Git Activity",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Sessions with Git context | 5 |",
            "| Commits | 7 |",
            "| Files Changed | 9 |",
            "| Insertions | +42 |",
            "| Deletions | −8 |",
            "",
            "## GitHub Activity",
            "| Metric | Value |",
            "| --- | ---: |",
            "| Sessions with GitHub context | 4 |",
            "| Sessions with pull requests | 3 |",
            "| Repositories | 2 |",
            "| Pull requests | 3 |",
            "",
            "### Repository Time",
            "| Repository | Active Time |",
            "| --- | ---: |",
            "| owner/repository | 5h 00m |",
            "| owner/other | 2h 00m |"
        ].joined(separator: "\n") + "\n"

        XCTAssertEqual(report, expected)
        XCTAssertEqual(Data(report.utf8), InsightsMarkdownExporter.data(summary: summary, projectTitle: "CodePulse *Report*", calendar: calendar))
    }

    func testMarkdownReportOmitsOptionalGitAndGitHubSectionsWhenContextAbsent() {
        let summary = summaryFixture()
        let withoutOptionalContext = InsightsSummary(
            timeframe: summary.timeframe,
            interval: summary.interval,
            comparisonInterval: summary.comparisonInterval,
            totalDuration: summary.totalDuration,
            comparisonDuration: summary.comparisonDuration,
            sessionCount: summary.sessionCount,
            comparisonSessionCount: summary.comparisonSessionCount,
            averageSessionDuration: summary.averageSessionDuration,
            longestSessionDuration: summary.longestSessionDuration,
            projectBreakdown: summary.projectBreakdown,
            typeBreakdown: summary.typeBreakdown,
            dailyActivity: summary.dailyActivity,
            developerToolInsights: summary.developerToolInsights,
            gitInsights: GitInsights(
                sessionsWithGitContext: 0,
                totalCommits: nil,
                totalFilesChanged: nil,
                totalInsertions: nil,
                totalDeletions: nil
            ),
            githubInsights: GitHubInsights(
                sessionsWithGitHubContext: 0,
                sessionsWithPullRequest: 0,
                uniqueRepositories: 0,
                uniquePullRequests: 0,
                repositoryBreakdown: []
            )
        )

        let report = InsightsMarkdownExporter.markdown(
            summary: withoutOptionalContext,
            projectTitle: "All Projects",
            calendar: calendar
        )

        XCTAssertFalse(report.contains("## Git Activity"))
        XCTAssertFalse(report.contains("## GitHub Activity"))
        XCTAssertTrue(report.contains("## Developer Tools"))
    }

    func testMarkdownReportZeroActivityIsUsefulAndHasNoZeroSections() {
        let summary = InsightsSummary(
            timeframe: .thisWeek,
            interval: DateInterval(start: date(year: 2024, month: 8, day: 12), duration: 86_400),
            comparisonInterval: DateInterval(start: date(year: 2024, month: 8, day: 5), duration: 86_400),
            totalDuration: 0,
            comparisonDuration: 0,
            sessionCount: 0,
            comparisonSessionCount: 0,
            averageSessionDuration: 0,
            longestSessionDuration: 0,
            projectBreakdown: [],
            typeBreakdown: [],
            dailyActivity: [],
            developerToolInsights: DeveloperToolInsights(
                sessionsWithCodex: 0,
                sessionsWithOpenCode: 0,
                sessionsWithBoth: 0,
                sessionsWithAnyTool: 0,
                sessionsWithNoTool: 0,
                modelBreakdown: [],
                profileBreakdown: []
            ),
            gitInsights: GitInsights(
                sessionsWithGitContext: 0,
                totalCommits: nil,
                totalFilesChanged: nil,
                totalInsertions: nil,
                totalDeletions: nil
            ),
            githubInsights: GitHubInsights(
                sessionsWithGitHubContext: 0,
                sessionsWithPullRequest: 0,
                uniqueRepositories: 0,
                uniquePullRequests: 0,
                repositoryBreakdown: []
            )
        )

        let report = InsightsMarkdownExporter.markdown(
            summary: summary,
            projectTitle: "CodePulse",
            calendar: calendar
        )

        XCTAssertEqual(report, [
            "# CodePulse Report",
            "**Period:** This Week",
            "**Project:** CodePulse",
            "",
            "No CodePulse activity was recorded for this selection."
        ].joined(separator: "\n") + "\n")
        XCTAssertFalse(report.contains("## Summary"))
    }

    func testMarkdownReportSupportsEveryTimeframeAndSelectedProjectLabel() {
        for timeframe in InsightsTimeframe.allCases {
            let summary = summaryFixture(timeframe: timeframe)
            let report = InsightsMarkdownExporter.markdown(
                summary: summary,
                projectTitle: "Legacy | Project\nName",
                calendar: calendar
            )
            XCTAssertTrue(report.contains("**Period:** \(timeframe.title)"), timeframe.rawValue)
            XCTAssertTrue(report.contains("**Project:** Legacy \\| Project Name"), timeframe.rawValue)
        }
    }

    func testExportFilenamesAreStableAndSanitized() {
        let reference = date(year: 2024, month: 8, day: 13, hour: 16)

        XCTAssertEqual(
            ExportFilename.history(referenceDate: reference, calendar: calendar),
            "CodePulse-History-2024-08-13.csv"
        )
        XCTAssertEqual(
            ExportFilename.report(
                projectTitle: nil,
                timeframe: .thisMonth,
                referenceDate: reference,
                calendar: calendar
            ),
            "CodePulse-Report-This-Month-2024-08-13.md"
        )
        XCTAssertEqual(
            ExportFilename.report(
                projectTitle: "CodePulse / Main: Docs",
                timeframe: .thisMonth,
                referenceDate: reference,
                calendar: calendar
            ),
            "CodePulse-Report-CodePulse-Main-Docs-This-Month-2024-08-13.md"
        )
        XCTAssertEqual(ExportFilename.sanitizedComponent(" /:\n ", fallback: "Project"), "Project")
    }

    func testAtomicExportWriterWritesOnlyTheRequestedUTF8File() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codepulse-export-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }

        let data = Data("Café 🚀".utf8)
        try AtomicExportFileWriter().write(data, to: url)

        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    private func historyFixture(reference: Date) -> [CompletedSession] {
        let alphaGit = GitSessionContext(
            repositoryRoot: "/private/alpha-repository",
            branchAtStart: "main",
            startWasDetached: false,
            branchAtEnd: "feature/alpha",
            endWasDetached: false,
            commitCount: 2,
            filesChanged: 3,
            insertions: 10,
            deletions: 2
        )
        let legacyGit = GitSessionContext(
            repositoryRoot: "/private/legacy-repository",
            branchAtStart: "legacy",
            startWasDetached: false
        )
        let codex = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "private-codex-session",
            workingDirectory: "/private/alpha",
            firstActivityAt: reference,
            lastActivityAt: reference.addingTimeInterval(300),
            model: "GPT-5.6",
            profile: "Builder"
        )
        let openCode = DeveloperToolSessionContext(
            tool: .opencode,
            externalSessionID: "private-opencode-session",
            workingDirectory: "/private/legacy",
            firstActivityAt: reference,
            lastActivityAt: reference.addingTimeInterval(300),
            model: "DeepSeek",
            profile: "Reviewer"
        )
        return [
            session(
                id: 2,
                projectID: UUID(uuidString: "00000000-0000-0000-0000-00000000b002")!,
                projectName: "Beta",
                type: .debugging,
                goal: "OpenCode debugging",
                startedAt: date(year: 2024, month: 4, day: 19, hour: 10),
                gitContext: nil,
                developerToolContexts: [openCode]
            ),
            session(
                id: 6,
                projectID: nil,
                projectName: nil,
                type: .coding,
                goal: "Tie second",
                startedAt: date(year: 2024, month: 4, day: 20, hour: 8),
                gitContext: nil
            ),
            session(
                id: 4,
                projectID: nil,
                projectName: "Legacy Name",
                type: .planning,
                goal: "Legacy plan",
                startedAt: date(year: 2024, month: 4, day: 10, hour: 10),
                gitContext: legacyGit,
                developerToolContexts: [codex, openCode]
            ),
            session(
                id: 1,
                projectID: alphaProjectID,
                projectName: "Alpha",
                type: .coding,
                goal: "Comma, \"quoted\" goal",
                outcome: "Finished",
                startedAt: date(year: 2024, month: 4, day: 20, hour: 10),
                gitContext: alphaGit,
                developerToolContexts: [codex]
            ),
            session(
                id: 3,
                projectID: nil,
                projectName: nil,
                type: .research,
                goal: "No tool notes",
                startedAt: date(year: 2024, month: 4, day: 20, hour: 9),
                gitContext: nil
            ),
            session(
                id: 5,
                projectID: nil,
                projectName: nil,
                type: .coding,
                goal: "Tie first",
                startedAt: date(year: 2024, month: 4, day: 20, hour: 8),
                gitContext: nil
            )
        ]
    }

    private func session(
        id: Int,
        projectID: UUID?,
        projectName: String?,
        type: SessionType,
        goal: String?,
        outcome: String? = nil,
        startedAt: Date,
        duration: TimeInterval = 3_600,
        pauseIntervals: [PauseInterval] = [],
        gitContext: GitSessionContext?,
        developerToolContexts: [DeveloperToolSessionContext] = []
    ) -> CompletedSession {
        CompletedSession(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", id))!,
            projectID: projectID,
            projectName: projectName,
            type: type,
            goal: goal,
            outcome: outcome,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            pauseIntervals: pauseIntervals,
            gitContext: gitContext,
            githubContext: nil,
            developerToolContexts: developerToolContexts
        )
    }

    private func summaryFixture(timeframe: InsightsTimeframe = .thisMonth) -> InsightsSummary {
        InsightsSummary(
            timeframe: timeframe,
            interval: DateInterval(start: date(year: 2024, month: 8, day: 1), duration: 31 * 86_400),
            comparisonInterval: DateInterval(start: date(year: 2024, month: 7, day: 1), duration: 31 * 86_400),
            totalDuration: 18 * 3_600 + 42 * 60,
            comparisonDuration: 17 * 3_600,
            sessionCount: 31,
            comparisonSessionCount: 28,
            averageSessionDuration: 36 * 60,
            longestSessionDuration: 2 * 3_600 + 8 * 60,
            projectBreakdown: [
                InsightsBreakdown(id: "project-1", label: "CodePulse | Docs\nWest", duration: 12 * 3_600 + 4 * 60),
                InsightsBreakdown(id: "project-2", label: "Café", duration: 6 * 3_600 + 38 * 60)
            ],
            typeBreakdown: [
                InsightsBreakdown(id: "coding", label: "Coding", duration: 12 * 3_600 + 4 * 60),
                InsightsBreakdown(id: "debugging", label: "Debugging", duration: 6 * 3_600 + 38 * 60)
            ],
            dailyActivity: [
                DailyActivity(date: date(year: 2024, month: 8, day: 10), duration: 2 * 3_600 + 14 * 60),
                DailyActivity(date: date(year: 2024, month: 8, day: 11), duration: 3 * 3_600 + 2 * 60)
            ],
            developerToolInsights: DeveloperToolInsights(
                sessionsWithCodex: 3,
                sessionsWithOpenCode: 2,
                sessionsWithBoth: 1,
                sessionsWithAnyTool: 4,
                sessionsWithNoTool: 27,
                modelBreakdown: [
                    InsightsCountBreakdown(id: "model:gpt", label: "GPT_5", count: 3),
                    InsightsCountBreakdown(id: "model:deepseek", label: "DeepSeek", count: 2)
                ],
                profileBreakdown: [
                    InsightsCountBreakdown(id: "profile:builder", label: "Builder", count: 3),
                    InsightsCountBreakdown(id: "profile:reviewer", label: "Reviewer | Safe", count: 1)
                ]
            ),
            gitInsights: GitInsights(
                sessionsWithGitContext: 5,
                totalCommits: 7,
                totalFilesChanged: 9,
                totalInsertions: 42,
                totalDeletions: 8
            ),
            githubInsights: GitHubInsights(
                sessionsWithGitHubContext: 4,
                sessionsWithPullRequest: 3,
                uniqueRepositories: 2,
                uniquePullRequests: 3,
                repositoryBreakdown: [
                    InsightsBreakdown(id: "github:owner/repository", label: "owner/repository", duration: 5 * 3_600),
                    InsightsBreakdown(id: "github:owner/other", label: "owner/other", duration: 2 * 3_600)
                ]
            )
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

private final class ExportTestClock: SessionClock {
    let now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class ExportTestPersistence: StatePersisting {
    var state: AppState
    private(set) var saveCount = 0

    init(_ state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }

    func save(_ state: AppState) {
        saveCount += 1
        self.state = state
    }
}
