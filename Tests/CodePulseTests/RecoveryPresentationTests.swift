import Foundation
import XCTest
@testable import CodePulse

final class RecoveryPresentationTests: XCTestCase {
    func testNewerSchemaRequiresUpdateAndKeepsRestoreSecondary() {
        let version = CodePulseStateSchema.currentVersion + 1
        let presentation = RecoveryPresentation.forStatus(.newerSchemaVersion(version))

        XCTAssertEqual(presentation.title, "CodePulse Needs a Newer Version")
        XCTAssertTrue(presentation.explanation.contains("version \(version)"))
        XCTAssertTrue(presentation.explanation.contains("left unchanged"))
        XCTAssertTrue(presentation.explanation.contains("read-only"))
        XCTAssertTrue(presentation.guidance.contains("newer version"))
        XCTAssertTrue(presentation.showsUpdateAction)
        XCTAssertFalse(presentation.restoreButtonIsProminent)
        XCTAssertTrue(presentation.lifecycleMessage.contains("needs a newer version"))
    }

    func testRecoveryStatusesKeepSpecificGuidanceAndRestorePriority() {
        let invalid = RecoveryPresentation.forStatus(.invalidState)
        XCTAssertEqual(invalid.title, "CodePulse Found Invalid Saved Data")
        XCTAssertFalse(invalid.showsUpdateAction)
        XCTAssertTrue(invalid.restoreButtonIsProminent)
        XCTAssertTrue(invalid.explanation.contains("integrity checks"))
        XCTAssertTrue(invalid.lifecycleMessage.contains("invalid saved data"))

        let unreadable = RecoveryPresentation.forStatus(.unreadable)
        XCTAssertEqual(unreadable.title, "CodePulse Couldn't Read Its Saved Data")
        XCTAssertTrue(unreadable.restoreButtonIsProminent)

        let unsafePath = RecoveryPresentation.forStatus(.unsafePath)
        XCTAssertEqual(unsafePath.title, "CodePulse Can't Safely Access Its Saved Data")
        XCTAssertFalse(unsafePath.restoreButtonIsProminent)
        XCTAssertTrue(unsafePath.explanation.contains("not been changed"))

        let migrationFailed = RecoveryPresentation.forStatus(.migrationFailed)
        XCTAssertEqual(migrationFailed.title, "CodePulse Couldn't Finish Updating Its Saved Data")
        XCTAssertFalse(migrationFailed.restoreButtonIsProminent)
        XCTAssertTrue(migrationFailed.guidance.contains("Relaunch CodePulse"))

        let rollbackFailed = RecoveryPresentation.forStatus(.migrationRollbackFailed)
        XCTAssertEqual(rollbackFailed.title, "CodePulse Couldn't Restore Its Previous Saved Data")
        XCTAssertFalse(rollbackFailed.restoreButtonIsProminent)
        XCTAssertTrue(rollbackFailed.explanation.contains("cannot verify which state is on disk"))
        XCTAssertFalse(rollbackFailed.explanation.contains("left unchanged"))
    }

    func testActiveSessionSummaryUsesExactCountAndPluralization() {
        XCTAssertNil(RecoveryPresentation.activeSessionSummary(count: 0))
        XCTAssertEqual(
            RecoveryPresentation.activeSessionSummary(count: 1),
            "1 active session"
        )
        XCTAssertEqual(
            RecoveryPresentation.activeSessionSummary(count: 2),
            "2 active sessions"
        )
    }

    func testBackupConfirmationMessageUsesPreviewActiveSessionCount() {
        let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let state = AppState(activeSessions: [
            ActiveSession(startedAt: exportedAt),
            ActiveSession(startedAt: exportedAt.addingTimeInterval(1))
        ])
        let preview = CodePulseBackupPreview(
            backup: CodePulseBackup(exportedAt: exportedAt, state: state),
            state: state
        )

        let message = RecoveryPresentation.backupConfirmationMessage(for: preview)

        XCTAssertTrue(message.contains("2 active sessions"))
        XCTAssertFalse(message.contains("1 active session"))
    }
}
