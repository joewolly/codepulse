import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class DeveloperToolIntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPreV06ActiveAndCompletedSessionsDecodeWithoutDeveloperContexts() throws {
        let active = ActiveSession(startedAt: now)
        let completed = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            goal: nil,
            outcome: nil,
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            pauseIntervals: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        var activeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(active)) as? [String: Any]
        )
        activeObject.removeValue(forKey: "developerToolContexts")
        let decodedActive = try JSONDecoder.iso8601.decode(
            ActiveSession.self,
            from: JSONSerialization.data(withJSONObject: activeObject)
        )

        var completedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(completed)) as? [String: Any]
        )
        completedObject.removeValue(forKey: "developerToolContexts")
        let decodedCompleted = try JSONDecoder.iso8601.decode(
            CompletedSession.self,
            from: JSONSerialization.data(withJSONObject: completedObject)
        )

        XCTAssertTrue(decodedActive.developerToolContexts.isEmpty)
        XCTAssertTrue(decodedCompleted.developerToolContexts.isEmpty)
    }

    func testDeveloperContextRoundTripsAndSupportsMultipleTools() throws {
        let contexts = [
            DeveloperToolSessionContext(
                tool: .codex,
                externalSessionID: "codex-1",
                workingDirectory: "/tmp/codepulse/Sources",
                firstActivityAt: now,
                lastActivityAt: now.addingTimeInterval(10),
                model: "GPT-5.6",
                eventCount: 3
            ),
            DeveloperToolSessionContext(
                tool: .opencode,
                externalSessionID: "ses_1",
                workingDirectory: "/tmp/codepulse",
                firstActivityAt: now.addingTimeInterval(20),
                lastActivityAt: now.addingTimeInterval(30),
                model: "DeepSeek V4 Flash",
                profile: "fixer",
                eventCount: 5,
                endedAt: now.addingTimeInterval(40)
            )
        ]
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: "CodePulse",
            goal: "Integrate",
            outcome: "Done",
            startedAt: now,
            endedAt: now.addingTimeInterval(100),
            pauseIntervals: [],
            developerToolContexts: contexts
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder.iso8601
        let decoded = try decoder.decode(CompletedSession.self, from: encoder.encode(session))

        XCTAssertEqual(decoded.developerToolContexts, contexts)
        XCTAssertEqual(decoded.developerToolContexts.map(\.tool), [.codex, .opencode])
        XCTAssertNil(decoded.developerToolContexts[0].profile)
    }

    func testEventCodecAndOptionalMetadata() throws {
        let event = DeveloperToolEvent(
            id: UUID(),
            tool: .codex,
            externalSessionID: "thread-1",
            eventType: .activity,
            timestamp: now,
            workingDirectory: "/tmp/codepulse/./Sources/../Sources",
            model: "  GPT-5.6 ",
            profile: "  "
        )

        let sanitized = try DeveloperToolEventValidator.sanitized(event, now: now)
        XCTAssertEqual(sanitized.workingDirectory, "/tmp/codepulse/Sources")
        XCTAssertEqual(sanitized.model, "GPT-5.6")
        XCTAssertNil(sanitized.profile)
        XCTAssertEqual(try DeveloperToolEventCodec.decode(DeveloperToolEventCodec.encode(sanitized)), sanitized)
    }

    func testProjectMatchingNormalizesChildrenAndRejectsUnrelatedDirectories() throws {
        XCTAssertTrue(DeveloperToolProjectPathMatcher.matches(
            projectPath: "/tmp/codepulse",
            workingDirectory: "/tmp/codepulse/Sources/../Sources"
        ))
        XCTAssertTrue(DeveloperToolProjectPathMatcher.matches(
            projectPath: "/tmp/codepulse",
            workingDirectory: "/tmp/codepulse"
        ))
        XCTAssertFalse(DeveloperToolProjectPathMatcher.matches(
            projectPath: "/tmp/codepulse",
            workingDirectory: "/tmp/codepulse-other"
        ))
        XCTAssertFalse(DeveloperToolProjectPathMatcher.matches(
            projectPath: "relative/codepulse",
            workingDirectory: "/tmp/codepulse"
        ))
    }

    func testProjectMatchingResolvesSymlinksWhenAvailable() throws {
        let root = try temporaryDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        let source = project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("linked-project", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)

        XCTAssertTrue(DeveloperToolProjectPathMatcher.matches(
            projectPath: project.path,
            workingDirectory: link.appendingPathComponent("Sources", isDirectory: true).path
        ))
    }

    func testEventConsumerAttachesOnlyToSelectedProjectAndSupportsMultipleExternalSessions() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("codepulse", isDirectory: true)
        let unrelatedURL = root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedURL, withIntermediateDirectories: true)
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperToolInbox(paths: paths)
        let consumer = DeveloperToolEventConsumer(inbox: inbox)
        let project = ProjectRecord(name: "CodePulse", folderPath: projectURL.path, createdAt: now)
        var state = AppState()
        state.projects = [project]
        state.activeSession = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: now.addingTimeInterval(-60)
        )

        let events = [
            event(id: UUID(), tool: .codex, sessionID: "codex-1", type: .sessionStarted, path: projectURL.path),
            event(id: UUID(), tool: .codex, sessionID: "codex-1", type: .activity, path: projectURL.appendingPathComponent("Sources").path),
            event(id: UUID(), tool: .opencode, sessionID: "ses-1", type: .activity, path: projectURL.path, model: "DeepSeek V4 Flash"),
            event(id: UUID(), tool: .codex, sessionID: "wrong-project", type: .activity, path: unrelatedURL.path)
        ]
        for event in events {
            try inbox.write(event)
        }

        XCTAssertTrue(consumer.processPending(state: &state, now: now))
        XCTAssertEqual(state.activeSession?.developerToolContexts.count, 2)
        XCTAssertEqual(
            state.activeSession?.developerToolContexts.first(where: { $0.externalSessionID == "codex-1" })?.eventCount,
            2
        )
        XCTAssertEqual(
            state.activeSession?.developerToolContexts.first(where: { $0.externalSessionID == "ses-1" })?.model,
            "DeepSeek V4 Flash"
        )
        XCTAssertEqual(state.developerToolIntegration?.processedEvents.count, 4)
        XCTAssertTrue(inbox.pendingEventURLs().isEmpty)
    }

    func testNoProjectAndEventsOutsideSessionTimelineAreIgnored() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("codepulse", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let inbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(applicationSupportDirectory: root))
        let consumer = DeveloperToolEventConsumer(inbox: inbox)

        var noProjectState = AppState()
        noProjectState.activeSession = ActiveSession(startedAt: now.addingTimeInterval(-60))
        try inbox.write(event(id: UUID(), tool: .codex, sessionID: "no-project", type: .activity, path: projectURL.path))
        _ = consumer.processPending(state: &noProjectState, now: now)
        XCTAssertTrue(noProjectState.activeSession?.developerToolContexts.isEmpty == true)

        let project = ProjectRecord(name: "CodePulse", folderPath: projectURL.path, createdAt: now)
        var beforeStartState = AppState()
        beforeStartState.projects = [project]
        beforeStartState.activeSession = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: now
        )
        try inbox.write(event(
            id: UUID(),
            tool: .codex,
            sessionID: "before-start",
            type: .activity,
            path: projectURL.path,
            timestamp: now.addingTimeInterval(-1)
        ))
        _ = consumer.processPending(state: &beforeStartState, now: now)
        XCTAssertTrue(beforeStartState.activeSession?.developerToolContexts.isEmpty == true)

        var afterCompletedState = AppState()
        afterCompletedState.projects = [project]
        afterCompletedState.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: project.id,
            projectName: project.name,
            goal: nil,
            outcome: nil,
            startedAt: now.addingTimeInterval(-100),
            endedAt: now.addingTimeInterval(-10),
            pauseIntervals: []
        )]
        try inbox.write(event(
            id: UUID(),
            tool: .opencode,
            sessionID: "after-completed",
            type: .activity,
            path: projectURL.path,
            timestamp: now.addingTimeInterval(-5)
        ))
        _ = consumer.processPending(state: &afterCompletedState, now: now)
        XCTAssertNil(afterCompletedState.activeSession)
        XCTAssertTrue(afterCompletedState.completedSessions[0].developerToolContexts.isEmpty)
    }

    func testDuplicateEventDoesNotInflateContextAfterRelaunch() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("codepulse", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperToolInbox(paths: paths)
        let project = ProjectRecord(name: "CodePulse", folderPath: projectURL.path, createdAt: now)
        var state = AppState()
        state.projects = [project]
        state.activeSession = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: now.addingTimeInterval(-60)
        )
        let event = event(id: UUID(), tool: .codex, sessionID: "codex-1", type: .activity, path: projectURL.path)
        try inbox.write(event)
        let firstConsumer = DeveloperToolEventConsumer(inbox: inbox)
        _ = firstConsumer.processPending(state: &state, now: now)

        let encoded = try DeveloperToolEventCodec.encode(event)
        try encoded.write(to: paths.inboxURL.appendingPathComponent("duplicate.json"), options: .atomic)
        let restartedConsumer = DeveloperToolEventConsumer(inbox: inbox)
        _ = restartedConsumer.processPending(state: &state, now: now.addingTimeInterval(1))

        XCTAssertEqual(state.activeSession?.developerToolContexts.first?.eventCount, 1)
        XCTAssertTrue(inbox.pendingEventURLs().isEmpty)
    }

    func testMalformedUnsupportedAndStaleEventsAreRemovedWithoutAttachment() throws {
        let root = try temporaryDirectory()
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: paths.inboxURL, withIntermediateDirectories: true)
        let malformed = paths.inboxURL.appendingPathComponent("malformed.json")
        try Data(#"{"prompt":"do not retain this"}"#.utf8).write(to: malformed, options: .atomic)

        let unsupported = DeveloperToolEvent(
            schemaVersion: 99,
            tool: .codex,
            externalSessionID: "unsupported",
            eventType: .activity,
            timestamp: now,
            workingDirectory: "/tmp/codepulse"
        )
        let unsupportedURL = paths.inboxURL.appendingPathComponent("unsupported.json")
        try DeveloperToolEventCodec.encode(unsupported).write(to: unsupportedURL, options: .atomic)

        let stale = event(
            id: UUID(),
            tool: .opencode,
            sessionID: "stale",
            type: .activity,
            path: "/tmp/codepulse",
            timestamp: now.addingTimeInterval(-8 * 24 * 60 * 60)
        )
        try DeveloperToolInbox(paths: paths).write(stale)

        var state = AppState()
        let consumer = DeveloperToolEventConsumer(inbox: DeveloperToolInbox(paths: paths))
        _ = consumer.processPending(state: &state, now: now)

        XCTAssertTrue(DeveloperToolInbox(paths: paths).pendingEventURLs().isEmpty)
        XCTAssertTrue(state.developerToolIntegration?.processedEvents.isEmpty != false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.rootURL.appendingPathComponent("Quarantine").path))
    }

    @MainActor
    func testMalformedIntegrationCannotBreakSessionLifecycle() throws {
        let root = try temporaryDirectory()
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: paths.inboxURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: paths.inboxURL.appendingPathComponent("bad.json"),
            options: .atomic
        )
        let persistence = TestPersistence()
        let store = SessionStore(
            persistence: persistence,
            gitService: NoOpGitService(),
            developerToolEventConsumer: DeveloperToolEventConsumer(inbox: DeveloperToolInbox(paths: paths)),
            automaticallyRefresh: false
        )

        XCTAssertTrue(store.startSession(projectID: nil, goal: "Test", at: now))
        XCTAssertTrue(store.pause(at: now.addingTimeInterval(10)))
        XCTAssertTrue(store.resume(at: now.addingTimeInterval(20)))
        XCTAssertTrue(store.finish(at: now.addingTimeInterval(30)))
        XCTAssertTrue(store.saveFinishedSession(outcome: "Saved"))
        XCTAssertEqual(store.state.completedSessions.count, 1)
    }

    private func event(
        id: UUID,
        tool: DeveloperTool,
        sessionID: String,
        type: DeveloperToolEventType,
        path: String,
        model: String? = nil,
        timestamp: Date? = nil
    ) -> DeveloperToolEvent {
        DeveloperToolEvent(
            id: id,
            tool: tool,
            externalSessionID: sessionID,
            eventType: type,
            timestamp: timestamp ?? now,
            workingDirectory: path,
            model: model
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseDeveloperToolTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private final class TestPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private final class NoOpGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}
