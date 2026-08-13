import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

@MainActor
final class SessionAutomationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    func testOldStateDefaultsAutomationOffAndOwnershipNil() throws {
        let active = ActiveSession(startedAt: start)
        let project = ProjectRecord(name: "Legacy", folderPath: "/tmp/legacy", createdAt: start)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(active)) as? [String: Any])
        object.removeValue(forKey: "automationMetadata")
        var stateObject: [String: Any] = [
            "projects": [try JSONSerialization.jsonObject(with: encoded(project))],
            "completedSessions": [],
            "activeSession": object,
            "settings": [
                "launchAtLogin": false,
                "menuBarDisplay": "projectAndTimer",
                "idleAppearance": "code",
                "defaultProjectBehavior": "lastUsed",
                "globalShortcutEnabled": true
            ]
        ]
        let decoded = try JSONDecoder.iso8601.decode(
            AppState.self,
            from: JSONSerialization.data(withJSONObject: stateObject)
        )

        XCTAssertFalse(decoded.settings.automationEnabled)
        XCTAssertTrue(decoded.automationRules.isEmpty)
        XCTAssertNil(decoded.activeSession?.automationMetadata)
        stateObject.removeValue(forKey: "automationRules")
    }

    func testAutomationRuleRoundTripsWithSafeDefaultsAndTaggedTrigger() throws {
        let projectID = UUID()
        let rule = SessionAutomationRule(
            name: "  Code work  ",
            trigger: .developerTool(.codex),
            projectID: projectID,
            goal: "  Ship local work  ",
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 30
        )
        let decoded = try JSONDecoder.iso8601.decode(
            SessionAutomationRule.self,
            from: encoded(rule)
        )

        XCTAssertEqual(decoded, rule)
        XCTAssertEqual(decoded.name, "Code work")
        XCTAssertEqual(decoded.goal, "Ship local work")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(rule)) as? [String: Any])
        let trigger = try XCTUnwrap(object["trigger"] as? [String: Any])
        XCTAssertEqual(trigger["kind"] as? String, "developerTool")
        XCTAssertEqual(trigger["developerTool"] as? String, "codex")
    }

    func testCoordinatorMatchesCodexAndOpenCodeOnlyForConfiguredProject() throws {
        let fixture = try makeFixture(tool: .codex, enabled: true, seedEvent: nil)
        let coordinator = SessionAutomationCoordinator()
        let child = fixture.projectURL.appendingPathComponent("Sources")
        let matching = event(
            tool: .codex,
            sessionID: "codex-1",
            type: .activity,
            path: child.path,
            timestamp: start
        )
        XCTAssertEqual(
            coordinator.action(for: matching, in: fixture.state, now: start),
            .start(rule: fixture.rule, startDate: start)
        )

        let prefix = event(
            tool: .codex,
            sessionID: "codex-2",
            type: .activity,
            path: fixture.projectURL.path + "-old",
            timestamp: start
        )
        XCTAssertNil(coordinator.action(for: prefix, in: fixture.state, now: start))

        let wrongTool = event(
            tool: .opencode,
            sessionID: "opencode-1",
            type: .activity,
            path: child.path,
            timestamp: start
        )
        XCTAssertNil(coordinator.action(for: wrongTool, in: fixture.state, now: start))
    }

    func testAutomaticStartAttachesContextBeforeEventAcknowledgement() throws {
        let seed = event(tool: .codex, sessionID: "codex-1", type: .sessionStarted, path: fixtureProjectPath())
        let fixture = try makeFixture(tool: .codex, enabled: true, seedEvent: seed)

        XCTAssertEqual(fixture.store.phase, .running)
        XCTAssertEqual(fixture.store.activeSession?.projectID, fixture.project.id)
        XCTAssertEqual(fixture.store.activeSession?.type, .coding)
        XCTAssertEqual(fixture.store.activeSession?.goal, fixture.rule.goal)
        XCTAssertEqual(fixture.store.activeSession?.automationMetadata?.startedByRuleID, fixture.rule.id)
        XCTAssertTrue(fixture.store.activeSession?.automationMetadata?.controlEnabled == true)
        XCTAssertEqual(fixture.store.activeSession?.developerToolContexts.count, 1)
        XCTAssertEqual(
            fixture.store.state.developerToolIntegration?.processedEvents.count,
            1,
            "\(fixture.store.state.developerToolIntegration?.processedEvents ?? [])"
        )
        XCTAssertTrue(fixture.inbox.pendingEventURLs().isEmpty)
    }

    func testOpenCodeActivityCanStartAnAutomaticSession() throws {
        let fixture = try makeFixture(
            tool: .opencode,
            enabled: true,
            seedEvent: event(tool: .opencode, sessionID: "opencode-1", type: .activity, path: fixtureProjectPath())
        )

        XCTAssertEqual(fixture.store.phase, .running)
        XCTAssertEqual(fixture.store.activeSession?.automationMetadata?.startedByTool, .opencode)
        XCTAssertEqual(fixture.store.activeSession?.developerToolContexts.first?.tool, .opencode)
    }

    func testDisabledAutomationAndRulesDoNotStartSessions() throws {
        let event = DeveloperToolEvent(
            tool: .codex,
            externalSessionID: "codex-disabled",
            eventType: .activity,
            timestamp: start,
            workingDirectory: fixtureProjectPath()
        )
        let disabledGlobal = try makeFixture(tool: .codex, enabled: false, seedEvent: event)
        XCTAssertEqual(disabledGlobal.store.phase, .idle)
        XCTAssertEqual(disabledGlobal.store.state.developerToolIntegration?.processedEvents.count, 1)

        let disabledRule = try makeFixture(tool: .codex, enabled: true, seedEvent: event, ruleEnabled: false)
        XCTAssertEqual(disabledRule.store.phase, .idle)
        XCTAssertEqual(disabledRule.store.state.developerToolIntegration?.processedEvents.count, 1)
    }

    func testStaleErrorAndUnknownEventsDoNotStartSessions() throws {
        let stale = event(
            tool: .codex,
            sessionID: "stale",
            type: .activity,
            path: fixtureProjectPath(),
            timestamp: start.addingTimeInterval(-SessionAutomationCoordinator.maximumStartBackdate - 1)
        )
        let staleFixture = try makeFixture(tool: .codex, enabled: true, seedEvent: stale)
        XCTAssertEqual(staleFixture.store.phase, .idle)

        let error = event(tool: .codex, sessionID: "error", type: .error, path: fixtureProjectPath())
        let errorFixture = try makeFixture(tool: .codex, enabled: true, seedEvent: error)
        XCTAssertEqual(errorFixture.store.phase, .idle)

        let unknown = event(tool: .codex, sessionID: "unknown", type: .unknown, path: fixtureProjectPath())
        let unknownFixture = try makeFixture(tool: .codex, enabled: true, seedEvent: unknown)
        XCTAssertEqual(unknownFixture.store.phase, .idle)
        XCTAssertTrue(unknownFixture.inbox.pendingEventURLs().isEmpty)
    }

    func testManualSessionCannotBeControlledButStillReceivesContext() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(tool: .codex, enabled: true, seedEvent: nil, clock: clock)
        XCTAssertTrue(fixture.store.startSession(projectID: fixture.project.id, goal: "Manual", at: start))
        let activity = event(
            tool: .codex,
            sessionID: "manual-context",
            type: .activity,
            path: fixture.projectURL.path,
            timestamp: start.addingTimeInterval(1)
        )
        try fixture.inbox.write(activity)
        clock.now = start.addingTimeInterval(5)
        fixture.store.refresh()

        XCTAssertEqual(fixture.store.phase, .running)
        XCTAssertNil(fixture.store.activeSession?.automationMetadata)
        XCTAssertEqual(fixture.store.activeSession?.developerToolContexts.count, 1)
    }

    func testDisabledAutomationStillEnrichesManualSessionContext() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(tool: .codex, enabled: false, seedEvent: nil, clock: clock)
        XCTAssertTrue(fixture.store.startSession(projectID: fixture.project.id, goal: "Manual", at: start))
        clock.now = start.addingTimeInterval(5)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "manual-disabled-automation",
            type: .activity,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()

        XCTAssertEqual(fixture.store.phase, .running)
        XCTAssertNil(fixture.store.activeSession?.automationMetadata)
        XCTAssertEqual(fixture.store.activeSession?.developerToolContexts.count, 1)
    }

    func testDeletedProjectRuleCannotStartAProjectlessSession() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = ProjectRecord(name: "Deleted", folderPath: projectURL.path, createdAt: start)
        let rule = SessionAutomationRule(
            name: "Deleted project",
            trigger: .developerTool(.codex),
            projectID: project.id
        )
        var state = AppState(
            settings: CodePulseSettings(automationEnabled: true),
            automationRules: [rule]
        )
        let coordinator = SessionAutomationCoordinator()
        let deletedProjectEvent = event(tool: .codex, sessionID: "deleted", type: .activity, path: projectURL.path)
        XCTAssertNil(coordinator.action(for: deletedProjectEvent, in: state, now: start))
        state.projects = [project]
        state.projects.removeAll()
        XCTAssertNil(coordinator.action(for: deletedProjectEvent, in: state, now: start))
    }

    func testMultipleClaimsShareOneSessionAndOneEndingClaimDoesNotPauseIt() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(tool: .codex, enabled: true, seedEvent: event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionStarted,
            path: fixtureProjectPath()
        ), clock: clock, includeOpenCodeRule: true, pauseDelay: 10, finishDelay: 30)
        let sessionID = try XCTUnwrap(fixture.store.activeSession?.id)

        clock.now = start.addingTimeInterval(5)
        try fixture.inbox.write(event(
            tool: .opencode,
            sessionID: "opencode-c",
            type: .activity,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.activeSession?.id, sessionID)
        XCTAssertEqual(fixture.store.activeSession?.automationMetadata?.claims.count, 2)

        clock.now = start.addingTimeInterval(10)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionEnded,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()

        XCTAssertEqual(fixture.store.phase, .running)
        XCTAssertEqual(
            fixture.store.activeSession?.automationMetadata?.claims.first(where: { $0.externalSessionID == "codex-a" })?.isActive,
            false
        )
        XCTAssertEqual(
            fixture.store.activeSession?.automationMetadata?.claims.first(where: { $0.externalSessionID == "opencode-c" })?.isActive,
            true
        )
    }

    func testAutomaticPauseResumeUsesSameSessionAndExactThresholds() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            pauseDelay: 10,
            finishDelay: 40,
            minimumSavedDuration: 0
        )
        let sessionID = try XCTUnwrap(fixture.store.activeSession?.id)

        clock.now = start.addingTimeInterval(9)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .running)

        clock.now = start.addingTimeInterval(10)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .paused)

        clock.now = start.addingTimeInterval(15)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .activity,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .running)
        XCTAssertEqual(fixture.store.activeSession?.id, sessionID)
        XCTAssertEqual(fixture.store.activeSession?.pauseIntervals.count, 1)
    }

    func testManualTakeoverSurvivesActivityAndRelaunch() throws {
        let clock = AutomationTestClock(start)
        let persistence = AutomationTestPersistence()
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            persistence: persistence,
            pauseDelay: 10,
            finishDelay: 30
        )
        XCTAssertTrue(fixture.store.pause(at: start.addingTimeInterval(1)))
        XCTAssertFalse(fixture.store.activeSession?.automationMetadata?.controlEnabled ?? true)

        clock.now = start.addingTimeInterval(2)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .activity,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .paused)

        let restored = makeStore(
            state: persistence.state,
            clock: clock,
            persistence: persistence,
            inbox: fixture.inbox
        )
        XCTAssertEqual(restored.phase, .paused)
        XCTAssertFalse(restored.activeSession?.automationMetadata?.controlEnabled ?? true)
    }

    func testProjectConflictDoesNotSwitchTheActiveSession() throws {
        let clock = AutomationTestClock(start)
        let first = try makeFixture(tool: .codex, enabled: true, seedEvent: event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionStarted,
            path: fixtureProjectPath()
        ), clock: clock)
        let otherURL = first.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        let otherProject = ProjectRecord(name: "Other", folderPath: otherURL.path, createdAt: start)
        var state = first.persistence.state
        state.projects.append(otherProject)
        let otherRule = SessionAutomationRule(
            name: "Other",
            trigger: .developerTool(.codex),
            projectID: otherProject.id,
            pauseDelay: 10,
            finishDelay: 30
        )
        state.automationRules.append(otherRule)
        first.persistence.save(state)

        let eventForOther = event(
            tool: .codex,
            sessionID: "codex-b",
            type: .activity,
            path: otherURL.path,
            timestamp: start.addingTimeInterval(5)
        )
        try first.inbox.write(eventForOther)
        clock.now = start.addingTimeInterval(5)
        first.store.refresh()

        XCTAssertEqual(first.store.activeSession?.projectID, first.project.id)
        XCTAssertEqual(first.store.activeSession?.developerToolContexts.count, 1)
    }

    func testAutomaticFinishSavesExactlyOnceWithNilOutcome() async throws {
        let clock = AutomationTestClock(start)
        let persistence = AutomationTestPersistence()
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            persistence: persistence,
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 0
        )
        clock.now = start.addingTimeInterval(20)
        fixture.store.refresh()
        try await settle(fixture.store)

        XCTAssertEqual(fixture.store.phase, .idle)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertNil(persistence.state.completedSessions[0].outcome)
        fixture.store.refresh()
        try await settle(fixture.store)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
    }

    func testAutomaticFinishRunsFinalGitCaptureBeforeSaving() async throws {
        let clock = AutomationTestClock(start)
        let persistence = AutomationTestPersistence()
        let gitService = AutomationRecordingGitService()
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-git", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            persistence: persistence,
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 0,
            gitService: gitService
        )
        try await settle(fixture.store)
        clock.now = start.addingTimeInterval(20)
        fixture.store.refresh()
        try await settle(fixture.store)

        XCTAssertEqual(gitService.finishCaptureCount, 1)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertEqual(persistence.state.completedSessions[0].gitContext?.branchAtEnd, "automation-end")
    }

    func testAutomaticMinimumDurationDiscardsShortButSavesExactThreshold() async throws {
        let shortClock = AutomationTestClock(start)
        let shortPersistence = AutomationTestPersistence()
        let short = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "short", type: .sessionStarted, path: fixtureProjectPath()),
            clock: shortClock,
            persistence: shortPersistence,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 3
        )
        shortClock.now = start.addingTimeInterval(2)
        short.store.refresh()
        try await settle(short.store)
        XCTAssertEqual(short.store.phase, .idle)
        XCTAssertTrue(shortPersistence.state.completedSessions.isEmpty)

        let exactClock = AutomationTestClock(start)
        let exactPersistence = AutomationTestPersistence()
        let exact = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "exact", type: .sessionStarted, path: fixtureProjectPath()),
            clock: exactClock,
            persistence: exactPersistence,
            pauseDelay: 3,
            finishDelay: 3,
            minimumSavedDuration: 3
        )
        exactClock.now = start.addingTimeInterval(3)
        exact.store.refresh()
        try await settle(exact.store)
        XCTAssertEqual(exactPersistence.state.completedSessions.count, 1)
        XCTAssertEqual(exactPersistence.state.completedSessions[0].activeDuration, 3, accuracy: 0.001)
    }

    func testManualShortSessionIsNeverAutomaticallyDiscarded() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(tool: .codex, enabled: true, seedEvent: nil, clock: clock)
        XCTAssertTrue(fixture.store.startSession(projectID: fixture.project.id, goal: "Short", at: start))
        clock.now = start.addingTimeInterval(1)
        XCTAssertTrue(fixture.store.finish())
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .finishing)
        XCTAssertNil(fixture.store.activeSession?.automationMetadata)
    }

    func testRunningAndPausedAutomationRestoreFromPersistedState() throws {
        let clock = AutomationTestClock(start)
        let persistence = AutomationTestPersistence()
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "restore", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            persistence: persistence,
            pauseDelay: 10,
            finishDelay: 100
        )
        clock.now = start.addingTimeInterval(5)
        let running = makeStore(state: persistence.state, clock: clock, persistence: persistence, inbox: fixture.inbox)
        XCTAssertEqual(running.phase, .running)
        XCTAssertNotNil(running.activeSession?.automationMetadata)

        clock.now = start.addingTimeInterval(10)
        running.refresh()
        XCTAssertEqual(running.phase, .paused)
        let paused = makeStore(state: persistence.state, clock: clock, persistence: persistence, inbox: fixture.inbox)
        XCTAssertEqual(paused.phase, .paused)
        XCTAssertNotNil(paused.activeSession?.automationMetadata)
    }

    func testPendingAutomaticSaveRecoversAfterRelaunchAndManualFinishingDoesNot() async throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = ProjectRecord(name: "Project", folderPath: projectURL.path, createdAt: start)
        let rule = SessionAutomationRule(
            name: "Rule",
            trigger: .developerTool(.codex),
            projectID: project.id,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0
        )
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedByTool: .codex,
            lastMatchingSignalAt: start,
            pendingAutomaticSave: true,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0,
            claims: []
        )
        var automatic = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: start,
            automationMetadata: metadata
        )
        automatic.endedAt = start.addingTimeInterval(2)
        automatic.phase = .finishing

        var state = AppState(
            projects: [project],
            activeSession: automatic,
            settings: CodePulseSettings(automationEnabled: true),
            automationRules: [rule]
        )
        let persistence = AutomationTestPersistence(state)
        let clock = AutomationTestClock(start.addingTimeInterval(2))
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root.appendingPathComponent("support"))
        let inbox = DeveloperToolInbox(paths: paths)
        let restored = makeStore(state: state, clock: clock, persistence: persistence, inbox: inbox)
        try await settle(restored)
        XCTAssertEqual(restored.phase, .idle)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)

        let secondRestore = makeStore(state: persistence.state, clock: clock, persistence: persistence, inbox: inbox)
        XCTAssertEqual(secondRestore.phase, .idle)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)

        state = persistence.state
        var manual = ActiveSession(startedAt: start)
        manual.endedAt = start.addingTimeInterval(2)
        manual.phase = .finishing
        state.activeSession = manual
        persistence.save(state)
        let manualRestore = makeStore(state: state, clock: clock, persistence: persistence, inbox: inbox)
        XCTAssertEqual(manualRestore.phase, .finishing)
        XCTAssertTrue(persistence.state.completedSessions.count == 1)
    }

    private func makeFixture(
        tool: DeveloperTool,
        enabled: Bool,
        seedEvent: DeveloperToolEvent?,
        clock: AutomationTestClock = AutomationTestClock(Date(timeIntervalSince1970: 1_900_000_000)),
        persistence: AutomationTestPersistence? = nil,
        ruleEnabled: Bool = true,
        includeOpenCodeRule: Bool = false,
        pauseDelay: TimeInterval = 60,
        finishDelay: TimeInterval = 300,
        minimumSavedDuration: TimeInterval = 60,
        gitService: GitServicing? = nil
    ) throws -> AutomationFixture {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = ProjectRecord(name: "Project", folderPath: projectURL.path, createdAt: start)
        let rule = SessionAutomationRule(
            name: "\(tool.title) Rule",
            isEnabled: ruleEnabled,
            trigger: .developerTool(tool),
            projectID: project.id,
            sessionType: .coding,
            goal: "Automated goal",
            pauseDelay: pauseDelay,
            finishDelay: finishDelay,
            minimumSavedDuration: minimumSavedDuration
        )
        var rules = [rule]
        if includeOpenCodeRule {
            rules.append(SessionAutomationRule(
                name: "OpenCode Rule",
                trigger: .developerTool(.opencode),
                projectID: project.id,
                pauseDelay: pauseDelay,
                finishDelay: finishDelay,
                minimumSavedDuration: minimumSavedDuration
            ))
        }
        let state = AppState(
            projects: [project],
            settings: CodePulseSettings(automationEnabled: enabled),
            automationRules: rules
        )
        let actualPersistence = persistence ?? AutomationTestPersistence(state)
        actualPersistence.save(state)
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root.appendingPathComponent("support"))
        let inbox = DeveloperToolInbox(paths: paths)
        if let seedEvent {
            let eventPath = seedEvent.workingDirectory == fixtureProjectPath()
                ? projectURL.path
                : seedEvent.workingDirectory
            try inbox.write(DeveloperToolEvent(
                schemaVersion: seedEvent.schemaVersion,
                id: seedEvent.id,
                tool: seedEvent.tool,
                externalSessionID: seedEvent.externalSessionID,
                eventType: seedEvent.eventType,
                timestamp: seedEvent.timestamp,
                workingDirectory: eventPath,
                model: seedEvent.model,
                profile: seedEvent.profile
            ))
        }
        let store = makeStore(
            state: state,
            clock: clock,
            persistence: actualPersistence,
            inbox: inbox,
            gitService: gitService
        )
        return AutomationFixture(
            root: root,
            projectURL: projectURL,
            project: project,
            rule: rule,
            state: state,
            persistence: actualPersistence,
            inbox: inbox,
            clock: clock,
            store: store
        )
    }

    private func makeStore(
        state: AppState,
        clock: AutomationTestClock,
        persistence: AutomationTestPersistence,
        inbox: DeveloperToolInbox,
        gitService: GitServicing? = nil
    ) -> SessionStore {
        persistence.save(state)
        return SessionStore(
            persistence: persistence,
            clock: clock,
            gitService: gitService ?? AutomationNoOpGitService(),
            developerToolEventConsumer: DeveloperToolEventConsumer(inbox: inbox),
            automaticallyRefresh: false
        )
    }

    private func event(
        tool: DeveloperTool,
        sessionID: String,
        type: DeveloperToolEventType,
        path: String,
        timestamp: Date? = nil
    ) -> DeveloperToolEvent {
        DeveloperToolEvent(
            tool: tool,
            externalSessionID: sessionID,
            eventType: type,
            timestamp: timestamp ?? start,
            workingDirectory: path
        )
    }

    private func fixtureProjectPath() -> String {
        "/tmp/CodePulse-automation-project"
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseAutomationTests-(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func settle(_ store: SessionStore) async throws {
        for _ in 0..<200 {
            if !store.gitCaptureInProgress { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for Git capture")
    }
}

private struct AutomationFixture {
    let root: URL
    let projectURL: URL
    let project: ProjectRecord
    let rule: SessionAutomationRule
    let state: AppState
    let persistence: AutomationTestPersistence
    let inbox: DeveloperToolInbox
    let clock: AutomationTestClock
    let store: SessionStore
}

private final class AutomationTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class AutomationTestPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private final class AutomationNoOpGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}

private final class AutomationRecordingGitService: GitServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _finishCaptureCount = 0

    var finishCaptureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _finishCaptureCount
    }

    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? {
        GitStartSnapshot(
            repositoryRoot: folderURL,
            branch: "automation-start",
            headSHA: "start-sha",
            isDetached: false,
            preExistingWorkingTreePaths: []
        )
    }

    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? {
        lock.lock()
        _finishCaptureCount += 1
        lock.unlock()
        return GitFinishSnapshot(
            branch: "automation-end",
            headSHA: "end-sha",
            isDetached: false,
            commitCount: 1,
            statistics: GitDiffStatistics()
        )
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
