import Foundation

/// User-facing copy for the launch recovery surface.
///
/// This is deliberately independent of SwiftUI so the recovery contract can be
/// exercised without rendering a window and the same concise lifecycle message
/// can be used by `SessionStore` when it records the initial recovery error.
struct RecoveryPresentation: Equatable {
    let title: String
    let explanation: String
    let guidance: String
    let systemImage: String
    let showsUpdateAction: Bool
    let restoreButtonIsProminent: Bool
    let restoreAccessibilityHint: String
    let dataFolderAccessibilityHint: String
    let quitAccessibilityHint: String
    let lifecycleMessage: String

    static func forStatus(_ status: StateLoadStatus) -> Self {
        switch status {
        case .newerSchemaVersion(let version):
            return Self(
                title: "CodePulse Needs a Newer Version",
                explanation: "This saved data was created with a newer CodePulse state format (version \(version)). Update CodePulse to open it. The original state file has been left unchanged and is read-only.",
                guidance: "Install a newer version of CodePulse, then relaunch it. You can also restore an older backup if you need to continue in this version.",
                systemImage: "arrow.up.circle",
                showsUpdateAction: true,
                restoreButtonIsProminent: false,
                restoreAccessibilityHint: "Selects and reviews a backup. The newer saved data remains unchanged until you update CodePulse.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without changing the newer saved data.",
                quitAccessibilityHint: "Quits CodePulse without changing the newer saved data.",
                lifecycleMessage: "CodePulse needs a newer version to open its saved data. The original state file was left unchanged."
            )

        case .invalidState:
            return Self(
                title: "CodePulse Found Invalid Saved Data",
                explanation: "CodePulse found saved data that does not pass its integrity checks. The original state file has been left unchanged and is read-only.",
                guidance: "Restore a valid backup to continue using CodePulse, or open the data folder to preserve and inspect the original file yourself.",
                systemImage: "exclamationmark.triangle",
                showsUpdateAction: false,
                restoreButtonIsProminent: true,
                restoreAccessibilityHint: "Selects and reviews a valid CodePulse backup before replacing the invalid saved data.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without changing its contents.",
                quitAccessibilityHint: "Quits CodePulse without changing the invalid saved data.",
                lifecycleMessage: "CodePulse found invalid saved data. The original state file was left unchanged."
            )

        case .migrationFailed:
            return Self(
                title: "CodePulse Couldn't Finish Updating Its Saved Data",
                explanation: "CodePulse could not safely finish updating its saved data. The original state file has been left unchanged and is read-only.",
                guidance: "Relaunch CodePulse to try the update again, or restore a valid backup to continue. You can also open the data folder to preserve and inspect the original file.",
                systemImage: "arrow.triangle.2.circlepath",
                showsUpdateAction: false,
                restoreButtonIsProminent: false,
                restoreAccessibilityHint: "Selects and reviews a valid CodePulse backup before replacing the unchanged saved data.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without changing its contents.",
                quitAccessibilityHint: "Quits CodePulse without changing the saved data.",
                lifecycleMessage: "CodePulse could not finish updating its saved data. The original state file was left unchanged."
            )

        case .migrationRollbackFailed:
            return Self(
                title: "CodePulse Couldn't Restore Its Previous Saved Data",
                explanation: "CodePulse could not finish updating its saved data or restore the previous state. It cannot verify which state is on disk, so all writes have been stopped.",
                guidance: "Quit CodePulse and preserve the data folder before continuing. Restore a known-good backup only when you are ready to replace the current file.",
                systemImage: "exclamationmark.shield",
                showsUpdateAction: false,
                restoreButtonIsProminent: false,
                restoreAccessibilityHint: "Selects and reviews a valid CodePulse backup before replacing the unverified saved data.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without making further changes.",
                quitAccessibilityHint: "Quits CodePulse without making further changes to the saved data.",
                lifecycleMessage: "CodePulse could not finish updating or restore its previous saved data. It cannot verify which state is on disk, so all writes were stopped."
            )

        case .unsafePath:
            return Self(
                title: "CodePulse Can't Safely Access Its Saved Data",
                explanation: "CodePulse could not safely access its local storage path. Your existing data has not been changed, and CodePulse is in read-only recovery mode.",
                guidance: "Open the data folder to inspect its location, or restore a valid backup after choosing a safe local storage path.",
                systemImage: "lock.shield",
                showsUpdateAction: false,
                restoreButtonIsProminent: false,
                restoreAccessibilityHint: "Selects and reviews a valid CodePulse backup without changing the existing data until you confirm.",
                dataFolderAccessibilityHint: "Reveals the configured CodePulse data folder without changing its contents.",
                quitAccessibilityHint: "Quits CodePulse without changing the existing data.",
                lifecycleMessage: "CodePulse could not safely access its saved data. The original state file was left unchanged."
            )

        case .unreadable:
            return Self(
                title: "CodePulse Couldn't Read Its Saved Data",
                explanation: "CodePulse could not safely read or verify its saved data. It has stopped all writes and entered read-only recovery mode.",
                guidance: "Restore a backup to continue using CodePulse, or open the data folder to preserve and inspect the original file yourself.",
                systemImage: "exclamationmark.triangle",
                showsUpdateAction: false,
                restoreButtonIsProminent: true,
                restoreAccessibilityHint: "Selects and reviews a valid CodePulse backup before replacing the unreadable saved data.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without changing its contents.",
                quitAccessibilityHint: "Quits CodePulse without changing the unreadable saved data.",
                lifecycleMessage: "CodePulse could not safely read or verify its saved data. All writes were stopped."
            )

        case .missing:
            return Self(
                title: "CodePulse Has No Saved Data",
                explanation: "CodePulse did not find an existing state file, so there is no saved data to recover.",
                guidance: "Restore a backup if you need to recover previous work, or continue with a new CodePulse state.",
                systemImage: "doc.badge.plus",
                showsUpdateAction: false,
                restoreButtonIsProminent: false,
                restoreAccessibilityHint: "Selects and reviews a CodePulse backup without changing any existing saved data.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without changing its contents.",
                quitAccessibilityHint: "Quits CodePulse without changing any saved data.",
                lifecycleMessage: "CodePulse did not find a saved data file."
            )

        case .notLoaded:
            return Self(
                title: "CodePulse Is Loading Its Saved Data",
                explanation: "CodePulse has not finished loading its saved data yet.",
                guidance: "Wait for CodePulse to finish loading, then try again.",
                systemImage: "hourglass",
                showsUpdateAction: false,
                restoreButtonIsProminent: false,
                restoreAccessibilityHint: "Selects and reviews a CodePulse backup.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without changing its contents.",
                quitAccessibilityHint: "Quits CodePulse without changing its saved data.",
                lifecycleMessage: "CodePulse has not finished loading its saved data."
            )

        case .loaded:
            return Self(
                title: "CodePulse Is Ready",
                explanation: "CodePulse loaded its saved data successfully.",
                guidance: "Continue using CodePulse.",
                systemImage: "checkmark.circle",
                showsUpdateAction: false,
                restoreButtonIsProminent: false,
                restoreAccessibilityHint: "Selects and reviews a CodePulse backup.",
                dataFolderAccessibilityHint: "Reveals the local CodePulse data folder without changing its contents.",
                quitAccessibilityHint: "Quits CodePulse.",
                lifecycleMessage: "CodePulse loaded its saved data successfully."
            )
        }
    }

    static func backupConfirmationMessage(for preview: CodePulseBackupPreview) -> String {
        var lines = [
            "Format: \(preview.format) v\(preview.version)",
            "Exported: \(preview.exportedAt.formatted(date: .abbreviated, time: .shortened))",
            "\(preview.projectCount) \(preview.projectCount == 1 ? "project" : "projects")",
            "\(preview.completedSessionCount) \(preview.completedSessionCount == 1 ? "saved session" : "saved sessions")"
        ]
        if let activeSessionSummary = activeSessionSummary(count: preview.activeSessionCount) {
            lines.append(activeSessionSummary)
        }
        return lines.joined(separator: "\n")
    }

    static func activeSessionSummary(count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? "active session" : "active sessions")"
    }
}
