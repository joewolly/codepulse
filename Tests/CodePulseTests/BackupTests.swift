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
