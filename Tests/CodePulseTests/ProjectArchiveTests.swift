import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

@MainActor
final class ProjectArchiveTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_750_000_000)

    func testLegacyProjectDecodesAsActiveWhenArchiveFieldIsMissing() throws {
        let project = ProjectRecord(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            name: "Legacy Project",
            folderPath: "/tmp/legacy-project",
            createdAt: start,
            lastUsedAt: start.addingTimeInterval(60)
        )
        let data = try JSONEncoder().encode(project)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["archivedAt"])

        let decoded = try JSONDecoder().decode(ProjectRecord.self, from: data)
        XCTAssertFalse(decoded.isArchived)
        XCTAssertNil(decoded.archivedAt)
        XCTAssertEqual(decoded.id, project.id)
        XCTAssertEqual(decoded.name, project.name)
        XCTAssertEqual(decoded.folderPath, project.folderPath)
        XCTAssertEqual(decoded.lastUsedAt, project.lastUsedAt)
    }

    func testArchiveAndRestoreUseInjectedTimestampAndPreserveProjectIdentity() throws {
        let projectID = UUID()
        let createdAt = start.addingTimeInterval(-500)
        let lastUsedAt = start.addingTimeInterval(-100)
        let project = ProjectRecord(
            id: projectID,
            name: "Archive Me",
            folderPath: "/tmp/archive-me",
            createdAt: createdAt,
            lastUsedAt: lastUsedAt
        )
        let persistence = ArchivePersistence(AppState(projects: [project]))
        let store = makeStore(persistence: persistence)
        let archivedAt = start.addingTimeInterval(42)

        let archived = try store.archiveProject(id: projectID, at: archivedAt)

        XCTAssertEqual(archived.id, projectID)
        XCTAssertEqual(archived.name, project.name)
        XCTAssertEqual(archived.folderPath, project.folderPath)
        XCTAssertEqual(archived.createdAt, createdAt)
        XCTAssertEqual(archived.lastUsedAt, lastUsedAt)
        XCTAssertEqual(archived.archivedAt, archivedAt)
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(persistence.state.projects.first?.archivedAt, archivedAt)

        let restored = try store.restoreProject(id: projectID)
        XCTAssertEqual(restored.id, projectID)
        XCTAssertNil(restored.archivedAt)
        XCTAssertFalse(restored.isArchived)
        XCTAssertEqual(restored.name, project.name)
        XCTAssertEqual(restored.folderPath, project.folderPath)
        XCTAssertEqual(restored.createdAt, createdAt)
        XCTAssertEqual(restored.lastUsedAt, lastUsedAt)
    }

    func testArchiveStatePersistsAcrossStoreReloadAndCannotBeAppliedTwice() throws {
        let project = ProjectRecord(name: "Persistent Project", createdAt: start)
        let persistence = ArchivePersistence(AppState(projects: [project]))
        let clock = ArchiveClock(start)
        let firstStore = makeStore(persistence: persistence, clock: clock)
        let archivedAt = start.addingTimeInterval(7)

        _ = try firstStore.archiveProject(id: project.id, at: archivedAt)

        let restoredStore = makeStore(persistence: persistence, clock: clock)
        XCTAssertEqual(restoredStore.state.projects.first?.archivedAt, archivedAt)
        XCTAssertThrowsError(try restoredStore.archiveProject(id: project.id, at: start)) { error in
            XCTAssertEqual(error as? ProjectArchiveError, .alreadyArchived)
        }
        _ = try restoredStore.restoreProject(id: project.id)
        XCTAssertThrowsError(try restoredStore.restoreProject(id: project.id)) { error in
            XCTAssertEqual(error as? ProjectArchiveError, .alreadyActive)
        }
    }

    func testArchivedProjectCannotStartManuallyAndRestoreMakesItSelectableAgain() throws {
        let project = ProjectRecord(name: "Inactive Project", createdAt: start)
        let persistence = ArchivePersistence(AppState(projects: [project]))
        let store = makeStore(persistence: persistence)

        XCTAssertTrue(store.startSession(projectID: project.id, goal: "before archive"))
        XCTAssertTrue(store.finish(at: start.addingTimeInterval(60)))
        XCTAssertTrue(store.saveFinishedSession(outcome: nil))

        _ = try store.archiveProject(id: project.id, at: start.addingTimeInterval(120))
        XCTAssertFalse(store.selectableProjectsSortedByRecentUse.contains(where: { $0.id == project.id }))
        XCTAssertFalse(store.startSession(projectID: project.id, goal: "blocked"))
        XCTAssertNil(store.activeSession)

        _ = try store.restoreProject(id: project.id)
        XCTAssertTrue(store.selectableProjectsSortedByRecentUse.contains(where: { $0.id == project.id }))
        XCTAssertTrue(store.startSession(projectID: project.id, goal: "after restore"))
        XCTAssertEqual(store.activeSession?.projectID, project.id)
    }

    func testArchivingActiveProjectIsBlockedForEveryLifecyclePhase() throws {
        for phase in [SessionPhase.running, .paused, .finishing] {
            let project = ProjectRecord(name: "Live Project", createdAt: start)
            let active = ActiveSession(
                projectID: project.id,
                projectName: project.name,
                startedAt: start,
                phase: phase
            )
            let store = makeStore(
                persistence: ArchivePersistence(AppState(projects: [project], activeSession: active))
            )

            XCTAssertThrowsError(try store.archiveProject(id: project.id, at: start.addingTimeInterval(1))) { error in
                XCTAssertEqual(error as? ProjectArchiveError, .activeSession)
                XCTAssertEqual(error.localizedDescription, "Finish or discard the current session before archiving this project.")
            }
            XCTAssertFalse(store.state.projects[0].isArchived)
        }
    }

    func testProjectGuardsInspectEveryActiveSessionAndLeaveUnrelatedProjectOperable() throws {
        let firstWorkspace = WorkspaceRecord(name: "First", createdAt: start)
        let secondWorkspace = WorkspaceRecord(name: "Second", createdAt: start)
        let guarded = ProjectRecord(
            workspaceID: firstWorkspace.id,
            name: "Guarded",
            createdAt: start
        )
        let secondGuarded = ProjectRecord(
            workspaceID: firstWorkspace.id,
            name: "Second Guarded",
            createdAt: start
        )
        let unrelated = ProjectRecord(
            workspaceID: firstWorkspace.id,
            name: "Unrelated",
            createdAt: start
        )

        for phase in [SessionPhase.running, .paused, .finishing] {
            var firstSession = ActiveSession(
                projectID: guarded.id,
                projectName: guarded.name,
                startedAt: start,
                phase: phase
            )
            if phase == .paused {
                firstSession.pauseIntervals = [PauseInterval(startedAt: start)]
            } else if phase == .finishing {
                firstSession.endedAt = start.addingTimeInterval(10)
            }
            let secondSession = ActiveSession(
                projectID: secondGuarded.id,
                projectName: secondGuarded.name,
                startedAt: start.addingTimeInterval(1)
            )
            let persistence = ArchivePersistence(AppState(
                workspaces: [firstWorkspace, secondWorkspace],
                projects: [guarded, secondGuarded, unrelated],
                activeSessions: [firstSession, secondSession]
            ))
            let store = makeStore(persistence: persistence)

            XCTAssertThrowsError(try store.archiveProject(id: guarded.id, at: start.addingTimeInterval(20))) { error in
                XCTAssertEqual(error as? ProjectArchiveError, .activeSession)
            }
            XCTAssertFalse(store.moveProject(id: guarded.id, to: secondWorkspace.id))
            store.deleteProject(id: guarded.id)
            XCTAssertTrue(store.state.projects.contains(where: { $0.id == guarded.id }))

            _ = try store.archiveProject(id: unrelated.id, at: start.addingTimeInterval(20))
            XCTAssertTrue(store.state.projects.first(where: { $0.id == unrelated.id })?.isArchived == true)
        }
    }

    func testArchivingDefaultProjectNormalizesSpecificAndLastUsedResolution() throws {
        let first = ProjectRecord(
            name: "First",
            createdAt: start,
            lastUsedAt: start.addingTimeInterval(10)
        )
        let second = ProjectRecord(
            name: "Second",
            createdAt: start,
            lastUsedAt: start.addingTimeInterval(20)
        )
        let settings = CodePulseSettings(
            defaultProjectBehavior: .specificProject,
            specificProjectID: first.id
        )
        let store = makeStore(
            persistence: ArchivePersistence(AppState(projects: [first, second], settings: settings))
        )

        _ = try store.archiveProject(id: second.id, at: start.addingTimeInterval(30))
        XCTAssertEqual(store.state.settings.defaultProjectBehavior, .specificProject)
        XCTAssertEqual(store.state.settings.specificProjectID, first.id)
        XCTAssertEqual(store.defaultProjectID, first.id)

        _ = try store.archiveProject(id: first.id, at: start.addingTimeInterval(40))
        XCTAssertEqual(store.state.settings.defaultProjectBehavior, .lastUsed)
        XCTAssertNil(store.state.settings.specificProjectID)
        XCTAssertNil(store.defaultProjectID)

        _ = try store.restoreProject(id: second.id)
        XCTAssertEqual(store.defaultProjectID, second.id)
        _ = try store.restoreProject(id: first.id)
        XCTAssertEqual(store.defaultProjectID, second.id)
        XCTAssertEqual(store.state.settings.defaultProjectBehavior, .lastUsed)
    }

    func testDecodedArchivedSpecificDefaultNormalizesWithoutChangingProjectState() {
        let archived = ProjectRecord(
            name: "Old Default",
            createdAt: start,
            archivedAt: start.addingTimeInterval(-1)
        )
        let state = AppState(
            projects: [archived],
            settings: CodePulseSettings(
                defaultProjectBehavior: .specificProject,
                specificProjectID: archived.id
            )
        )
        let persistence = ArchivePersistence(state)
        let store = makeStore(persistence: persistence)

        XCTAssertEqual(store.state.projects.first?.archivedAt, archived.archivedAt)
        XCTAssertEqual(store.state.settings.defaultProjectBehavior, .lastUsed)
        XCTAssertNil(store.state.settings.specificProjectID)
        XCTAssertNil(store.defaultProjectID)
    }

    func testArchivedPresetIsPreservedUnavailableForQuickStartAndValidAfterRestore() throws {
        let project = ProjectRecord(name: "Preset Project", createdAt: start)
        let preset = SessionPreset(
            id: UUID(),
            name: "Coding Preset",
            projectID: project.id,
            sessionType: .coding,
            goal: "Keep this goal"
        )
        let store = makeStore(
            persistence: ArchivePersistence(AppState(projects: [project], sessionPresets: [preset]))
        )

        XCTAssertTrue(store.sessionPresetsAvailableForManualStart.contains(where: { $0.id == preset.id }))
        _ = try store.archiveProject(id: project.id, at: start.addingTimeInterval(1))

        XCTAssertEqual(store.sessionPreset(id: preset.id), preset)
        XCTAssertFalse(store.isSessionPresetAvailableForManualStart(preset))
        XCTAssertFalse(store.sessionPresetsAvailableForManualStart.contains(where: { $0.id == preset.id }))
        XCTAssertEqual(store.projectsForPresetEditing(preset).last?.id, project.id)

        _ = try store.restoreProject(id: project.id)
        XCTAssertTrue(store.isSessionPresetAvailableForManualStart(preset))
        XCTAssertTrue(store.sessionPresetsAvailableForManualStart.contains(where: { $0.id == preset.id }))
        XCTAssertEqual(store.sessionPreset(id: preset.id)?.id, preset.id)
    }

    func testDeveloperAndApplicationRulesFailSafeAcrossArchiveAndRestore() throws {
        let project = ProjectRecord(
            name: "Automation Project",
            folderPath: FileManager.default.temporaryDirectory.path,
            createdAt: start
        )
        let preset = SessionPreset(name: "Automation Preset", projectID: project.id)
        let application = ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor")
        let developerRule = SessionAutomationRule(
            id: UUID(),
            name: "Codex rule",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 0
        )
        let applicationRule = SessionAutomationRule(
            id: UUID(),
            name: "Editor rule",
            trigger: .applications(ApplicationAutomationTrigger(applications: [application])),
            presetID: preset.id,
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 0
        )
        let settings = CodePulseSettings(automationEnabled: true)
        let persistence = ArchivePersistence(AppState(
            projects: [project],
            settings: settings,
            sessionPresets: [preset],
            automationRules: [developerRule, applicationRule]
        ))
        let store = makeStore(persistence: persistence)
        let event = DeveloperToolEvent(
            tool: .codex,
            externalSessionID: "external-1",
            eventType: .sessionStarted,
            timestamp: start,
            workingDirectory: FileManager.default.temporaryDirectory.path
        )

        XCTAssertTrue(store.isAutomationRuleUsable(developerRule))
        XCTAssertTrue(store.isAutomationRuleUsable(applicationRule))
        XCTAssertNotNil(store.sessionAutomationCoordinator.action(for: event, in: store.state, now: start))
        XCTAssertNotNil(store.sessionAutomationCoordinator.action(for: application, in: store.state, now: start))

        _ = try store.archiveProject(id: project.id, at: start.addingTimeInterval(1))
        XCTAssertTrue(store.state.settings.automationEnabled)
        XCTAssertTrue(store.state.automationRules.allSatisfy(\.isEnabled))
        XCTAssertFalse(store.isAutomationRuleUsable(developerRule))
        XCTAssertFalse(store.isAutomationRuleUsable(applicationRule))
        XCTAssertNil(store.sessionAutomationCoordinator.action(for: event, in: store.state, now: start))
        XCTAssertNil(store.sessionAutomationCoordinator.action(for: application, in: store.state, now: start))
        XCTAssertFalse(store.startAutomatedSession(
            with: developerRule,
            event: event,
            at: start,
            signalAt: start
        ))

        let newRule = SessionAutomationRule(
            name: "New archived rule",
            trigger: .developerTool(.opencode),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        XCTAssertFalse(store.upsertAutomationRule(newRule))
        XCTAssertTrue(store.upsertAutomationRule(developerRule))

        _ = try store.restoreProject(id: project.id)
        XCTAssertTrue(store.isAutomationRuleUsable(developerRule))
        XCTAssertTrue(store.isAutomationRuleUsable(applicationRule))
        XCTAssertEqual(store.state.automationRules.map(\.id), [developerRule.id, applicationRule.id])
        XCTAssertTrue(store.state.automationRules.allSatisfy(\.isEnabled))
    }

    func testMalformedArchivedProjectOwnershipIsRelinquishedOnLaunch() {
        let project = ProjectRecord(
            name: "Malformed Active Project",
            folderPath: FileManager.default.temporaryDirectory.path,
            createdAt: start,
            archivedAt: start.addingTimeInterval(-1)
        )
        let preset = SessionPreset(name: "Malformed Preset", projectID: project.id)
        let rule = SessionAutomationRule(
            name: "Malformed rule",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedBySource: .developerTool(tool: .codex, externalSessionID: "external-1"),
            lastMatchingSignalAt: start,
            pauseEligibleAt: start.addingTimeInterval(60),
            finishEligibleAt: start.addingTimeInterval(300),
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(
                source: .developerTool(tool: .codex, externalSessionID: "external-1"),
                isActive: true,
                lastSignalAt: start
            )]
        )
        let activeSession = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: start,
            automationMetadata: metadata
        )
        let store = makeStore(persistence: ArchivePersistence(AppState(
            projects: [project],
            activeSession: activeSession,
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        )))

        XCTAssertEqual(store.activeSession?.projectID, project.id)
        XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)
        XCTAssertTrue(store.activeSession?.automationMetadata?.claims.isEmpty ?? false)
    }

    func testControlStartRejectsArchivedProjectAndPresetThenSucceedsAfterRestore() throws {
        let project = ProjectRecord(name: "Old Project", createdAt: start)
        let preset = SessionPreset(name: "Old Preset", projectID: project.id)
        let persistence = ArchivePersistence(AppState(projects: [project], sessionPresets: [preset]))
        let clock = ArchiveClock(start)
        let transport = CodePulseControlTransport(paths: CodePulseControlPaths(
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulseArchiveControl-\(UUID().uuidString)", isDirectory: true)
        ))
        let store = makeStore(persistence: persistence, clock: clock, controlTransport: transport)
        _ = try store.archiveProject(id: project.id, at: start.addingTimeInterval(1))

        let direct = try send(
            CodePulseControlCommand(
                issuedAt: start,
                action: .startManual(projectName: project.name, sessionType: "coding", goal: nil)
            ),
            to: store,
            through: transport
        )
        XCTAssertEqual(direct.result, .presetOrProjectNotFound)
        XCTAssertEqual(direct.message, "Project \"Old Project\" is archived.")

        let presetStart = try send(
            CodePulseControlCommand(issuedAt: start, action: .startPresetID(preset.id)),
            to: store,
            through: transport
        )
        XCTAssertEqual(presetStart.result, .presetOrProjectNotFound)
        XCTAssertEqual(presetStart.message, "Project \"Old Project\" is archived.")
        XCTAssertNil(store.activeSession)

        _ = try store.restoreProject(id: project.id)
        let restoredStart = try send(
            CodePulseControlCommand(issuedAt: start.addingTimeInterval(2), action: .startPresetID(preset.id)),
            to: store,
            through: transport
        )
        XCTAssertEqual(restoredStart.result, .success)
        XCTAssertEqual(store.activeSession?.projectID, project.id)
    }

    func testArchivedHistoryRemainsQueryableAndExportsRemainUnchanged() throws {
        let project = ProjectRecord(name: "Historical Project", createdAt: start)
        let session = CompletedSession(
            id: UUID(),
            projectID: project.id,
            projectName: project.name,
            type: .coding,
            goal: "Historical goal",
            outcome: "Done",
            startedAt: start,
            endedAt: start.addingTimeInterval(3_600),
            pauseIntervals: []
        )
        let persistence = ArchivePersistence(AppState(projects: [project], completedSessions: [session]))
        let store = makeStore(persistence: persistence)
        let calendar = Calendar(identifier: .gregorian)
        let query = HistoryQuery(project: .projectID(project.id))
        let before = InsightsCalculator.summary(
            state: store.state,
            calendar: calendar,
            referenceDate: start.addingTimeInterval(7_200),
            timeframe: .allTime,
            project: .projectID(project.id)
        )

        _ = try store.archiveProject(id: project.id, at: start.addingTimeInterval(4_000))
        let matching = store.historySessions(for: query, referenceDate: start.addingTimeInterval(7_200))
        let after = InsightsCalculator.summary(
            state: store.state,
            calendar: calendar,
            referenceDate: start.addingTimeInterval(7_200),
            timeframe: .allTime,
            project: .projectID(project.id)
        )
        let csv = HistoryCSVExporter.csv(for: matching)
        let markdown = InsightsMarkdownExporter.markdown(
            summary: after,
            projectTitle: project.name,
            calendar: calendar
        )

        XCTAssertEqual(store.state.completedSessions, [session])
        XCTAssertEqual(matching, [session])
        XCTAssertEqual(store.historyGroups(for: query, referenceDate: start.addingTimeInterval(7_200)).flatMap(\.sessions), [session])
        XCTAssertTrue(store.historyProjectOptions.contains { $0.filter == .projectID(project.id) && $0.title == project.name })
        XCTAssertTrue(store.insightsProjectOptions.contains { $0.filter == .projectID(project.id) && $0.title == project.name })
        XCTAssertEqual(after.totalDuration, before.totalDuration, accuracy: 0.001)
        XCTAssertEqual(after.sessionCount, before.sessionCount)
        XCTAssertEqual(after.averageSessionDuration, before.averageSessionDuration, accuracy: 0.001)
        XCTAssertEqual(after.longestSessionDuration, before.longestSessionDuration, accuracy: 0.001)
        XCTAssertEqual(csv.components(separatedBy: "\r\n").first, HistoryCSVExporter.columns.joined(separator: ","))
        XCTAssertTrue(csv.contains("Historical Project"))
        XCTAssertFalse(csv.contains("archivedAt"))
        XCTAssertTrue(markdown.contains("**Project:** Historical Project"))
        XCTAssertTrue(markdown.contains("- Sessions: 1"))
        XCTAssertTrue(markdown.contains("- Longest Session: 1h 00m"))
        XCTAssertFalse(markdown.contains("archivedAt"))
    }

    func testBackupRoundTripPreservesArchiveStateAndRestoreNormalizesArchivedDefault() throws {
        let project = ProjectRecord(
            name: "Portable Archived Project",
            folderPath: FileManager.default.temporaryDirectory.path,
            createdAt: start,
            archivedAt: start.addingTimeInterval(-10)
        )
        let preset = SessionPreset(name: "Portable Preset", projectID: project.id)
        let rule = SessionAutomationRule(
            name: "Portable rule",
            isEnabled: true,
            trigger: .developerTool(.codex),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let source = AppState(
            projects: [project],
            settings: CodePulseSettings(
                defaultProjectBehavior: .specificProject,
                specificProjectID: project.id,
                automationEnabled: true
            ),
            sessionPresets: [preset],
            automationRules: [rule]
        )

        let data = try CodePulseBackupCodec.encode(state: source, exportedAt: start)
        let decoded = try CodePulseBackupCodec.decode(data)
        let normalized = try BackupRestoreNormalizer.normalize(decoded.state, preservingLaunchAtLogin: false)

        XCTAssertEqual(decoded.state.projects.first?.archivedAt, project.archivedAt)
        XCTAssertEqual(normalized.projects.first?.id, project.id)
        XCTAssertEqual(normalized.projects.first?.archivedAt, project.archivedAt)
        XCTAssertEqual(normalized.sessionPresets, [preset])
        XCTAssertEqual(normalized.automationRules.first?.id, rule.id)
        XCTAssertTrue(normalized.automationRules.first?.isEnabled ?? false)
        XCTAssertEqual(normalized.settings.defaultProjectBehavior, .lastUsed)
        XCTAssertNil(normalized.settings.specificProjectID)
        XCTAssertFalse(normalized.settings.automationEnabled)
    }

    private func makeStore(
        persistence: ArchivePersistence,
        clock: ArchiveClock? = nil,
        controlTransport: CodePulseControlTransport? = nil
    ) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: clock ?? ArchiveClock(start),
            calendar: Calendar(identifier: .gregorian),
            developerToolEventConsumer: DeveloperToolEventConsumer(inbox: DeveloperToolInbox(
                paths: DeveloperToolIntegrationPaths(
                    applicationSupportDirectory: FileManager.default.temporaryDirectory
                        .appendingPathComponent("CodePulseArchiveInbox-\(UUID().uuidString)", isDirectory: true)
                )
            )),
            automaticallyRefresh: false,
            controlTransport: controlTransport
        )
    }

    private func send(
        _ command: CodePulseControlCommand,
        to store: SessionStore,
        through transport: CodePulseControlTransport
    ) throws -> CodePulseControlResponse {
        try transport.writeCommand(command)
        store.processPendingControlCommands(force: true)
        let response = try XCTUnwrap(transport.readResponse(for: command.id))
        _ = transport.removeResponse(for: command.id)
        return response
    }
}

private final class ArchiveClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class ArchivePersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}
