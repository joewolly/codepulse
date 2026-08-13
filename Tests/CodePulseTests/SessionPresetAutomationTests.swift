import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

@MainActor
final class SessionPresetAutomationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_950_000_000)

    func testMilestoneOneRuleMigratesToOneDeterministicPresetIdempotently() throws {
        let project = ProjectRecord(
            name: "CodePulse",
            folderPath: "/tmp/codepulse-migration",
            createdAt: start
        )
        let legacyRule = SessionAutomationRule(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Legacy Codex",
            trigger: .developerTool(.codex),
            projectID: project.id,
            sessionType: .debugging,
            goal: "Migrate this rule"
        )

        let legacyObject: [String: Any] = [
            "projects": [try jsonObject(project)],
            "completedSessions": [],
            "settings": ["automationEnabled": true],
            "automationRules": [try jsonObject(legacyRule)]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let first = try decodeState(legacyData)
        let second = try decodeState(try encode(first))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sessionPresets.count, 1)
        XCTAssertEqual(second.sessionPresets.count, 1)
        XCTAssertEqual(first.sessionPresets[0].id, second.sessionPresets[0].id)
        XCTAssertEqual(first.sessionPresets[0].projectID, project.id)
        XCTAssertEqual(first.sessionPresets[0].sessionType, .debugging)
        XCTAssertEqual(first.sessionPresets[0].goal, "Migrate this rule")
        XCTAssertEqual(first.automationRules[0].presetID, first.sessionPresets[0].id)
        XCTAssertNil(first.automationRules[0].projectID)

        let canonicalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(first)) as? [String: Any])
        let canonicalRule = try XCTUnwrap((canonicalObject["automationRules"] as? [[String: Any]])?.first)
        XCTAssertNil(canonicalRule["projectID"])
        XCTAssertNotNil(canonicalRule["presetID"])
    }

    func testPresetRoundTripAndQuickStartRemainManual() throws {
        let project = try makeProject(name: "Preset Project")
        let preset = SessionPreset(
            name: "  Focus preset  ",
            projectID: project.record.id,
            sessionType: .review,
            goal: "  Review the change  "
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            sessionPresets: [preset]
        ))
        let clock = PresetTestClock(start)
        let store = makeStore(persistence: persistence, clock: clock)

        let data = try encode(persistence.state)
        XCTAssertEqual(try decodeState(data), persistence.state)
        XCTAssertTrue(store.startSession(using: preset, at: start))
        XCTAssertEqual(store.activeSession?.projectID, project.record.id)
        XCTAssertEqual(store.activeSession?.type, .review)
        XCTAssertEqual(store.activeSession?.goal, "Review the change")
        XCTAssertNil(store.activeSession?.automationMetadata)
    }

    func testApplicationRuleStartsAndSwitchesWithinOneSession() async throws {
        let project = try makeProject(name: "Application Project")
        let preset = SessionPreset(name: "Application Coding", projectID: project.record.id)
        let xcode = ApplicationIdentity(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode")
        let terminal = ApplicationIdentity(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
        let safari = ApplicationIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        let rule = SessionAutomationRule(
            name: "Apple Development Apps",
            trigger: .applications(ApplicationAutomationTrigger(applications: [xcode, terminal])),
            presetID: preset.id,
            pauseDelay: 10,
            finishDelay: 30,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: xcode)
        let store = makeStore(persistence: persistence, clock: clock, monitor: monitor)
        let sessionID = try XCTUnwrap(store.activeSession?.id)

        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.automationMetadata?.claims.count, 1)
        XCTAssertEqual(store.activeAutomationStatusLabel, "Automatic · Xcode")

        monitor.setCurrentApplication(terminal)
        XCTAssertEqual(store.activeSession?.id, sessionID)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(
            store.activeSession?.automationMetadata?.claims.first(where: { $0.source == .application(bundleIdentifier: "com.apple.Terminal") })?.isActive,
            true
        )
        XCTAssertEqual(
            store.activeSession?.automationMetadata?.claims.first(where: { $0.source == .application(bundleIdentifier: "com.apple.dt.Xcode") })?.isActive,
            false
        )

        monitor.setCurrentApplication(safari)
        clock.now = start.addingTimeInterval(9)
        store.refresh()
        XCTAssertEqual(store.phase, .running)
        clock.now = start.addingTimeInterval(10)
        store.refresh()
        XCTAssertEqual(store.phase, .paused)

        monitor.setCurrentApplication(xcode)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.id, sessionID)

        monitor.setCurrentApplication(safari)
        clock.now = start.addingTimeInterval(20)
        store.refresh()
        XCTAssertEqual(store.phase, .paused)
        monitor.setCurrentApplication(terminal)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.id, sessionID)

        monitor.setCurrentApplication(safari)
        clock.now = start.addingTimeInterval(50)
        store.refresh()
        try await settle(store)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertEqual(persistence.state.completedSessions[0].id, sessionID)
    }

    func testApplicationIdentityDeduplicatesByBundleIdentifier() throws {
        let trigger = ApplicationAutomationTrigger(applications: [
            ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor"),
            ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Renamed Editor"),
            ApplicationIdentity(bundleIdentifier: "", displayName: "Missing")
        ])

        XCTAssertEqual(trigger.applications.count, 1)
        XCTAssertEqual(trigger.applications[0].displayName, "Editor")
        XCTAssertTrue(trigger.matches(bundleIdentifier: "com.example.Editor"))
        XCTAssertFalse(trigger.matches(bundleIdentifier: "Editor"))
    }

    func testDeletingPresetRelinquishesActiveAutomationWithoutFinishing() throws {
        let project = try makeProject(name: "Delete Preset Project")
        let preset = SessionPreset(name: "Delete Me", projectID: project.record.id)
        let application = ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor")
        let rule = SessionAutomationRule(
            name: "Editor Rule",
            trigger: .applications(ApplicationAutomationTrigger(applications: [application])),
            presetID: preset.id,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: application)
        let store = makeStore(persistence: persistence, clock: clock, monitor: monitor)
        XCTAssertEqual(store.phase, .running)

        store.deleteSessionPreset(id: preset.id)

        XCTAssertEqual(store.phase, .running)
        XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)
        clock.now = start.addingTimeInterval(5)
        store.refresh()
        XCTAssertEqual(store.phase, .running)
        XCTAssertTrue(persistence.state.completedSessions.isEmpty)
    }

    func testApplicationAndDeveloperClaimsCoexistAndKeepOneSessionAlive() throws {
        let project = try makeProject(name: "Mixed Claims Project")
        let preset = SessionPreset(name: "Mixed Coding", projectID: project.record.id)
        let xcode = ApplicationIdentity(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode")
        let appRule = SessionAutomationRule(
            name: "Xcode",
            trigger: .applications(ApplicationAutomationTrigger(applications: [xcode])),
            presetID: preset.id,
            pauseDelay: 20,
            finishDelay: 40,
            minimumSavedDuration: 0
        )
        let developerRule = SessionAutomationRule(
            name: "Codex",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            pauseDelay: 20,
            finishDelay: 40,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [appRule, developerRule]
        ))
        let paths = DeveloperToolIntegrationPaths(
            applicationSupportDirectory: project.url.appendingPathComponent("support")
        )
        let inbox = DeveloperToolInbox(paths: paths)
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: xcode)
        let store = makeStore(
            persistence: persistence,
            clock: clock,
            monitor: monitor,
            inbox: inbox
        )
        let sessionID = try XCTUnwrap(store.activeSession?.id)

        clock.now = start.addingTimeInterval(5)
        try inbox.write(DeveloperToolEvent(
            tool: .codex,
            externalSessionID: "codex-mixed",
            eventType: .activity,
            timestamp: clock.now,
            workingDirectory: project.url.path
        ))
        store.refresh()

        XCTAssertEqual(store.activeSession?.id, sessionID)
        XCTAssertEqual(store.activeSession?.automationMetadata?.claims.count, 2)

        monitor.setCurrentApplication(ApplicationIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari"))
        clock.now = start.addingTimeInterval(10)
        store.refresh()
        XCTAssertEqual(store.phase, .running)

        try inbox.write(DeveloperToolEvent(
            tool: .codex,
            externalSessionID: "codex-mixed",
            eventType: .sessionEnded,
            timestamp: clock.now,
            workingDirectory: project.url.path
        ))
        clock.now = start.addingTimeInterval(15)
        store.refresh()
        XCTAssertEqual(store.phase, .running)

        monitor.setCurrentApplication(xcode)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.id, sessionID)
        XCTAssertEqual(
            store.activeSession?.automationMetadata?.claims.first(where: { $0.source == .application(bundleIdentifier: xcode.bundleIdentifier) })?.isActive,
            true
        )
    }

    func testManualTakeoverPreventsApplicationAutoResume() throws {
        let project = try makeProject(name: "Manual Takeover Project")
        let preset = SessionPreset(name: "Manual Coding", projectID: project.record.id)
        let editor = ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor")
        let rule = SessionAutomationRule(
            name: "Editor",
            trigger: .applications(ApplicationAutomationTrigger(applications: [editor])),
            presetID: preset.id,
            pauseDelay: 1,
            finishDelay: 3,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: editor)
        let store = makeStore(persistence: persistence, clock: clock, monitor: monitor)

        XCTAssertTrue(store.pause(at: start.addingTimeInterval(1)))
        monitor.setCurrentApplication(ApplicationIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari"))
        clock.now = start.addingTimeInterval(2)
        store.refresh()
        monitor.setCurrentApplication(editor)

        XCTAssertEqual(store.phase, .paused)
        XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)
    }

    private func makeProject(name: String) throws -> (record: ProjectRecord, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulsePresetTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (ProjectRecord(name: name, folderPath: url.path, createdAt: start), url)
    }

    private func makeStore(
        persistence: PresetTestPersistence,
        clock: PresetTestClock,
        monitor: FrontmostApplicationMonitoring? = nil,
        inbox: DeveloperToolInbox? = nil
    ) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: clock,
            gitService: PresetNoOpGitService(),
            developerToolEventConsumer: inbox.map { DeveloperToolEventConsumer(inbox: $0) } ?? DeveloperToolEventConsumer(),
            automaticallyRefresh: false,
            frontmostApplicationMonitor: monitor
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decodeState(_ data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: data)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encode(value))
    }

    private func settle(_ store: SessionStore) async throws {
        for _ in 0..<200 {
            if !store.gitCaptureInProgress { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for Git capture")
    }
}

private final class PresetTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class PresetTestPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private final class PresetNoOpGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}
