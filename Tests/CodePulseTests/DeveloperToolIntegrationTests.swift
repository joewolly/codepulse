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

    func testBackupsContainDeveloperMetadataWithoutConversationContent() throws {
        let project = ProjectRecord(name: "CodePulse", folderPath: "/tmp/codepulse", createdAt: now)
        let context = DeveloperToolSessionContext(
            tool: .codex,
            externalSessionID: "thread-privacy",
            workingDirectory: "/tmp/codepulse/Sources",
            firstActivityAt: now,
            lastActivityAt: now.addingTimeInterval(5),
            model: "GPT-5.6",
            profile: "default",
            eventCount: 2
        )
        var state = AppState()
        state.projects = [project]
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: project.id,
            projectName: project.name,
            goal: "Review local integration",
            outcome: "Saved",
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            pauseIntervals: [],
            developerToolContexts: [context]
        )]
        let processedEventID = UUID()
        state.developerToolIntegration = DeveloperToolIntegrationProcessingState(
            processedEvents: [DeveloperToolProcessedEvent(id: processedEventID, processedAt: now)]
        )

        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: now)
        let backupText = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(backupText.contains("developerToolContexts"))
        XCTAssertTrue(backupText.contains("thread-privacy"))
        XCTAssertTrue(backupText.contains("GPT-5.6"))
        XCTAssertFalse(backupText.contains(processedEventID.uuidString))
        XCTAssertFalse(backupText.contains("developerToolIntegration"))
        for forbidden in ["transcript", "assistant message", "tool-call arguments", "command output", "api key"] {
            XCTAssertFalse(backupText.localizedCaseInsensitiveContains(forbidden), "Found \(forbidden) in backup")
        }
        var expectedPortableState = state
        expectedPortableState.developerToolIntegration = nil
        XCTAssertEqual(try CodePulseBackupCodec.decode(data).state, expectedPortableState)
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

    func testEventDecoderRejectsInvalidToolAndMissingRequiredFields() throws {
        let invalidTool = Data(#"{"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","tool":"cursor","externalSessionID":"x","eventType":"activity","timestamp":"2026-08-11T00:00:00Z","workingDirectory":"/tmp/codepulse"}"#.utf8)
        XCTAssertThrowsError(try DeveloperToolEventCodec.decode(invalidTool))

        let missingDirectory = Data(#"{"schemaVersion":1,"id":"00000000-0000-0000-0000-000000000001","tool":"codex","externalSessionID":"x","eventType":"activity","timestamp":"2026-08-11T00:00:00Z"}"#.utf8)
        XCTAssertThrowsError(try DeveloperToolEventCodec.decode(missingDirectory))
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

    func testValidatedEventIsSurfacedBeforeProcessedAcknowledgement() throws {
        let root = try temporaryDirectory()
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperToolInbox(paths: paths)
        let event = event(
            id: UUID(),
            tool: .codex,
            sessionID: "staged",
            type: .activity,
            path: root.path
        )
        try inbox.write(event)

        let reader = DeveloperToolEventReader(inbox: inbox)
        var state = AppState()
        let pending = reader.drainPending(state: &state, now: now)

        XCTAssertEqual(pending.map(\.event.id), [event.id])
        XCTAssertTrue(state.developerToolIntegration?.processedEvents.isEmpty != false)

        let first = try XCTUnwrap(pending.first)
        XCTAssertTrue(reader.markProcessed(first, in: &state, at: now))
        XCTAssertEqual(state.developerToolIntegration?.processedEvents.map { $0.id }, [event.id])
        reader.cleanup(first)
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

    func testCleanupFailureDoesNotReattachProcessedEvent() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("codepulse", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let project = ProjectRecord(name: "CodePulse", folderPath: projectURL.path, createdAt: now)
        var state = AppState()
        state.projects = [project]
        state.activeSession = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: now.addingTimeInterval(-60)
        )
        let event = event(id: UUID(), tool: .codex, sessionID: "cleanup-failure", type: .activity, path: projectURL.path)
        try DeveloperToolInbox(paths: paths).write(event)

        let failingInbox = DeveloperToolInbox(
            paths: paths,
            fileManager: FailingRemoveFileManager()
        )
        let consumer = DeveloperToolEventConsumer(inbox: failingInbox)
        XCTAssertTrue(consumer.processPending(state: &state, now: now))
        XCTAssertEqual(state.activeSession?.developerToolContexts.first?.eventCount, 1)
        let retainedURL = try XCTUnwrap(failingInbox.pendingEventURLs().first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedURL.path))
        XCTAssertFalse(failingInbox.remove(retainedURL))

        _ = consumer.processPending(state: &state, now: now.addingTimeInterval(1))
        XCTAssertEqual(state.activeSession?.developerToolContexts.first?.eventCount, 1)
    }

    func testRestoreBoundaryRejectsRetainedProcessedDeveloperEvent() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("codepulse", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let project = ProjectRecord(name: "CodePulse", folderPath: projectURL.path, createdAt: now)
        var state = AppState()
        state.projects = [project]
        state.activeSession = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: now.addingTimeInterval(-60)
        )
        let event = event(
            id: UUID(),
            tool: .codex,
            sessionID: "retained-before-restore",
            type: .activity,
            path: projectURL.path,
            timestamp: now
        )
        try DeveloperToolInbox(paths: paths).write(event)

        // Process once while cleanup fails, leaving the file behind with its
        // ID in the old local ledger.
        let failingConsumer = DeveloperToolEventConsumer(inbox: DeveloperToolInbox(
            paths: paths,
            fileManager: FailingRemoveFileManager()
        ))
        XCTAssertTrue(failingConsumer.processPending(state: &state, now: now))
        XCTAssertEqual(state.activeSession?.developerToolContexts.first?.eventCount, 1)
        XCTAssertEqual(state.developerToolIntegration?.processedEvents.count, 1)

        // Restore imports the session context but intentionally clears the
        // portable replay ledger. The retained old file is still ineligible.
        state.developerToolIntegration = nil
        state.localInputAcceptanceDate = now.addingTimeInterval(1)
        let restoredConsumer = DeveloperToolEventConsumer(inbox: DeveloperToolInbox(paths: paths))
        XCTAssertFalse(restoredConsumer.processPending(state: &state, now: now.addingTimeInterval(2)))
        XCTAssertEqual(state.activeSession?.developerToolContexts.first?.eventCount, 1)
        XCTAssertNil(state.developerToolIntegration)
        XCTAssertTrue(DeveloperToolInbox(paths: paths).pendingEventURLs().isEmpty)
    }

    func testRestoreBoundaryRejectsPreRestoreEventAcrossRelaunchAndAcceptsPostRestoreEvent() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("codepulse", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperToolInbox(paths: paths)
        let project = ProjectRecord(name: "CodePulse", folderPath: projectURL.path, createdAt: now)
        let boundary = now
        let state = AppState(
            projects: [project],
            activeSession: ActiveSession(
                projectID: project.id,
                projectName: project.name,
                startedAt: boundary.addingTimeInterval(-60)
            ),
            localInputAcceptanceDate: boundary
        )
        let preRestore = event(
            id: UUID(),
            tool: .opencode,
            sessionID: "pre-restore",
            type: .activity,
            path: projectURL.path,
            timestamp: boundary.addingTimeInterval(-1)
        )
        try inbox.write(preRestore)

        // Encode/decode the imported state to model the persisted relaunch
        // path, including the machine-local boundary.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var relaunchedState = try decoder.decode(AppState.self, from: encoder.encode(state))
        let relaunchedConsumer = DeveloperToolEventConsumer(inbox: inbox)
        XCTAssertFalse(relaunchedConsumer.processPending(
            state: &relaunchedState,
            now: boundary.addingTimeInterval(2)
        ))
        XCTAssertTrue(relaunchedState.activeSession?.developerToolContexts.isEmpty == true)
        XCTAssertTrue(inbox.pendingEventURLs().isEmpty)

        let postRestore = event(
            id: UUID(),
            tool: .opencode,
            sessionID: "post-restore",
            type: .activity,
            path: projectURL.path,
            timestamp: boundary.addingTimeInterval(1)
        )
        try inbox.write(postRestore)
        XCTAssertTrue(relaunchedConsumer.processPending(
            state: &relaunchedState,
            now: boundary.addingTimeInterval(2)
        ))
        XCTAssertEqual(relaunchedState.activeSession?.developerToolContexts.count, 1)
        XCTAssertEqual(relaunchedState.activeSession?.developerToolContexts.first?.externalSessionID, "post-restore")
        XCTAssertTrue(inbox.pendingEventURLs().isEmpty)
    }

    func testSameSecondPreRestoreEventIsRejectedAfterPersistedRelaunch() throws {
        let root = try temporaryDirectory()
        let projectURL = root.appendingPathComponent("codepulse", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let inbox = DeveloperToolInbox(paths: paths)
        let second = now.addingTimeInterval(60)
        let staleTimestamp = second.addingTimeInterval(0.200)
        let restoreBoundary = second.addingTimeInterval(0.800)
        let project = ProjectRecord(name: "CodePulse", folderPath: projectURL.path, createdAt: second)
        let persistedState = AppState(
            projects: [project],
            activeSession: ActiveSession(
                projectID: project.id,
                projectName: project.name,
                startedAt: second.addingTimeInterval(-60)
            ),
            localInputAcceptanceDate: restoreBoundary
        )
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(persistedState)

        let preRestore = event(
            id: UUID(),
            tool: .opencode,
            sessionID: "same-second-pre-restore",
            type: .activity,
            path: projectURL.path,
            timestamp: staleTimestamp
        )
        try inbox.write(preRestore)

        let relaunchedState = JSONFilePersistence(fileURL: stateURL).load()
        let persistedBoundary = try XCTUnwrap(relaunchedState.localInputAcceptanceDate)
        XCTAssertEqual(persistedBoundary, second)
        XCTAssertNotEqual(persistedBoundary, restoreBoundary)
        let persistedEventURL = try XCTUnwrap(inbox.pendingEventURLs().first)
        XCTAssertEqual(
            try inbox.readEvent(from: persistedEventURL, now: second.addingTimeInterval(1)).timestamp,
            second
        )

        var processedState = relaunchedState
        let beforeProcessing = processedState
        let consumer = DeveloperToolEventConsumer(inbox: inbox)
        XCTAssertFalse(consumer.processPending(
            state: &processedState,
            now: second.addingTimeInterval(1)
        ))
        XCTAssertEqual(processedState, beforeProcessing)
        XCTAssertTrue(processedState.activeSession?.developerToolContexts.isEmpty == true)
        XCTAssertNil(processedState.developerToolIntegration)
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

    func testInboxRejectsSymlinkedDirectoriesAndEventTargets() throws {
        let root = try temporaryDirectory()
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.inboxURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: paths.inboxURL, withDestinationURL: outside)

        let event = event(id: UUID(), tool: .codex, sessionID: "symlinked", type: .activity, path: "/tmp/codepulse")
        XCTAssertThrowsError(try DeveloperToolInbox(paths: paths).write(event)) { error in
            XCTAssertEqual(error as? DeveloperToolInboxError, .unsafePath)
        }

        let safeRoot = try temporaryDirectory()
        let safePaths = DeveloperToolIntegrationPaths(applicationSupportDirectory: safeRoot)
        let safeInbox = DeveloperToolInbox(paths: safePaths)
        try safeInbox.write(event)
        let eventURL = safePaths.inboxURL.appendingPathComponent("\(event.id.uuidString.lowercased()).json")
        let target = outside.appendingPathComponent("target.json")
        try FileManager.default.removeItem(at: eventURL)
        try FileManager.default.createSymbolicLink(at: eventURL, withDestinationURL: target)
        XCTAssertThrowsError(try safeInbox.write(event)) { error in
            XCTAssertEqual(error as? DeveloperToolInboxError, .unsafePath)
        }
    }

    func testInboxRejectsSymlinkedManagedParentDirectories() throws {
        let root = try temporaryDirectory()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let managedRoot = paths.rootURL
            .deletingLastPathComponent()
        try FileManager.default.createSymbolicLink(at: managedRoot, withDestinationURL: outside)

        let event = event(id: UUID(), tool: .codex, sessionID: "parent-symlink", type: .activity, path: "/tmp/codepulse")
        XCTAssertThrowsError(try DeveloperToolInbox(paths: paths).write(event)) { error in
            XCTAssertEqual(error as? DeveloperToolInboxError, .unsafePath)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent("Integrations/Inbox/\(event.id.uuidString.lowercased()).json").path
        ))
    }

    func testInboxRejectsWritesAfterCapacityLimit() throws {
        let root = try temporaryDirectory()
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        try FileManager.default.createDirectory(at: paths.inboxURL, withIntermediateDirectories: true)
        try Data(repeating: 0, count: DeveloperToolIntegrationLimits.maximumInboxBytes)
            .write(to: paths.inboxURL.appendingPathComponent("capacity filler"), options: .atomic)

        let event = event(id: UUID(), tool: .codex, sessionID: "capacity", type: .activity, path: "/tmp/codepulse")
        XCTAssertThrowsError(try DeveloperToolInbox(paths: paths).write(event)) { error in
            XCTAssertEqual(error as? DeveloperToolInboxError, .inboxFull)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.inboxURL.appendingPathComponent("\(event.id.uuidString.lowercased()).json").path
        ))
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

    func testCodexInstallerPreservesUserHooksAndIsIdempotent() throws {
        let root = try temporaryDirectory()
        let codexDirectory = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let userConfiguration: [String: Any] = [
            "hooks": [
                "Stop": [[
                    "hooks": [[
                        "type": "command",
                        "command": "/usr/local/bin/user-hook",
                        "statusMessage": "User-owned hook"
                    ]]
                ]]
            ],
            "other": "preserve me"
        ]
        try JSONSerialization.data(withJSONObject: userConfiguration, options: [.prettyPrinted])
            .write(to: hooksURL, options: .atomic)
        try Data("[features]\nother = true\n".utf8).write(to: configURL, options: .atomic)

        let installer = CodexIntegrationInstaller(hooksURL: hooksURL, configURL: configURL)
        let helperURL = root.appendingPathComponent("CodePulse.app/Contents/Helpers/codepulse integration")
        try installer.enable(helperURL: helperURL)
        try installer.enable(helperURL: helperURL)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let stopGroups = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopGroups.count, 2)
        XCTAssertEqual(object["other"] as? String, "preserve me")
        XCTAssertTrue(hooks["SessionStart"] != nil)
        XCTAssertTrue(hooks["SessionEnd"] != nil)
        XCTAssertTrue(String(data: try Data(contentsOf: configURL), encoding: .utf8)?.contains("CodePulse managed") == true)

        try installer.disable()
        let disabledObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let disabledHooks = try XCTUnwrap(disabledObject["hooks"] as? [String: Any])
        let remainingStopGroups = try XCTUnwrap(disabledHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(remainingStopGroups.count, 1)
        XCTAssertNil(disabledHooks["SessionStart"])
        XCTAssertNil(disabledHooks["SessionEnd"])
        XCTAssertFalse(String(data: try Data(contentsOf: configURL), encoding: .utf8)?.contains("CodePulse managed") == true)
    }

    func testCodexInstallerRemovesMalformedMarkerOwnedGroupsWithoutTouchingUserHooks() throws {
        let root = try temporaryDirectory()
        let codexDirectory = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let userGroup: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "/usr/local/bin/user-hook",
                "statusMessage": "User-owned hook"
            ]]
        ]
        let malformedManagedGroup: [String: Any] = [
            "hooks": [[
                "type": "command",
                "statusMessage": CodexIntegrationInstaller.managedMarker
            ]]
        ]
        let userConfiguration: [String: Any] = [
            "hooks": [
                "Stop": [userGroup, malformedManagedGroup]
            ]
        ]
        try JSONSerialization.data(withJSONObject: userConfiguration, options: [.prettyPrinted])
            .write(to: hooksURL, options: .atomic)
        try Data("[features]\n".utf8).write(to: configURL, options: .atomic)

        let installer = CodexIntegrationInstaller(hooksURL: hooksURL, configURL: configURL)
        try installer.enable(helperURL: root.appendingPathComponent("CodePulse.app/Contents/Helpers/helper"))

        let enabledObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let enabledHooks = try XCTUnwrap(enabledObject["hooks"] as? [String: Any])
        let stopGroups = try XCTUnwrap(enabledHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(stopGroups.count, 2)
        XCTAssertEqual(stopGroups.filter { group in
            (group["hooks"] as? [[String: Any]])?.contains {
                $0["statusMessage"] as? String == CodexIntegrationInstaller.managedMarker
            } == true
        }.count, 1)
        XCTAssertNotNil(enabledHooks["SessionStart"])
        XCTAssertNotNil(enabledHooks["SessionEnd"])

        try installer.disable()
        let disabledObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let disabledHooks = try XCTUnwrap(disabledObject["hooks"] as? [String: Any])
        let remainingStopGroups = try XCTUnwrap(disabledHooks["Stop"] as? [[String: Any]])
        XCTAssertEqual(remainingStopGroups.count, 1)
        XCTAssertFalse(String(data: try Data(contentsOf: configURL), encoding: .utf8)?.contains("CodePulse managed") == true)
    }

    func testCodexInstallerQuotesUnicodeAndApostropheHelperPaths() throws {
        let root = try temporaryDirectory()
        let codexDirectory = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let helperURL = root.appendingPathComponent("CodePulse's helper 🧪/Contents/Helpers/codepulse-integration")
        try Data("[features]\n".utf8).write(to: configURL, options: .atomic)

        try CodexIntegrationInstaller(hooksURL: hooksURL, configURL: configURL)
            .enable(helperURL: helperURL)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
        )
        let hooks = try XCTUnwrap(object["hooks"] as? [String: Any])
        let sessionStart = try XCTUnwrap(hooks["SessionStart"] as? [[String: Any]])
        let handlers = try XCTUnwrap(sessionStart[0]["hooks"] as? [[String: Any]])
        let command = try XCTUnwrap(handlers[0]["command"] as? String)
        XCTAssertTrue(command.contains("CodePulse"))
        XCTAssertTrue(command.contains("s helper 🧪"))
        XCTAssertTrue(command.contains("'\\''"))
    }

    func testCodexInstallerRespectsExplicitlyDisabledHooks() throws {
        let root = try temporaryDirectory()
        let codexDirectory = root.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        try Data("[features]\nhooks = false\n".utf8).write(to: configURL, options: .atomic)

        let installer = CodexIntegrationInstaller(hooksURL: hooksURL, configURL: configURL)
        XCTAssertThrowsError(try installer.enable(helperURL: root.appendingPathComponent("helper"))) { error in
            XCTAssertEqual(error as? DeveloperToolIntegrationError, .hooksDisabledByUser)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: hooksURL.path))
        XCTAssertEqual(String(data: try Data(contentsOf: configURL), encoding: .utf8), "[features]\nhooks = false\n")
    }

    func testCodexInstallerRejectsSymlinkedConfigurationDirectory() throws {
        let root = try temporaryDirectory()
        let codexDirectory = root.appendingPathComponent(".codex", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: codexDirectory, withDestinationURL: outside)

        let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
        let configURL = codexDirectory.appendingPathComponent("config.toml")
        let installer = CodexIntegrationInstaller(hooksURL: hooksURL, configURL: configURL)

        XCTAssertThrowsError(try installer.enable(helperURL: root.appendingPathComponent("helper"))) { error in
            XCTAssertEqual(
                error as? DeveloperToolIntegrationError,
                .configurationPathInUse(configURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("hooks.json").path))
    }

    func testOpenCodeInstallerUsesIndependentManagedPlugin() throws {
        let root = try temporaryDirectory()
        let pluginURL = root
            .appendingPathComponent(".config/opencode/plugins", isDirectory: true)
            .appendingPathComponent("codepulse-integration.js")
        let installer = OpenCodeIntegrationInstaller(pluginURL: pluginURL)
        let helperURL = root.appendingPathComponent("CodePulse.app/Contents/Helpers/codepulse-integration")

        try installer.enable(helperURL: helperURL)
        let source = try String(contentsOf: pluginURL, encoding: .utf8)
        XCTAssertTrue(source.hasPrefix(OpenCodeIntegrationInstaller.managedMarker))
        XCTAssertTrue(source.contains("Bun.spawn([CODEPULSE_HELPER, \"--event\"]"))
        XCTAssertTrue(source.contains("const CODEPULSE_SCHEMA_VERSION = \(DeveloperToolEvent.currentSchemaVersion);"))
        XCTAssertTrue(source.contains("await child.stdin.end();"))
        XCTAssertTrue(source.contains("await child.exited;"))
        XCTAssertTrue(source.contains("session.created"))
        XCTAssertTrue(source.contains("session.status"))
        for forbiddenKey in [
            "prompt", "message", "content", "part", "parts", "tool",
            "command", "arguments", "input", "output", "transcript"
        ] {
            XCTAssertFalse(
                source.contains("properties.\(forbiddenKey)"),
                "Found forwarded OpenCode payload key properties.\(forbiddenKey)"
            )
        }
        for forbiddenEventPrefix in [
            #"event.type === "message."#, #"event.type === "tool."#, #"event.type === "command."#
        ] {
            XCTAssertFalse(
                source.contains(forbiddenEventPrefix),
                "Found content-bearing OpenCode event subscription \(forbiddenEventPrefix)"
            )
        }

        try installer.disable()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pluginURL.path))

        try FileManager.default.createDirectory(at: pluginURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("export const UserPlugin = async () => ({})\n".utf8).write(to: pluginURL, options: .atomic)
        XCTAssertThrowsError(try installer.enable(helperURL: helperURL)) { error in
            XCTAssertEqual(
                error as? DeveloperToolIntegrationError,
                .configurationPathInUse(pluginURL.path)
            )
        }
        XCTAssertEqual(String(data: try Data(contentsOf: pluginURL), encoding: .utf8), "export const UserPlugin = async () => ({})\n")
    }

    func testOpenCodeInstallerRejectsSymlinkedPluginDirectory() throws {
        let root = try temporaryDirectory()
        let pluginDirectory = root.appendingPathComponent(".config/opencode/plugins", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pluginDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: pluginDirectory, withDestinationURL: outside)

        let pluginURL = pluginDirectory.appendingPathComponent("codepulse-integration.js")
        let installer = OpenCodeIntegrationInstaller(pluginURL: pluginURL)
        XCTAssertThrowsError(try installer.enable(helperURL: root.appendingPathComponent("helper"))) { error in
            XCTAssertEqual(
                error as? DeveloperToolIntegrationError,
                .configurationPathInUse(pluginURL.path)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("codepulse-integration.js").path))
    }

    func testSystemDetectorFindsOfficialOpenCodeInstallPathWhenPresent() throws {
        let officialPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".opencode/bin/opencode")
        guard FileManager.default.isExecutableFile(atPath: officialPath.path) else {
            throw XCTSkip("OpenCode is not installed by the official installer in this environment")
        }

        XCTAssertTrue(SystemDeveloperToolExecutableDetector().isAvailable(named: "opencode"))
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

private final class FailingRemoveFileManager: FileManager {
    override func removeItem(at url: URL) throws {
        throw NSError(domain: "DeveloperToolIntegrationTests", code: 1)
    }
}
