import Foundation
import XCTest
import CodePulseIntegration
@testable import CodePulse

final class WorkspaceIntelligenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    func testExplicitWorkspaceScopeUsesCurrentMembershipAndIgnoresSelectionProjectlessAndOrphans() throws {
        let workspaceA = workspace(1, name: "A")
        let workspaceB = workspace(2, name: "B")
        let projectA = project(1, workspaceID: workspaceA.id, name: "Alpha")
        let projectB = project(2, workspaceID: workspaceB.id, name: "Beta")
        let sessionA = session(1, project: projectA, startedAt: now.addingTimeInterval(-600), duration: 120)
        let sessionB = session(2, project: projectB, startedAt: now.addingTimeInterval(-500), duration: 240)
        let projectless = CompletedSession(
            id: uuid(3), projectID: nil, projectName: nil, goal: nil, outcome: nil,
            startedAt: now.addingTimeInterval(-400), endedAt: now.addingTimeInterval(-340), pauseIntervals: []
        )
        let orphan = CompletedSession(
            id: uuid(4), projectID: uuid(99), projectName: "Deleted", goal: nil, outcome: nil,
            startedAt: now.addingTimeInterval(-300), endedAt: now.addingTimeInterval(-240), pauseIntervals: []
        )
        var state = AppState(
            workspaces: [workspaceA, workspaceB],
            projects: [projectA, projectB],
            completedSessions: [sessionA, sessionB, projectless, orphan],
            settings: CodePulseSettings(selectedWorkspaceID: workspaceB.id)
        )

