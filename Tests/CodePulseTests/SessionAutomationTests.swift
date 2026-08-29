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
        var legacyProject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(project)) as? [String: Any])
        legacyProject.removeValue(forKey: "workspaceID")
        var stateObject: [String: Any] = [
            "projects": [legacyProject],
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

    func testMalformedAutomationStateKeepsSessionsAndProjects() throws {
        let project = ProjectRecord(name: "Recoverable", folderPath: "/tmp/recoverable", createdAt: start)
        let active = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: start
        )
        let state = AppState(projects: [project], activeSession: active)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded(state)) as? [String: Any])
        object["sessionPresets"] = [["id": "not-a-uuid"]]
        object["automationRules"] = [["id": "not-a-uuid"]]
        var activeSessions = try XCTUnwrap(object["activeSessions"] as? [[String: Any]])
        var activeObject = try XCTUnwrap(activeSessions.first)
        activeObject["automationMetadata"] = ["controlEnabled": true]
        activeSessions[0] = activeObject
        object["activeSessions"] = activeSessions

        let decoded = try JSONDecoder.iso8601.decode(
            AppState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.projects, state.projects)
        XCTAssertEqual(decoded.activeSession?.id, active.id)
        XCTAssertEqual(decoded.activeSession?.projectID, project.id)
        XCTAssertNil(decoded.activeSession?.automationMetadata)
        XCTAssertTrue(decoded.sessionPresets.isEmpty)
        XCTAssertTrue(decoded.automationRules.isEmpty)
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

    func testCoordinatorUsesTheResolvedProjectForDeveloperToolStarts() throws {
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
            .startWithResolvedProject(rule: fixture.rule, projectID: fixture.project.id, startDate: start)
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

    func testProjectResolutionDrivesOneProjectIndependentCodexAndOpenCodeRule() throws {
        let fixture = try makeTwoProjectFixture()
        let coordinator = SessionAutomationCoordinator()

        let codePulseCodex = event(
            tool: .codex,
            sessionID: "codex-codepulse",
            type: .activity,
            path: fixture.codePulseURL.appendingPathComponent("Sources/CodePulse/Insights").path
        )
        let proxPilotCodex = event(
            tool: .codex,
            sessionID: "codex-proxpilot",
            type: .activity,
            path: fixture.proxPilotURL.path
        )
        let codePulseOpenCode = event(
            tool: .opencode,
            sessionID: "opencode-codepulse",
            type: .activity,
            path: fixture.codePulseURL.path
        )
        let proxPilotOpenCode = event(
            tool: .opencode,
            sessionID: "opencode-proxpilot",
            type: .activity,
            path: fixture.proxPilotURL.appendingPathComponent("Sources").path
        )

        XCTAssertEqual(
            DeveloperToolProjectResolver.projectID(
                for: codePulseCodex.workingDirectory,
                in: fixture.state.projects
            ),
            fixture.codePulse.id
        )
        XCTAssertEqual(
            DeveloperToolProjectResolver.projectID(
                for: proxPilotCodex.workingDirectory,
                in: fixture.state.projects
            ),
            fixture.proxPilot.id
        )
        XCTAssertEqual(
            coordinator.action(for: codePulseCodex, in: fixture.state, now: start),
            .startWithResolvedProject(rule: fixture.codexRule, projectID: fixture.codePulse.id, startDate: start)
        )
        XCTAssertEqual(
            coordinator.action(for: proxPilotCodex, in: fixture.state, now: start),
            .startWithResolvedProject(rule: fixture.codexRule, projectID: fixture.proxPilot.id, startDate: start)
        )
        XCTAssertEqual(
            coordinator.action(for: codePulseOpenCode, in: fixture.state, now: start),
            .startWithResolvedProject(rule: fixture.openCodeRule, projectID: fixture.codePulse.id, startDate: start)
        )
        XCTAssertEqual(
            coordinator.action(for: proxPilotOpenCode, in: fixture.state, now: start),
            .startWithResolvedProject(rule: fixture.openCodeRule, projectID: fixture.proxPilot.id, startDate: start)
        )
    }

    func testDeveloperToolLegacyScopeAndProjectlessFallbackPreserveTemplateSelection() throws {
        let root = try temporaryDirectory()
        let codePulseURL = root.appendingPathComponent("CodePulse", isDirectory: true)
        let proxPilotURL = root.appendingPathComponent("ProxPilot", isDirectory: true)
        try FileManager.default.createDirectory(at: codePulseURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proxPilotURL, withIntermediateDirectories: true)
        let codePulse = ProjectRecord(name: "CodePulse", folderPath: codePulseURL.path, createdAt: start)
        let proxPilot = ProjectRecord(name: "ProxPilot", folderPath: proxPilotURL.path, createdAt: start)
        let codePulseLegacyRule = SessionAutomationRule(
            name: "CodePulse Legacy Codex",
            trigger: .developerTool(.codex),
            projectID: codePulse.id,
            sessionType: .debugging,
            goal: "Goal A",
            minimumSavedDuration: 0
        )
        let projectlessPreset = SessionPreset(
            name: "Projectless Codex Template",
            projectID: nil,
            sessionType: .review,
            goal: "Fallback goal"
        )
        let projectlessRule = SessionAutomationRule(
            name: "Projectless Codex",
            trigger: .developerTool(.codex),
            presetID: projectlessPreset.id,
            minimumSavedDuration: 0
        )
        let state = AppState(
            projects: [codePulse, proxPilot],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [projectlessPreset],
            automationRules: [codePulseLegacyRule, projectlessRule]
        )
        let canonicalLegacyRule = try XCTUnwrap(
            state.automationRules.first(where: { $0.id == codePulseLegacyRule.id })
        )
        let codePulseEvent = event(
            tool: .codex,
            sessionID: "legacy-codepulse",
            type: .sessionStarted,
            path: codePulseURL.path
        )
        let proxPilotEvent = event(
            tool: .codex,
            sessionID: "projectless-proxpilot",
            type: .sessionStarted,
            path: proxPilotURL.path
        )
        let coordinator = SessionAutomationCoordinator()

        XCTAssertEqual(
            coordinator.action(for: codePulseEvent, in: state, now: start),
            .startWithResolvedProject(
                rule: canonicalLegacyRule,
                projectID: codePulse.id,
                startDate: start
            )
        )
        XCTAssertEqual(
            coordinator.action(for: proxPilotEvent, in: state, now: start),
            .startWithResolvedProject(
                rule: projectlessRule,
                projectID: proxPilot.id,
                startDate: start
            )
        )
        XCTAssertNil(
            coordinator.action(
                for: proxPilotEvent,
                in: AppState(
                    projects: [codePulse, proxPilot],
                    settings: CodePulseSettings(automationEnabled: true),
                    automationRules: [codePulseLegacyRule]
                ),
                now: start
            )
        )

        let codePulsePersistence = AutomationTestPersistence(state)
        let codePulseInbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
            applicationSupportDirectory: root.appendingPathComponent("support-codepulse")
        ))
        let codePulseStore = makeStore(
            state: state,
            clock: AutomationTestClock(start),
            persistence: codePulsePersistence,
            inbox: codePulseInbox
        )
        XCTAssertTrue(codePulseStore.startAutomatedSession(
            with: canonicalLegacyRule,
            event: codePulseEvent,
            at: start,
            signalAt: start
        ))
        XCTAssertEqual(codePulseStore.activeSession?.projectID, codePulse.id)
        XCTAssertEqual(codePulseStore.activeSession?.type, .debugging)
        XCTAssertEqual(codePulseStore.activeSession?.goal, "Goal A")

        let proxPilotPersistence = AutomationTestPersistence(state)
        let proxPilotInbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
            applicationSupportDirectory: root.appendingPathComponent("support-proxpilot")
        ))
        let proxPilotStore = makeStore(
            state: state,
            clock: AutomationTestClock(start),
            persistence: proxPilotPersistence,
            inbox: proxPilotInbox
        )
        XCTAssertFalse(proxPilotStore.startAutomatedSession(
            with: canonicalLegacyRule,
            event: proxPilotEvent,
            at: start,
            signalAt: start
        ))
        XCTAssertNil(proxPilotStore.activeSession)
        XCTAssertTrue(proxPilotStore.startAutomatedSession(
            with: projectlessRule,
            event: proxPilotEvent,
            at: start,
            signalAt: start
        ))
        XCTAssertEqual(proxPilotStore.activeSession?.projectID, proxPilot.id)
        XCTAssertEqual(proxPilotStore.activeSession?.type, .review)
        XCTAssertEqual(proxPilotStore.activeSession?.goal, "Fallback goal")

        XCTAssertEqual(
            coordinator.action(
                for: event(
                    tool: .codex,
                    sessionID: "projectless-codepulse",
                    type: .sessionStarted,
                    path: codePulseURL.path
                ),
                in: AppState(
                    projects: [codePulse, proxPilot],
                    settings: CodePulseSettings(automationEnabled: true),
                    sessionPresets: [projectlessPreset],
                    automationRules: [projectlessRule]
                ),
                now: start
            ),
            .startWithResolvedProject(
                rule: projectlessRule,
                projectID: codePulse.id,
                startDate: start
            )
        )
    }

    func testTwoLegacyDeveloperRulesSelectTheMatchingProjectTemplate() throws {
        for tool in DeveloperTool.allCases {
            let root = try temporaryDirectory()
            let codePulseURL = root.appendingPathComponent("CodePulse", isDirectory: true)
            let proxPilotURL = root.appendingPathComponent("ProxPilot", isDirectory: true)
            try FileManager.default.createDirectory(at: codePulseURL, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: proxPilotURL, withIntermediateDirectories: true)
            let codePulse = ProjectRecord(name: "CodePulse", folderPath: codePulseURL.path, createdAt: start)
            let proxPilot = ProjectRecord(name: "ProxPilot", folderPath: proxPilotURL.path, createdAt: start)
            let codePulseRule = SessionAutomationRule(
                name: "CodePulse (\(tool.title))",
                trigger: .developerTool(tool),
                projectID: codePulse.id,
                sessionType: .debugging,
                goal: "Goal A",
                minimumSavedDuration: 0
            )
            let proxPilotRule = SessionAutomationRule(
                name: "ProxPilot (\(tool.title))",
                trigger: .developerTool(tool),
                projectID: proxPilot.id,
                sessionType: .review,
                goal: "Goal B",
                minimumSavedDuration: 0
            )
            let state = AppState(
                projects: [codePulse, proxPilot],
                settings: CodePulseSettings(automationEnabled: true),
                automationRules: [codePulseRule, proxPilotRule]
            )
            let canonicalCodePulseRule = try XCTUnwrap(
                state.automationRules.first(where: { $0.id == codePulseRule.id })
            )
            let canonicalProxPilotRule = try XCTUnwrap(
                state.automationRules.first(where: { $0.id == proxPilotRule.id })
            )
            let codePulseEvent = event(
                tool: tool,
                sessionID: "\(tool.rawValue)-codepulse-legacy",
                type: .sessionStarted,
                path: codePulseURL.path
            )
            let proxPilotEvent = event(
                tool: tool,
                sessionID: "\(tool.rawValue)-proxpilot-legacy",
                type: .sessionStarted,
                path: proxPilotURL.path
            )
            let coordinator = SessionAutomationCoordinator()

            XCTAssertEqual(
                coordinator.action(for: codePulseEvent, in: state, now: start),
                .startWithResolvedProject(
                    rule: canonicalCodePulseRule,
                    projectID: codePulse.id,
                    startDate: start
                ),
                tool.rawValue
            )
            XCTAssertEqual(
                coordinator.action(for: proxPilotEvent, in: state, now: start),
                .startWithResolvedProject(
                    rule: canonicalProxPilotRule,
                    projectID: proxPilot.id,
                    startDate: start
                ),
                tool.rawValue
            )

            let codePulsePersistence = AutomationTestPersistence(state)
            let codePulseStore = makeStore(
                state: state,
                clock: AutomationTestClock(start),
                persistence: codePulsePersistence,
                inbox: DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
                    applicationSupportDirectory: root.appendingPathComponent("support-codepulse")
                ))
            )
            XCTAssertTrue(codePulseStore.startAutomatedSession(
                with: canonicalCodePulseRule,
                event: codePulseEvent,
                at: start,
                signalAt: start
            ))
            XCTAssertEqual(codePulseStore.activeSession?.projectID, codePulse.id)
            XCTAssertEqual(codePulseStore.activeSession?.type, .debugging)
            XCTAssertEqual(codePulseStore.activeSession?.goal, "Goal A")

            let proxPilotPersistence = AutomationTestPersistence(state)
            let proxPilotStore = makeStore(
                state: state,
                clock: AutomationTestClock(start),
                persistence: proxPilotPersistence,
                inbox: DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
                    applicationSupportDirectory: root.appendingPathComponent("support-proxpilot")
                ))
            )
            XCTAssertTrue(proxPilotStore.startAutomatedSession(
                with: canonicalProxPilotRule,
                event: proxPilotEvent,
                at: start,
                signalAt: start
            ))
            XCTAssertEqual(proxPilotStore.activeSession?.projectID, proxPilot.id)
            XCTAssertEqual(proxPilotStore.activeSession?.type, .review)
            XCTAssertEqual(proxPilotStore.activeSession?.goal, "Goal B")
        }
    }

    func testAmbiguousProjectlessDeveloperRulesFailClosed() throws {
        for tool in DeveloperTool.allCases {
            let root = try temporaryDirectory()
            let projectURL = root.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let project = ProjectRecord(name: "Project", folderPath: projectURL.path, createdAt: start)
            let firstPreset = SessionPreset(name: "First (\(tool.title))", projectID: nil)
            let secondPreset = SessionPreset(name: "Second (\(tool.title))", projectID: nil)
            let firstRule = SessionAutomationRule(
                name: "First (\(tool.title))",
                trigger: .developerTool(tool),
                presetID: firstPreset.id,
                minimumSavedDuration: 0
            )
            let secondRule = SessionAutomationRule(
                name: "Second (\(tool.title))",
                trigger: .developerTool(tool),
                presetID: secondPreset.id,
                minimumSavedDuration: 0
            )
            let state = AppState(
                projects: [project],
                settings: CodePulseSettings(automationEnabled: true),
                sessionPresets: [firstPreset, secondPreset],
                automationRules: [firstRule, secondRule]
            )
            let event = event(
                tool: tool,
                sessionID: "\(tool.rawValue)-ambiguous-projectless",
                type: .sessionStarted,
                path: projectURL.path
            )

            XCTAssertNil(SessionAutomationCoordinator().action(for: event, in: state, now: start), tool.rawValue)
            XCTAssertTrue(
                SessionAutomationCoordinator().rulesSupporting(
                    .developerTool(tool: tool, externalSessionID: event.externalSessionID),
                    projectID: project.id,
                    in: state
                ).isEmpty,
                tool.rawValue
            )
        }
    }

    func testAmbiguousLegacyDeveloperRulesFailClosed() throws {
        for tool in DeveloperTool.allCases {
            let root = try temporaryDirectory()
            let projectURL = root.appendingPathComponent("Project", isDirectory: true)
            try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
            let project = ProjectRecord(name: "Project", folderPath: projectURL.path, createdAt: start)
            let firstRule = SessionAutomationRule(
                name: "First (\(tool.title))",
                trigger: .developerTool(tool),
                projectID: project.id,
                goal: "Goal A",
                minimumSavedDuration: 0
            )
            let secondRule = SessionAutomationRule(
                name: "Second (\(tool.title))",
                trigger: .developerTool(tool),
                projectID: project.id,
                goal: "Goal B",
                minimumSavedDuration: 0
            )
            let state = AppState(
                projects: [project],
                settings: CodePulseSettings(automationEnabled: true),
                automationRules: [firstRule, secondRule]
            )
            let event = event(
                tool: tool,
                sessionID: "\(tool.rawValue)-ambiguous-legacy",
                type: .sessionStarted,
                path: projectURL.path
            )

            XCTAssertNil(SessionAutomationCoordinator().action(for: event, in: state, now: start), tool.rawValue)
            XCTAssertTrue(
                SessionAutomationCoordinator().rulesSupporting(
                    .developerTool(tool: tool, externalSessionID: event.externalSessionID),
                    projectID: project.id,
                    in: state
                ).isEmpty,
                tool.rawValue
            )
        }
    }

    func testDirectDeveloperToolStartWithoutAnEventProjectFailsClosed() throws {
        let fixture = try makeTwoProjectFixture()
        let persistence = AutomationTestPersistence(fixture.state)
        let inbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
            applicationSupportDirectory: fixture.root.appendingPathComponent("support")
        ))
        let store = makeStore(
            state: fixture.state,
            clock: AutomationTestClock(start),
            persistence: persistence,
            inbox: inbox
        )

        XCTAssertFalse(store.startAutomatedSession(
            with: fixture.codexRule,
            source: .developerTool(tool: .codex, externalSessionID: "without-event"),
            at: start,
            signalAt: start
        ))
        XCTAssertNil(store.activeSession)
    }

    func testUnattributedDeveloperToolActivityFailsClosedForProjectAutomations() throws {
        let fixture = try makeTwoProjectFixture()
        let coordinator = SessionAutomationCoordinator()
        let outside = fixture.root.appendingPathComponent("unrelated-repository", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let unrelated = event(
            tool: .codex,
            sessionID: "codex-unrelated",
            type: .activity,
            path: outside.path
        )
        let malformed = event(
            tool: .opencode,
            sessionID: "opencode-relative",
            type: .activity,
            path: "relative/project"
        )

        XCTAssertNil(DeveloperToolProjectResolver.projectID(
            for: unrelated.workingDirectory,
            in: fixture.state.projects
        ))
        XCTAssertNil(coordinator.action(for: unrelated, in: fixture.state, now: start))
        XCTAssertNil(coordinator.action(for: malformed, in: fixture.state, now: start))

        let activeFixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(
                tool: .codex,
                sessionID: "active-codepulse",
                type: .sessionStarted,
                path: fixtureProjectPath()
            )
        )
        XCTAssertNil(coordinator.action(for: malformed, in: activeFixture.store.state, now: start))
    }

    func testSeparateDeveloperToolSessionsRemainProjectIsolatedWithoutGlobalCurrentProject() throws {
        let fixture = try makeTwoProjectFixture()
        let coordinator = SessionAutomationCoordinator()
        let codePulseEvent = event(
            tool: .codex,
            sessionID: "session-a",
            type: .sessionStarted,
            path: fixture.codePulseURL.appendingPathComponent("Sources").path
        )
        let proxPilotEvent = event(
            tool: .codex,
            sessionID: "session-b",
            type: .sessionStarted,
            path: fixture.proxPilotURL.appendingPathComponent("Sources").path
        )

        let firstAction = coordinator.action(for: codePulseEvent, in: fixture.state, now: start)
        let secondAction = coordinator.action(for: proxPilotEvent, in: fixture.state, now: start)

        XCTAssertEqual(firstAction, .startWithResolvedProject(rule: fixture.codexRule, projectID: fixture.codePulse.id, startDate: start))
        XCTAssertEqual(secondAction, .startWithResolvedProject(rule: fixture.codexRule, projectID: fixture.proxPilot.id, startDate: start))
        if case .startWithResolvedProject(let firstRule, let firstProjectID, _) = firstAction {
            XCTAssertEqual(firstRule.presetID, fixture.codexRule.presetID)
            XCTAssertEqual(firstProjectID, fixture.codePulse.id)
        } else {
            XCTFail("CodePulse activity did not produce a start action")
        }
        if case .startWithResolvedProject(let secondRule, let secondProjectID, _) = secondAction {
            XCTAssertEqual(secondRule.presetID, fixture.codexRule.presetID)
            XCTAssertEqual(secondProjectID, fixture.proxPilot.id)
        } else {
            XCTFail("ProxPilot activity did not produce a start action")
        }
    }

    func testActiveDeveloperToolSessionRemainsIsolatedWhenAnotherProjectEventArrives() throws {
        for tool in DeveloperTool.allCases {
            let fixture = try makeTwoProjectFixture()
            let clock = AutomationTestClock(start)
            let persistence = AutomationTestPersistence(fixture.state)
            let inbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
                applicationSupportDirectory: fixture.root.appendingPathComponent("support-\(tool.rawValue)")
            ))
            let store = makeStore(
                state: fixture.state,
                clock: clock,
                persistence: persistence,
                inbox: inbox
            )

            let codePulseEvent = event(
                tool: tool,
                sessionID: "\(tool.rawValue)-codepulse",
                type: .sessionStarted,
                path: fixture.codePulseURL.appendingPathComponent("Sources").path,
                timestamp: start
            )
            XCTAssertNotNil(store.sessionAutomationCoordinator.action(for: codePulseEvent, in: store.state, now: start))
            try inbox.write(codePulseEvent)
            clock.now = start.addingTimeInterval(5)
            store.refresh()

            let codePulseSessionID = try XCTUnwrap(store.activeSession?.id)
            XCTAssertEqual(store.activeSession?.projectID, fixture.codePulse.id)
            XCTAssertTrue(store.activeSession?.automationMetadata?.controlEnabled == true)
            XCTAssertEqual(
                store.activeSession?.automationMetadata?.claims.map(\.source),
                [.developerTool(tool: tool, externalSessionID: "\(tool.rawValue)-codepulse")]
            )

            clock.now = start.addingTimeInterval(10)
            try inbox.write(event(
                tool: tool,
                sessionID: "\(tool.rawValue)-proxpilot",
                type: .activity,
                path: fixture.proxPilotURL.appendingPathComponent("Sources").path,
                timestamp: clock.now
            ))
            store.refresh()

            XCTAssertEqual(store.state.activeSessions.count, 2)
            let original = try XCTUnwrap(store.state.activeSession(id: codePulseSessionID))
            XCTAssertEqual(original.projectID, fixture.codePulse.id)
            XCTAssertEqual(
                original.automationMetadata?.claims.map(\.source),
                [.developerTool(tool: tool, externalSessionID: "\(tool.rawValue)-codepulse")]
            )
            XCTAssertFalse(original.developerToolContexts.contains(where: {
                $0.externalSessionID == "\(tool.rawValue)-proxpilot"
            }))
            XCTAssertEqual(
                store.state.activeSessions.first(where: { $0.id != codePulseSessionID })?.projectID,
                fixture.proxPilot.id
            )
            XCTAssertEqual(store.state.developerToolIntegration?.processedEvents.count, 2)
        }
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
            tool: .opencode,
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

    func testDifferentThreadsOwnDifferentSessionsAndOneEndDoesNotPauseTheOther() throws {
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
        XCTAssertEqual(fixture.store.state.activeSessions.count, 2)
        let openCodeSessionID = try XCTUnwrap(fixture.store.state.activeSessions.first(where: { $0.id != sessionID })?.id)
        let openCodeBefore = fixture.store.state.activeSession(id: openCodeSessionID)

        clock.now = start.addingTimeInterval(10)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionEnded,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()

        XCTAssertEqual(fixture.store.state.activeSession(id: sessionID)?.phase, .running)
        XCTAssertEqual(
            fixture.store.state.activeSession(id: sessionID)?.automationMetadata?.claims.first?.isActive,
            false
        )
        XCTAssertEqual(fixture.store.state.activeSession(id: openCodeSessionID), openCodeBefore)
    }

    func testSecondaryDeveloperToolClaimAdmissionIsAtomicAtCapacityAndRetirementProtection() throws {
        struct AdmissionCase {
            let sessionID: String
            let retired: [RetiredDeveloperToolThread]
        }
        let protectedIdentity = DeveloperToolThreadIdentity(tool: .opencode, externalSessionID: "protected-secondary")
        let cases = [
            AdmissionCase(
                sessionID: "capacity-secondary",
                retired: (0..<2_047).map { index in
                    RetiredDeveloperToolThread(
                        tool: .codex,
                        externalSessionID: "retained-" + String(index),
                        retiredAt: start.addingTimeInterval(-1),
                        lastAcceptedEventAt: start.addingTimeInterval(-1)
                    )
                }
            ),
            AdmissionCase(
                sessionID: protectedIdentity.externalSessionID,
                retired: [RetiredDeveloperToolThread(
                    tool: protectedIdentity.tool,
                    externalSessionID: protectedIdentity.externalSessionID,
                    retiredAt: start,
                    lastAcceptedEventAt: start
                )]
            )
        ]

        for admissionCase in cases {
            let fixture = try makeFixture(
                tool: .codex,
                enabled: true,
                seedEvent: nil,
                includeOpenCodeRule: true,
                minimumSavedDuration: 0
            )
            let primaryIdentity = DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "primary-owner")
            let metadata = SessionAutomationMetadata(
                startedByRuleID: fixture.rule.id,
                startedByRuleName: fixture.rule.name,
                startedBySource: .developerTool(
                    tool: primaryIdentity.tool,
                    externalSessionID: primaryIdentity.externalSessionID
                ),
                lastMatchingSignalAt: start,
                pauseDelay: 60,
                finishDelay: 300,
                minimumSavedDuration: 0,
                claims: [SessionAutomationClaim(
                    source: .developerTool(
                        tool: primaryIdentity.tool,
                        externalSessionID: primaryIdentity.externalSessionID
                    ),
                    isActive: true,
                    lastSignalAt: start
                )]
            )
            var state = fixture.state
            state.activeSession = ActiveSession(
                projectID: fixture.project.id,
                projectName: fixture.project.name,
                startedAt: start,
                automationMetadata: metadata
            )
            state.developerToolIntegration = DeveloperToolIntegrationProcessingState(
                retiredDeveloperToolThreads: admissionCase.retired,
                reservedDeveloperToolThreads: [primaryIdentity]
            )
            let persistence = AutomationTestPersistence(state)
            let clock = AutomationTestClock(start)
            let inbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
                applicationSupportDirectory: fixture.root.appendingPathComponent("atomic-" + admissionCase.sessionID)
            ))
            let store = makeStore(
                state: state,
                clock: clock,
                persistence: persistence,
                inbox: inbox
            )

            if admissionCase.sessionID == "capacity-secondary" {
                XCTAssertEqual(store.state.developerToolIntegration?.retiredDeveloperToolThreads.count, 2_047)
            }
            clock.now = start.addingTimeInterval(5)
            try inbox.write(event(
                tool: .opencode,
                sessionID: admissionCase.sessionID,
                type: .activity,
                path: fixture.projectURL.path,
                timestamp: clock.now
            ))
            store.refresh()

            let claims = store.activeSession?.automationMetadata?.claims ?? []
            XCTAssertEqual(claims.map(\.externalSessionID), [primaryIdentity.externalSessionID])
            XCTAssertFalse(store.state.developerToolOwnershipIdentities.contains(
                DeveloperToolThreadIdentity(tool: .opencode, externalSessionID: admissionCase.sessionID)
            ))
            XCTAssertEqual(store.state.reservedDeveloperToolOwnershipIdentities, Set([primaryIdentity]))
            if admissionCase.sessionID == protectedIdentity.externalSessionID {
                XCTAssertTrue(store.state.developerToolIntegration?.retiredDeveloperToolThreads.contains {
                    $0.identity == protectedIdentity
                } == true)
            } else {
                XCTAssertEqual(store.state.developerToolIntegration?.retiredDeveloperToolThreads.count, 2_047)
                XCTAssertTrue(store.state.developerToolIntegration?.retiredDeveloperToolThreads.first?.isProtected(at: clock.now) == true)
                XCTAssertEqual(store.state.protectedRetiredDeveloperToolThreadCount(at: clock.now), 2_047)
                XCTAssertEqual(store.state.developerToolThreadCapacityUsed(at: clock.now), 2_048)
            }
        }
    }

    func testAutomationRelinquishmentPreservesInactiveDeveloperToolOwnershipUntilRetirement() throws {
        for automationEnabled in [false, true] {
            let fixture = try makeFixture(
                tool: .codex,
                enabled: automationEnabled,
                seedEvent: nil,
                ruleEnabled: !automationEnabled,
                minimumSavedDuration: 0
            )
            let identity = DeveloperToolThreadIdentity(
                tool: .codex,
                externalSessionID: "retained-owner-" + String(automationEnabled)
            )
            let metadata = SessionAutomationMetadata(
                startedByRuleID: fixture.rule.id,
                startedByRuleName: fixture.rule.name,
                startedBySource: .developerTool(tool: identity.tool, externalSessionID: identity.externalSessionID),
                lastMatchingSignalAt: start,
                pauseDelay: 1,
                finishDelay: 2,
                minimumSavedDuration: 0,
                claims: [SessionAutomationClaim(
                    source: .developerTool(tool: identity.tool, externalSessionID: identity.externalSessionID),
                    isActive: true,
                    lastSignalAt: start
                )]
            )
            var state = fixture.state
            state.activeSession = ActiveSession(
                projectID: fixture.project.id,
                projectName: fixture.project.name,
                startedAt: start,
                automationMetadata: metadata
            )
            state.developerToolIntegration = DeveloperToolIntegrationProcessingState(
                reservedDeveloperToolThreads: [identity]
            )
            let persistence = AutomationTestPersistence(state)
            let store = makeStore(
                state: state,
                clock: AutomationTestClock(start),
                persistence: persistence,
                inbox: DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(
                    applicationSupportDirectory: fixture.root.appendingPathComponent(
                        "relinquish-" + String(automationEnabled)
                    )
                ))
            )

            XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)
            XCTAssertEqual(store.activeSession?.automationMetadata?.claims.map(\.isActive), [false])
            XCTAssertTrue(store.state.developerToolOwnershipIdentities.contains(identity))
            XCTAssertTrue(store.state.reservedDeveloperToolOwnershipIdentities.contains(identity))

            XCTAssertTrue(store.finish(at: start.addingTimeInterval(1)))
            XCTAssertTrue(store.discardSession())
            XCTAssertNil(store.activeSession)
            XCTAssertTrue(store.state.developerToolIntegration?.retiredDeveloperToolThreads.contains {
                $0.identity == identity
            } == true)
        }
    }

    func testAutomaticCodexTurnDoesNotPauseWithoutIdleSignal() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 0
        )

        clock.now = start.addingTimeInterval(59)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .running)

        clock.now = start.addingTimeInterval(60)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .running)

        clock.now = start.addingTimeInterval(300)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .running)
        XCTAssertTrue(fixture.store.activeSession?.automationMetadata?.claims.first?.isActive == true)
    }

    func testAutomaticCodexStopBeginsPauseCountdownAtExactThreshold() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 0
        )

        clock.now = start.addingTimeInterval(300)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionIdle,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()

        clock.now = start.addingTimeInterval(359)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .running)

        clock.now = start.addingTimeInterval(360)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .paused)
    }

    func testAutomaticCodexTurnBeforePauseCancelsIdleCountdown() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 0
        )
        let sessionID = try XCTUnwrap(fixture.store.activeSession?.id)

        clock.now = start.addingTimeInterval(300)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionIdle,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()

        clock.now = start.addingTimeInterval(330)
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
        XCTAssertEqual(fixture.store.activeSession?.pauseIntervals.count, 0)
        XCTAssertTrue(fixture.store.activeSession?.automationMetadata?.claims.first?.isActive == true)
    }

    func testAutomaticCodexTurnAfterPauseResumesSameSession() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 0
        )
        let sessionID = try XCTUnwrap(fixture.store.activeSession?.id)

        clock.now = start.addingTimeInterval(300)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionIdle,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()
        clock.now = start.addingTimeInterval(360)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .paused)

        clock.now = start.addingTimeInterval(390)
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
        XCTAssertTrue(fixture.persistence.state.completedSessions.isEmpty)
    }

    func testAutomaticCodexSessionEndMarksClaimIdle() throws {
        let clock = AutomationTestClock(start)
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-a", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 0
        )

        clock.now = start.addingTimeInterval(300)
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionEnded,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        fixture.store.refresh()

        XCTAssertEqual(
            fixture.store.activeSession?.automationMetadata?.claims.first?.isActive,
            false
        )
        clock.now = start.addingTimeInterval(359)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .running)
        clock.now = start.addingTimeInterval(360)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .paused)
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
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-a",
            type: .sessionIdle,
            path: fixture.projectURL.path,
            timestamp: start
        ))
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
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-git",
            type: .sessionIdle,
            path: fixture.projectURL.path,
            timestamp: start
        ))
        try await settle(fixture.store)
        clock.now = start.addingTimeInterval(20)
        fixture.store.refresh()
        try await settle(fixture.store)

        XCTAssertEqual(gitService.finishCaptureCount, 1)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertEqual(persistence.state.completedSessions[0].gitContext?.branchAtEnd, "automation-end")
    }

    func testAutomaticFinishCommitFailureLeavesPausedSessionForRetry() async throws {
        let clock = AutomationTestClock(start)
        let persistence = AutomationTestPersistence()
        let fixture = try makeFixture(
            tool: .codex,
            enabled: true,
            seedEvent: event(tool: .codex, sessionID: "codex-finish-retry", type: .sessionStarted, path: fixtureProjectPath()),
            clock: clock,
            persistence: persistence,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0
        )
        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "codex-finish-retry",
            type: .sessionIdle,
            path: fixture.projectURL.path,
            timestamp: start.addingTimeInterval(5)
        ))

        clock.now = start.addingTimeInterval(6)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.phase, .paused)

        persistence.failCriticalSaves = true
        clock.now = start.addingTimeInterval(7)
        fixture.store.refresh()
        try await settle(fixture.store)
        XCTAssertEqual(fixture.store.phase, .paused)
        XCTAssertFalse(persistence.state.activeSession?.automationMetadata?.pendingAutomaticSave ?? true)

        persistence.failCriticalSaves = false
        fixture.store.refresh()
        try await settle(fixture.store)
        XCTAssertEqual(fixture.store.phase, .idle)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)

        fixture.store.refresh()
        try await settle(fixture.store)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
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
        try short.inbox.write(event(
            tool: .codex,
            sessionID: "short",
            type: .sessionIdle,
            path: short.projectURL.path,
            timestamp: start
        ))
        shortClock.now = start.addingTimeInterval(6)
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
        try exact.inbox.write(event(
            tool: .codex,
            sessionID: "exact",
            type: .sessionIdle,
            path: exact.projectURL.path,
            timestamp: start
        ))
        exactClock.now = start.addingTimeInterval(6)
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

        try fixture.inbox.write(event(
            tool: .codex,
            sessionID: "restore",
            type: .sessionIdle,
            path: fixture.projectURL.path,
            timestamp: clock.now
        ))
        running.refresh()
        clock.now = start.addingTimeInterval(15)
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
        persistence.failNextCriticalSave = true
        let failedRestore = makeStore(state: state, clock: clock, persistence: persistence, inbox: inbox)
        try await settle(failedRestore)
        XCTAssertEqual(failedRestore.phase, .finishing)
        XCTAssertEqual(persistence.state.completedSessions.count, 0)

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

    func testAutomaticMinimumDurationDiscardFailureRemainsRetryable() async throws {
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
            minimumSavedDuration: 3
        )
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedByTool: .codex,
            lastMatchingSignalAt: start,
            pendingAutomaticSave: true,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 3,
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

        let state = AppState(
            projects: [project],
            activeSession: automatic,
            settings: CodePulseSettings(automationEnabled: true),
            automationRules: [rule]
        )
        let persistence = AutomationTestPersistence(state)
        let clock = AutomationTestClock(start.addingTimeInterval(2))
        let inbox = DeveloperToolInbox(
            paths: DeveloperToolIntegrationPaths(applicationSupportDirectory: root.appendingPathComponent("support"))
        )

        persistence.failNextCriticalSave = true
        let failedRestore = makeStore(state: state, clock: clock, persistence: persistence, inbox: inbox)
        try await settle(failedRestore)
        XCTAssertEqual(failedRestore.phase, .finishing)
        XCTAssertNotNil(persistence.state.activeSession)
        XCTAssertTrue(persistence.state.completedSessions.isEmpty)

        let retry = makeStore(state: state, clock: clock, persistence: persistence, inbox: inbox)
        try await settle(retry)
        XCTAssertEqual(retry.phase, .idle)
        XCTAssertNil(persistence.state.activeSession)
        XCTAssertTrue(persistence.state.completedSessions.isEmpty)

        let secondRetry = makeStore(state: persistence.state, clock: clock, persistence: persistence, inbox: inbox)
        XCTAssertEqual(secondRetry.phase, .idle)
        XCTAssertTrue(persistence.state.completedSessions.isEmpty)
    }

    private func makeTwoProjectFixture() throws -> TwoProjectAutomationFixture {
        let root = try temporaryDirectory()
        let codePulseURL = root.appendingPathComponent("CodePulse", isDirectory: true)
        let proxPilotURL = root.appendingPathComponent("ProxPilot", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codePulseURL.appendingPathComponent("Sources/CodePulse/Insights", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: proxPilotURL.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )

        let codePulse = ProjectRecord(
            name: "CodePulse",
            folderPath: codePulseURL.path,
            createdAt: start
        )
        let proxPilot = ProjectRecord(
            name: "ProxPilot",
            folderPath: proxPilotURL.path,
            createdAt: start
        )
        let codexPreset = SessionPreset(
            name: "Developer coding template",
            projectID: nil,
            goal: "Automated goal"
        )
        let openCodePreset = SessionPreset(
            name: "Developer review template",
            projectID: nil,
            sessionType: .review
        )
        let codexRule = SessionAutomationRule(
            name: "Codex automation",
            trigger: .developerTool(.codex),
            presetID: codexPreset.id,
            minimumSavedDuration: 0
        )
        let openCodeRule = SessionAutomationRule(
            name: "OpenCode automation",
            trigger: .developerTool(.opencode),
            presetID: openCodePreset.id,
            minimumSavedDuration: 0
        )
        let state = AppState(
            projects: [codePulse, proxPilot],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [codexPreset, openCodePreset],
            automationRules: [
                codexRule,
                openCodeRule
            ]
        )

        return TwoProjectAutomationFixture(
            root: root,
            codePulseURL: codePulseURL,
            proxPilotURL: proxPilotURL,
            codePulse: codePulse,
            proxPilot: proxPilot,
            codexRule: codexRule,
            openCodeRule: openCodeRule,
            state: state
        )
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
            .appendingPathComponent("CodePulseAutomationTests-\(UUID().uuidString)", isDirectory: true)
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

private struct TwoProjectAutomationFixture {
    let root: URL
    let codePulseURL: URL
    let proxPilotURL: URL
    let codePulse: ProjectRecord
    let proxPilot: ProjectRecord
    let codexRule: SessionAutomationRule
    let openCodeRule: SessionAutomationRule
    let state: AppState
}

private final class AutomationTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class AutomationTestPersistence: StatePersisting {
    var state: AppState
    var failCriticalSaves = false
    var failNextCriticalSave = false

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }

    func saveCritical(_ state: AppState) throws {
        if failCriticalSaves || failNextCriticalSave {
            failNextCriticalSave = false
            throw AutomationCriticalSaveFailure()
        }
        self.state = state
    }
}

private struct AutomationCriticalSaveFailure: Error {}

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
