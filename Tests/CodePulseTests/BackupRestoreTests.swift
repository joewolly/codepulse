import Foundation
import XCTest
@testable import CodePulse

private struct RestoreInjectedFailure: Error {}

@MainActor
final class BackupRestoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    func testReleasedV08FixturePreservesHistoryAndContextsButResetsMachineState() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "v0_8_backup",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let backup = try CodePulseBackupCodec.decode(Data(contentsOf: url))
        XCTAssertEqual(backup.version, 1)
        XCTAssertEqual(backup.state.projects.count, 2)
        XCTAssertEqual(backup.state.completedSessions.count, 1)
        XCTAssertEqual(backup.state.sessionPresets.count, 2)
        XCTAssertEqual(backup.state.automationRules.count, 2)
        XCTAssertTrue(backup.state.settings.automationEnabled)
        XCTAssertEqual(backup.state.completedSessions.first?.gitContext?.repositoryRoot, "/tmp/codepulse-v08-fixture-main")
        XCTAssertEqual(backup.state.completedSessions.first?.githubContext?.pullRequest?.number, 42)
        XCTAssertEqual(backup.state.completedSessions.first?.developerToolContexts.count, 1)

        let restored = try BackupRestoreNormalizer.normalize(
            backup.state,
            preservingLaunchAtLogin: false
        )
        XCTAssertFalse(restored.settings.automationEnabled)
        XCTAssertFalse(restored.settings.launchAtLogin)
        XCTAssertNil(restored.developerToolIntegration)
        XCTAssertNil(restored.controlProcessing)
        XCTAssertNil(restored.localInputAcceptanceDate)
        XCTAssertEqual(restored.projects.map(\.name), ["Fixture Main", "Fixture Docs"])
        XCTAssertEqual(restored.completedSessions.first?.developerToolContexts.count, 1)
        XCTAssertEqual(restored.activeSession?.developerToolContexts.count, 1)
        XCTAssertEqual(restored.activeSession?.pauseIntervals.count, 1)
        XCTAssertNil(restored.activeSession?.pauseIntervals.first?.endedAt)
        XCTAssertEqual(restored.activeSession?.automationMetadata?.claims, [])
        XCTAssertFalse(restored.activeSession?.automationMetadata?.controlEnabled ?? true)
        XCTAssertFalse(restored.activeSession?.automationMetadata?.pendingAutomaticSave ?? true)
        XCTAssertTrue(restored.automationRules.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(restored.settings.defaultProjectBehavior, .lastUsed)
        XCTAssertNil(restored.settings.specificProjectID)
    }

    func testBackupCodecDifferentiatesMalformedUnsupportedAndMissingHistory() throws {
        var object = try JSONSerialization.jsonObject(
            with: CodePulseBackupCodec.encode(state: AppState(), exportedAt: now)
        ) as! [String: Any]

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(Data("{".utf8))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .malformedJSON)
        }

        object["format"] = "not-codepulse"
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .unsupportedFormat)
        }

        object["format"] = CodePulseBackup.format
        object["version"] = CodePulseBackup.currentVersion + 1
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .unsupportedVersion(2))
            XCTAssertEqual(error.localizedDescription, "This backup was created by a newer CodePulse version and cannot be restored safely.")
        }

        object["version"] = CodePulseBackup.currentVersion
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        state.removeValue(forKey: "completedSessions")
        object["state"] = state
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .missingRequiredField("saved session"))
        }
    }

    func testBackupCodecRejectsCorruptSessionTimelineDuplicatesAndOversizedInput() throws {
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            goal: nil,
            outcome: nil,
            startedAt: now,
            endedAt: now.addingTimeInterval(-1),
            pauseIntervals: []
        )
        let timelineObject = try JSONSerialization.jsonObject(
            with: CodePulseBackupCodec.encode(
                state: AppState(completedSessions: [session]),
                exportedAt: now
            )
        ) as! [String: Any]
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: timelineObject))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .invalidTimeline)
        }

        var corruptObject = try JSONSerialization.jsonObject(
            with: CodePulseBackupCodec.encode(state: AppState(), exportedAt: now)
        ) as! [String: Any]
        var corruptState = try XCTUnwrap(corruptObject["state"] as? [String: Any])
        corruptState["completedSessions"] = [[
            "id": UUID().uuidString,
            "startedAt": "not-a-date",
            "endedAt": "not-a-date",
            "pauseIntervals": []
        ]]
        corruptObject["state"] = corruptState
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: corruptObject))) { error in
            guard case .malformedHistoryField("saved session") = (error as? CodePulseBackupError) else {
                return XCTFail("Expected malformed saved-session error, got \(error)")
            }
        }

        let duplicateID = UUID()
        let duplicate = CompletedSession(
            id: duplicateID,
            projectID: nil,
            projectName: nil,
            goal: nil,
            outcome: nil,
            startedAt: now,
            endedAt: now.addingTimeInterval(10),
            pauseIntervals: []
        )
        let duplicateData = try CodePulseBackupCodec.encode(
            state: AppState(completedSessions: [duplicate, duplicate]),
            exportedAt: now
        )
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(duplicateData)) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .duplicateIdentifier("session"))
        }

        let oversized = Data(repeating: 0, count: CodePulseBackupError.maximumInputBytes + 1)
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(oversized)) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .inputTooLarge)
        }
        _ = timelineObject
    }

    func testBackupCodecRejectsOverlappingAndFollowingOpenPauseIntervals() throws {
        let overlappingSession = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            goal: nil,
            outcome: nil,
            startedAt: now,
            endedAt: now.addingTimeInterval(60),
            pauseIntervals: [
                PauseInterval(startedAt: now.addingTimeInterval(20), endedAt: now.addingTimeInterval(40)),
                PauseInterval(startedAt: now.addingTimeInterval(10), endedAt: now.addingTimeInterval(30))
            ]
        )
        let overlappingData = try CodePulseBackupCodec.encode(
            state: AppState(completedSessions: [overlappingSession]),
            exportedAt: now
        )
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(overlappingData)) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .invalidTimeline)
        }

        var activeSession = ActiveSession(startedAt: now, phase: .paused)
        activeSession.pauseIntervals = [
            PauseInterval(startedAt: now.addingTimeInterval(20)),
            PauseInterval(startedAt: now.addingTimeInterval(30), endedAt: now.addingTimeInterval(40))
        ]
        let openIntervalData = try CodePulseBackupCodec.encode(
            state: AppState(activeSession: activeSession),
            exportedAt: now
        )
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(openIntervalData)) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .invalidTimeline)
        }
    }

    func testPreviewContainsDeterministicCountsDatesAndRelinkSignal() throws {
        let existing = try temporaryDirectory().appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let project = ProjectRecord(name: "Available", folderPath: existing.path, createdAt: now)
        let missing = ProjectRecord(name: "Moved", folderPath: "/tmp/codepulse-missing-fixture", createdAt: now)
        let session = CompletedSession(
            id: UUID(),
            projectID: project.id,
            projectName: project.name,
            goal: nil,
            outcome: nil,
            startedAt: now.addingTimeInterval(-300),
            endedAt: now.addingTimeInterval(-100),
            pauseIntervals: []
        )
        let state = AppState(
            projects: [project, missing],
            completedSessions: [session],
            activeSession: ActiveSession(startedAt: now),
            sessionPresets: [SessionPreset(name: "Preset")],
            automationRules: []
        )
        let backup = CodePulseBackup(exportedAt: now, state: state)
        let preview = CodePulseBackupPreview(backup: backup, state: state)

        XCTAssertEqual(preview.format, CodePulseBackup.format)
        XCTAssertEqual(preview.version, 1)
        XCTAssertEqual(preview.projectCount, 2)
        XCTAssertEqual(preview.completedSessionCount, 1)
        XCTAssertEqual(preview.presetCount, 1)
        XCTAssertEqual(preview.automationRuleCount, 0)
        XCTAssertTrue(preview.includesActiveSession)
        XCTAssertEqual(preview.earliestSavedSessionAt, session.startedAt)
        XCTAssertEqual(preview.latestSavedSessionAt, session.endedAt)
        XCTAssertEqual(preview.projectsNeedingRelinkCount, 1)
    }

    func testRestoreNormalizationPreservesValidConfigurationAndCurrentLoginSetting() throws {
        let projectURL = try temporaryDirectory().appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
        let project = ProjectRecord(name: "Project", folderPath: projectURL.path, createdAt: now)
        let preset = SessionPreset(name: "Coding", projectID: project.id)
        let rule = SessionAutomationRule(
            name: "Codex",
            trigger: .developerTool(.codex),
            presetID: preset.id
        )
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedBySource: .developerTool(tool: .codex, externalSessionID: "old-machine"),
            lastMatchingSignalAt: now,
            pendingAutomaticSave: true,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 60,
            claims: [SessionAutomationClaim(
                source: .developerTool(tool: .codex, externalSessionID: "old-machine"),
                isActive: true,
                lastSignalAt: now
            )]
        )
        let eventID = UUID()
        let state = AppState(
            projects: [project],
            activeSession: ActiveSession(
                projectID: project.id,
                projectName: project.name,
                startedAt: now,
                automationMetadata: metadata
            ),
            settings: CodePulseSettings(
                launchAtLogin: false,
                defaultProjectBehavior: .specificProject,
                specificProjectID: project.id,
                automationEnabled: true
            ),
            sessionPresets: [preset],
            developerToolIntegration: DeveloperToolIntegrationProcessingState(
                processedEvents: [DeveloperToolProcessedEvent(id: eventID, processedAt: now)]
            ),
            automationRules: [rule],
            controlProcessing: CodePulseControlProcessingState()
        )

        let normalized = try BackupRestoreNormalizer.normalize(
            state,
            preservingLaunchAtLogin: true
        )
        XCTAssertTrue(normalized.settings.launchAtLogin)
        XCTAssertFalse(normalized.settings.automationEnabled)
        XCTAssertEqual(normalized.settings.defaultProjectBehavior, .specificProject)
        XCTAssertEqual(normalized.settings.specificProjectID, project.id)
        XCTAssertEqual(normalized.automationRules, [rule])
        XCTAssertTrue(normalized.automationRules[0].isEnabled)
        XCTAssertNil(normalized.developerToolIntegration)
        XCTAssertNil(normalized.controlProcessing)
        XCTAssertEqual(normalized.activeSession?.pauseIntervals, [])
        XCTAssertFalse(normalized.activeSession?.automationMetadata?.controlEnabled ?? true)
        XCTAssertFalse(normalized.activeSession?.automationMetadata?.pendingAutomaticSave ?? true)
        XCTAssertTrue(normalized.activeSession?.automationMetadata?.claims.isEmpty == true)
    }

    func testSessionStoreUsesCurrentMachineLoginItemStateDuringRestoreInspection() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let currentState = AppState(settings: CodePulseSettings(launchAtLogin: false))
        let importedState = AppState(settings: CodePulseSettings(launchAtLogin: true))
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(currentState)
        let store = SessionStore(
            persistence: persistence,
            clock: RestoreTestClock(now),
            automaticallyRefresh: false,
            currentLaunchAtLoginState: { false }
        )
        let backupURL = root.appendingPathComponent("candidate.json")
        try CodePulseBackupCodec.encode(state: importedState, exportedAt: now).write(to: backupURL)

        let candidate = try store.inspectBackup(at: backupURL)
        XCTAssertFalse(candidate.state.settings.launchAtLogin)
    }

    func testTransactionalRestoreWritesAndVerifiesRecoveryAndSurvivesReload() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(stateA)

        let receipt = try persistence.replaceStateTransactionally(
            with: stateB,
            recoverySnapshot: stateA,
            exportedAt: now
        )

        XCTAssertEqual(persistence.load(), stateB)
        XCTAssertEqual(JSONFilePersistence(fileURL: stateURL).load(), stateB)
        let recovery = try CodePulseBackupCodec.decode(Data(contentsOf: receipt.recoveryBackupURL))
        XCTAssertEqual(recovery.state, CodePulseBackupCodec.portableState(from: stateA))
        XCTAssertTrue(receipt.recoveryBackupURL.lastPathComponent.hasPrefix("Pre-Restore Backup "))
        XCTAssertEqual(try permissions(of: stateURL), 0o600)
        XCTAssertEqual(try permissions(of: stateURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(of: receipt.recoveryBackupURL), 0o600)
        XCTAssertEqual(try permissions(of: receipt.recoveryBackupURL.deletingLastPathComponent()), 0o700)
    }

    func testUnreadableRestoreTreatsDisappearedPrimaryAsMissing() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ malformed state".utf8).write(to: stateURL, options: .atomic)

        let persistence = JSONFilePersistence(fileURL: stateURL)
        XCTAssertEqual(persistence.load(), AppState())
        XCTAssertEqual(persistence.loadStatus, .unreadable)
        try FileManager.default.removeItem(at: stateURL)

        let receipt = try persistence.replaceStateTransactionally(
            with: stateB,
            recoverySnapshot: stateA,
            exportedAt: now
        )

        XCTAssertEqual(persistence.loadStatus, .loaded)
        XCTAssertEqual(persistence.load(), stateB)
        XCTAssertTrue(receipt.recoveryBackupURL.lastPathComponent.hasPrefix("Pre-Restore Backup "))
        let recovery = try CodePulseBackupCodec.decode(Data(contentsOf: receipt.recoveryBackupURL))
        XCTAssertEqual(recovery.state, CodePulseBackupCodec.portableState(from: stateA))
    }

    func testFailuresBeforeLiveReplacementLeaveCurrentStateByteIdentical() throws {
        let points: [StateRestoreFailurePoint] = [
            .recoveryWrite,
            .recoveryVerification,
            .candidateWrite,
            .candidateVerification
        ]
        for point in points {
            let root = try temporaryDirectory()
            let stateURL = root.appendingPathComponent("CodePulse/state.json")
            let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
            let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
            let base = JSONFilePersistence(fileURL: stateURL)
            base.save(stateA)
            let before = try Data(contentsOf: stateURL)
            let failing = JSONFilePersistence(
                fileURL: stateURL,
                failureInjector: { injected in
                    if Self.sameFailurePoint(injected, point) {
                        throw RestoreInjectedFailure()
                    }
                }
            )

            XCTAssertThrowsError(try failing.replaceStateTransactionally(
                with: stateB,
                recoverySnapshot: stateA,
                exportedAt: now
            ), "Expected injected \(String(describing: point)) failure")
            XCTAssertEqual(try Data(contentsOf: stateURL), before)
            XCTAssertEqual(failing.load(), stateA)
            let leftovers = try FileManager.default.contentsOfDirectory(
                at: stateURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).filter { $0.lastPathComponent.hasPrefix(".state.restore-") }
            XCTAssertTrue(leftovers.isEmpty)
        }
    }

    func testFailureAfterLiveReplacementRollsBackAndReportsRecovery() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if Self.sameFailurePoint(point, .afterLiveReplacement) {
                    throw RestoreInjectedFailure()
                }
            }
        )
        persistence.save(stateA)

        XCTAssertThrowsError(try persistence.replaceStateTransactionally(
            with: stateB,
            recoverySnapshot: stateA,
            exportedAt: now
        )) { error in
            guard let error = error as? StatePersistenceError,
                  case .restoreFailedRollbackSucceeded = error else {
                return XCTFail("Expected successful rollback error, got \(error)")
            }
        }
        XCTAssertEqual(persistence.load(), stateA)
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: stateURL.deletingLastPathComponent().appendingPathComponent("Backups"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryFiles.count, 1)
    }

    func testRollbackFailureIsSevereAndDoesNotClaimSuccess() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if Self.sameFailurePoint(point, .afterLiveReplacement) ||
                    Self.sameFailurePoint(point, .rollbackWrite) {
                    throw RestoreInjectedFailure()
                }
            }
        )
        persistence.save(stateA)

        XCTAssertThrowsError(try persistence.replaceStateTransactionally(
            with: stateB,
            recoverySnapshot: stateA,
            exportedAt: now
        )) { error in
            guard let error = error as? StatePersistenceError,
                  case .restoreFailedRollbackFailed = error else {
                return XCTFail("Expected severe rollback failure, got \(error)")
            }
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        XCTAssertEqual(persistence.load(), stateB)
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: stateURL.deletingLastPathComponent().appendingPathComponent("Backups"),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(recoveryFiles.count, 1)
    }

    func testRecoveryRetentionKeepsNewestFiveAutomaticFilesAndUserBackup() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState()
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(stateA)
        let backupDirectory = stateURL.deletingLastPathComponent().appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let userBackup = backupDirectory.appendingPathComponent("My Export.json")
        try Data("user backup".utf8).write(to: userBackup)

        var receipts: [StateRestoreReceipt] = []
        for offset in 0..<7 {
            let receipt = try persistence.replaceStateTransactionally(
                with: offset.isMultiple(of: 2) ? stateA : stateB,
                recoverySnapshot: offset.isMultiple(of: 2) ? stateB : stateA,
                exportedAt: now.addingTimeInterval(TimeInterval(offset))
            )
            receipts.append(receipt)
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        XCTAssertEqual(
            files.compactMap { AutomaticRecoveryBackupFilename.parse($0.lastPathComponent) }.count,
            5
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: userBackup.path))
        for receipt in receipts.prefix(2) {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: receipt.recoveryBackupURL.path),
                "Expected \(receipt.recoveryBackupURL.lastPathComponent) to be pruned"
            )
        }
        for receipt in receipts.suffix(5) {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: receipt.recoveryBackupURL.path),
                "Expected \(receipt.recoveryBackupURL.lastPathComponent) to be retained"
            )
        }
    }

    func testRecoveryRetentionKeepsNewestFivePerKindAndLeavesMalformedFilesUnmanaged() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let backupDirectory = stateURL.deletingLastPathComponent().appendingPathComponent("Backups")
        let corruptData = Data("{ truncated state".utf8)
        let normalStateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let normalStateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        try FileManager.default.createDirectory(
            at: stateURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let initialPersistence = JSONFilePersistence(fileURL: stateURL)
        initialPersistence.save(AppState())
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let manualUnreadableCopy = backupDirectory.appendingPathComponent(
            "Unreadable State 2026-08-13T22-15-01Z-manual.json"
        )
        try corruptData.write(to: manualUnreadableCopy, options: .atomic)

        var normalReceipts: [StateRestoreReceipt] = []
        for offset in 0..<7 {
            normalReceipts.append(try initialPersistence.replaceStateTransactionally(
                with: offset.isMultiple(of: 2) ? normalStateA : normalStateB,
                recoverySnapshot: normalStateA,
                exportedAt: now.addingTimeInterval(TimeInterval(offset))
            ))
        }

        var receipts: [StateRestoreReceipt] = []
        for offset in 0..<7 {
            try corruptData.write(to: stateURL, options: .atomic)
            let persistence = JSONFilePersistence(fileURL: stateURL)
            XCTAssertEqual(persistence.loadStatus, .notLoaded)
            XCTAssertEqual(persistence.load(), AppState())
            XCTAssertEqual(persistence.loadStatus, .unreadable)
            receipts.append(try persistence.replaceStateTransactionally(
                with: AppState(settings: CodePulseSettings(
                    menuBarDisplay: offset.isMultiple(of: 2) ? .timerOnly : .iconOnly
                )),
                recoverySnapshot: AppState(),
                exportedAt: now.addingTimeInterval(TimeInterval(offset + 10))
            ))
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let automatic = files.compactMap {
            AutomaticRecoveryBackupFilename.parse($0.lastPathComponent)
        }
        let automaticByKind = Dictionary(grouping: automatic, by: { $0.kind })
        XCTAssertEqual(automaticByKind[.preRestore]?.count, 5)
        XCTAssertEqual(automaticByKind[.unreadableState]?.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manualUnreadableCopy.path))
        for receipt in normalReceipts.prefix(2) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.recoveryBackupURL.path))
        }
        for receipt in normalReceipts.suffix(5) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.recoveryBackupURL.path))
        }
        for receipt in receipts.prefix(2) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.recoveryBackupURL.path))
        }
        for receipt in receipts.suffix(5) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.recoveryBackupURL.path))
            XCTAssertEqual(try Data(contentsOf: receipt.recoveryBackupURL), corruptData)
        }
    }

    func testAutomaticRecoveryFilenameMatcherUsesExactGeneratedGrammar() {
        let matching: [(String, Int)] = [
            ("Pre-Restore Backup 2026-08-13T22-15-01Z.json", 0),
            ("Pre-Restore Backup 2026-08-13T22-15-01Z-1.json", 1),
            ("Pre-Restore Backup 2026-08-13T22-15-01Z-999.json", 999),
            ("Unreadable State 2026-08-13T22-15-01Z.json", 0),
            ("Unreadable State 2026-08-13T22-15-01Z-1.json", 1)
        ]
        for (fileName, suffix) in matching {
            XCTAssertEqual(
                AutomaticRecoveryBackupFilename.parse(fileName)?.collisionSuffix,
                suffix,
                fileName
            )
        }

        let nonMatching = [
            "Pre-Restore Backup important-copy.json",
            "Pre-Restore Backup 2026-08-13.json",
            "Pre-Restore Backup 2026-08-13T22-15-01Z-manual.json",
            "Unreadable State 2026-08-13T22-15-01Z-manual.json",
            "Pre-Restore Backup 2026-08-13T22-15-01Z.txt",
            "my Pre-Restore Backup 2026-08-13T22-15-01Z.json"
        ]
        for fileName in nonMatching {
            XCTAssertNil(AutomaticRecoveryBackupFilename.parse(fileName), fileName)
        }
    }

    func testUnreadableRecoveryCopyCannotBeInspectedAsRestoreCandidate() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(AppState())
        let store = SessionStore(
            persistence: persistence,
            clock: RestoreTestClock(now),
            automaticallyRefresh: false
        )
        let unreadableURL = root.appendingPathComponent(
            "CodePulse/Backups/Unreadable State 2026-08-13T22-15-01Z.json"
        )
        try FileManager.default.createDirectory(
            at: unreadableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ not a backup }".utf8).write(to: unreadableURL, options: .atomic)

        XCTAssertThrowsError(try store.inspectBackup(at: unreadableURL)) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .malformedJSON)
        }
    }

    func testRecoveryRetentionProtectsCurrentBackupAndIgnoresManualPrefixCollisions() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState()
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(stateA)

        let backupDirectory = stateURL.deletingLastPathComponent().appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let manualFiles = [
            "Pre-Restore Backup important-copy.json",
            "Pre-Restore Backup 2026-08-13T22-15-01Z-manual.json"
        ]
        for name in manualFiles {
            try Data("user-owned".utf8).write(to: backupDirectory.appendingPathComponent(name))
        }

        var receipts: [StateRestoreReceipt] = []
        for offset in 0..<5 {
            receipts.append(try persistence.replaceStateTransactionally(
                with: offset.isMultiple(of: 2) ? stateA : stateB,
                recoverySnapshot: stateA,
                exportedAt: now.addingTimeInterval(TimeInterval(offset))
            ))
        }

        let manipulatedDate = Date(timeIntervalSince1970: 4_000_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: manipulatedDate],
            ofItemAtPath: receipts[0].recoveryBackupURL.path
        )

        let current = try persistence.replaceStateTransactionally(
            with: stateB,
            recoverySnapshot: stateA,
            exportedAt: now.addingTimeInterval(5)
        )
        let files = try FileManager.default.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let automatic = files.compactMap { AutomaticRecoveryBackupFilename.parse($0.lastPathComponent) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: current.recoveryBackupURL.path))
        XCTAssertEqual(automatic.count, JSONFilePersistence.automaticRecoveryRetentionCount)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipts[0].recoveryBackupURL.path))
        for receipt in receipts.dropFirst() {
            XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.recoveryBackupURL.path))
        }
        for name in manualFiles {
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupDirectory.appendingPathComponent(name).path))
        }
    }

    func testRecoveryFilenamesUseCollisionSuffixesForSameExportTimestamp() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let state = AppState()
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(state)

        let receipts = try (0..<3).map { _ in
            try persistence.replaceStateTransactionally(
                with: state,
                recoverySnapshot: state,
                exportedAt: now
            )
        }

        XCTAssertEqual(
            receipts.compactMap {
                AutomaticRecoveryBackupFilename.parse($0.recoveryBackupURL.lastPathComponent)?.collisionSuffix
            },
            [0, 1, 2]
        )
    }

    func testManagedSymlinkPathIsRejected() throws {
        let root = try temporaryDirectory()
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let managed = root.appendingPathComponent("managed", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: managed, withDestinationURL: outside)
        let stateURL = managed.appendingPathComponent("state.json")
        let persistence = JSONFilePersistence(fileURL: stateURL)

        XCTAssertThrowsError(try persistence.replaceStateTransactionally(
            with: AppState(),
            recoverySnapshot: AppState(),
            exportedAt: now
        )) { error in
            guard case .unsafeStoragePath = (error as? StatePersistenceError) else {
                return XCTFail("Expected unsafe storage error, got \(error)")
            }
        }
    }

    func testSessionStoreBlocksRestoreWithCurrentActiveSessionAndKeepsMemoryOnFailure() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let active = ActiveSession(startedAt: now)
        let stateA = AppState(activeSession: active)
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(stateA)
        let store = SessionStore(
            persistence: persistence,
            clock: RestoreTestClock(now),
            automaticallyRefresh: false
        )
        let backupURL = root.appendingPathComponent("candidate.json")
        try CodePulseBackupCodec.encode(state: stateB, exportedAt: now).write(to: backupURL)
        let candidate = try store.inspectBackup(at: backupURL)

        XCTAssertThrowsError(try store.restoreBackup(candidate)) { error in
            XCTAssertEqual((error as? BackupRestoreError)?.localizedDescription, "Finish or discard the current session before restoring a backup.")
        }
        XCTAssertEqual(store.state, stateA)
        XCTAssertEqual(persistence.load(), stateA)
    }

    func testSessionStoreBlocksRestoreForRunningPausedAndFinishingSessions() throws {
        var paused = ActiveSession(startedAt: now)
        XCTAssertTrue(paused.pause(at: now.addingTimeInterval(10)))
        var finishing = ActiveSession(startedAt: now)
        XCTAssertTrue(finishing.finish(at: now.addingTimeInterval(10)))

        let cases: [ActiveSession] = [
            ActiveSession(startedAt: now),
            paused,
            finishing
        ]

        for activeSession in cases {
            let root = try temporaryDirectory()
            let stateURL = root.appendingPathComponent("CodePulse/state.json")
            let stateA = AppState(activeSession: activeSession)
            let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
            let persistence = JSONFilePersistence(fileURL: stateURL)
            persistence.save(stateA)
            let store = SessionStore(
                persistence: persistence,
                clock: RestoreTestClock(now),
                automaticallyRefresh: false
            )
            let backupURL = root.appendingPathComponent("candidate.json")
            try CodePulseBackupCodec.encode(state: stateB, exportedAt: now).write(to: backupURL)
            let candidate = try store.inspectBackup(at: backupURL)

            XCTAssertThrowsError(try store.restoreBackup(candidate), "Expected active-session restore to be blocked") { error in
                XCTAssertEqual(
                    (error as? BackupRestoreError)?.localizedDescription,
                    "Finish or discard the current session before restoring a backup."
                )
            }
            XCTAssertEqual(store.state, stateA)
            XCTAssertEqual(persistence.load(), stateA)
        }
    }

    func testSessionStoreCommitsOnlyAfterDurableRestoreAndReloadLoadsCandidate() throws {
        let root = try temporaryDirectory()
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let stateA = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let stateB = AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly))
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(stateA)
        let store = SessionStore(
            persistence: persistence,
            clock: RestoreTestClock(now),
            automaticallyRefresh: false
        )
        let backupURL = root.appendingPathComponent("candidate.json")
        try CodePulseBackupCodec.encode(state: stateB, exportedAt: now).write(to: backupURL)
        let candidate = try store.inspectBackup(at: backupURL)
        let result = try store.restoreBackup(candidate)

        var expectedRestoredState = candidate.state
        expectedRestoredState.localInputAcceptanceDate = now
        XCTAssertEqual(store.state, expectedRestoredState)
        XCTAssertEqual(JSONFilePersistence(fileURL: stateURL).load(), expectedRestoredState)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.recoveryBackupURL.path))

        let failingPersistence = JSONFilePersistence(
            fileURL: stateURL,
            failureInjector: { point in
                if Self.sameFailurePoint(point, .candidateWrite) {
                    throw RestoreInjectedFailure()
                }
            }
        )
        let failingStore = SessionStore(
            persistence: failingPersistence,
            clock: RestoreTestClock(now),
            automaticallyRefresh: false
        )
        let before = failingStore.state
        let candidateForFailure = try failingStore.inspectBackup(at: backupURL)
        XCTAssertThrowsError(try failingStore.restoreBackup(candidateForFailure))
        XCTAssertEqual(failingStore.state, before)
        XCTAssertEqual(failingPersistence.load(), before)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseBackupRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func sameFailurePoint(_ lhs: StateRestoreFailurePoint, _ rhs: StateRestoreFailurePoint) -> Bool {
        switch (lhs, rhs) {
        case (.recoveryWrite, .recoveryWrite),
             (.recoveryVerification, .recoveryVerification),
             (.candidateEncoding, .candidateEncoding),
             (.candidateWrite, .candidateWrite),
             (.candidateVerification, .candidateVerification),
             (.liveReplacement, .liveReplacement),
             (.liveDurability, .liveDurability),
             (.afterLiveReplacement, .afterLiveReplacement),
             (.liveVerification, .liveVerification),
             (.rollbackWrite, .rollbackWrite),
             (.rollbackVerification, .rollbackVerification):
            return true
        default:
            return false
        }
    }
}

private final class RestoreTestClock: SessionClock {
    let now: Date

    init(_ now: Date) {
        self.now = now
    }
}
