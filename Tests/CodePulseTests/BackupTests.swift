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
        XCTAssertEqual(object["version"] as? Int, 1)

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
}
