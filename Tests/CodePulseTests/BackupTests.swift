import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class BackupTests: XCTestCase {
    func testVersionedBackupRoundTripsState() throws {
        let project = ProjectRecord(
            name: "CodePulse",
            folderPath: "/tmp/codepulse",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        var state = AppState()
        state.projects = [project]
        state.settings.globalShortcutEnabled = false
        state.completedSessions = [CompletedSession(
            id: UUID(),
            projectID: project.id,
            projectName: project.name,
            type: .debugging,
            goal: "Inspect",
            outcome: "Done",
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            endedAt: Date(timeIntervalSince1970: 1_700_000_200),
            pauseIntervals: []
        )]
        let exportedAt = Date(timeIntervalSince1970: 1_700_000_300)

        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: exportedAt)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(object["format"] as? String, "codepulse-backup")
        XCTAssertEqual(object["version"] as? Int, CodePulseBackup.currentVersion)
        let wireState = try XCTUnwrap(object["state"] as? [String: Any])
        XCTAssertEqual(wireState["schemaVersion"] as? Int, 2)
        XCTAssertTrue(wireState.keys.contains("activeSession"))
        XCTAssertTrue(wireState["activeSession"] is NSNull)
        XCTAssertNil(wireState["activeSessions"])

        let backup = try CodePulseBackupCodec.decode(data)
        XCTAssertEqual(backup.format, CodePulseBackup.format)
        XCTAssertEqual(backup.version, CodePulseBackup.currentVersion)
        XCTAssertEqual(backup.exportedAt, exportedAt)
        XCTAssertEqual(backup.state, state)
    }

    func testAutomationConfigurationAndActiveOwnershipAreIncludedInBackup() throws {
        let project = ProjectRecord(
            name: "CodePulse",
            folderPath: "/tmp/codepulse",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let rule = SessionAutomationRule(
            name: "Codex",
            trigger: .developerTool(.codex),
            projectID: project.id,
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 60
        )
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedByTool: .codex,
            lastMatchingSignalAt: Date(timeIntervalSince1970: 1_700_000_000),
            pauseDelay: 10,
            finishDelay: 20,
            minimumSavedDuration: 60,
            claims: [SessionAutomationClaim(
                tool: .codex,
                externalSessionID: "thread-1",
                isActive: true,
                lastSignalAt: Date(timeIntervalSince1970: 1_700_000_000)
            )]
        )
        let active = ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            automationMetadata: metadata
        )
        let state = AppState(
            projects: [project],
            activeSession: active,
            settings: CodePulseSettings(automationEnabled: true),
            automationRules: [rule]
        )

        let data = try CodePulseBackupCodec.encode(
            state: state,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let backup = try CodePulseBackupCodec.decode(data)

        XCTAssertTrue(backup.state.settings.automationEnabled)
        XCTAssertEqual(backup.state.automationRules, [rule])
        XCTAssertEqual(backup.state.activeSession?.automationMetadata, metadata)
    }

    func testBackupV2OneActiveSessionUsesSingularWireFieldAndPreservesIdentity() throws {
        let activeID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        let active = ActiveSession(id: activeID, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let state = AppState(activeSession: active)

        let data = try CodePulseBackupCodec.encode(
            state: state,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let wireState = try XCTUnwrap(root["state"] as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertEqual(wireState["schemaVersion"] as? Int, 2)
        XCTAssertNil(wireState["activeSessions"])
        let wireActive = try XCTUnwrap(wireState["activeSession"] as? [String: Any])
        XCTAssertEqual(wireActive["id"] as? String, activeID.uuidString)

        let imported = try CodePulseBackupCodec.decode(data)
        XCTAssertEqual(imported.state.schemaVersion, CodePulseStateSchema.currentVersion)
        XCTAssertEqual(imported.state.activeSessions, [active])
    }

    func testBackupV2RejectsMultipleActiveSessionsBeforeWritingAFile() throws {
        let state = AppState(activeSessions: [
            ActiveSession(startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
            ActiveSession(startedAt: Date(timeIntervalSince1970: 1_700_000_001))
        ])
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulse-v2-multiple-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        XCTAssertThrowsError(try CodePulseBackupCodec.encode(
            state: state,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .multipleActiveSessionsUnsupported)
            XCTAssertTrue(error.localizedDescription.contains("cannot represent multiple active Sessions"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testBackupV2RejectsActiveSessionsPortableHybrid() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: CodePulseBackupCodec.encode(
                state: AppState(),
                exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ) as? [String: Any])
        root["version"] = CodePulseBackup.currentVersion
        var state = try XCTUnwrap(root["state"] as? [String: Any])
        state["activeSessions"] = []
        state["schemaVersion"] = 2
        root["state"] = state

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(
            try JSONSerialization.data(withJSONObject: root)
        )) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .malformedConfiguration)
        }
    }

    func testBackupV2RejectsSchemaThreePortableState() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: CodePulseBackupCodec.encode(
                state: AppState(),
                exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
            )
        ) as? [String: Any])
        root["version"] = CodePulseBackup.currentVersion
        root["state"] = try XCTUnwrap(JSONSerialization.jsonObject(
            with: encoder.encode(AppState())
        ) as? [String: Any])

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(
            try JSONSerialization.data(withJSONObject: root)
        )) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .missingRequiredField("workspace schema"))
        }
    }

    func testPresetBackedApplicationAutomationAndMixedClaimBackupRoundTrip() throws {
        let project = ProjectRecord(
            name: "CodePulse",
            folderPath: "/tmp/codepulse",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let preset = SessionPreset(name: "Coding", projectID: project.id, goal: "Ship it")
        let application = ApplicationIdentity(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode")
        let rule = SessionAutomationRule(
            name: "Xcode Coding",
            trigger: .applications(ApplicationAutomationTrigger(applications: [application])),
            presetID: preset.id
        )
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedBySource: .application(bundleIdentifier: application.bundleIdentifier),
            lastMatchingSignalAt: Date(timeIntervalSince1970: 1_700_000_000),
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 60,
            claims: [
                SessionAutomationClaim(
                    source: .application(bundleIdentifier: application.bundleIdentifier),
                    isActive: true,
                    lastSignalAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                SessionAutomationClaim(
                    source: .developerTool(tool: .codex, externalSessionID: "thread-1"),
                    isActive: true,
                    lastSignalAt: Date(timeIntervalSince1970: 1_700_000_001)
                )
            ]
        )
        let state = AppState(
            projects: [project],
            activeSession: ActiveSession(
                projectID: project.id,
                projectName: project.name,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                automationMetadata: metadata
            ),
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        )

        let data = try CodePulseBackupCodec.encode(
            state: state,
            exportedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let backup = try CodePulseBackupCodec.decode(data)

        XCTAssertEqual(backup.state.sessionPresets, [preset])
        XCTAssertEqual(backup.state.automationRules, [rule])
        XCTAssertEqual(backup.state.activeSession?.automationMetadata, metadata)
        XCTAssertTrue(text.contains("bundleIdentifier"))
        XCTAssertTrue(text.contains("sessionPresets"))
        XCTAssertFalse(text.contains("frontmostApplicationHistory"))
        XCTAssertFalse(text.contains("applicationActivationLog"))
    }

    func testBackupDecoderRejectsWrongFormatAndVersion() throws {
        let data = try CodePulseBackupCodec.encode(state: AppState(), exportedAt: Date())
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        object["format"] = "not-codepulse"
        let wrongFormat = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(wrongFormat)) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .unsupportedFormat)
        }

        object["format"] = "codepulse-backup"
        object["version"] = 999
        let wrongVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try CodePulseBackupCodec.decode(wrongVersion)) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .unsupportedVersion(999))
        }
    }

    func testControlLedgerIsNotExportedAsUserBackupHistory() throws {
        let commandID = UUID()
        let status = CodePulseControlStatus(
            phase: "idle",
            elapsedSeconds: 0,
            automationControlled: false
        )
        let response = CodePulseControlResponse(
            commandID: commandID,
            result: .success,
            message: "CodePulse status retrieved.",
            status: status
        )
        var state = AppState()
        state.localInputAcceptanceDate = Date(timeIntervalSince1970: 1_800_000_000)
        state.controlProcessing = CodePulseControlProcessingState(processedCommands: [
            CodePulseProcessedControlCommand(
                id: commandID,
                processedAt: Date(timeIntervalSince1970: 1_700_000_000),
                response: response
            )
        ])

        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: Date())
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let backup = try CodePulseBackupCodec.decode(data)

        XCTAssertNil(backup.state.controlProcessing)
        XCTAssertNil(backup.state.localInputAcceptanceDate)
        XCTAssertFalse(text.contains("controlProcessing"))
        XCTAssertFalse(text.contains("localInputAcceptanceDate"))
        XCTAssertFalse(text.contains(commandID.uuidString))
    }
}