        let before = state.completedSessions
        let intelligenceA = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspaceA.id, timeframe: .allTime
        ))
        XCTAssertEqual(intelligenceA.patterns.projectsTouched, 1)
        XCTAssertEqual(intelligenceA.patterns.projectBreakdown.map(\.label), [projectA.name])
        XCTAssertEqual(intelligenceA.resumeItems.map(\.projectID), [projectA.id])

        state.settings.selectedWorkspaceID = workspaceA.id
        let sameA = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspaceA.id, timeframe: .allTime
        ))
        XCTAssertEqual(sameA, intelligenceA)
        XCTAssertEqual(state.completedSessions, before)
    }

    func testProjectMovementUpdatesIntelligenceRetroactivelyWithoutRewritingSessions() throws {
        let workspaceA = workspace(10, name: "A")
        let workspaceB = workspace(11, name: "B")
        let projectA = project(10, workspaceID: workspaceA.id, name: "Alpha")
        let recorded = session(10, project: projectA, startedAt: now.addingTimeInterval(-300), duration: 120)
        let state = AppState(workspaces: [workspaceA, workspaceB], projects: [projectA], completedSessions: [recorded])
        let before = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspaceA.id, timeframe: .allTime
        ))
        XCTAssertEqual(before.patterns.projectsTouched, 1)

        let movedProject = ProjectRecord(
            id: projectA.id, workspaceID: workspaceB.id, name: projectA.name,
            createdAt: projectA.createdAt, lastUsedAt: projectA.lastUsedAt, archivedAt: projectA.archivedAt
        )
        let movedState = AppState(workspaces: [workspaceA, workspaceB], projects: [movedProject], completedSessions: [recorded])
        let afterA = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: movedState, calendar: calendar, referenceDate: now, workspaceID: workspaceA.id, timeframe: .allTime
        ))
        let afterB = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: movedState, calendar: calendar, referenceDate: now, workspaceID: workspaceB.id, timeframe: .allTime
        ))
        XCTAssertEqual(afterA.patterns.projectsTouched, 0)
        XCTAssertEqual(afterA.patterns.projectBreakdown, [])
        XCTAssertEqual(afterB.patterns.projectsTouched, 1)
        XCTAssertEqual(movedState.completedSessions, [recorded])
    }

    func testPatternsReuseProjectBreakdownLargestShareSwitchesAndSustainedFocus() throws {
        let workspace = workspace(20, name: "Patterns")
        let alpha = project(20, workspaceID: workspace.id, name: "Alpha")
        let beta = project(21, workspaceID: workspace.id, name: "Beta")
        let start = now.addingTimeInterval(-7_200)
        let alphaLong = session(20, project: alpha, startedAt: start, duration: 1_800)
        let betaShort = session(21, project: beta, startedAt: start.addingTimeInterval(1_860), duration: 60)
        let alphaShort = session(22, project: alpha, startedAt: start.addingTimeInterval(1_980), duration: 60)
        let state = AppState(
            workspaces: [workspace], projects: [alpha, beta],
            completedSessions: [alphaLong, betaShort, alphaShort]
        )

        let intelligence = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspace.id, timeframe: .allTime
        ))
        XCTAssertEqual(intelligence.patterns.projectsTouched, 2)
        XCTAssertEqual(intelligence.patterns.projectBreakdown, [
            InsightsBreakdown(id: "id:\(alpha.id.uuidString)", label: alpha.name, duration: 1_860),
            InsightsBreakdown(id: "id:\(beta.id.uuidString)", label: beta.name, duration: 60)
        ])
        XCTAssertEqual(intelligence.patterns.largestProjectTimeShare ?? -1, 1_860.0 / 1_920.0, accuracy: 0.000_001)
        XCTAssertEqual(intelligence.patterns.rapidProjectSwitches, 2)
        XCTAssertEqual(intelligence.patterns.sustainedFocusShare ?? -1, 1_860.0 / 1_920.0, accuracy: 0.000_001)
    }

    func testResumeContextIsNewestFirstBoundedAndExcludesArchivedAndActiveProjects() throws {
        let workspace = workspace(30, name: "Resume")
        let projects = (0..<6).map { index in
            project(30 + index, workspaceID: workspace.id, name: "Project \(index)", archived: index == 5)
        }
        let sessions = projects.enumerated().map { index, project in
            session(
                30 + index,
                project: project,
                startedAt: now.addingTimeInterval(-Double(1_000 - index * 100)),
                duration: 60
            )
        }
        let active = ActiveSession(
            id: uuid(90), projectID: projects[0].id, projectName: projects[0].name,
            type: .coding, goal: "Currently working", startedAt: now.addingTimeInterval(-10)
        )
        let state = AppState(
            workspaces: [workspace], projects: projects,
            completedSessions: sessions, activeSession: active
        )

        let intelligence = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspace.id, timeframe: .allTime
        ))
        XCTAssertEqual(intelligence.resumeItems.count, 4)
        XCTAssertEqual(intelligence.resumeItems.map(\.projectID), [projects[4].id, projects[3].id, projects[2].id, projects[1].id])
        XCTAssertFalse(intelligence.resumeItems.contains { $0.projectID == projects[0].id })
        XCTAssertFalse(intelligence.resumeItems.contains { $0.projectID == projects[5].id })
    }

    func testResumeTieBreakIsStableBySessionThenProjectUUID() throws {
        let workspace = workspace(40, name: "Ties")
        let first = project(40, workspaceID: workspace.id, name: "First")
        let second = project(41, workspaceID: workspace.id, name: "Second")
        let endedAt = now.addingTimeInterval(-100)
        let firstSession = session(42, project: first, startedAt: endedAt.addingTimeInterval(-60), duration: 60)
        let secondSession = session(41, project: second, startedAt: endedAt.addingTimeInterval(-60), duration: 60)
        let state = AppState(workspaces: [workspace], projects: [first, second], completedSessions: [firstSession, secondSession])
        let intelligence = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspace.id, timeframe: .allTime
        ))
        XCTAssertEqual(intelligence.resumeItems.map(\.latestSessionID), [secondSession.id, firstSession.id])
    }

    func testResumeAndContinuationEvidenceUsesRecordedGoalOutcomeGitHubGitAndDeveloperContext() throws {
        let workspace = workspace(50, name: "Evidence")
        let followUpProject = project(50, workspaceID: workspace.id, name: "Follow Up")
        let completedProject = project(51, workspaceID: workspace.id, name: "Closed Loop")
        let outcomeOnlyProject = project(52, workspaceID: workspace.id, name: "Outcome Only")
        let pullRequest = GitHubPullRequestSnapshot(
            number: 42, title: "Workspace experience", state: .open, isDraft: false,
            url: "https://github.com/joewolly/codepulse/pull/42"
        )
        let followUp = session(
            50, project: followUpProject, startedAt: now.addingTimeInterval(-600), duration: 60,
            goal: "Finish workspace scope filters", outcome: nil,
            gitContext: GitSessionContext(repositoryRoot: "/tmp/codepulse", branchAtStart: "feature/workspaces"),
            githubContext: GitHubSessionContext(
                repositoryNameWithOwner: "joewolly/codepulse", repositoryURL: "https://github.com/joewolly/codepulse", pullRequest: pullRequest
            ),
            developerToolContexts: [DeveloperToolSessionContext(
                tool: .codex, externalSessionID: "codex-1", workingDirectory: "/tmp/codepulse",
                firstActivityAt: now.addingTimeInterval(-620), lastActivityAt: now.addingTimeInterval(-590), model: "gpt-5"
            )]
        )
        let closed = session(
            51, project: completedProject, startedAt: now.addingTimeInterval(-500), duration: 60,
            goal: "Ship filters", outcome: "Filters shipped"
        )
        let outcomeOnly = session(
            52, project: outcomeOnlyProject, startedAt: now.addingTimeInterval(-400), duration: 60,
            goal: nil, outcome: "Reviewed the dashboard"
        )
        let state = AppState(
            workspaces: [workspace], projects: [followUpProject, completedProject, outcomeOnlyProject],
            completedSessions: [followUp, closed, outcomeOnly]
        )

        let intelligence = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspace.id, timeframe: .allTime
        ))
        let resume = try XCTUnwrap(intelligence.resumeItems.first { $0.projectID == followUpProject.id })
        XCTAssertEqual(resume.goal, "Finish workspace scope filters")
        XCTAssertNil(resume.outcome)
        XCTAssertTrue(resume.hasUnrecordedOutcome)
        XCTAssertEqual(resume.gitBranch, "feature/workspaces")
        XCTAssertEqual(resume.githubPullRequest?.number, 42)
        XCTAssertEqual(resume.githubRepositoryNameWithOwner, "joewolly/codepulse")
        XCTAssertEqual(resume.developerToolContext, "Codex · gpt-5")
        XCTAssertFalse(intelligence.resumeItems.contains { $0.hasUnrecordedOutcome && $0.projectID != followUpProject.id })

        XCTAssertEqual(intelligence.continuationHints.map(\.kind), [.outcomeFollowUp, .resumeRecentProject, .recentCodeContext])
        XCTAssertTrue(intelligence.continuationHints.first?.message.contains("without a recorded outcome") == true)
        XCTAssertTrue(intelligence.continuationHints.last?.message.contains("PR #42") == true)
        XCTAssertFalse(intelligence.continuationHints.contains { $0.message.contains("should work") })
        let resumeHint = try XCTUnwrap(intelligence.continuationHints.first { $0.kind == .resumeRecentProject })
        XCTAssertEqual(resumeHint.projectID, outcomeOnlyProject.id)
        XCTAssertEqual(resumeHint.message, "\(outcomeOnlyProject.name) was the most recently active Project in this Workspace.")
    }

    func testMostRecentFollowUpDoesNotFallThroughToOlderResumeProject() throws {
        let workspace = workspace(80, name: "Ordering")
        let recentProject = project(80, workspaceID: workspace.id, name: "Recent Project")
        let olderProject = project(81, workspaceID: workspace.id, name: "Older Project")
        let recentSession = session(
            80,
            project: recentProject,
            startedAt: now.addingTimeInterval(-120),
            duration: 60,
            goal: "Review workspace intelligence",
            gitContext: GitSessionContext(
                repositoryRoot: "/tmp/codepulse",
                branchAtStart: "feature/phase3"
            )
        )
        let olderSession = session(
            81,
            project: olderProject,
            startedAt: now.addingTimeInterval(-420),
            duration: 60
        )
        let state = AppState(
            workspaces: [workspace],
            projects: [recentProject, olderProject],
            completedSessions: [recentSession, olderSession]
        )

        let intelligence = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspace.id, timeframe: .allTime
        ))
        XCTAssertEqual(intelligence.resumeItems.map(\.projectID), [recentProject.id, olderProject.id])

        let followUpHint = try XCTUnwrap(intelligence.continuationHints.first { $0.kind == .outcomeFollowUp })
        XCTAssertEqual(followUpHint.projectID, recentProject.id)
        XCTAssertFalse(intelligence.continuationHints.contains { $0.kind == .resumeRecentProject })
        XCTAssertFalse(intelligence.continuationHints.contains {
            $0.projectID == olderProject.id && $0.message.contains("most recently active")
        })
        XCTAssertEqual(
            intelligence.continuationHints.first { $0.kind == .recentCodeContext }?.projectID,
            recentProject.id
        )
    }

    func testActiveWorkspaceSessionSuppressesGenericResumeHintButDoesNotMutateActiveSession() throws {
        let workspace = workspace(60, name: "Active")
        let activeProject = project(60, workspaceID: workspace.id, name: "Active Project")
        let otherProject = project(61, workspaceID: workspace.id, name: "Other Project")
        let active = ActiveSession(
            id: uuid(60), projectID: activeProject.id, projectName: activeProject.name,
            type: .debugging, goal: "Investigate", startedAt: now.addingTimeInterval(-30)
        )
        let otherSession = session(61, project: otherProject, startedAt: now.addingTimeInterval(-300), duration: 60)
        let state = AppState(workspaces: [workspace], projects: [activeProject, otherProject], completedSessions: [otherSession], activeSession: active)
        let intelligence = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspace.id, timeframe: .allTime
        ))
        XCTAssertFalse(intelligence.resumeItems.contains { $0.projectID == activeProject.id })
        XCTAssertFalse(intelligence.continuationHints.contains { $0.kind == .resumeRecentProject })
        XCTAssertEqual(state.activeSession, active)
    }

    func testAllActiveProjectsInWorkspaceAreExcludedButOtherWorkspaceRemainsIndependent() throws {
        let workspaceA = workspace(90, name: "Target")
        let workspaceB = workspace(91, name: "Other")
        let activeA = project(90, workspaceID: workspaceA.id, name: "Active A")
        let activeA2 = project(91, workspaceID: workspaceA.id, name: "Active A2")
        let eligibleA = project(92, workspaceID: workspaceA.id, name: "Eligible A")
        let activeB = project(93, workspaceID: workspaceB.id, name: "Active B")
        let completedA = session(90, project: activeA, startedAt: now.addingTimeInterval(-400), duration: 60)
        let completedA2 = session(91, project: activeA2, startedAt: now.addingTimeInterval(-300), duration: 60)
        let completedEligibleA = session(92, project: eligibleA, startedAt: now.addingTimeInterval(-200), duration: 60)
        let completedB = session(93, project: activeB, startedAt: now.addingTimeInterval(-100), duration: 60)
        let state = AppState(
            workspaces: [workspaceA, workspaceB],
            projects: [activeA, activeA2, eligibleA, activeB],
            completedSessions: [completedA, completedA2, completedEligibleA, completedB],
            activeSessions: [
                ActiveSession(id: uuid(190), projectID: activeA.id, projectName: activeA.name, startedAt: now.addingTimeInterval(-30)),
                ActiveSession(id: uuid(191), projectID: activeA2.id, projectName: activeA2.name, startedAt: now.addingTimeInterval(-20)),
                ActiveSession(id: uuid(192), projectID: activeB.id, projectName: activeB.name, startedAt: now.addingTimeInterval(-10))
            ]
        )

        let target = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state,
            calendar: calendar,
            referenceDate: now,
            workspaceID: workspaceA.id,
            timeframe: .allTime
        ))
        XCTAssertFalse(target.resumeItems.contains { $0.projectID == activeA.id })
        XCTAssertFalse(target.resumeItems.contains { $0.projectID == activeA2.id })
        XCTAssertTrue(target.resumeItems.contains { $0.projectID == eligibleA.id })
        XCTAssertFalse(target.continuationHints.contains { hint in
            [activeA.id, activeA2.id].contains(hint.projectID)
        })

        // An active Session in another Workspace must not suppress the target
        // Workspace's continuation guidance.
        var onlyOtherWorkspaceActive = state
        onlyOtherWorkspaceActive.activeSessions = [
            ActiveSession(
                id: uuid(193),
                projectID: activeB.id,
                projectName: activeB.name,
                startedAt: now.addingTimeInterval(-10)
            )
        ]
        let targetWithoutLocalActive = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: onlyOtherWorkspaceActive,
            calendar: calendar,
            referenceDate: now,
            workspaceID: workspaceA.id,
            timeframe: .allTime
        ))
        XCTAssertTrue(targetWithoutLocalActive.resumeItems.contains { $0.projectID == eligibleA.id })
        XCTAssertTrue(targetWithoutLocalActive.continuationHints.contains {
            $0.kind == .resumeRecentProject && $0.projectID == eligibleA.id
        })

        let otherWorkspace = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state,
            calendar: calendar,
            referenceDate: now,
            workspaceID: workspaceB.id,
            timeframe: .allTime
        ))
        XCTAssertFalse(otherWorkspace.resumeItems.contains { $0.projectID == activeB.id })
    }

    func testEmptyWorkspaceHasStableEmptyIntelligence() throws {
        let workspace = workspace(70, name: "Empty")
        let state = AppState(workspaces: [workspace])
        let intelligence = try XCTUnwrap(WorkspaceIntelligenceCalculator.snapshot(
            state: state, calendar: calendar, referenceDate: now, workspaceID: workspace.id, timeframe: .last30Days
        ))
        XCTAssertEqual(intelligence.patterns.projectsTouched, 0)
        XCTAssertEqual(intelligence.patterns.projectBreakdown, [])
        XCTAssertNil(intelligence.patterns.largestProjectTimeShare)
        XCTAssertEqual(intelligence.patterns.rapidProjectSwitches, 0)
        XCTAssertNil(intelligence.patterns.sustainedFocusShare)
        XCTAssertTrue(intelligence.resumeItems.isEmpty)
        XCTAssertTrue(intelligence.continuationHints.isEmpty)
    }

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
    }

    private func workspace(_ value: Int, name: String) -> WorkspaceRecord {
        WorkspaceRecord(id: uuid(value), name: name, createdAt: now)
    }

    private func project(_ value: Int, workspaceID: UUID, name: String, archived: Bool = false) -> ProjectRecord {
        ProjectRecord(
            id: uuid(value), workspaceID: workspaceID, name: name, createdAt: now,
            archivedAt: archived ? now.addingTimeInterval(-10) : nil
        )
    }

    private func session(
        _ value: Int,
        project: ProjectRecord,
        startedAt: Date,
        duration: TimeInterval,
        goal: String? = nil,
        outcome: String? = nil,
        gitContext: GitSessionContext? = nil,
        githubContext: GitHubSessionContext? = nil,
        developerToolContexts: [DeveloperToolSessionContext] = []
    ) -> CompletedSession {
        CompletedSession(
            id: uuid(value), projectID: project.id, projectName: project.name,
            type: .coding, goal: goal, outcome: outcome,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(duration), pauseIntervals: [],
            gitContext: gitContext, githubContext: githubContext, developerToolContexts: developerToolContexts
        )
    }
}
