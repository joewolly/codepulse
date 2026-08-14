import CodePulseControlClient
import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

@MainActor
final class CodePulseControlTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    func testCLIParserSupportsStatusJSONPresetIDAndDirectStart() throws {
        let status = try CodePulseControlCLIParser.parse(
            arguments: ["status", "--json"],
            issuedAt: start
        )
        XCTAssertTrue(status.wantsJSONStatus)
        XCTAssertEqual(status.command.action, .status)

        let preset = try CodePulseControlCLIParser.parse(
            arguments: ["start", "--preset", "CodePulse Coding"],
            issuedAt: start
        )
        XCTAssertEqual(preset.command.action, .startPreset(name: "CodePulse Coding"))

        let presetID = UUID()
        let byID = try CodePulseControlCLIParser.parse(
            arguments: ["start", "--preset-id", presetID.uuidString],
            issuedAt: start
        )
        XCTAssertEqual(byID.command.action, .startPresetID(presetID))

        let direct = try CodePulseControlCLIParser.parse(
            arguments: ["start", "--project", "CodePulse", "--type", "CODING", "--goal", "Fix release"],
            issuedAt: start
        )
        XCTAssertEqual(
            direct.command.action,
            .startManual(projectName: "CodePulse", sessionType: "coding", goal: "Fix release")
        )
    }

    func testCLIParserRejectsInvalidAndConflictingArguments() {
        XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["status", "--json", "extra"]))
        XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["start", "--preset", "One", "--preset-id", UUID().uuidString]))
        XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["start", "--project", "CodePulse"]))
        XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["start", "--project", "CodePulse", "--type", "unknown"]))
        XCTAssertThrowsError(try CodePulseControlCLIParser.parse(arguments: ["pause", "unexpected"]))
    }

    func testPresetNamesAreCaseInsensitiveUniqueAndInvalidRulesAreRejected() {
        let (store, _, persistence, _) = makeStore()
        let projectID = persistence.state.projects[0].id
        let first = SessionPreset(name: "Coding", projectID: projectID)
        XCTAssertTrue(store.upsertSessionPreset(first))
        XCTAssertFalse(store.upsertSessionPreset(SessionPreset(
            name: " coding ",
            projectID: projectID
        )))
        XCTAssertTrue(store.upsertSessionPreset(SessionPreset(
            id: first.id,
            name: "CODING",
            projectID: projectID
        )))

        let invalidRule = SessionAutomationRule(
            name: "Invalid",
            trigger: .developerTool(.codex),
            presetID: first.id,
            pauseDelay: 30,
            finishDelay: 10
        )
        XCTAssertFalse(store.upsertAutomationRule(invalidRule))
    }

    func testCommandCodecRejectsUnexpectedFieldsUnsupportedSchemaAndStaleCommand() throws {
        let command = CodePulseControlCommand(
            schemaVersion: CodePulseControlCommand.currentSchemaVersion,
            id: UUID(),
            issuedAt: start,
            action: .pause
        )
        let encoded = try CodePulseControlCommandCodec.encode(command)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unexpected"] = true
        let unexpected = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try CodePulseControlCommandCodec.decode(unexpected)) { error in
            XCTAssertEqual(error as? CodePulseControlValidationError, .unexpectedField("unexpected"))
        }

        let unsupported = CodePulseControlCommand(
            schemaVersion: 99,
            id: command.id,
            issuedAt: start,
            action: .pause
        )
        XCTAssertThrowsError(try CodePulseControlCommandValidator.sanitized(unsupported, now: start)) { error in
            XCTAssertEqual(error as? CodePulseControlValidationError, .unsupportedSchemaVersion(99))
        }

        let stale = CodePulseControlCommand(
            id: UUID(),
            issuedAt: start.addingTimeInterval(-CodePulseControlLimits.maximumCommandAge - 1),
            action: .pause
        )
        XCTAssertThrowsError(try CodePulseControlCommandValidator.sanitized(stale, now: start)) { error in
            XCTAssertEqual(error as? CodePulseControlValidationError, .commandTooOld)
        }

        let response = CodePulseControlResponse(
            commandID: command.id,
            result: .success,
            message: "ok",
            status: CodePulseControlStatus(
                phase: "running",
                project: "CodePulse",
                sessionType: "coding",
                elapsedSeconds: 1,
                automationControlled: false
            )
        )
        let responseData = try CodePulseControlResponseCodec.encode(response)
        var responseObject = try XCTUnwrap(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
        var statusObject = try XCTUnwrap(responseObject["status"] as? [String: Any])
        statusObject["elapsedSeconds"] = -1
        responseObject["status"] = statusObject
        let negativeElapsed = try JSONSerialization.data(withJSONObject: responseObject)
        XCTAssertThrowsError(try CodePulseControlResponseCodec.decode(negativeElapsed))

        responseObject["status"] = statusObject.merging(["elapsedSeconds": 1]) { _, new in new }
        responseObject["message"] = String(repeating: "x", count: CodePulseControlLimits.maximumMessageLength + 1)
        let oversizedMessage = try JSONSerialization.data(withJSONObject: responseObject)
        XCTAssertThrowsError(try CodePulseControlResponseCodec.decode(oversizedMessage))
    }

    func testTransportRejectsSymlinkedManagedParentAndBoundsPendingCommands() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let redirected = temporaryDirectory.appendingPathComponent("redirected", isDirectory: true)
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        let applicationSupport = temporaryDirectory.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        let codePulseDirectory = applicationSupport.appendingPathComponent("CodePulse", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: codePulseDirectory, withDestinationURL: redirected)

        let redirectedTransport = CodePulseControlTransport(
            paths: CodePulseControlPaths(applicationSupportDirectory: applicationSupport)
        )
        XCTAssertThrowsError(try redirectedTransport.writeCommand(CodePulseControlCommand(
            issuedAt: start,
            action: .status
        )))

        let safeSupport = temporaryDirectory.appendingPathComponent("safe-support", isDirectory: true)
        let transport = CodePulseControlTransport(
            paths: CodePulseControlPaths(applicationSupportDirectory: safeSupport)
        )
        try FileManager.default.createDirectory(at: transport.paths.commandsURL, withIntermediateDirectories: true)
        let staleTemporaryFile = transport.paths.commandsURL
            .appendingPathComponent(".command-abandoned.tmp")
        try Data("stale".utf8).write(to: staleTemporaryFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-CodePulseControlLimits.maximumTemporaryFileAge - 1)],
            ofItemAtPath: staleTemporaryFile.path
        )
        for _ in 0..<CodePulseControlLimits.maximumPendingCommands {
            try transport.writeCommand(CodePulseControlCommand(issuedAt: start, action: .status))
        }
        XCTAssertThrowsError(try transport.writeCommand(CodePulseControlCommand(issuedAt: start, action: .status)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemporaryFile.path))

        let responseID = UUID()
        try transport.writeResponse(CodePulseControlResponse(
            commandID: responseID,
            result: .success,
            message: "done",
            status: CodePulseControlStatus(
                phase: "idle",
                elapsedSeconds: 0,
                automationControlled: false
            )
        ))
        let responseURL = transport.paths.responsesURL
            .appendingPathComponent("\(responseID.uuidString.lowercased()).json")
        try FileManager.default.setAttributes(
            [.modificationDate: start.addingTimeInterval(-CodePulseControlLimits.processedCommandRetention - 1)],
            ofItemAtPath: responseURL.path
        )
        transport.pruneResponses(now: start)
        XCTAssertNil(try transport.readResponse(for: responseID))
    }

    func testTransportUsesPrivateControlDirectoriesAndFiles() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let transport = CodePulseControlTransport(
            paths: CodePulseControlPaths(
                applicationSupportDirectory: temporaryDirectory.appendingPathComponent("support", isDirectory: true)
            )
        )
        let command = CodePulseControlCommand(issuedAt: start, action: .status)
        try transport.writeCommand(command)

        let commandDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: transport.paths.commandsURL.path)
        let commandDirectoryPermissions = try XCTUnwrap(commandDirectoryAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(commandDirectoryPermissions.intValue, 0o700)

        let commandURL = transport.paths.commandsURL
            .appendingPathComponent("\(command.id.uuidString.lowercased()).json")
        let commandAttributes = try FileManager.default.attributesOfItem(atPath: commandURL.path)
        let commandPermissions = try XCTUnwrap(commandAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(commandPermissions.intValue, 0o600)

        try transport.writeResponse(CodePulseControlResponse(
            commandID: command.id,
            result: .success,
            message: "done"
        ))
        let responseDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: transport.paths.responsesURL.path)
        let responseDirectoryPermissions = try XCTUnwrap(responseDirectoryAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(responseDirectoryPermissions.intValue, 0o700)

        let responseURL = transport.paths.responsesURL
            .appendingPathComponent("\(command.id.uuidString.lowercased()).json")
        let responseAttributes = try FileManager.default.attributesOfItem(atPath: responseURL.path)
        let responsePermissions = try XCTUnwrap(responseAttributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(responsePermissions.intValue, 0o600)
    }

    func testManualPresetLifecycleAndStatusJSONRemainPrivacyMinimal() throws {
        let (store, transport, persistence, clock) = makeStore()
        let projectID = persistence.state.projects.first!.id
        let preset = SessionPreset(name: "CodePulse Coding", projectID: projectID, sessionType: .coding)
        XCTAssertTrue(store.upsertSessionPreset(preset))

        let idle = try send(
            CodePulseControlCommand(issuedAt: start, action: .status),
            to: store,
            through: transport
        )
        XCTAssertEqual(idle.result, .success)
        XCTAssertEqual(idle.status?.phase, "idle")
        let idleJSON = try XCTUnwrap(idle.status).jsonObject()
        XCTAssertEqual(Set(idleJSON.keys), ["automationControlled", "elapsedSeconds", "phase", "schemaVersion"])

        let startCommand = CodePulseControlCommand(issuedAt: start, action: .startPreset(name: preset.name))
        let started = try send(startCommand, to: store, through: transport)
        XCTAssertEqual(started.result, .success)
        XCTAssertEqual(store.phase, .running)
        XCTAssertNil(store.activeSession?.automationMetadata)
        XCTAssertEqual(started.status?.automationControlled, false)

        clock.advance(42)
        store.refresh()
        let running = try send(
            CodePulseControlCommand(issuedAt: clock.now, action: .status),
            to: store,
            through: transport
        )
        XCTAssertEqual(running.status?.project, "CodePulse")
        XCTAssertEqual(running.status?.sessionType, "coding")
        XCTAssertEqual(running.status?.elapsedSeconds, 42)
        XCTAssertFalse(running.status?.automationControlled ?? true)

        let finish = try send(
            CodePulseControlCommand(issuedAt: clock.now, action: .finish),
            to: store,
            through: transport
        )
        XCTAssertEqual(finish.result, .success)
        XCTAssertEqual(store.phase, .finishing)
        XCTAssertTrue(persistence.state.completedSessions.isEmpty)

        XCTAssertTrue(store.saveFinishedSession(outcome: nil))
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertTrue(try XCTUnwrap(finish.status).phase == "finishing")
    }

    func testInvalidTransitionsMissingProjectAndExpiredCommandReturnDeterministicResults() throws {
        let (store, transport, _, clock) = makeStore()

        let pause = try send(
            CodePulseControlCommand(issuedAt: start, action: .pause),
            to: store,
            through: transport
        )
        XCTAssertEqual(pause.result, .invalidStateTransition)

        let missing = try send(
            CodePulseControlCommand(issuedAt: start, action: .startManual(
                projectName: "Missing",
                sessionType: "coding",
                goal: nil
            )),
            to: store,
            through: transport
        )
        XCTAssertEqual(missing.result, .presetOrProjectNotFound)

        let stale = CodePulseControlCommand(
            issuedAt: clock.now.addingTimeInterval(-CodePulseControlLimits.maximumCommandAge - 1),
            action: .status
        )
        let expired = try send(stale, to: store, through: transport)
        XCTAssertEqual(expired.result, .commandRejected)
        XCTAssertEqual(expired.message, "The control command has expired.")
        XCTAssertTrue(transport.pendingCommandURLs().isEmpty)

        let prelaunchID = UUID()
        try transport.writeCommand(CodePulseControlCommand(
            id: prelaunchID,
            issuedAt: start,
            action: .startManual(projectName: "CodePulse", sessionType: "coding", goal: nil)
        ))
        let relaunched = makeStore(
            persistence: ControlPersistence(AppState(projects: [ProjectRecord(name: "CodePulse", createdAt: start)])),
            clock: FixedControlClock(start.addingTimeInterval(1)),
            transport: transport
        ).store
        let prelaunchResponse = try XCTUnwrap(transport.readResponse(for: prelaunchID))
        XCTAssertEqual(prelaunchResponse.result, .commandRejected)
        XCTAssertEqual(relaunched.phase, .idle)
        _ = transport.removeResponse(for: prelaunchID)
    }

    func testCLICommandsTakeOverAutomationAndLaterSignalsCannotReclaimIt() throws {
        let project = ProjectRecord(
            name: "Automated Project",
            folderPath: FileManager.default.temporaryDirectory.path,
            createdAt: start
        )
        let preset = SessionPreset(name: "Automated Coding", projectID: project.id)
        let rule = SessionAutomationRule(
            name: "Terminal automation",
            trigger: .applications(ApplicationAutomationTrigger(applications: [
                ApplicationIdentity(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
            ])),
            presetID: preset.id,
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 0
        )
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedBySource: .application(bundleIdentifier: "com.apple.Terminal"),
            lastMatchingSignalAt: start,
            pauseEligibleAt: start.addingTimeInterval(10),
            finishEligibleAt: start.addingTimeInterval(20),
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(
                source: .application(bundleIdentifier: "com.apple.Terminal"),
                isActive: true,
                lastSignalAt: start
            )]
        )
        let active = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: start,
            automationMetadata: metadata
        )
        let state = AppState(
            projects: [project],
            activeSession: active,
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        )
        let (store, transport, _, clock) = makeStore(state: state)

        let pause = try send(
            CodePulseControlCommand(issuedAt: start, action: .pause),
            to: store,
            through: transport
        )
        XCTAssertEqual(pause.result, .success)
        XCTAssertEqual(store.phase, .paused)
        XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)

        clock.advance(30)
        let resume = try send(
            CodePulseControlCommand(issuedAt: clock.now, action: .resume),
            to: store,
            through: transport
        )
        XCTAssertEqual(resume.result, .success)
        XCTAssertEqual(store.phase, .running)
        XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)

        store.handleFrontmostApplication(ApplicationIdentity(
            bundleIdentifier: "com.apple.Terminal",
            displayName: "Terminal"
        ))
        clock.advance(100)
        store.refresh()
        XCTAssertEqual(store.phase, .running)

        let finish = try send(
            CodePulseControlCommand(issuedAt: clock.now, action: .finish),
            to: store,
            through: transport
        )
        XCTAssertEqual(finish.result, .success)
        XCTAssertEqual(store.phase, .finishing)
        XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)
    }

    func testDuplicateMutationAndRelaunchExecuteAtMostOnce() throws {
        let (store, transport, persistence, _) = makeStore()
        let project = persistence.state.projects[0]
        let preset = SessionPreset(name: "Once", projectID: project.id)
        XCTAssertTrue(store.upsertSessionPreset(preset))
        let command = CodePulseControlCommand(issuedAt: start, action: .startPresetID(preset.id))

        let first = try send(command, to: store, through: transport)
        XCTAssertEqual(first.result, .success)
        let duplicate = try send(command, to: store, through: transport)
        XCTAssertEqual(duplicate, first)
        XCTAssertEqual(persistence.state.completedSessions.count, 0)
        XCTAssertEqual(store.state.controlProcessing?.processedCommands.count, 1)

        let relaunched = makeStore(
            state: persistence.state,
            persistence: persistence,
            clock: FixedControlClock(start),
            transport: transport
        ).store
        let relaunchDuplicate = try send(command, to: relaunched, through: transport)
        XCTAssertEqual(relaunchDuplicate, first)
        XCTAssertEqual(relaunched.state.activeSession?.id, store.state.activeSession?.id)

        let expiredRelaunch = makeStore(
            state: persistence.state,
            persistence: persistence,
            clock: FixedControlClock(start.addingTimeInterval(CodePulseControlLimits.processedCommandRetention + 1)),
            transport: transport
        ).store
        XCTAssertNil(expiredRelaunch.state.controlProcessing)
        let expiredDuplicate = try send(command, to: expiredRelaunch, through: transport)
        XCTAssertEqual(expiredDuplicate.result, .commandRejected)
    }

    func testRestoreRejectsSurvivingProcessedCommandAndAllowsPostRestoreCommand() throws {
        let root = try makeTemporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let controlSupport = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: controlSupport, withIntermediateDirectories: true)
        let transport = CodePulseControlTransport(paths: CodePulseControlPaths(
            applicationSupportDirectory: controlSupport
        ))
        let clock = FixedControlClock(start)
        let originalProject = ProjectRecord(name: "Original", createdAt: start)
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(AppState(projects: [originalProject]))
        let store = SessionStore(
            persistence: persistence,
            clock: clock,
            automaticallyRefresh: false,
            controlTransport: transport,
            currentLaunchAtLoginState: { false }
        )

        let originalPreset = SessionPreset(name: "Original preset", projectID: originalProject.id)
        XCTAssertTrue(store.upsertSessionPreset(originalPreset))

        let command = CodePulseControlCommand(
            issuedAt: start.addingTimeInterval(1),
            action: .startPresetID(originalPreset.id)
        )
        clock.now = start.addingTimeInterval(1)
        let firstResponse = store.processControlCommand(command, at: clock.now)
        XCTAssertEqual(firstResponse.result, .success)
        XCTAssertTrue(store.finish(at: start.addingTimeInterval(2)))
        XCTAssertTrue(store.discardSession())

        // The command was already executed, but its queue file survived as if
        // response writing or cleanup had failed.
        try transport.writeCommand(command)

        let restoredProject = ProjectRecord(name: "Restored", createdAt: start)
        let restoredPreset = SessionPreset(name: "Restored preset", projectID: restoredProject.id)
        let candidateURL = root.appendingPathComponent("candidate.json")
        try CodePulseBackupCodec.encode(
            state: AppState(projects: [restoredProject], sessionPresets: [restoredPreset]),
            exportedAt: start
        ).write(to: candidateURL)
        let candidate = try store.inspectBackup(at: candidateURL)

        clock.now = start.addingTimeInterval(3)
        _ = try store.restoreBackup(candidate)
        XCTAssertEqual(store.state.localInputAcceptanceDate, clock.now)

        store.processPendingControlCommands(force: true)
        let staleResponse = try XCTUnwrap(transport.readResponse(for: command.id))
        XCTAssertEqual(staleResponse.result, .commandRejected)
        XCTAssertEqual(staleResponse.message, "The command was issued before the most recent CodePulse restore.")
        XCTAssertTrue(transport.pendingCommandURLs().isEmpty)
        XCTAssertEqual(store.state.projects, [restoredProject])
        XCTAssertTrue(store.state.completedSessions.isEmpty)
        XCTAssertNil(store.activeSession)
        _ = transport.removeResponse(for: command.id)

        clock.now = start.addingTimeInterval(4)
        let postRestore = CodePulseControlCommand(
            issuedAt: clock.now,
            action: .startPresetID(restoredPreset.id)
        )
        try transport.writeCommand(postRestore)
        store.processPendingControlCommands(force: true)
        let postRestoreResponse = try XCTUnwrap(transport.readResponse(for: postRestore.id))
        XCTAssertEqual(postRestoreResponse.result, .success)
        XCTAssertEqual(store.activeSession?.projectID, restoredProject.id)
        _ = transport.removeResponse(for: postRestore.id)
    }

    func testRecoveryStatusCommandUsesReadOnlyFailureMessage() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ invalid CodePulse state".utf8).write(to: stateURL, options: .atomic)

        let store = SessionStore(
            persistence: JSONFilePersistence(fileURL: stateURL),
            clock: FixedControlClock(start),
            automaticallyRefresh: false
        )
        XCTAssertTrue(store.isInRecoveryMode)

        let response = store.processControlCommand(
            CodePulseControlCommand(issuedAt: start, action: .status),
            at: start
        )
        XCTAssertEqual(response.result, .internalFailure)
        XCTAssertEqual(
            response.message,
            "CodePulse saved data is unavailable; recover it before requesting status."
        )
    }

    func testNeverProcessedPreRestoreCommandIsRejectedAfterRelaunch() throws {
        let root = try makeTemporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let controlSupport = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: controlSupport, withIntermediateDirectories: true)
        let transport = CodePulseControlTransport(paths: CodePulseControlPaths(
            applicationSupportDirectory: controlSupport
        ))
        let clock = FixedControlClock(start)
        let originalProject = ProjectRecord(name: "Original", createdAt: start)
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(AppState(projects: [originalProject]))
        let store = SessionStore(
            persistence: persistence,
            clock: clock,
            automaticallyRefresh: false,
            controlTransport: transport,
            currentLaunchAtLoginState: { false }
        )

        let staleCommand = CodePulseControlCommand(
            issuedAt: start.addingTimeInterval(1),
            action: .startManual(projectName: originalProject.name, sessionType: "coding", goal: nil)
        )
        try transport.writeCommand(staleCommand)

        let restoredProject = ProjectRecord(name: "Imported", createdAt: start)
        let candidateURL = root.appendingPathComponent("candidate.json")
        try CodePulseBackupCodec.encode(
            state: AppState(projects: [restoredProject]),
            exportedAt: start
        ).write(to: candidateURL)
        let candidate = try store.inspectBackup(at: candidateURL)
        clock.now = start.addingTimeInterval(2)
        _ = try store.restoreBackup(candidate)
        let boundary = clock.now
        XCTAssertEqual(persistence.load().localInputAcceptanceDate, boundary)

        // The next store instance processes the retained file during launch.
        let relaunched = SessionStore(
            persistence: JSONFilePersistence(fileURL: stateURL),
            clock: FixedControlClock(start.addingTimeInterval(3)),
            automaticallyRefresh: false,
            controlTransport: transport,
            currentLaunchAtLoginState: { false }
        )
        let response = try XCTUnwrap(transport.readResponse(for: staleCommand.id))
        XCTAssertEqual(response.result, .commandRejected)
        XCTAssertEqual(response.message, "The command was issued before the most recent CodePulse restore.")
        XCTAssertTrue(transport.pendingCommandURLs().isEmpty)
        XCTAssertEqual(relaunched.state.projects, [restoredProject])
        XCTAssertNil(relaunched.activeSession)
        _ = transport.removeResponse(for: staleCommand.id)
    }

    func testSameSecondPreRestoreCommandIsRejectedAfterPersistedRelaunch() throws {
        let root = try makeTemporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let controlSupport = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: controlSupport, withIntermediateDirectories: true)
        let transport = CodePulseControlTransport(paths: CodePulseControlPaths(
            applicationSupportDirectory: controlSupport
        ))
        let second = start.addingTimeInterval(60)
        let staleTimestamp = second.addingTimeInterval(0.200)
        let restoreBoundary = second.addingTimeInterval(0.800)
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(AppState())

        let restoredProject = ProjectRecord(name: "Imported", createdAt: second)
        let staleCommand = CodePulseControlCommand(
            issuedAt: staleTimestamp,
            action: .startManual(
                projectName: restoredProject.name,
                sessionType: "coding",
                goal: nil
            )
        )
        try transport.writeCommand(staleCommand)

        persistence.save(AppState(
            projects: [restoredProject],
            localInputAcceptanceDate: restoreBoundary
        ))
        XCTAssertEqual(transport.pendingCommandURLs().count, 1)

        let persistedBoundary = try XCTUnwrap(
            JSONFilePersistence(fileURL: stateURL).load().localInputAcceptanceDate
        )
        XCTAssertEqual(persistedBoundary, second)
        XCTAssertNotEqual(persistedBoundary, restoreBoundary)
        let persistedCommandURL = try XCTUnwrap(transport.pendingCommandURLs().first)
        XCTAssertEqual(try transport.readCommand(from: persistedCommandURL).issuedAt, second)

        let relaunched = SessionStore(
            persistence: JSONFilePersistence(fileURL: stateURL),
            clock: FixedControlClock(second.addingTimeInterval(1)),
            automaticallyRefresh: false,
            controlTransport: transport,
            currentLaunchAtLoginState: { false }
        )
        let response = try XCTUnwrap(transport.readResponse(for: staleCommand.id))
        XCTAssertEqual(response.result, .commandRejected)
        XCTAssertEqual(response.message, "The command was issued before the most recent CodePulse restore.")
        XCTAssertTrue(transport.pendingCommandURLs().isEmpty)
        XCTAssertEqual(relaunched.state.projects, [restoredProject])
        XCTAssertTrue(relaunched.state.completedSessions.isEmpty)
        XCTAssertNil(relaunched.state.activeSession)
        _ = transport.removeResponse(for: staleCommand.id)
    }

    func testClientDistinguishesUnavailableAndBoundedTimeoutWithoutSleeping() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let transport = CodePulseControlTransport(paths: CodePulseControlPaths(
            applicationSupportDirectory: temporaryDirectory
        ))
        let unavailable = CodePulseControlClient(
            transport: transport,
            appIsRunning: { false },
            now: { self.start },
            sleep: { _ in }
        )
        XCTAssertThrowsError(try unavailable.send(CodePulseControlCommand(issuedAt: start, action: .status))) { error in
            XCTAssertEqual(error as? CodePulseControlClientError, .appUnavailable)
        }

        var now = start
        let timeout = CodePulseControlClient(
            transport: transport,
            appIsRunning: { true },
            now: { now },
            sleep: { interval in now = now.addingTimeInterval(interval) }
        )
        XCTAssertThrowsError(try timeout.send(
            CodePulseControlCommand(issuedAt: start, action: .status),
            timeout: 0.1
        )) { error in
            XCTAssertEqual(error as? CodePulseControlClientError, .responseTimeout)
        }
        XCTAssertTrue(transport.pendingCommandURLs().isEmpty)
    }

    func testMutationCommitFailureRetainsCommandForRetryWithoutRecordingSuccess() throws {
        let (store, transport, persistence, clock) = makeStore()
        let command = CodePulseControlCommand(
            issuedAt: clock.now,
            action: .startManual(projectName: "CodePulse", sessionType: "coding", goal: nil)
        )

        persistence.failCriticalSaves = true
        try transport.writeCommand(command)
        store.processPendingControlCommands(force: true)
        let failed = try XCTUnwrap(transport.readResponse(for: command.id))
        XCTAssertEqual(failed.result, .internalFailure)
        XCTAssertTrue(transport.pendingCommandURLs().contains { $0.lastPathComponent.contains(command.id.uuidString.lowercased()) })
        XCTAssertNil(store.activeSession)
        XCTAssertNil(persistence.state.controlProcessing)
        _ = transport.removeResponse(for: command.id)

        persistence.failCriticalSaves = false
        store.processPendingControlCommands(force: true)
        let succeeded = try XCTUnwrap(transport.readResponse(for: command.id))
        XCTAssertEqual(succeeded.result, .success)
        XCTAssertNotNil(store.activeSession)
        XCTAssertTrue(transport.pendingCommandURLs().isEmpty)
        XCTAssertEqual(persistence.state.controlProcessing?.processedCommands.count, 1)
        _ = transport.removeResponse(for: command.id)

        // Re-retaining the same command replays the stored result and cannot
        // create a second active session.
        try transport.writeCommand(command)
        store.processPendingControlCommands(force: true)
        let replayed = try XCTUnwrap(transport.readResponse(for: command.id))
        XCTAssertEqual(replayed, succeeded)
        XCTAssertEqual(store.state.controlProcessing?.processedCommands.count, 1)
        _ = transport.removeResponse(for: command.id)
    }

    private func makeStore(
        state: AppState? = nil,
        persistence: ControlPersistence? = nil,
        clock: FixedControlClock? = nil,
        transport: CodePulseControlTransport? = nil
    ) -> (
        store: SessionStore,
        transport: CodePulseControlTransport,
        persistence: ControlPersistence,
        clock: FixedControlClock
    ) {
        let clock = clock ?? FixedControlClock(start)
        let persistence = persistence ?? ControlPersistence(state ?? AppState(
            projects: [ProjectRecord(name: "CodePulse", createdAt: start)]
        ))
        let transport = transport ?? CodePulseControlTransport(paths: CodePulseControlPaths(
            applicationSupportDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulseControl-\(UUID().uuidString)", isDirectory: true)
        ))
        let store = SessionStore(
            persistence: persistence,
            clock: clock,
            automaticallyRefresh: false,
            controlTransport: transport
        )
        return (store, transport, persistence, clock)
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

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseControlTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private final class FixedControlClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }

    func advance(_ interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

private final class ControlPersistence: StatePersisting {
    var state: AppState
    var failCriticalSaves = false

    init(_ state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }

    func save(_ state: AppState) {
        self.state = state
    }

    func saveCritical(_ state: AppState) throws {
        if failCriticalSaves {
            throw ControlCriticalSaveFailure()
        }
        self.state = state
    }
}

private struct ControlCriticalSaveFailure: Error {}

private extension CodePulseControlStatus {
    func jsonObject() throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
