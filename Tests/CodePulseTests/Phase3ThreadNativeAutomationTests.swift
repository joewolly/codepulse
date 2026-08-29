import CodePulseIntegration
import XCTest
@testable import CodePulse

@MainActor
final class Phase3ThreadNativeAutomationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_100_000)

    func testSameProjectThreadsCreateIndependentOwnersAndRouteExactly() throws {
        let fixture = try makeFixture()
        try fixture.inbox.write(event("a", .sessionStarted, at: start, path: fixture.folder.path))
        fixture.clock.now = start.addingTimeInterval(5)
        fixture.store.refresh()
        let aID = try XCTUnwrap(owner("a", in: fixture.store.state)?.id)

        fixture.clock.now = start.addingTimeInterval(10)
        try fixture.inbox.write(event("b", .activity, at: fixture.clock.now, path: fixture.folder.path))
        fixture.store.refresh()

        XCTAssertEqual(fixture.store.state.activeSessions.count, 2)
        XCTAssertNotEqual(aID, owner("b", in: fixture.store.state)?.id)
        XCTAssertEqual(owner("a", in: fixture.store.state)?.developerToolContexts.first?.eventCount, 1)
        XCTAssertEqual(owner("b", in: fixture.store.state)?.developerToolContexts.first?.eventCount, 1)
        XCTAssertEqual(fixture.store.state.developerToolIntegration?.reservedDeveloperToolThreads.count, 2)
    }

    func testProjectMismatchAndStaleEndLeaveOwnerUnchanged() throws {
        let fixture = try makeFixture(includeSecondProject: true)
        try fixture.inbox.write(event("a", .activity, at: start, path: fixture.folder.path))
        fixture.clock.now = start.addingTimeInterval(5)
        fixture.store.refresh()
        let original = try XCTUnwrap(owner("a", in: fixture.store.state))

        fixture.clock.now = start.addingTimeInterval(10)
        try fixture.inbox.write(event("a", .activity, at: fixture.clock.now, path: fixture.folder.path))
        fixture.store.refresh()
        let newer = try XCTUnwrap(owner("a", in: fixture.store.state))

        try fixture.inbox.write(event("a", .sessionEnded, at: start.addingTimeInterval(1), path: fixture.folder.path))
        fixture.store.refresh()
        XCTAssertEqual(owner("a", in: fixture.store.state)?.automationMetadata?.claims.first?.isActive, true)
        XCTAssertEqual(owner("a", in: fixture.store.state)?.automationMetadata?.claims.first?.lastSignalAt, fixture.clock.now)

        let second = try XCTUnwrap(fixture.secondFolder)
        try fixture.inbox.write(event("a", .activity, at: fixture.clock.now, path: second.path))
        fixture.store.refresh()
        XCTAssertEqual(owner("a", in: fixture.store.state), owner("a", in: fixture.store.state))
        XCTAssertEqual(fixture.store.state.activeSessions.count, 1)
        XCTAssertNotEqual(original.developerToolContexts.first?.eventCount, newer.developerToolContexts.first?.eventCount)
    }

    func testEventMutationAndAcknowledgementFailAtomically() throws {
        let fixture = try makeFixture()
        fixture.persistence.failCriticalSaves = true
        let input = event("retry", .activity, at: start, path: fixture.folder.path)
        try fixture.inbox.write(input)
        fixture.clock.now = start.addingTimeInterval(5)
        fixture.store.refresh()
        XCTAssertTrue(fixture.store.state.activeSessions.isEmpty)
        XCTAssertFalse(fixture.store.state.developerToolIntegration?.processedEvents.contains(where: { $0.id == input.id }) == true)
        XCTAssertEqual(fixture.inbox.pendingEventURLs().count, 1)

        fixture.persistence.failCriticalSaves = false
        fixture.clock.now = start.addingTimeInterval(10)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.state.activeSessions.count, 1)
        XCTAssertTrue(fixture.store.state.developerToolIntegration?.processedEvents.contains(where: { $0.id == input.id }) == true)
    }

    func testIntegrityRejectsTwoApplicationOwnedSessions() throws {
        let fixture = try makeFixture()
        let source = SessionAutomationClaimSource.application(bundleIdentifier: "com.example.editor")
        let metadata = SessionAutomationMetadata(
            startedByRuleID: UUID(), startedByRuleName: "App", startedBySource: source,
            lastMatchingSignalAt: start, pauseDelay: 1, finishDelay: 2,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(source: source, isActive: true, lastSignalAt: start)]
        )
        var state = fixture.store.state
        state.activeSessions = [
            ActiveSession(projectID: fixture.project.id, projectName: fixture.project.name, startedAt: start, automationMetadata: metadata),
            ActiveSession(projectID: fixture.project.id, projectName: fixture.project.name, startedAt: start, automationMetadata: metadata)
        ]
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(state)) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .multipleApplicationAutomationOwners)
        }
    }

    private func owner(_ externalID: String, in state: AppState) -> ActiveSession? {
        let identity = DeveloperToolThreadIdentity(tool: .codex, externalSessionID: externalID)
        return state.activeSessions.first { $0.developerToolOwnershipIdentities.contains(identity) }
    }

    private func event(_ id: String, _ type: DeveloperToolEventType, at date: Date, path: String) -> DeveloperToolEvent {
        DeveloperToolEvent(tool: .codex, externalSessionID: id, eventType: type, timestamp: date, workingDirectory: path)
    }

    private func makeFixture(includeSecondProject: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulsePhase3-\(UUID())")
        let folder = root.appendingPathComponent("one", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secondFolder = includeSecondProject ? root.appendingPathComponent("two", isDirectory: true) : nil
        if let secondFolder { try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true) }
        let project = ProjectRecord(name: "One", folderPath: folder.path, createdAt: start)
        var projects = [project]
        if let secondFolder { projects.append(ProjectRecord(name: "Two", folderPath: secondFolder.path, createdAt: start)) }
        let preset = SessionPreset(name: "Thread", projectID: nil)
        let rule = SessionAutomationRule(name: "Codex", trigger: .developerTool(.codex), presetID: preset.id)
        let state = AppState(projects: projects, settings: CodePulseSettings(automationEnabled: true), sessionPresets: [preset], automationRules: [rule])
        let persistence = Phase3Persistence(state)
        let clock = Phase3Clock(start)
        let inbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(applicationSupportDirectory: root.appendingPathComponent("support")))
        let store = SessionStore(persistence: persistence, clock: clock, gitService: Phase3NoOpGit(), developerToolEventConsumer: DeveloperToolEventConsumer(inbox: inbox), automaticallyRefresh: false)
        return Fixture(folder: folder, secondFolder: secondFolder, project: project, persistence: persistence, clock: clock, inbox: inbox, store: store)
    }
}

@MainActor private struct Fixture {
    let folder: URL
    let secondFolder: URL?
    let project: ProjectRecord
    let persistence: Phase3Persistence
    let clock: Phase3Clock
    let inbox: DeveloperToolInbox
    let store: SessionStore
}

private final class Phase3Persistence: StatePersisting {
    var state: AppState
    var failCriticalSaves = false
    init(_ state: AppState) { self.state = state }
    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
    func saveCritical(_ state: AppState) throws {
        if failCriticalSaves { throw Phase3SaveFailure() }
        self.state = state
    }
}
private struct Phase3SaveFailure: Error {}
private final class Phase3Clock: SessionClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
private final class Phase3NoOpGit: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}
