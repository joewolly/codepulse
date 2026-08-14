import Foundation
import XCTest
@testable import CodePulse

private final class FirstRunClock: SessionClock {
    let now: Date

    init(now: Date) {
        self.now = now
    }
}

private final class FirstRunPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }

    func save(_ state: AppState) {
        self.state = state
    }
}

@MainActor
final class FirstRunClarityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testFreshStateIsEligibleButExistingStateWithoutFlagIsCompleted() throws {
        XCTAssertFalse(AppState().settings.hasCompletedOnboarding)

        let project = ProjectRecord(name: "Existing Project", createdAt: now)
        let session = CompletedSession(
            id: UUID(),
            projectID: project.id,
            projectName: project.name,
            type: .coding,
            goal: "Existing goal",
            outcome: "Existing outcome",
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            pauseIntervals: []
        )
        let legacyState = AppState(projects: [project], completedSessions: [session])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(legacyState)) as? [String: Any]
        )
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "hasCompletedOnboarding")
        object["settings"] = settings

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            AppState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.settings.hasCompletedOnboarding)
        XCTAssertEqual(decoded.projects, legacyState.projects)
        XCTAssertEqual(decoded.completedSessions, legacyState.completedSessions)
    }

    func testMalformedOnboardingFlagDoesNotMakeExistingStateUnreadable() throws {
        let project = ProjectRecord(name: "Existing Project", createdAt: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(AppState(projects: [project]))) as? [String: Any]
        )
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["hasCompletedOnboarding"] = ["unexpected": true]
        object["settings"] = settings

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            AppState.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertTrue(decoded.settings.hasCompletedOnboarding)
        XCTAssertEqual(decoded.projects, [project])
    }

    func testCompletingOnboardingPersistsAndDoesNotAlterActiveSession() {
        let active = ActiveSession(
            projectName: "No Project",
            startedAt: now,
            phase: .running
        )
        let persistence = FirstRunPersistence(AppState(activeSession: active))
        let store = makeStore(persistence: persistence)

        XCTAssertTrue(store.shouldPresentOnboarding)
        store.markOnboardingCompleted()

        XCTAssertFalse(store.shouldPresentOnboarding)
        XCTAssertTrue(store.state.settings.hasCompletedOnboarding)
        XCTAssertEqual(store.state.activeSession, active)
        XCTAssertEqual(persistence.state.activeSession, active)
        XCTAssertTrue(persistence.state.sessionPresets.isEmpty)
        XCTAssertTrue(persistence.state.automationRules.isEmpty)

        store.markOnboardingCompleted()
        XCTAssertEqual(persistence.state.activeSession, active)
    }

    func testOnboardingCompletionSurvivesJSONRelaunch() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulse-first-run-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let firstStore = SessionStore(
            persistence: JSONFilePersistence(fileURL: url),
            clock: FirstRunClock(now: now),
            automaticallyRefresh: false
        )
        XCTAssertTrue(firstStore.shouldPresentOnboarding)
        firstStore.markOnboardingCompleted()

        let secondStore = SessionStore(
            persistence: JSONFilePersistence(fileURL: url),
            clock: FirstRunClock(now: now),
            automaticallyRefresh: false
        )
        XCTAssertFalse(secondStore.shouldPresentOnboarding)
    }

    func testActiveSessionSurvivesRelaunchWithLegacyStateAndOnboardingDoesNotOwnLifecycle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulse-first-run-active-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }

        let active = ActiveSession(
            projectName: "No Project",
            startedAt: now,
            phase: .running
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoder.encode(AppState(activeSession: active))) as? [String: Any]
        )
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "hasCompletedOnboarding")
        object["settings"] = settings
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)

        let store = SessionStore(
            persistence: JSONFilePersistence(fileURL: url),
            clock: FirstRunClock(now: now),
            automaticallyRefresh: false
        )

        XCTAssertFalse(store.shouldPresentOnboarding)
        XCTAssertEqual(store.state.activeSession, active)
        XCTAssertEqual(store.phase, .running)
    }

    func testBackupCompatibilityKeepsOnboardingInformational() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(forResource: "v0_8_backup", withExtension: "json", subdirectory: "Fixtures")
        )
        let legacyBackup = try CodePulseBackupCodec.decode(Data(contentsOf: fixtureURL))
        XCTAssertEqual(legacyBackup.version, 1)
        XCTAssertTrue(legacyBackup.state.settings.hasCompletedOnboarding)
        let normalizedLegacy = try BackupRestoreNormalizer.normalize(
            legacyBackup.state,
            preservingLaunchAtLogin: false
        )
        XCTAssertTrue(normalizedLegacy.settings.hasCompletedOnboarding)

        let freshData = try CodePulseBackupCodec.encode(
            state: AppState(),
            exportedAt: now
        )
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: freshData) as? [String: Any]
        )
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        var settings = try XCTUnwrap(state["settings"] as? [String: Any])
        settings.removeValue(forKey: "hasCompletedOnboarding")
        state["settings"] = settings
        object["state"] = state

        let decodedV09Compatible = try CodePulseBackupCodec.decode(
            JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertTrue(decodedV09Compatible.state.settings.hasCompletedOnboarding)
        let normalized = try BackupRestoreNormalizer.normalize(
            decodedV09Compatible.state,
            preservingLaunchAtLogin: false
        )
        XCTAssertTrue(normalized.settings.hasCompletedOnboarding)

        let uncompletedBackup = try CodePulseBackupCodec.decode(freshData)
        XCTAssertFalse(uncompletedBackup.state.settings.hasCompletedOnboarding)
        let normalizedUncompleted = try BackupRestoreNormalizer.normalize(
            uncompletedBackup.state,
            preservingLaunchAtLogin: false
        )
        XCTAssertTrue(normalizedUncompleted.settings.hasCompletedOnboarding)
    }

    func testProjectAdditionUsesNormalStorePathAndCancelIsAStateNoOp() {
        let persistence = FirstRunPersistence()
        let store = makeStore(persistence: persistence)
        let before = store.state

        XCTAssertNil(ProjectFolderSelection.addProject(to: store, folderURL: nil))
        XCTAssertEqual(store.state, before)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulse-project-\(UUID().uuidString)", isDirectory: true)
        let projectID = ProjectFolderSelection.addProject(to: store, folderURL: folder)
        let project = store.state.projects.first

        XCTAssertNotNil(projectID)
        XCTAssertEqual(store.state.projects.count, 1)
        XCTAssertEqual(project?.id, projectID)
        XCTAssertEqual(project?.name, folder.lastPathComponent)
        XCTAssertEqual(project?.folderPath, folder.path)
        XCTAssertNil(store.state.activeSession)
        XCTAssertTrue(store.state.sessionPresets.isEmpty)
        XCTAssertTrue(store.state.automationRules.isEmpty)
    }

    func testEmptyStateCopyDistinguishesEmptyFilteredAndUnavailableStates() {
        let noHistory = EmptyStateCopy.history(hasAnySessions: false)
        let filteredHistory = EmptyStateCopy.history(hasAnySessions: true)
        XCTAssertEqual(noHistory.title, "No Sessions Yet")
        XCTAssertTrue(noHistory.message.contains("Finish and save"))
        XCTAssertEqual(filteredHistory.title, "No Matching Sessions")

        let noInsights = EmptyStateCopy.insights(
            hasSavedSessions: false,
            timeframeTitle: "This Week",
            projectTitle: "All Projects",
            isAllProjects: true
        )
        let filteredInsights = EmptyStateCopy.insights(
            hasSavedSessions: true,
            timeframeTitle: "This Week",
            projectTitle: "Demo",
            isAllProjects: false
        )
        XCTAssertEqual(noInsights.title, "Not Enough Activity Yet")
        XCTAssertTrue(noInsights.message.contains("save sessions"))
        XCTAssertEqual(filteredInsights.title, "No Activity in This Selection")
        XCTAssertTrue(filteredInsights.message.contains("Demo"))

        XCTAssertEqual(
            EmptyStateCopy.presetAvailability(savedCount: 0, availableCount: 0),
            .noneSaved
        )
        XCTAssertEqual(
            EmptyStateCopy.presetAvailability(savedCount: 2, availableCount: 0),
            .savedButUnavailable
        )
        XCTAssertEqual(
            EmptyStateCopy.presetAvailability(savedCount: 2, availableCount: 1),
            .someAvailable
        )
        XCTAssertNotNil(EmptyStateCopy.automationEmptyState(ruleCount: 0))
        XCTAssertNil(EmptyStateCopy.automationEmptyState(ruleCount: 1))
    }

    private func makeStore(persistence: StatePersisting) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: FirstRunClock(now: now),
            calendar: Calendar(identifier: .gregorian),
            automaticallyRefresh: false
        )
    }
}
